// Copyright 2026 Dolphin-Sparking Project
// SPDX-License-Identifier: GPL-2.0-or-later

#include "DolphinNoGUI/SparkingLobby.h"

#include <cctype>

#include <fmt/format.h>

#include "Common/Version.h"
#include "DolphinNoGUI/SparkingIO.h"
#include "UICommon/NetPlayIndex.h"

namespace Sparking
{
namespace
{
constexpr std::string_view TAG = "SPK1";

std::string ParseGameId(const std::string& game)
{
  // "Title (RDSPAF, Revision 0)" -> "RDSPAF"
  const size_t open = game.rfind('(');
  if (open == std::string::npos || open + 7 > game.size())
    return {};
  const std::string id = game.substr(open + 1, 6);
  for (const char c : id)
  {
    if (!std::isalnum(static_cast<unsigned char>(c)))
      return {};
  }
  const char after = game[open + 7];
  return after == ',' || after == ')' ? id : std::string();
}
}  // namespace

bool IsValidLobbyMode(const std::string& mode)
{
  return mode == "single" || mode == "team" || mode == "any";
}

bool LobbyModesMatch(const std::string& wanted, const std::string& lobby)
{
  return wanted == "any" || lobby == "any" || wanted == lobby;
}

std::string MakeLobbyName(const std::string& mode, const std::string& link,
                          const std::string& host)
{
  // '|' separates fields; keep it out of the host name.
  std::string clean = host;
  for (char& c : clean)
  {
    if (c == '|')
      c = '/';
  }
  return fmt::format("{}|{}|{}|{}", TAG, mode, link, clean);
}

std::optional<std::vector<LobbyInfo>> ListLobbies(std::string* error)
{
  NetPlayIndex index;
  // Same build only (the version string is never shown, it only filters), no private lobbies.
  const auto sessions =
      index.List({{"version", Common::GetScmDescStr()}, {"password", "0"}});
  if (!sessions)
  {
    if (error)
      *error = index.GetLastError();
    return std::nullopt;
  }

  std::vector<LobbyInfo> lobbies;
  for (const ::NetPlaySession& s : *sessions)
  {
    // "SPK1|mode|link|host name"
    if (!s.name.starts_with(std::string(TAG) + "|"))
      continue;
    const size_t a = s.name.find('|');
    const size_t b = s.name.find('|', a + 1);
    const size_t c = b == std::string::npos ? b : s.name.find('|', b + 1);
    if (b == std::string::npos || c == std::string::npos)
      continue;
    LobbyInfo lobby;
    lobby.mode = s.name.substr(a + 1, b - a - 1);
    lobby.link = s.name.substr(b + 1, c - b - 1);
    lobby.host = s.name.substr(c + 1);
    if (!IsValidLobbyMode(lobby.mode))
      continue;
    lobby.region = s.region;
    lobby.game = s.game_id;
    lobby.game_id = ParseGameId(s.game_id);
    lobby.players = s.player_count;
    lobby.in_game = s.in_game;
    lobby.method = s.method;
    lobby.join = s.method == "traversal" ? s.server_id : fmt::format("{}:{}", s.server_id, s.port);
    lobbies.push_back(std::move(lobby));
  }
  return lobbies;
}

std::string LobbyJson(const LobbyInfo& lobby)
{
  return Json()
      .Add("host", lobby.host)
      .Add("mode", lobby.mode)
      .Add("link", lobby.link)
      .Add("region", lobby.region)
      .Add("game", lobby.game)
      .Add("game_id", lobby.game_id)
      .Add("players", lobby.players)
      .Add("in_game", lobby.in_game)
      .Add("joinable", !lobby.in_game && lobby.players < 2)
      .Add("method", lobby.method)
      .Add("join", lobby.join)
      .Str();
}
}  // namespace Sparking
