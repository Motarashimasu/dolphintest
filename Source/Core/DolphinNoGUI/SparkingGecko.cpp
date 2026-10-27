// Copyright 2026 Dolphin-Sparking Project
// SPDX-License-Identifier: GPL-2.0-or-later

#include "DolphinNoGUI/SparkingGecko.h"

#include <algorithm>
#include <set>
#include <string_view>

#include <fmt/format.h>

#include "Common/Config/Config.h"
#include "Common/Crypto/SHA1.h"
#include "Common/IniFile.h"
#include "Core/ActionReplay.h"
#include "Core/Config/SessionSettings.h"
#include "Core/ConfigManager.h"
#include "Core/GeckoCode.h"
#include "Core/GeckoCodeConfig.h"
#include "DolphinNoGUI/SparkingIO.h"

namespace Sparking
{
namespace
{
std::vector<Gecko::GeckoCode> LoadAllCodes(const std::string& game_id, std::optional<u16> revision)
{
  const Common::IniFile global_ini = SConfig::LoadDefaultGameIni(game_id, revision);
  const Common::IniFile local_ini = SConfig::LoadLocalGameIni(game_id, revision);
  return Gecko::LoadCodes(global_ini, local_ini);
}

// The non-empty, trimmed lines of a [Sparking.*] section (Sys ini first, then the user's).
std::vector<std::string> SectionLines(const std::string& game_id, std::optional<u16> revision,
                                      const std::string& section)
{
  std::vector<std::string> out;
  for (const Common::IniFile& ini :
       {SConfig::LoadDefaultGameIni(game_id, revision), SConfig::LoadLocalGameIni(game_id, revision)})
  {
    std::vector<std::string> lines;
    ini.GetLines(section, &lines);  // (comments removed, lines trimmed)
    for (std::string& l : lines)
    {
      if (!l.empty() && std::ranges::find(out, l) == out.end())
        out.push_back(std::move(l));
    }
  }
  return out;
}

std::string Trim(std::string_view s)
{
  const size_t a = s.find_first_not_of(" \t");
  if (a == std::string_view::npos)
    return {};
  const size_t b = s.find_last_not_of(" \t");
  return std::string(s.substr(a, b - a + 1));
}
}  // namespace

std::vector<std::string> LobbyCodeNames(const std::string& game_id, std::optional<u16> revision)
{
  return SectionLines(game_id, revision, "Sparking.LobbyCodes");
}

std::vector<std::pair<std::string, std::vector<std::string>>>
ExclusiveCodeGroups(const std::string& game_id, std::optional<u16> revision)
{
  // "<group> = Code A | Code B" (key = value lines; the user ini's group replaces the Sys one).
  std::map<std::string, std::string> raw;
  for (const Common::IniFile& ini :
       {SConfig::LoadDefaultGameIni(game_id, revision), SConfig::LoadLocalGameIni(game_id, revision)})
  {
    if (const Common::IniFile::Section* section = ini.GetSection("Sparking.Exclusive"))
    {
      for (const auto& [key, value] : section->GetValues())
        raw[key] = value;
    }
  }
  std::vector<std::pair<std::string, std::vector<std::string>>> groups;
  for (const auto& [key, value] : raw)
  {
    std::vector<std::string> names;
    std::string_view rest = value;
    while (!rest.empty())
    {
      const size_t bar = rest.find('|');
      if (std::string n = Trim(rest.substr(0, bar)); !n.empty())
        names.push_back(std::move(n));
      rest = bar == std::string_view::npos ? std::string_view{} : rest.substr(bar + 1);
    }
    if (names.size() >= 2)
      groups.emplace_back(key, std::move(names));
  }
  return groups;
}

std::vector<std::string> ExclusiveGroupConflicts(const std::string& game_id, u16 revision,
                                                 const std::vector<std::string>& names)
{
  std::vector<std::string> dropped;
  for (const auto& [group, members] : ExclusiveCodeGroups(game_id, revision))
  {
    bool have_one = false;
    for (const std::string& n : names)
    {
      if (std::ranges::find(members, n) == members.end())
        continue;
      if (have_one)
        dropped.push_back(n);
      have_one = true;
    }
  }
  return dropped;
}

std::string ListGeckoCodesJson(const std::string& game_id, std::optional<u16> revision)
{
  std::vector<std::string> items;
  const std::vector<std::string> lobby = LobbyCodeNames(game_id, revision);
  const auto groups = ExclusiveCodeGroups(game_id, revision);
  for (const Gecko::GeckoCode& code : LoadAllCodes(game_id, revision))
  {
    std::string group;
    for (const auto& [g, members] : groups)
    {
      if (std::ranges::find(members, code.name) != members.end())
        group = g;
    }
    std::vector<std::string> notes, lines;
    for (const std::string& n : code.notes)
      notes.push_back(Json::Escape(n));
    for (const Gecko::GeckoCode::Code& c : code.codes)
      lines.push_back(Json::Escape(c.original_line));
    items.push_back(Json()
                        .Add("name", code.name)
                        .Add("creator", code.creator)
                        .AddRaw("notes", JsonArray(notes))
                        .Add("default_enabled", code.default_enabled)
                        .Add("user_defined", code.user_defined)
                        .AddRaw("lines", JsonArray(lines))
                        .Add("lobby_option", std::ranges::find(lobby, code.name) != lobby.end())
                        .Add("group", group)
                        .Str());
  }
  return JsonArray(items);
}

std::vector<std::string> ActivateExclusiveGeckoCodes(const std::string& game_id, u16 revision,
                                                     const std::vector<std::string>& names,
                                                     const std::vector<std::string>& ar_names)
{
  std::vector<Gecko::GeckoCode> selected;
  std::vector<std::string> missing;
  const std::vector<Gecko::GeckoCode> all = LoadAllCodes(game_id, revision);
  for (const std::string& name : names)
  {
    const auto it = std::ranges::find_if(all, [&](const auto& c) { return c.name == name; });
    if (it == all.end())
    {
      missing.push_back(name);
      continue;
    }
    Gecko::GeckoCode code = *it;
    code.enabled = true;
    selected.push_back(std::move(code));
  }

  // PatchEngine::LoadPatches activates the "synced" code lists when this override is set (that's
  // how NetPlay pushes the host's codes). Reusing it keeps the user's ini untouched. The current-run
  // layer is cleared when the game stops, so this applies to exactly one boot.
  // Action Replay codes: only the ones asked for by name (offline: Training Display).
  std::vector<ActionReplay::ARCode> ar_selected;
  if (!ar_names.empty())
  {
    const std::vector<ActionReplay::ARCode> ar_all =
        ActionReplay::LoadCodes(SConfig::LoadDefaultGameIni(game_id, revision),
                                SConfig::LoadLocalGameIni(game_id, revision));
    for (const std::string& name : ar_names)
    {
      const auto it = std::ranges::find_if(ar_all, [&](const auto& c) { return c.name == name; });
      if (it == ar_all.end())
      {
        missing.push_back(name);
        continue;
      }
      ActionReplay::ARCode code = *it;
      code.enabled = true;
      ar_selected.push_back(std::move(code));
    }
  }

  Gecko::UpdateSyncedCodes(selected);
  ActionReplay::UpdateSyncedCodes(ar_selected);
  Config::SetCurrent(Config::SESSION_CODE_SYNC_OVERRIDE, true);
  return missing;
}

std::vector<std::string> DefaultEnabledGeckoNames(const std::string& game_id, u16 revision,
                                                  const std::vector<std::string>& exclude)
{
  std::vector<std::string> names;
  for (const Gecko::GeckoCode& code : LoadAllCodes(game_id, revision))
  {
    if (code.enabled && std::ranges::find(exclude, code.name) == exclude.end())
      names.push_back(code.name);
  }
  return names;
}

std::vector<std::pair<u32, u32>> PortCodeWrites(const std::string& game_id, u16 revision,
                                                const std::map<int, std::vector<std::string>>& port_gecko)
{
  std::vector<std::pair<u32, u32>> out;
  const std::vector<Gecko::GeckoCode> all = LoadAllCodes(game_id, revision);
  for (const auto& [port, names] : port_gecko)
  {
    for (const std::string& name : names)
    {
      const auto it = std::ranges::find_if(all, [&](const auto& c) { return c.name == name; });
      if (it == all.end())
        continue;
      const auto& lines = it->codes;
      for (std::size_t i = 0; i < lines.size(); ++i)
      {
        const u32 type = lines[i].address >> 24;
        const u32 offset = lines[i].address & 0x01FFFFFF;
        const u32 data = lines[i].data;
        u32 size = 0;
        std::size_t payload = 0;  // lines after this one that are data, not codes
        switch (type & 0xFE)
        {
        case 0x00:  // 8-bit write (x count)
          size = (data >> 16) + 1;
          break;
        case 0x02:  // 16-bit write (x count)
          size = 2 * ((data >> 16) + 1);
          break;
        case 0x04:  // 32-bit write
          size = 4;
          break;
        case 0x06:  // string write
          size = data;
          payload = (data + 7) / 8;
          break;
        case 0xC2:  // insert ASM: the hooked instruction becomes a branch
          size = 4;
          payload = data;
          break;
        case 0xC0:  // execute ASM
        case 0xF2:
          payload = data;
          break;
        case 0x08:  // serial write
          payload = 1;
          break;
        default:
          break;
        }
        // Only the base-address forms (not pointer-relative ones), in MEM1.
        if (size != 0 && (type & 0x10) == 0 && offset < 0x01800000)
          out.emplace_back(offset, size);
        i += payload;
      }
    }
  }
  return out;
}

std::string HashNetplayGeckoSetup(const std::string& game_id, u16 revision, bool use_defaults,
                                  const std::map<int, std::vector<std::string>>& port_gecko,
                                  const std::vector<std::string>& lobby_on)
{
  std::vector<std::string> port_names;
  for (const auto& [port, names] : port_gecko)
    port_names.insert(port_names.end(), names.begin(), names.end());

  std::set<std::string> wanted(port_names.begin(), port_names.end());
  // Every code the host may switch on (on or not, everyone must have the same ones).
  const std::vector<std::string> lobby = LobbyCodeNames(game_id, revision);
  wanted.insert(lobby.begin(), lobby.end());
  port_names.insert(port_names.end(), lobby.begin(), lobby.end());  // never "defaults"
  if (use_defaults)
  {
    for (std::string& n : DefaultEnabledGeckoNames(game_id, revision, port_names))
      wanted.insert(std::move(n));
  }

  const std::vector<Gecko::GeckoCode> all = LoadAllCodes(game_id, revision);
  auto ctx = Common::SHA1::CreateContext();
  for (const std::string& name : wanted)  // std::set: stable order
  {
    ctx->Update(name);
    const auto it = std::ranges::find_if(all, [&](const auto& c) { return c.name == name; });
    if (it == all.end())
    {
      ctx->Update(std::string_view("|missing\n"));
      continue;
    }
    for (const Gecko::GeckoCode::Code& c : it->codes)
      ctx->Update(fmt::format("|{:08X}{:08X}", c.address, c.data));
    ctx->Update(std::string_view("\n"));
  }
  // Which of them the host switched on (sorted: the order they were picked doesn't matter).
  std::set<std::string> on(lobby_on.begin(), lobby_on.end());
  for (const std::string& name : on)
    ctx->Update("|on:" + name + "\n");
  return Common::SHA1::DigestToString(ctx->Finish());
}

}  // namespace Sparking
