// Copyright 2026 Dolphin-Sparking Project
// SPDX-License-Identifier: GPL-2.0-or-later

#include "Core/NeoCode.h"

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cstdlib>
#include <deque>
#include <limits>
#include <span>
#include <vector>

#include "AudioCommon/Mixer.h"
#include "AudioCommon/SoundStream.h"
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
  std::vector<u64> blocks;  // each CHECKSUM_BLOCK of MEM1's
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
Clock::time_point s_resim_start;
std::deque<Record> s_records;      // oldest first
std::vector<Record> s_spare;       // buffers to reuse
u64 s_final_ticks = 0;
std::vector<PendingChecksum> s_checksums;
std::vector<std::pair<u32, u32>> s_checksum_skip;  // sorted, merged {begin, end}
Stats s_stats;
double s_save_total = 0, s_load_total = 0;
int s_saves = 0, s_loads = 0;
u64 s_next_stats = 0;
std::array<u64, 4> s_stalled_at{};  // poll that last had to wait (counts each wait once)
std::array<GCPadStatus, 4> s_stable{};  // Stabilize: each local pad's last output
std::array<u64, 4> s_field_start_poll{};  // each pad's poll index when this field started

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
  system.GetCPU().BreakForJob();  // (not Break: that pauses the sound stream and the GPU thread)
}

// Re-run mode on / off: as fast as possible (no throttle, no VSync change), not drawn, silent.
void SetFastForward(Core::System& system, bool on)
{
  system.GetCoreTiming().SetSparkingUnthrottled(on);
  if (SoundStream* stream = system.GetSoundStream())
    stream->GetMixer()->SetSparkingDiscard(on);
  VideoCommon::g_sparking_skip_draw = on;
  if (!on)
    VideoCommon::g_sparking_skip_present = false;
}

void Resume(Core::System& system)
{
  system.GetCPU().ResumeAfterJob();
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
  SetFastForward(system, false);
  s_stats.resim_ms = std::max(s_stats.resim_ms, Ms(s_resim_start, Clock::now()));
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
            s_cb.checksum(c->field, c->checksum, c->blocks);
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
  s_stats.queued = 0;
  for (int pad = 0; pad < 4; ++pad)
    s_stats.queued = std::max(s_stats.queued, Queued(pad));
  if (s_cb.stats)
    s_cb.stats(s_stats);
  s_stats.rollback_fields = 0;
  s_stats.resim_ms = 0;
  s_save_total = s_load_total = 0;
  s_saves = s_loads = 0;
}

// During a re-run, a field whose inputs are all real AND the next field's too (as many real ones
// are already in for every pad as this field used) would be saved only to be dropped at the next
// field end: a newer final save replaces it, and no rewind goes back to anything older than the
// newest final save. Skipping it makes each re-run frame cheaper (the save is a quarter of it).
bool SaveNotNeeded()
{
  if (!s_resim || s_finish_resim || s_field % CHECKSUM_FIELDS == 0)
    return false;
  for (int p = 0; p < 4; ++p)
  {
    const u64 used = s_poll[p] - s_field_start_poll[p];
    if (s_confirmed[p] < s_poll[p] + used)
      return false;
  }
  return true;
}

