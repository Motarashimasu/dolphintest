// Copyright 2026 Dolphin-Sparking Project
// SPDX-License-Identifier: GPL-2.0-or-later

// Rollback saves that copy only the memory the game changed.
//
// A rollback save every frame used to copy all of MEM1 + MEM2 (88 MB, ~15 ms), while a BT3 fight
// changes only ~200 of their 4 KB pages per frame. So: after a snapshot every host view of the
// tracked memory (the plain view Dolphin's C++ code uses, the fastmem physical view, the DBAT
// logical views) is made read-only. The first write to a page, from any thread, faults; the
// fault handler (EMM) makes that page writable again in the view written through and marks it
// changed. An unchanged page is protected in every view.
//
// Snapshot: copy the changed pages (all of them the first time) into a shadow copy and protect
// them again. Restore: copy the changed pages back from the shadow (= memory at the snapshot)
// and protect them again.
//
// History (NEOcode saves every field and may go back several): with SetHistory(n) a snapshot
// first keeps the shadow's old contents of the pages it overwrites (an undo record for the
// previous snapshot), so RestoreTo can go back to any of the last n snapshots by applying them
// newest first.
//
// Mapping changes (DBAT remaps, page table mappings) and shutdown disarm it (everything
// unprotected, the shadow invalid); the next snapshot starts over with a full copy.
#pragma once

#include <array>
#include <atomic>
#include <cstddef>
#include <memory>
#include <span>
#include <vector>

#include "Common/CommonTypes.h"

namespace Common
{
class MemArena;
}

namespace Memory
{
class SparkingDirtyPages
{
public:
  // A host mapping of part of the shared memory segment.
  struct View
  {
    u8* host = nullptr;
    u32 shm_position = 0;
    u32 size = 0;
  };
  // Memory to track (MEM1, MEM2): its range of the segment and its plain host view.
  struct Range
  {
    u8* host = nullptr;
    u32 shm_position = 0;
    u32 size = 0;
  };

  SparkingDirtyPages(Common::MemArena& arena, u32 page_size);
  ~SparkingDirtyPages();

  bool IsArmed() const { return m_armed.load(std::memory_order_acquire); }

  // Copies the changed pages into the shadow and starts tracking them again. Not armed: sets up
  // with these views / ranges, copies everything and arms. `pages`: pages copied.
  void Snapshot(std::span<const View> views, std::span<const Range> ranges, u64* pages);
  // Puts the memory back as it was at the last snapshot. False if not armed (nothing done).
  bool Restore(u64* pages);
  // How many earlier snapshots RestoreTo can go back to (0 = only the last; the default).
  void SetHistory(std::size_t count);
  // Id of the last snapshot (0 = none since arming). Each snapshot gets the next id.
  u64 GetSnapshotId() const { return m_snapshot_id; }
  // Puts the memory back as it was at snapshot `id` (the last one or one still in the history);
  // later snapshots are forgotten. False (nothing done) if not armed or `id` is gone.
  bool RestoreTo(u64 id, u64* pages);
  // Stops tracking: every view writable again, the shadow invalid.
  void Disarm();

  // From the memory fault handler (any thread): a write to a protected tracked page. True if it
  // was one (the page is writable again and marked changed).
  bool HandleFault(uintptr_t address);
  // Before host code writes into tracked memory without a fault (a file read straight into
  // emulated memory: the OS returns an error instead of faulting).
  void PrepareHostWrite(const void* address, std::size_t size);

  u64 GetFaultCount() const { return m_faults.load(std::memory_order_relaxed); }

private:
  static constexpr std::size_t MAX_VIEWS = 64;
  static constexpr std::size_t MAX_RANGES = 4;

  bool IsTracked(u32 shm_position) const;
  // Protect / unprotect [shm_begin, shm_end) in every view.
  void SetProtection(u32 shm_begin, u32 shm_end, bool writeable);
  // Makes the page writable in `view` and marks it changed.
  void MarkWritten(const View& view, u32 shm_position);

  Common::MemArena& m_arena;
  const u32 m_page_size;
  std::array<View, MAX_VIEWS> m_views{};
  std::size_t m_view_count = 0;
  std::array<Range, MAX_RANGES> m_ranges{};
  std::size_t m_range_count = 0;
  u32 m_shm_end = 0;  // end of the last tracked range (sizes the bitmap and the shadow)
  std::unique_ptr<std::atomic<u8>[]> m_dirty;  // per page: 1 = written since the snapshot
  std::size_t m_page_count = 0;
  std::vector<u8> m_shadow;  // indexed by segment position
  // Undo record of snapshot `id`: its contents of the pages that changed before snapshot id + 1.
  struct Undo
  {
    u64 id = 0;
    std::vector<u32> pages;  // page indices
    std::vector<u8> data;    // their contents, one page each
  };
  std::vector<Undo> m_history;  // oldest first; the last one belongs to snapshot m_snapshot_id - 1
  std::size_t m_history_size = 0;
  u64 m_snapshot_id = 0;
  std::atomic<bool> m_armed{false};
  std::atomic<u64> m_faults{0};
};
}  // namespace Memory
