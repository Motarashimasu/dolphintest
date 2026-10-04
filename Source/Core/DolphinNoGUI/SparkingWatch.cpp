// Copyright 2026 Dolphin-Sparking Project
// SPDX-License-Identifier: GPL-2.0-or-later

#include "DolphinNoGUI/SparkingWatch.h"

#include <algorithm>
#include <bit>
#include <charconv>
#include <cmath>
#include <cstring>
#include <mutex>
#include <optional>
#include <sstream>
#include <vector>

#include <fmt/format.h>

#include "Common/HookableEvent.h"
#include "Common/IniFile.h"
#include "Common/Swap.h"
#include "Core/ConfigManager.h"
#include "Core/HW/Memmap.h"
#include "Core/System.h"
#include "DolphinNoGUI/SparkingIO.h"
#include "VideoCommon/VideoEvents.h"

namespace Sparking
{
namespace
{
enum class ValueType
{
  U8,
  U16,
  U32,
  S8,
  S16,
  S32,
  F32,
};

struct Watch
{
  std::string name;
  ValueType type = ValueType::U32;
  u32 address = 0;
  std::vector<u32> offsets;  // pointer chain: address = read_u32(address) + offset, per entry
  std::optional<double> last;
  bool reported = false;  // every watch is reported once at game start, even if unreadable
};

enum class Op
{
  Eq,
  Ne,
  Lt,
  Le,
  Gt,
  Ge,
};

struct Condition
{
  size_t watch = 0;  // index into s_watches
  Op op = Op::Eq;
  double value = 0;
};

struct Trigger
{
  std::string name;
  std::vector<Condition> all;  // every condition must hold
  bool was_true = true;        // true at start: a condition already true at load doesn't fire
};

std::mutex s_mutex;
std::vector<Watch> s_watches;
std::vector<Trigger> s_triggers;

std::string Trim(std::string_view s)
{
  while (!s.empty() && (s.front() == ' ' || s.front() == '\t'))
    s.remove_prefix(1);
  while (!s.empty() && (s.back() == ' ' || s.back() == '\t' || s.back() == '\r'))
    s.remove_suffix(1);
  return std::string(s);
}

std::optional<u32> ParseU32(std::string_view s)
{
  s = std::string_view(s).substr(0, s.find_first_of(" \t"));
  int base = 10;
  if (s.starts_with("0x") || s.starts_with("0X"))
  {
    s.remove_prefix(2);
    base = 16;
  }
  u32 v = 0;
  const auto [ptr, ec] = std::from_chars(s.data(), s.data() + s.size(), v, base);
  if (ec != std::errc() || ptr != s.data() + s.size())
    return std::nullopt;
  return v;
}

std::optional<ValueType> ParseType(std::string_view s)
{
  if (s == "u8")
    return ValueType::U8;
  if (s == "u16")
    return ValueType::U16;
  if (s == "u32")
    return ValueType::U32;
  if (s == "s8")
    return ValueType::S8;
  if (s == "s16")
    return ValueType::S16;
  if (s == "s32")
    return ValueType::S32;
  if (s == "f32" || s == "float")
    return ValueType::F32;
  return std::nullopt;
}

size_t TypeSize(ValueType t)
{
  switch (t)
  {
  case ValueType::U8:
  case ValueType::S8:
    return 1;
  case ValueType::U16:
  case ValueType::S16:
    return 2;
  default:
    return 4;
  }
}

// "f32 0x803D1024 > 0x1C > 0x8"
std::optional<Watch> ParseWatch(const std::string& name, const std::string& spec)
{
  std::vector<std::string> parts;
  std::stringstream ss(spec);
  for (std::string part; std::getline(ss, part, '>');)
    parts.push_back(Trim(part));
  if (parts.empty())
    return std::nullopt;

  const std::string head = parts[0];
  const size_t space = head.find_first_of(" \t");
  if (space == std::string::npos)
    return std::nullopt;
  const auto type = ParseType(head.substr(0, space));
  const auto address = ParseU32(Trim(head.substr(space)));
  if (!type || !address)
    return std::nullopt;

  Watch w;
  w.name = name;
  w.type = *type;
  w.address = *address;
  for (size_t i = 1; i < parts.size(); ++i)
  {
    const auto offset = ParseU32(parts[i]);
    if (!offset)
      return std::nullopt;
    w.offsets.push_back(*offset);
  }
  return w;
}

// "p1_health_pct <= 0 && p2_health_pct > 0"
std::optional<Trigger> ParseTrigger(const std::string& name, const std::string& spec)
{
  Trigger t;
  t.name = name;
  size_t pos = 0;
  while (pos <= spec.size())
  {
    const size_t amp = spec.find("&&", pos);
    const std::string clause =
        Trim(std::string_view(spec).substr(pos, amp == std::string::npos ? std::string::npos :
                                                                           amp - pos));
    pos = amp == std::string::npos ? spec.size() + 1 : amp + 2;

    static constexpr std::pair<std::string_view, Op> ops[] = {
        {"==", Op::Eq}, {"!=", Op::Ne}, {"<=", Op::Le}, {">=", Op::Ge}, {"<", Op::Lt}, {">", Op::Gt},
    };
    std::optional<Condition> cond;
    for (const auto& [text, op] : ops)
    {
      const size_t at = clause.find(text);
      if (at == std::string::npos)
        continue;
      const std::string watch = Trim(std::string_view(clause).substr(0, at));
      const std::string number = Trim(std::string_view(clause).substr(at + text.size()));
      const auto it = std::ranges::find_if(s_watches, [&](const Watch& w) { return w.name == watch; });
      if (it == s_watches.end())
        return std::nullopt;
      double value = 0;
      const auto [p, ec] = std::from_chars(number.data(), number.data() + number.size(), value);
      if (ec != std::errc())
        return std::nullopt;
      cond = Condition{static_cast<size_t>(it - s_watches.begin()), op, value};
      break;
    }
    if (!cond)
      return std::nullopt;
    t.all.push_back(*cond);
  }
  return t.all.empty() ? std::nullopt : std::optional<Trigger>(t);
}

// Reads guest memory without touching the CPU (RAM is plain host memory). Only MEM1 (0x80/0xC0)
// and MEM2 (0x90/0xD0) are allowed; anything else, or out of range, is "unreadable".
bool ReadGuest(Core::System& system, u32 address, void* out, size_t size)
{
  auto& memory = system.GetMemory();
  const u32 segment = address >> 28;
  const u32 offset = address & 0x0FFFFFFF;
  const u8* base = nullptr;
  u32 limit = 0;
  if (segment == 0x8 || segment == 0xC)
  {
    base = memory.GetRAM();
    limit = memory.GetRamSizeReal();
  }
  else if (segment == 0x9 || segment == 0xD)
  {
    base = memory.GetEXRAM();
    limit = memory.GetExRamSizeReal();
  }
  if (!base || offset + size > limit || offset + size < offset)
    return false;
  std::memcpy(out, base + offset, size);
  return true;
}

std::optional<double> ReadWatch(Core::System& system, const Watch& w)
{
  u32 address = w.address;
  for (const u32 offset : w.offsets)
  {
    u32 pointer = 0;
    if (!ReadGuest(system, address, &pointer, 4))
      return std::nullopt;
    address = Common::swap32(pointer) + offset;
  }
  u8 raw[4] = {};
  const size_t size = TypeSize(w.type);
  if (!ReadGuest(system, address, raw, size))
    return std::nullopt;
  const u32 v32 = (u32(raw[0]) << 24) | (u32(raw[1]) << 16) | (u32(raw[2]) << 8) | raw[3];
  const u16 v16 = static_cast<u16>((raw[0] << 8) | raw[1]);
  switch (w.type)
  {
  case ValueType::U8:
    return raw[0];
  case ValueType::S8:
    return static_cast<s8>(raw[0]);
  case ValueType::U16:
    return v16;
  case ValueType::S16:
    return static_cast<s16>(v16);
  case ValueType::U32:
    return v32;
  case ValueType::S32:
    return static_cast<s32>(v32);
  case ValueType::F32:
  {
    const float f = std::bit_cast<float>(v32);
    if (!std::isfinite(f))
      return std::nullopt;
    return std::round(static_cast<double>(f) * 1000.0) / 1000.0;  // 3 decimals: no float noise
  }
  }
  return std::nullopt;
}

std::string FormatValue(const std::optional<double>& v)
{
  if (!v)
    return "null";
  if (*v == std::floor(*v) && std::abs(*v) < 1e15)
    return fmt::format("{}", static_cast<long long>(*v));
  return fmt::format("{}", *v);
}

bool Holds(const Condition& c, const std::optional<double>& v)
{
  if (!v)
    return false;
  switch (c.op)
  {
  case Op::Eq:
    return *v == c.value;
  case Op::Ne:
    return *v != c.value;
  case Op::Lt:
    return *v < c.value;
  case Op::Le:
    return *v <= c.value;
  case Op::Gt:
    return *v > c.value;
  case Op::Ge:
    return *v >= c.value;
  }
  return false;
}

// CPU thread, once per video field.
void OnField()
{
  std::lock_guard lk(s_mutex);
  if (s_watches.empty())
    return;
  auto& system = Core::System::GetInstance();
  for (Watch& w : s_watches)
  {
    const std::optional<double> value = ReadWatch(system, w);
    if (w.reported && value == w.last)
      continue;
    w.last = value;
    w.reported = true;
    Emit("watch", Json().Add("name", w.name).AddRaw("value", FormatValue(value)));
  }
  for (Trigger& t : s_triggers)
  {
    bool now = true;
    for (const Condition& c : t.all)
      now = now && Holds(c, s_watches[c.watch].last);
    if (now && !t.was_true)
      Emit("game_event", Json().Add("name", t.name));
    t.was_true = now;
  }
}
}  // namespace

void InitWatcher()
{
  // Deliberately never destroyed (same reason as the core state hook).
  static auto* const hook = new Common::EventHook(
      Core::System::GetInstance().GetVideoEvents().vi_end_field_event.Register([] { OnField(); }));
  (void)hook;
}

void LoadWatches(const std::string& game_id, u16 revision)
{
  std::lock_guard lk(s_mutex);
  s_watches.clear();
  s_triggers.clear();

  // Local game ini entries override the bundled (Sys) ones with the same name.
  std::vector<std::pair<std::string, std::string>> watch_specs, trigger_specs;
  const auto collect = [](const Common::IniFile& ini, const char* section_name, auto* out) {
    if (const auto* section = ini.GetSection(section_name))
    {
      for (const auto& [key, value] : section->GetValues())
      {
        std::erase_if(*out, [&](const auto& kv) { return kv.first == key; });
        out->emplace_back(key, value);
      }
    }
  };
  for (const Common::IniFile& ini : {SConfig::LoadDefaultGameIni(game_id, revision),
                                     SConfig::LoadLocalGameIni(game_id, revision)})
  {
    collect(ini, "Sparking.Watch", &watch_specs);
    collect(ini, "Sparking.Trigger", &trigger_specs);
  }

  for (const auto& [name, spec] : watch_specs)
  {
    if (auto w = ParseWatch(name, spec))
      s_watches.push_back(std::move(*w));
    else
      Emit("error", Json().Add("code", "bad_watch").Add("name", name).Add("spec", spec));
  }
  for (const auto& [name, spec] : trigger_specs)
  {
    if (auto t = ParseTrigger(name, spec))
      s_triggers.push_back(std::move(*t));
    else
      Emit("error", Json().Add("code", "bad_trigger").Add("name", name).Add("spec", spec));
  }

  std::vector<std::string> watch_names, trigger_names;
  for (const Watch& w : s_watches)
    watch_names.push_back(Json::Escape(w.name));
  for (const Trigger& t : s_triggers)
    trigger_names.push_back(Json::Escape(t.name));
  Emit("watches_loaded", Json()
                             .AddRaw("watches", JsonArray(watch_names))
                             .AddRaw("triggers", JsonArray(trigger_names)));
}

void ClearWatches()
{
  std::lock_guard lk(s_mutex);
  s_watches.clear();
  s_triggers.clear();
}

void EmitWatchValues()
{
  std::lock_guard lk(s_mutex);
  Json values;
  for (const Watch& w : s_watches)
    values.AddRaw(w.name, FormatValue(w.last));
  Emit("watch_values", Json().AddRaw("values", values.Str()));
}
}  // namespace Sparking
