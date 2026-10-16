// Copyright 2026 Dolphin-Sparking Project
// SPDX-License-Identifier: GPL-2.0-or-later

#include "Core/HW/SparkingDirtyPages.h"

#include <algorithm>
#include <cstring>

#include "Common/MemArena.h"

namespace Memory
{
SparkingDirtyPages::SparkingDirtyPages(Common::MemArena& arena, u32 page_size)
    : m_arena(arena), m_page_size(page_size)
{
}

SparkingDirtyPages::~SparkingDirtyPages()
{
  Disarm();
}

bool SparkingDirtyPages::IsTracked(u32 shm_position) const
{
  for (std::size_t i = 0; i < m_range_count; ++i)
  {
    const Range& r = m_ranges[i];
    if (shm_position >= r.shm_position && shm_position - r.shm_position < r.size)
      return true;
  }
  return false;
}

void SparkingDirtyPages::SetProtection(u32 shm_begin, u32 shm_end, bool writeable)
{
  for (std::size_t i = 0; i < m_view_count; ++i)
  {
    const View& v = m_views[i];
    const u32 lo = std::max(shm_begin, v.shm_position);
    const u32 hi = static_cast<u32>(std::min<u64>(shm_end, u64(v.shm_position) + v.size));
    if (lo < hi)
      m_arena.ChangeMappingProtection(v.host + (lo - v.shm_position), hi - lo, writeable);
  }
}

void SparkingDirtyPages::MarkWritten(const View& view, u32 shm_position)
{
  const u32 page_begin = shm_position / m_page_size * m_page_size;
  // Only this view becomes writable (one system call; the game nearly always writes a page
  // through one view). A write through another view faults once more and lands here too. A
  // snapshot / restore protects every view of a marked page again.
  m_arena.ChangeMappingProtection(view.host + (page_begin - view.shm_position), m_page_size, true);
  m_dirty[page_begin / m_page_size].store(1, std::memory_order_release);
}

void SparkingDirtyPages::Snapshot(std::span<const View> views, std::span<const Range> ranges,
                                  u64* pages)
{
  *pages = 0;
  if (!IsArmed())
  {
    // Set up and copy everything.
    m_view_count = std::min(views.size(), MAX_VIEWS);
    std::copy_n(views.begin(), m_view_count, m_views.begin());
    m_range_count = std::min(ranges.size(), MAX_RANGES);
    std::copy_n(ranges.begin(), m_range_count, m_ranges.begin());
    m_shm_end = 0;
    for (std::size_t i = 0; i < m_range_count; ++i)
      m_shm_end = std::max(m_shm_end, m_ranges[i].shm_position + m_ranges[i].size);
    const std::size_t page_count = (m_shm_end + m_page_size - 1) / m_page_size;
    if (page_count != m_page_count || !m_dirty)
    {
      m_dirty = std::make_unique<std::atomic<u8>[]>(page_count);
      m_page_count = page_count;
    }
    for (std::size_t i = 0; i < m_page_count; ++i)
      m_dirty[i].store(0, std::memory_order_relaxed);
    m_shadow.resize(m_shm_end);
    // Armed before protecting, so a write right after the protection is handled. A write before
    // it lands in memory before the copy below, so the copy has it.
    m_armed.store(true, std::memory_order_release);
    for (std::size_t i = 0; i < m_range_count; ++i)
    {
      const Range& r = m_ranges[i];
      SetProtection(r.shm_position, r.shm_position + r.size, false);
      std::memcpy(m_shadow.data() + r.shm_position, r.host, r.size);
      *pages += r.size / m_page_size;
    }
    return;
  }

  for (std::size_t i = 0; i < m_range_count; ++i)
  {
    const Range& r = m_ranges[i];
    const std::size_t first = r.shm_position / m_page_size;
    const std::size_t last = (r.shm_position + r.size) / m_page_size;
    std::size_t p = first;
    while (p < last)
    {
      if (!m_dirty[p].load(std::memory_order_acquire))
      {
        ++p;
        continue;
      }
      std::size_t end = p;
      while (end < last && m_dirty[end].load(std::memory_order_acquire))
        ++end;
      // Unmark, protect, then copy: a write after the protection faults and marks the page for
      // the next snapshot; a write before the copy is in it.
      for (std::size_t k = p; k < end; ++k)
        m_dirty[k].store(0, std::memory_order_release);
      const u32 begin_pos = static_cast<u32>(p * m_page_size);
      const u32 end_pos = static_cast<u32>(end * m_page_size);
      SetProtection(begin_pos, end_pos, false);
      std::memcpy(m_shadow.data() + begin_pos, r.host + (begin_pos - r.shm_position),
                  end_pos - begin_pos);
      *pages += end - p;
      p = end;
    }
  }
}

bool SparkingDirtyPages::Restore(u64* pages)
{
  *pages = 0;
  if (!IsArmed())
    return false;
  for (std::size_t i = 0; i < m_range_count; ++i)
  {
    const Range& r = m_ranges[i];
    const std::size_t first = r.shm_position / m_page_size;
    const std::size_t last = (r.shm_position + r.size) / m_page_size;
    std::size_t p = first;
    while (p < last)
    {
      if (!m_dirty[p].load(std::memory_order_acquire))
      {
        ++p;
        continue;
      }
      std::size_t end = p;
      while (end < last && m_dirty[end].load(std::memory_order_acquire))
        ++end;
      // The pages are writable (marked): copy back, then unmark and protect.
      const u32 begin_pos = static_cast<u32>(p * m_page_size);
      const u32 end_pos = static_cast<u32>(end * m_page_size);
      std::memcpy(r.host + (begin_pos - r.shm_position), m_shadow.data() + begin_pos,
                  end_pos - begin_pos);
      for (std::size_t k = p; k < end; ++k)
        m_dirty[k].store(0, std::memory_order_release);
      SetProtection(begin_pos, end_pos, false);
      *pages += end - p;
      p = end;
    }
  }
  return true;
}

void SparkingDirtyPages::Disarm()
{
  if (!IsArmed())
    return;
  // Writable again before disarming, so nothing faults while disarmed.
  for (std::size_t i = 0; i < m_range_count; ++i)
    SetProtection(m_ranges[i].shm_position, m_ranges[i].shm_position + m_ranges[i].size, true);
  m_armed.store(false, std::memory_order_release);
}

bool SparkingDirtyPages::HandleFault(uintptr_t address)
{
  if (!IsArmed())
    return false;
  for (std::size_t i = 0; i < m_view_count; ++i)
  {
    const View& v = m_views[i];
    const uintptr_t host = reinterpret_cast<uintptr_t>(v.host);
    if (address < host || address - host >= v.size)
      continue;
    const u32 shm_position = v.shm_position + static_cast<u32>(address - host);
    if (!IsTracked(shm_position))
      return false;
    MarkWritten(v, shm_position);
    m_faults.fetch_add(1, std::memory_order_relaxed);
    return true;
  }
  return false;
}

void SparkingDirtyPages::PrepareHostWrite(const void* address, std::size_t size)
{
  if (!IsArmed() || size == 0)
    return;
  const uintptr_t begin = reinterpret_cast<uintptr_t>(address);
  const uintptr_t end = begin + size;
  for (std::size_t i = 0; i < m_view_count; ++i)
  {
    const View& v = m_views[i];
    const uintptr_t host = reinterpret_cast<uintptr_t>(v.host);
    const uintptr_t lo = std::max(begin, host);
    const uintptr_t hi = std::min<uintptr_t>(end, host + v.size);
    for (uintptr_t a = lo; a < hi;)
    {
      const u32 shm_position = v.shm_position + static_cast<u32>(a - host);
      if (IsTracked(shm_position))
        MarkWritten(v, shm_position);
      a = (a - host) / m_page_size * m_page_size + host + m_page_size;
    }
  }
}
}  // namespace Memory