void JobSnapshot(Core::System& system)
{
  if (s_finish_resim)
    FinishResim(system);
  if (SaveNotNeeded())
  {
    ++s_stats.saves_skipped;
    s_field_start_poll = s_poll;
    Resume(system);
    return;
  }
  s_field_start_poll = s_poll;
  const auto t0 = Clock::now();
  Record record;
  if (!s_spare.empty())
  {
    record = std::move(s_spare.back());
    s_spare.pop_back();
  }
  record.state_size = State::SaveToMemory(system, record.state, true, false);
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
    // Not the Gecko code area, nor what the per-port codes write: each player runs their own
    // port's codes (the splitscreen removers), so those differ between players by design.
    // Hashed in CHECKSUM_BLOCK pieces: when the players' checksums differ, the pieces' hashes
    // show where (Callbacks::checksum).
    const u8* ram = memory.GetRAM();
    const u32 ram_size = memory.GetRamSizeReal();
    PendingChecksum pending{s_field, s_records.back().ticks, 0, {}};
    pending.blocks.reserve(ram_size / CHECKSUM_BLOCK + 1);
    auto skip = s_checksum_skip.begin();
    for (u32 block = 0; block < ram_size; block += CHECKSUM_BLOCK)
    {
      const u32 block_end = std::min(ram_size, block + CHECKSUM_BLOCK);
      u64 hash = 0;
      u64 part = 1;
      u32 pos = block;
      while (skip != s_checksum_skip.end() && skip->second <= block)
        ++skip;
      for (auto it = skip; it != s_checksum_skip.end() && it->first < block_end; ++it)
      {
        if (it->first > pos)
          hash ^= Common::GetHash64(ram + pos, it->first - pos, 0) * (2 * part++ + 1);
        pos = std::max(pos, std::min(it->second, block_end));
      }
      if (pos < block_end)
        hash ^= Common::GetHash64(ram + pos, block_end - pos, 0) * (2 * part + 1);
      pending.blocks.push_back(hash);
      pending.checksum = pending.checksum * 0x100000001B3ull ^ hash;
    }
    s_checksums.push_back(std::move(pending));
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
        system, std::span<u8>(const_cast<u8*>(target->state.data()), target->state_size), true, false);
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
  s_field_start_poll = s_poll;
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
    s_resim_start = t0;
    SetFastForward(system, true);
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
  s_field_start_poll = {};
  s_stable.fill(GCPadStatus{});
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

void SetChecksumSkip(std::vector<std::pair<u32, u32>> ranges)
{
  ranges.emplace_back(Gecko::INSTALLER_BASE_ADDRESS & 0x01FFFFFF,
                      (Gecko::INSTALLER_END_ADDRESS - Gecko::INSTALLER_BASE_ADDRESS));
  std::vector<std::pair<u32, u32>> spans;  // {begin, end}
  for (const auto& [offset, size] : ranges)
    spans.emplace_back(offset & ~3u, (offset + size + 3) & ~3u);   // whole words
  std::ranges::sort(spans);
  s_checksum_skip.clear();
  for (const auto& s : spans)
  {
    if (!s_checksum_skip.empty() && s.first <= s_checksum_skip.back().second)
      s_checksum_skip.back().second = std::max(s_checksum_skip.back().second, s.second);
    else
      s_checksum_skip.push_back(s);
  }
}

void Stop()
{
  s_active = false;
  s_field_hook.reset();
  if (s_resim)
  {
    SetFastForward(Core::System::GetInstance(), false);
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

namespace
{
// Keeps `prev` while `raw` stays within `tolerance` of it.
u8 Hold(u8 raw, u8 prev, int tolerance)
{
  return std::abs(int(raw) - int(prev)) <= tolerance ? prev : raw;
}

u8 StableAxis(u8 raw, u8 prev, u8 center)
{
  if (std::abs(int(raw) - int(center)) <= 6)
    return center;
  return Hold(raw, prev, 3);
}

u8 StableAnalog(u8 raw, u8 prev)
{
  if (raw <= 12)
    return 0;
  if (raw >= 243)
    return 255;
  return Hold(raw, prev, 6);
}
}  // namespace

void Stabilize(int pad, GCPadStatus* status)
{
  if (pad < 0 || pad >= 4)
    return;
  GCPadStatus& prev = s_stable[pad];
  status->stickX = StableAxis(status->stickX, prev.stickX, GCPadStatus::MAIN_STICK_CENTER_X);
  status->stickY = StableAxis(status->stickY, prev.stickY, GCPadStatus::MAIN_STICK_CENTER_Y);
  status->substickX = StableAxis(status->substickX, prev.substickX, GCPadStatus::C_STICK_CENTER_X);
  status->substickY = StableAxis(status->substickY, prev.substickY, GCPadStatus::C_STICK_CENTER_Y);
  status->triggerLeft = StableAnalog(status->triggerLeft, prev.triggerLeft);
  status->triggerRight = StableAnalog(status->triggerRight, prev.triggerRight);
  status->analogA = StableAnalog(status->analogA, prev.analogA);
  status->analogB = StableAnalog(status->analogB, prev.analogB);
  prev = *status;
}

u64 Queued(int pad)
{
  if (pad < 0 || pad >= 4)
    return 0;
  return s_confirmed[pad] > s_poll[pad] ? s_confirmed[pad] - s_poll[pad] : 0;
}

u64 NowTicks()
{
  return Core::System::GetInstance().GetCoreTiming().GetTicks();
}
}  // namespace NeoCode
