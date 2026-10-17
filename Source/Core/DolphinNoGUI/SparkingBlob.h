// Copyright 2026 Dolphin-Sparking Project
// SPDX-License-Identifier: GPL-2.0-or-later

// A tiny binary writer / reader for state kept in memory (NEOcode saves the watcher's and the
// HUD's state with every field). Only for this process: no versioning, no endianness.
#pragma once

#include <cstring>
#include <optional>
#include <string>
#include <type_traits>

namespace Sparking
{
class BlobWriter
{
public:
  template <typename T>
  void Put(const T& value)
  {
    static_assert(std::is_trivially_copyable_v<T>);
    m_data.append(reinterpret_cast<const char*>(&value), sizeof(T));
  }
  void Put(const std::string& value)
  {
    Put(value.size());
    m_data += value;
  }
  void Put(const std::optional<double>& value)
  {
    Put(value.has_value());
    Put(value.value_or(0.0));
  }
  std::string Take() { return std::move(m_data); }

private:
  std::string m_data;
};

class BlobReader
{
public:
  explicit BlobReader(const std::string& data) : m_data(data) {}
  template <typename T>
  void Get(T& value)
  {
    static_assert(std::is_trivially_copyable_v<T>);
    if (m_at + sizeof(T) > m_data.size())
    {
      m_ok = false;
      return;
    }
    std::memcpy(&value, m_data.data() + m_at, sizeof(T));
    m_at += sizeof(T);
  }
  void Get(std::string& value)
  {
    std::size_t size = 0;
    Get(size);
    if (!m_ok || m_at + size > m_data.size())
    {
      m_ok = false;
      return;
    }
    value.assign(m_data, m_at, size);
    m_at += size;
  }
  void Get(std::optional<double>& value)
  {
    bool has = false;
    double v = 0;
    Get(has);
    Get(v);
    value = has ? std::optional<double>(v) : std::nullopt;
  }
  bool Ok() const { return m_ok; }

private:
  const std::string& m_data;
  std::size_t m_at = 0;
  bool m_ok = true;
};
}  // namespace Sparking
