// Copyright 2026 Dolphin-Sparking Project
// SPDX-License-Identifier: GPL-2.0-or-later

#include "DolphinNoGUI/SparkingGecko.h"

#include <algorithm>

#include "Common/Config/Config.h"
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

}  // namespace Sparking
