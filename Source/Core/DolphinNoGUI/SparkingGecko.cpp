// Copyright 2026 Dolphin-Sparking Project
// SPDX-License-Identifier: GPL-2.0-or-later

#include "DolphinNoGUI/SparkingGecko.h"

#include <algorithm>
#include <set>

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
}  // namespace

std::string ListGeckoCodesJson(const std::string& game_id, std::optional<u16> revision)
{
  std::vector<std::string> items;
  for (const Gecko::GeckoCode& code : LoadAllCodes(game_id, revision))
  {
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
                        .Str());
  }
  return JsonArray(items);
}

std::vector<std::string> ActivateExclusiveGeckoCodes(const std::string& game_id, u16 revision,
                                                     const std::vector<std::string>& names)
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
  Gecko::UpdateSyncedCodes(selected);
  ActionReplay::UpdateSyncedCodes({});
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

std::string HashNetplayGeckoSetup(const std::string& game_id, u16 revision, bool use_defaults,
                                  const std::map<int, std::vector<std::string>>& port_gecko)
{
  std::vector<std::string> port_names;
  for (const auto& [port, names] : port_gecko)
    port_names.insert(port_names.end(), names.begin(), names.end());

  std::set<std::string> wanted(port_names.begin(), port_names.end());
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
  return Common::SHA1::DigestToString(ctx->Finish());
}

}  // namespace Sparking
