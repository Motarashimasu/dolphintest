// Copyright 2026 Dolphin-Sparking Project
// SPDX-License-Identifier: GPL-2.0-or-later

// Public lobbies on Dolphin's lobby server (NetPlay index, lobby.dolphin-emu.org).
//
// The index only stores a few fixed fields (name, region, game, player count, in-game, version,
// room code), so Sparking packs its own data into the session NAME:
//     SPK1|<mode>|<link>|<host name>        e.g. "SPK1|single|wired|Goku"
// Lobbies without that tag (regular Dolphin users) are ignored, and the list is always filtered
// to the exact same build (the index's "version" = Dolphin's scm description string), so players
// only ever see lobbies they can actually play with.

#pragma once

#include <optional>
#include <string>
#include <vector>

namespace Sparking
{
// "single", "team" or "any".
bool IsValidLobbyMode(const std::string& mode);
// Whether someone looking for `wanted` can join a lobby hosting `lobby` ("any" matches all).
bool LobbyModesMatch(const std::string& wanted, const std::string& lobby);

std::string MakeLobbyName(const std::string& mode, const std::string& link,
                          const std::string& host);

struct LobbyInfo
{
  std::string host;
  std::string mode;
  std::string link;
  std::string region;
  std::string game;     // the host's netplay game name ("Title (GAMEID, Revision N)")
  std::string game_id;  // parsed from `game` when possible
  int players = 0;
  bool in_game = false;
  std::string method;   // "traversal" or "direct"
  std::string join;     // what --netplay-join takes: room code, or ip:port
};

// Lobbies on the index for this exact build, without passwords, carrying the Sparking tag.
// nullopt (and `error` set) if the server couldn't be reached.
std::optional<std::vector<LobbyInfo>> ListLobbies(std::string* error);

// JSON object for one lobby (no version: the frontend never shows it).
std::string LobbyJson(const LobbyInfo& lobby);
}  // namespace Sparking
