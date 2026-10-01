// Copyright 2026 Dolphin-Sparking Project
// SPDX-License-Identifier: GPL-2.0-or-later

// Gecko code control for the Sparking frontend.
//
// The frontend owns which codes are on (per game, per player) and passes them at launch. Dolphin
// then activates *exactly* those codes for the next boot, all others off, via the same mechanism
// NetPlay's "sync codes" uses -- so nothing is written to the user's GameSettings ini.

#pragma once

#include <map>
#include <optional>
#include <string>
#include <vector>

#include "Common/CommonTypes.h"

namespace Sparking
{
// Every Gecko code Dolphin knows for a game (bundled Sys/GameSettings + user GameSettings), as a
// JSON array of {name, creator, notes, default_enabled, user_defined, lines}.
std::string ListGeckoCodesJson(const std::string& game_id, std::optional<u16> revision);

// Make exactly `names` the active Gecko codes (and no Action Replay codes) for the next boot.
// Must be called on the host thread before the game boots. Returns the names that weren't found.
std::vector<std::string> ActivateExclusiveGeckoCodes(const std::string& game_id, u16 revision,
                                                     const std::vector<std::string>& names);

// Names of the codes the game's inis enable by default (Sys + user [Gecko_Enabled]), minus
// `exclude` (e.g. per-port codes, which must never be on for everyone).
std::vector<std::string> DefaultEnabledGeckoNames(const std::string& game_id, u16 revision,
                                                  const std::vector<std::string>& exclude);

// Fingerprint of a netplay Gecko setup: the default-on codes (if use_defaults) plus every per-port
// code, by name and exact code lines. Peers with different fingerprints would run different code
// and desync.
std::string HashNetplayGeckoSetup(const std::string& game_id, u16 revision, bool use_defaults,
                                  const std::map<int, std::vector<std::string>>& port_gecko);

}  // namespace Sparking
