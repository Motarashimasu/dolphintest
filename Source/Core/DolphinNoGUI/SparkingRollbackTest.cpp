// Copyright 2026 Dolphin-Sparking Project
// SPDX-License-Identifier: GPL-2.0-or-later

#include "DolphinNoGUI/SparkingRollbackTest.h"

#include <algorithm>
#include <chrono>
#include <cstring>
#include <mutex>
#include <span>
#include <string_view>
#include <vector>

#include <fmt/format.h>

#include "Common/Buffer.h"
#include "Common/FileUtil.h"
#include "Common/IOFile.h"
#include "Common/StringUtil.h"
#include "Common/HookableEvent.h"
#include "Core/Config/GraphicsSettings.h"
#include "Core/Config/MainSettings.h"
#include "Core/Core.h"
#include "Core/CoreTiming.h"
#include "Core/GeckoCode.h"
#include "Core/HW/CPU.h"
#include "Core/HW/DSP.h"
#include "Core/HW/Memmap.h"
#include "Core/HW/SI/SI_DeviceGCController.h"
#include "Core/IOS/IOS.h"
#include "Core/PowerPC/JitInterface.h"
#include "Core/State.h"
#include "Core/System.h"
#include "DolphinNoGUI/SparkingIO.h"
#include "DolphinNoGUI/SparkingWatch.h"
#include "InputCommon/GCPadStatus.h"
#include "VideoCommon/EFBInterface.h"
#include "VideoCommon/Present.h"
#include "VideoCommon/VideoEvents.h"

