// Copyright 2026 Dolphin-Sparking Project
// SPDX-License-Identifier: GPL-2.0-or-later

#include "Core/NeoCode.h"

#include <algorithm>
#include <atomic>
#include <chrono>
#include <deque>
#include <limits>
#include <span>
#include <vector>

#include "Common/Buffer.h"
#include "Common/Hash.h"
#include "Common/HookableEvent.h"
#include "Common/Logging/Log.h"
#include "Core/Config/MainSettings.h"
#include "Core/CoreTiming.h"
#include "Core/GeckoCode.h"
#include "Core/HW/CPU.h"
#include "Core/HW/Memmap.h"
#include "Core/PowerPC/JitInterface.h"
#include "Core/State.h"
#include "Core/System.h"
#include "VideoCommon/Fifo.h"
#include "VideoCommon/Present.h"
#include "VideoCommon/VideoEvents.h"

namespace NeoCode
{
namespace
{
using Clock = std::chrono::steady_clock;
constexpr u64 NONE = std::numeric_limits<u64>::max();
constexpr std::size_t MAX_RECORDS = MAX_ROLLBACK_FIELDS + 3;

struct Entry
{
  GCPadStatus value;
  bool confirmed = false;
};

// The state at the end of a field (= the start of the next one).
struct Record
{
  u64 field = 0;
  u64 ticks = 0;
  std::array<u64, 4> poll{};  // each pad's next poll index
  u64 snapshot = 0;           // memory snapshot id
  Common::UniqueBuffer<u8> state;
  std::size_t state_size = 0;
  std::string side;
};

struct PendingChecksum
{
  u64 field = 0;
  u64 ticks = 0;
  u64 checksum = 0;
};

std::atomic<bool> s_active{false};
std::function<void()> s_drain;
Callbacks s_cb;
Common::EventHook s_field_hook;

// CPU thread.
std::array<std::deque<Entry>, 4> s_log;
std::array<u64, 4> s_log_base{};   // poll index of s_log[pad][0]
std::array<u64, 4> s_poll{};       // next poll index handed to the game
std::array<u64, 4> s_confirmed{};  // real inputs received
std::array<GCPadStatus, 4> s_last{};
std::array<u64, 4> s_wrong{};      // first poll whose guess was wrong (NONE)
u64 s_field = 0;
bool s_armed = false;   // saving: guesses allowed
bool s_broken = false;  // a save / rewind failed: delay netplay from here on
bool s_resim = false;
bool s_finish_resim = false;
u64 s_resim_target = 0;
float s_saved_speed = 1.0f;
std::deque<Record> s_records;      // oldest first
std::vector<Record> s_spare;       // buffers to reuse
u64 s_final_ticks = 0;
std::vector<PendingChecksum> s_checksums;
Stats s_stats;
double s_save_total = 0, s_load_total = 0;
int s_saves = 0, s_loads = 0;
u64 s_next_stats = 0;
std::array<u64, 4> s_stalled_at{};  // poll that last had to wait (counts each wait once)

bool Same(const GCPadStatus& a, const GCPadStatus& b)
{
  return a.button == b.button && a.stickX == b.stickX && a.stickY == b.stickY &&
         a.substickX == b.substickX && a.substickY == b.substickY &&
         a.triggerLeft == b.triggerLeft && a.triggerRight == b.triggerRight &&
         a.analogA == b.analogA && a.analogB == b.analogB && a.isConnected == b.isConnected;
}

double Ms(Clock::time_point a, Clock::time_point b)
{
  return std::chrono::duration<double, std::milli>(b - a).count();
}

Entry& EntryAt(int pad, u64 index)
{
  auto& log = s_log[pad];
  while (s_log_base[pad] + log.size() <= index)
    log.push_back(Entry{s_last[pad], false});
  return log[index - s_log_base[pad]];
}

// The field whose start state is the latest one before poll `index` of `pad` (0 if older than
// every saved field).
u64 FieldOfPoll(int pad, u64 index)
{
  for (auto it = s_records.rbegin(); it != s_records.rend(); ++it)
  {
    if (it->poll[pad] <= index)
      return it->field;
  }
  return 0;
}

bool CanGuess(int pad)
{
  if (!s_armed || s_broken || s_records.empty())
    return false;
  // The oldest input still missing: a rewind for it must not go past what's saved.
  const u64 behind = s_field - FieldOfPoll(pad, s_confirmed[pad]);
  return FieldOfPoll(pad, s_confirmed[pad]) != 0 && behind < MAX_ROLLBACK_FIELDS;
}

void AtThisField(void (*job)(Core::System&))
{
  auto& system = Core::System::GetInstance();
  system.GetCPU().AddCPUThreadJob([job, &system] { job(system); });
  system.GetCPU().Break();
}

void Resume(Core::System& system)
{
  system.GetCPU().SetStepping(false);
}

void Fail(const std::string& reason)
{
  if (s_broken)
    return;
  s_broken = true;
  ERROR_LOG_FMT(NETPLAY, "NEOcode stopped: {}", reason);
  if (s_cb.failed)
    s_cb.failed(reason);
}

void FinishResim(Core::System& system)
{
  // Let the GPU finish the re-run's commands (skipped), then draw and show again.
  system.GetFifo().SyncGPU(Fifo::SyncGPUReason::Other, false);
  VideoCommon::g_sparking_skip_draw = false;
  VideoCommon::g_sparking_skip_present = false;
  Config::SetCurrent(Config::MAIN_EMULATION_SPEED, s_saved_speed);
  s_resim = false;
  s_finish_resim = false;
}

// Newest record whose state is final (every input before it is real): what happened up to it
// can't change any more, and no rewind will go further back than it.
void UpdateFinal()
{
  for (auto it = s_records.rbegin(); it != s_records.rend(); ++it)
  {
    bool final_state = true;
    for (int p = 0; p < 4; ++p)
      final_state = final_state && s_confirmed[p] >= it->poll[p];
    if (!final_state)
      continue;
    if (it->ticks > s_final_ticks)
    {
      s_final_ticks = it->ticks;
      if (s_cb.final_until)
        s_cb.final_until(s_final_ticks);
      for (auto c = s_checksums.begin(); c != s_checksums.end();)
      {
        if (c->ticks <= s_final_ticks)
        {
          if (s_cb.checksum)
            s_cb.checksum(c->field, c->checksum);
          c = s_checksums.erase(c);
        }
        else
        {
          ++c;
        }
      }
    }
    // Older records aren't needed any more.
    const std::size_t keep_from = static_cast<std::size_t>(std::distance(it, s_records.rend())) - 1;
    for (std::size_t i = 0; i < keep_from; ++i)
    {
      s_spare.push_back(std::move(s_records.front()));
      s_records.pop_front();
    }
    break;
  }
  // Forget inputs older than the oldest saved field.
  if (!s_records.empty())
  {
    for (int p = 0; p < 4; ++p)
    {
      const u64 keep = std::min(s_records.front().poll[p], s_confirmed[p]);
      while (s_log_base[p] < keep && !s_log[p].empty())
      {
        s_log[p].pop_front();
        ++s_log_base[p];
      }
    }
  }
}

void EmitStats()
{
  s_stats.field = s_field;
  s_stats.save_ms = s_saves ? s_save_total / s_saves : 0;
  s_stats.load_ms = s_loads ? s_load_total / s_loads : 0;
  s_stats.guessing = s_armed && !s_broken;
  if (s_cb.stats)
    s_cb.stats(s_stats);
  s_stats.rollback_fields = 0;
  s_save_total = s_load_total = 0;
  s_saves = s_loads = 0;
}

void JobSnapshot(Core::System& system)
{
  if (s_finish_resim)
    FinishResim(system);
  const auto t0 = Clock::now();
  Record record;
  if (!s_spare.empty())
  {
    record = std::move(s_spare.back());
    s_spare.pop_back();
  }
  record.state_size = State::SaveToMemory(system, record.state, true);
  u64 pages = 0;
  auto& memory = system.GetMemory();
  if (record.state_size == 0 || !memory.SparkingSnapshot(&pages))
  {
    Fail(record.state_size == 0 ? "save_failed" : "memory_not_trackable");
    Resume(system);
    return;
  }
  record.snapshot = memory.SparkingSnapshotId();
  if (record.snapshot == 1 && !s_records.empty())
  {
    // The memory mappings changed since the last save (tracking started over): the older saves
    // can't be restored. Guesses still open can't be taken back any more.
    for (Record& r : s_records)
      s_spare.push_back(std::move(r));
    s_records.clear();
    for (int p = 0; p < 4; ++p)
    {
      if (s_confirmed[p] < s_poll[p])
        Fail("memory_mappings_changed");
    }
  }
  record.field = s_field;
  record.ticks = system.GetCoreTiming().GetTicks();
  record.poll = s_poll;
  record.side = s_cb.save_side ? s_cb.save_side() : std::string();
  s_records.push_back(std::move(record));
  while (s_records.size() > MAX_RECORDS)
  {
    s_spare.push_back(std::move(s_records.front()));
    s_records.pop_front();
  }
  s_armed = true;

  if (s_field % CHECKSUM_FIELDS == 0)
  {
    const u64 checksum = Common::GetHash64(memory.GetRAM(), memory.GetRamSizeReal(), 0);
    s_checksums.push_back({s_field, s_records.back().ticks, checksum});
  }
  s_save_total += Ms(t0, Clock::now());
  ++s_saves;
  UpdateFinal();
  if (!s_resim && s_field >= s_next_stats)
  {
    s_next_stats = s_field + 60;
    EmitStats();
  }
  Resume(system);
}

void JobRollback(Core::System& system)
{
  // The newest saved field before every wrong guess.
  const Record* target = nullptr;
  for (auto it = s_records.rbegin(); it != s_records.rend(); ++it)
  {
    bool before_all = true;
    for (int p = 0; p < 4; ++p)
      before_all = before_all && (s_wrong[p] == NONE || it->poll[p] <= s_wrong[p]);
    if (before_all)
    {
      target = &*it;
      break;
    }
  }
  if (!target)
  {
    Fail("rewind_too_far");
    s_wrong.fill(NONE);
    Resume(system);
    return;
  }

  const auto t0 = Clock::now();
  const u64 from_field = s_field;
  auto& memory = system.GetMemory();
  auto& jit = system.GetJitInterface();
  Gecko::SetReinstallOnLoad(false);
  jit.SetKeepCacheOnLoad(true);
  VideoCommon::g_sparking_skip_present = true;
  u64 pages = 0;
  bool ok = memory.SparkingRestoreTo(target->snapshot, &pages);
  if (ok)
  {
    ok = State::LoadFromMemory(
        system, std::span<u8>(const_cast<u8*>(target->state.data()), target->state_size), true);
  }
  jit.SetKeepCacheOnLoad(false);
  Gecko::SetReinstallOnLoad(true);
  if (!ok)
  {
    VideoCommon::g_sparking_skip_present = s_resim;
    Fail("load_failed");
    s_wrong.fill(NONE);
    Resume(system);
    return;
  }
  if (s_cb.load_side)
    s_cb.load_side(target->side);
  s_poll = target->poll;
  s_field = target->field;
  s_wrong.fill(NONE);
  // Later saves and checksums are of a past that didn't happen.
  while (!s_records.empty() && &s_records.back() != target)
  {
    s_spare.push_back(std::move(s_records.back()));
    s_records.pop_back();
  }
  std::erase_if(s_checksums, [](const PendingChecksum& c) { return c.field > s_field; });
  if (s_cb.rewound_to)
    s_cb.rewound_to(s_records.back().ticks);

  const int fields = static_cast<int>(from_field - s_field);
  ++s_stats.rollbacks;
  s_stats.rollback_fields = std::max(s_stats.rollback_fields, fields);
  s_stats.rollback_fields_total += static_cast<u64>(fields);
  if (!s_resim)
  {
    // Re-run to where we were as fast as possible, without drawing (nobody sees it).
    s_resim = true;
    s_resim_target = from_field;
    s_saved_speed = Config::Get(Config::MAIN_EMULATION_SPEED);
    Config::SetCurrent(Config::MAIN_EMULATION_SPEED, 0.0f);
    VideoCommon::g_sparking_skip_draw = true;
  }
  s_finish_resim = false;
  s_load_total += Ms(t0, Clock::now());
  ++s_loads;
  Resume(system);
}

void OnField()
{
  if (!s_active)
    return;
  ++s_field;
  if (s_broken)
    return;
  if (!s_armed)
  {
    if (s_field >= START_FIELDS)
      AtThisField(JobSnapshot);
    return;
  }
  if (s_drain)
    s_drain();
  if (s_resim && s_field >= s_resim_target)
    s_finish_resim = true;
  bool wrong = false;
  for (int p = 0; p < 4; ++p)
    wrong = wrong || s_wrong[p] != NONE;
  AtThisField(wrong ? JobRollback : JobSnapshot);
}
}  // namespace

void Start(std::function<void()> drain, Callbacks callbacks)
{
  for (int p = 0; p < 4; ++p)
  {
    s_log[p].clear();
    s_log_base[p] = 0;
    s_last[p] = GCPadStatus{};
  }
  s_poll = {};
  s_confirmed = {};
  s_wrong.fill(NONE);
  s_stalled_at = {};
  s_field = 0;
  s_armed = false;
  s_broken = false;
  s_resim = false;
  s_finish_resim = false;
  s_records.clear();
  s_spare.clear();
  s_final_ticks = 0;
  s_checksums.clear();
  s_stats = {};
  s_save_total = s_load_total = 0;
  s_saves = s_loads = 0;
  s_next_stats = START_FIELDS + 60;
  s_drain = std::move(drain);
  s_cb = std::move(callbacks);
  auto& system = Core::System::GetInstance();
  system.GetMemory().SparkingSetHistory(MAX_RECORDS + 2);
  s_field_hook = system.GetVideoEvents().vi_end_field_event.Register([] { OnField(); });
  s_active = true;
}

void Stop()
{
  s_active = false;
  s_field_hook.reset();
  if (s_resim)
  {
    VideoCommon::g_sparking_skip_draw = false;
    VideoCommon::g_sparking_skip_present = false;
    Config::SetCurrent(Config::MAIN_EMULATION_SPEED, s_saved_speed);
    s_resim = false;
  }
  Core::System::GetInstance().GetMemory().SparkingSetHistory(0);
}

bool IsActive()
{
  return s_active;
}

bool IsResimulating()
{
  return s_resim;
}

void Confirm(int pad, const GCPadStatus& status)
{
  if (pad < 0 || pad >= 4)
    return;
  const u64 index = s_confirmed[pad]++;
  Entry& entry = EntryAt(pad, index);
  if (!entry.confirmed)
  {
    // Already played with a guess (this pass): was it right?
    if (index < s_poll[pad] && !Same(entry.value, status))
    {
      s_wrong[pad] = std::min(s_wrong[pad], index);
      ++s_stats.wrong_guesses;
    }
    entry.value = status;
    entry.confirmed = true;
  }
  s_last[pad] = status;
}

bool GetInput(int pad, GCPadStatus* status)
{
  if (pad < 0 || pad >= 4)
    return false;
  const u64 index = s_poll[pad];
  Entry& entry = EntryAt(pad, index);
  if (!entry.confirmed)
  {
    if (!CanGuess(pad))
    {
      if (!s_resim && s_stalled_at[pad] != index + 1)
      {
        s_stalled_at[pad] = index + 1;
        ++s_stats.stalls;
      }
      return false;
    }
    entry.value = s_last[pad];  // (again: the newest real input is the best guess)
    ++s_stats.guesses;
  }
  ++s_stats.polls;
  *status = entry.value;
  ++s_poll[pad];
  return true;
}

u64 NowTicks()
{
  return Core::System::GetInstance().GetCoreTiming().GetTicks();
}
}  // namespace NeoCode