namespace Sparking
{
namespace
{
using Clock = std::chrono::steady_clock;

enum class Phase
{
  Off,
  Starting,   // booted: waiting for deterministic emulation to be switched on
  Idle,       // playing normally until the next test
  Recording,  // first pass after the save: inputs recorded
  Replaying,  // second pass after the rewind: inputs replayed
};

struct Poll
{
  int device;
  GCPadStatus status;
};

struct Stat
{
  double total = 0, max = 0;
  int n = 0;
  void Add(double v)
  {
    total += v;
    max = std::max(max, v);
    ++n;
  }
  double Avg() const { return n ? total / n : 0; }
};

// All of this is touched on the CPU thread only (field hook, pad hook, CPU-thread jobs).
Phase s_phase = Phase::Off;
int s_depth = 4;
int s_gap = 20;
int s_fields = 0;     // fields since the current phase began
u64 s_field_no = 0;   // fields since boot (first pass numbering)
u64 s_cycle_start_field = 0;
Common::UniqueBuffer<u8> s_state;
std::size_t s_state_size = 0;
std::vector<Poll> s_polls;
std::size_t s_replay_at = 0;
bool s_input_mismatch = false;
std::vector<u8> s_mem1_first, s_aram_first;
Clock::time_point s_replay_start;
float s_saved_speed = 1.0f;
int s_cycles = 0, s_mismatches = 0;
Stat s_save, s_load, s_resim;  // ms; s_resim per field
std::vector<double> s_recent_resim;  // the last 20 re-runs (ms per field)
int s_extra_polls = 0;               // polls in a re-run beyond the recorded ones
Clock::time_point s_test_start;
// Traced words (--rollback-trace, plus the first differing spots of each mismatch): their value
// at every field of the first run and of the re-run.
// Everything the emulator did in each run, in order: events that ran (name, time, how late,
// userdata) and IPC commands IOS handled (device, command, time, reply delay). On a mismatch the
// first place the two runs part ways is reported.
std::vector<std::string> s_log_first, s_log_re;
std::vector<std::string>* s_log_into = nullptr;

void OnEvent(const std::string& name, s64 time, s64 late, u64 userdata)
{
  if (s_log_into && s_log_into->size() < 200000)
    s_log_into->push_back(fmt::format("event {} t={} late={} data={:x}", name, time, late, userdata));
}

void OnIPC(u32 address, u32 command, u32 fd, const std::string& device, s64 now, s64 delay)
{
  if (s_log_into && s_log_into->size() < 200000)
  {
    s_log_into->push_back(fmt::format("ipc {} cmd={} fd={} at={:x} t={} reply_in={}", device,
                                      command, fd, address, now, delay));
  }
}

// What the CPU got from the GPU goes into the same list (EFB peeks, bounding box, GPU counters:
// the EFB isn't restored by a rewind unless "Rewind graphics too" is on). EFB copies the GPU
// writes into RAM (address, size, hash) happen on the GPU thread: they get their own list.
std::mutex s_gpu_log_lock;
std::vector<std::string> s_gpu_first, s_gpu_re;
std::vector<std::string>* s_gpu_into = nullptr;

void OnGpu(const char* what, u32 a, u32 b, u64 c)
{
  if (std::string_view(what) == "efb_copy")
  {
    std::lock_guard lock(s_gpu_log_lock);
    if (s_gpu_into && s_gpu_into->size() < 200000)
      s_gpu_into->push_back(fmt::format("efb_copy to={:x} bytes={} hash={:x}", a, b, c));
    return;
  }
  if (s_log_into && s_log_into->size() < 200000)
    s_log_into->push_back(fmt::format("{} {:x} = {:x}", what, a, b));
}

void LogInto(std::vector<std::string>* cpu, std::vector<std::string>* gpu)
{
  s_log_into = cpu;
  std::lock_guard lock(s_gpu_log_lock);
  s_gpu_into = gpu;
}

// The first entries where the two runs differ (with a little context), as JSON.
std::string FirstDivergence(const std::vector<std::string>& first,
                            const std::vector<std::string>& re)
{
  std::size_t i = 0;
  while (i < first.size() && i < re.size() && first[i] == re[i])
    ++i;
  const auto slice = [i](const std::vector<std::string>& v) {
    std::vector<std::string> out;
    for (std::size_t k = i >= 3 ? i - 3 : 0; k < v.size() && k < i + 6; ++k)
      out.push_back(Json::Escape((k == i ? ">> " : "   ") + v[k]));
    return JsonArray(out);
  };
  std::size_t peeks = 0;
  for (const std::string& e : first)
    peeks += e.starts_with("efb_peek") || e.starts_with("bbox") || e.starts_with("gpu_counter");
  return Json()
      .Add("same", i == first.size() && i == re.size())
      .Add("index", static_cast<int64_t>(i))
      .Add("first_run_entries", static_cast<int64_t>(first.size()))
      .Add("re_run_entries", static_cast<int64_t>(re.size()))
      .Add("gpu_reads_first_run", static_cast<int64_t>(peeks))
      .AddRaw("first_run", slice(first))
      .AddRaw("re_run", slice(re))
      .Str();
}

std::vector<u32> s_trace;
bool s_keep_jit = true;  // keep the compiled code across rewinds (--rollback-recompile: don't)
// The emulator's scheduled events (what happens when: disc reads, IOS replies, audio DMA, ...)
// at the save, right after the rewind's load, and at the end of each run.
std::string s_events_save, s_events_loaded, s_events_first_end;

std::string Events(Core::System& system)
{
  return system.GetCoreTiming().GetScheduledEventsSummary();
}

// Lines of `a` that aren't in `b` (at most 10), as a JSON array of strings.
std::string OnlyIn(const std::string& a, const std::string& b)
{
  std::vector<std::string> out;
  const auto lines_b = SplitString(b, '\n');
  for (const std::string& line : SplitString(a, '\n'))
  {
    if (!line.empty() && out.size() < 10 && std::ranges::find(lines_b, line) == lines_b.end())
      out.push_back(Json::Escape(line));
  }
  return JsonArray(out);
}
std::vector<std::vector<u32>> s_trace_first, s_trace_re;

void TraceField(std::vector<std::vector<u32>>* into)
{
  if (s_trace.empty())
    return;
  auto& memory = Core::System::GetInstance().GetMemory();
  into->resize(s_trace.size());
  for (std::size_t i = 0; i < s_trace.size(); ++i)
    (*into)[i].push_back(memory.Read_U32(s_trace[i]));
}

std::string TraceJson()
{
  std::vector<std::string> out;
  const auto list = [](const std::vector<std::vector<u32>>& v, std::size_t i) {
    std::vector<std::string> items;
    if (i < v.size())
    {
      for (const u32 x : v[i])
        items.push_back(fmt::format("\"{:08X}\"", x));
    }
    return JsonArray(items);
  };
  for (std::size_t i = 0; i < s_trace.size(); ++i)
  {
    out.push_back(fmt::format("{{\"address\":\"0x{:08X}\",\"first_run\":{},\"re_run\":{}}}",
                              s_trace[i], list(s_trace_first, i), list(s_trace_re, i)));
  }
  return JsonArray(out);
}
std::string s_log_path;
Common::EventHook s_field_hook;

void Log(const std::string& line)
{
  if (s_log_path.empty())
    return;
  File::IOFile f(s_log_path, "ab");
  f.WriteString(line + "\n");
}

void EmitLogged(std::string_view event, const Json& json)
{
  Emit(event, json);
  Log(fmt::format("{{\"event\":\"{}\",{}", event, json.Str().substr(1)));
}

double Ms(Clock::time_point a, Clock::time_point b)
{
  return std::chrono::duration<double, std::milli>(b - a).count();
}

// How many fields this PC could re-run inside one field (16.7 ms), after saving that field's
// state and loading the rewind state: rollback netplay's budget. -1 = not measured yet.
int MaxRollbackFields()
{
  if (!s_resim.n || s_resim.Avg() <= 0)
    return -1;
  constexpr double FIELD_MS = 1000.0 / 59.94;
  const double left = FIELD_MS - s_save.Avg() - s_load.Avg();
  // One field is the normal one (the present); the rest can be re-runs.
  return std::max(0, static_cast<int>(left / s_resim.Avg()) - 1);
}

void EmitStats()
{
  EmitLogged("rollback_test_stats",
             Json()
                 .Add("cycles", s_cycles)
                 .Add("mismatches", s_mismatches)
                 .AddRaw("save_ms", fmt::format("{:.2f}", s_save.Avg()))
                 .AddRaw("save_ms_max", fmt::format("{:.2f}", s_save.max))
                 .AddRaw("load_ms", fmt::format("{:.2f}", s_load.Avg()))
                 .AddRaw("load_ms_max", fmt::format("{:.2f}", s_load.max))
                 .AddRaw("rerun_ms_per_field", fmt::format("{:.2f}", s_resim.Avg()))
                 .AddRaw("rerun_ms_per_field_max", fmt::format("{:.2f}", s_resim.max))
                 .AddRaw("rerun_ms_recent", fmt::format("{:.2f}", [] {
                   double t = 0;
                   for (double v : s_recent_resim)
                     t += v;
                   return s_recent_resim.empty() ? 0.0 : t / s_recent_resim.size();
                 }()))
                 .Add("state_kb", static_cast<int64_t>(s_state_size / 1024))
                 .Add("max_rollback_fields", MaxRollbackFields()));
}

void CopyGameMemory(Core::System& system, std::vector<u8>* mem1, std::vector<u8>* aram)
{
  auto& memory = system.GetMemory();
  const u8* ram = memory.GetRAM();
  mem1->assign(ram, ram + memory.GetRamSizeReal());
  const u8* a = system.GetDSP().GetARAMPtr();
  if (a)
    aram->assign(a, a + DSP::ARAM_SIZE);
  else
    aram->clear();
}

// Differing 32-byte lines of MEM1, merged into ranges (the first 16), as JSON.
std::string DiffRanges(const std::vector<u8>& a, const u8* b, std::size_t size, u64* total,
                       std::vector<std::size_t>* starts)
{
  constexpr std::size_t LINE = 32;
  std::vector<std::string> ranges;
  *total = 0;
  std::size_t start = 0, end = 0;
  bool open = false;
  const auto close = [&] {
    if (open && ranges.size() < 16)
    {
      ranges.push_back(fmt::format("{{\"address\":\"0x{:08X}\",\"bytes\":{}}}",
                                   0x80000000u + static_cast<u32>(start), end - start));
      starts->push_back(start);
    }
    open = false;
  };
  for (std::size_t at = 0; at < size; at += LINE)
  {
    const std::size_t n = std::min(LINE, size - at);
    if (std::memcmp(a.data() + at, b + at, n) == 0)
      continue;
    for (std::size_t i = 0; i < n; ++i)
      *total += a[at + i] != b[at + i];
    if (open && at <= end + LINE * 4)  // nearby differences: one range
    {
      end = at + n;
      continue;
    }
    close();
    start = at;
    end = at + n;
    open = true;
  }
  close();
  return JsonArray(ranges);
}

std::string Hex(const u8* p, std::size_t n)
{
  std::string out;
  for (std::size_t i = 0; i < n; ++i)
    out += fmt::format("{:02X}", p[i]);
  return out;
}

// The first differing bytes of the first ranges, first run vs re-run (to see what the data is).
std::string Samples(const std::vector<u8>& a, const u8* b, std::size_t size,
                    const std::vector<std::size_t>& starts)
{
  std::vector<std::string> out;
  for (std::size_t k = 0; k < starts.size() && k < 6; ++k)
  {
    std::size_t at = starts[k];
    while (at < size && a[at] == b[at])
      ++at;
    at &= ~std::size_t{3};
    const std::size_t n = std::min<std::size_t>(16, size - at);
    out.push_back(fmt::format("{{\"address\":\"0x{:08X}\",\"first_run\":\"{}\",\"re_run\":\"{}\"}}",
                              0x80000000u + static_cast<u32>(at), Hex(a.data() + at, n),
                              Hex(b + at, n)));
  }
  return JsonArray(out);
}

void Resume(Core::System& system)
{
  system.GetCPU().SetStepping(false);
}

// --- the three steps, each a CPU-thread job with the CPU stopped right after a field ---------

void JobSave(Core::System& system)
{
  const auto t0 = Clock::now();
  s_state_size = State::SaveToMemory(system, s_state);
  s_events_save = Events(system);
  s_save.Add(Ms(t0, Clock::now()));
  if (s_state_size == 0)
  {
    EmitLogged("rollback_mismatch", Json().Add("error", "save_failed"));
    s_phase = Phase::Idle;
  }
  else
  {
    s_polls.clear();
    s_input_mismatch = false;
    s_trace_first.clear();
    s_trace_re.clear();
    s_log_first.clear();
    s_log_re.clear();
    {
      std::lock_guard lock(s_gpu_log_lock);
      s_gpu_first.clear();
      s_gpu_re.clear();
    }
    LogInto(&s_log_first, &s_gpu_first);
    s_cycle_start_field = s_field_no;
    s_phase = Phase::Recording;
  }
  s_fields = 0;
  Resume(system);
}

void JobRewind(Core::System& system)
{
  CopyGameMemory(system, &s_mem1_first, &s_aram_first);
  s_events_first_end = Events(system);
  const auto t0 = Clock::now();
  Gecko::SetReinstallOnLoad(false);  // same session, same codes: leave the handler as it was
  system.GetJitInterface().SetKeepCacheOnLoad(s_keep_jit);
  const bool ok = State::LoadFromMemory(system, std::span<u8>(s_state.data(), s_state_size));
  system.GetJitInterface().SetKeepCacheOnLoad(false);
  Gecko::SetReinstallOnLoad(true);
  s_events_loaded = Events(system);
  LogInto(&s_log_re, &s_gpu_re);
  s_load.Add(Ms(t0, Clock::now()));
  if (!ok)
  {
    EmitLogged("rollback_mismatch", Json().Add("error", "load_failed"));
    LogInto(nullptr, nullptr);
    s_phase = Phase::Idle;
    s_fields = 0;
    Resume(system);
    return;
  }
  // Re-run as fast as possible, like rollback netcode does.
  s_saved_speed = Config::Get(Config::MAIN_EMULATION_SPEED);
  Config::SetCurrent(Config::MAIN_EMULATION_SPEED, 0.0f);
  s_replay_at = 0;
  s_extra_polls = 0;
  VideoCommon::g_sparking_skip_present = true;  // re-runs aren't shown, like real rollback
  s_phase = Phase::Replaying;
  s_fields = 0;
  s_replay_start = Clock::now();
  Resume(system);
}

void JobCompare(Core::System& system)
{
  const double rerun = Ms(s_replay_start, Clock::now()) / s_depth;
  s_resim.Add(rerun);
  s_recent_resim.push_back(rerun);
  if (s_recent_resim.size() > 20)
    s_recent_resim.erase(s_recent_resim.begin());
  Config::SetCurrent(Config::MAIN_EMULATION_SPEED, s_saved_speed);
  VideoCommon::g_sparking_skip_present = false;
  ++s_cycles;

  auto& memory = system.GetMemory();
  const std::string events_re_end = Events(system);
  LogInto(nullptr, nullptr);
  u64 mem1_diff = 0, aram_diff = 0;
  const std::size_t mem1_size = std::min<std::size_t>(s_mem1_first.size(), memory.GetRamSizeReal());
  std::vector<std::size_t> starts;
  const std::string ranges =
      DiffRanges(s_mem1_first, memory.GetRAM(), mem1_size, &mem1_diff, &starts);
  const u8* aram = system.GetDSP().GetARAMPtr();
  if (aram && s_aram_first.size() == DSP::ARAM_SIZE)
  {
    for (std::size_t i = 0; i < DSP::ARAM_SIZE; i += 4096)
    {
      if (std::memcmp(s_aram_first.data() + i, aram + i, 4096) != 0)
      {
        for (std::size_t j = i; j < i + 4096; ++j)
          aram_diff += s_aram_first[j] != aram[j];
      }
    }
  }
  const bool unused_inputs = s_replay_at != s_polls.size();
  if (mem1_diff || aram_diff || s_input_mismatch || unused_inputs)
  {
    ++s_mismatches;
    EmitLogged("rollback_mismatch",
               Json()
                   .Add("cycle", s_cycles)
                   .Add("field", static_cast<int64_t>(s_cycle_start_field))
                   .Add("mem1_bytes", static_cast<int64_t>(mem1_diff))
                   .AddRaw("mem1", ranges)
                   .Add("aram_bytes", static_cast<int64_t>(aram_diff))
                   .Add("input_mismatch", s_input_mismatch || unused_inputs)
                   .Add("polls", static_cast<int64_t>(s_polls.size()))
                   .Add("polls_replayed", static_cast<int64_t>(s_replay_at))
                   .Add("polls_extra", s_extra_polls)
                   .AddRaw("seconds", fmt::format("{:.1f}", Ms(s_test_start, Clock::now()) / 1000))
                   .Add("state_kb", static_cast<int64_t>(s_state_size / 1024))
                   .AddRaw("watches", WatchValuesJson())
                   .AddRaw("samples", Samples(s_mem1_first, memory.GetRAM(), mem1_size, starts))
                   .AddRaw("trace", TraceJson())
                   .Add("events_restored", s_events_loaded == s_events_save)
                   .AddRaw("events_lost_by_load", OnlyIn(s_events_save, s_events_loaded))
                   .AddRaw("events_added_by_load", OnlyIn(s_events_loaded, s_events_save))
                   .AddRaw("events_only_first_run", OnlyIn(s_events_first_end, events_re_end))
                   .AddRaw("events_only_re_run", OnlyIn(events_re_end, s_events_first_end))
                   .AddRaw("first_divergence", FirstDivergence(s_log_first, s_log_re))
                   .AddRaw("gpu_copies_divergence", FirstDivergence(s_gpu_first, s_gpu_re)));
    // Follow the first differing spots from now on (their values field by field).
    for (std::size_t k = 0; k < starts.size() && k < 4 && s_trace.size() < 12; ++k)
    {
      std::size_t at = starts[k];
      while (at < mem1_size && s_mem1_first[at] == memory.GetRAM()[at])
        ++at;
      const u32 addr = 0x80000000u + static_cast<u32>(at & ~std::size_t{3});
      if (std::ranges::find(s_trace, addr) == s_trace.end())
        s_trace.push_back(addr);
    }
  }
  if (s_cycles <= 3 || s_cycles % 20 == 0 || mem1_diff || aram_diff)
    EmitStats();
  s_phase = Phase::Idle;
  s_fields = 0;
  Resume(system);
}

// After a field ends, stop the CPU right there and run `job` (the same point every time).
void AtThisField(void (*job)(Core::System&))
{
  auto& system = Core::System::GetInstance();
  system.GetCPU().AddCPUThreadJob([job, &system] { job(system); });
  system.GetCPU().Break();
}

void OnField()
{
  switch (s_phase)
  {
  case Phase::Off:
    return;
  case Phase::Starting:
    // After boot, not before: deterministic mode at boot would give a Wii game a temporary,
    // empty NAND (as in netplay), without the player's save. Switch it on from the host thread.
    if (++s_fields == 30)
    {
      Core::QueueHostJob([](Core::System& system) {
        Core::SetForceDeterminism(true);  // as in netplay (GPU thread in sync, clock, ...)
        Core::UpdateWantDeterminism(system);
        Core::RunOnCPUThread(system, [] {
          s_phase = Phase::Idle;
          s_fields = 0;
        });
      });
    }
    return;
  case Phase::Idle:
    ++s_field_no;
    if (++s_fields >= s_gap)
      AtThisField(JobSave);
    return;
  case Phase::Recording:
    ++s_field_no;
    TraceField(&s_trace_first);
    if (++s_fields >= s_depth)
      AtThisField(JobRewind);
    return;
  case Phase::Replaying:
    TraceField(&s_trace_re);
    if (++s_fields >= s_depth)
      AtThisField(JobCompare);
    return;
  }
}

void OnPad(int device, GCPadStatus* status)
{
  if (s_phase == Phase::Recording)
  {
    s_polls.push_back({device, *status});
  }
  else if (s_phase == Phase::Replaying)
  {
    if (s_replay_at < s_polls.size() && s_polls[s_replay_at].device == device)
      *status = s_polls[s_replay_at++].status;
    else
    {
      s_input_mismatch = true;  // the game polled differently the second time
      ++s_extra_polls;
    }
  }
}
}  // namespace

void InitRollbackTest(int fields, int gap, const std::string& log_path,
                      const std::vector<u32>& trace, bool keep_jit)
{
  s_keep_jit = keep_jit;
  s_trace = trace;
  s_depth = std::clamp(fields, 1, 16);
  s_gap = std::clamp(gap, 1, 600);
  s_log_path = log_path;
  if (!s_log_path.empty())
    File::CreateFullPath(s_log_path);
  s_phase = Phase::Starting;
  s_fields = 0;
  s_test_start = Clock::now();
  g_sparking_pad_hook = &OnPad;
  CoreTiming::g_sparking_event_hook = &OnEvent;
  IOS::HLE::g_sparking_ipc_hook = &OnIPC;
  g_sparking_gpu_hook = &OnGpu;
  s_field_hook = Core::System::GetInstance().GetVideoEvents().vi_end_field_event.Register(
      [] { OnField(); });
  EmitLogged("rollback_test", Json()
                                  .Add("state", "started")
                                  .Add("fields", s_depth)
                                  .Add("gap", s_gap)
                                  .Add("gpu_state", Config::Get(Config::GFX_SAVE_TEXTURE_CACHE_TO_STATE))
                                  .Add("keep_jit", s_keep_jit)
                                  .Add("log", s_log_path));
}

bool RollbackTestActive()
{
  return s_phase != Phase::Off;
}
}  // namespace Sparking
