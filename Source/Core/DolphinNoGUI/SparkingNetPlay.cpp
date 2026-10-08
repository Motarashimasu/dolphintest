// Copyright 2026 Dolphin-Sparking Project
// SPDX-License-Identifier: GPL-2.0-or-later

#include "DolphinNoGUI/SparkingNetPlay.h"

#include "DolphinNoGUI/SparkingDisplay.h"
#include "DolphinNoGUI/SparkingGecko.h"
#include "DolphinNoGUI/SparkingHud.h"
#include "DolphinNoGUI/SparkingLobby.h"
#include "DolphinNoGUI/SparkingNet.h"
#include "DolphinNoGUI/SparkingWatch.h"

#include <algorithm>
#include <array>
#include <charconv>
#include <filesystem>
#include <set>
#include <string_view>

#include <fmt/format.h>

#include "Common/Crypto/SHA1.h"
#include "Common/FileUtil.h"
#include "Common/IOFile.h"
#include "Common/IniFile.h"
#include "Core/ConfigManager.h"
#include "Common/NandPaths.h"
#include "Common/StringUtil.h"
#include "Common/TraversalClient.h"
#include "Core/Boot/Boot.h"
#include "Core/Config/MainSettings.h"
#include "Core/Config/NetplaySettings.h"
#include "Core/Config/UISettings.h"
#include "Core/Core.h"
#include "Core/IOS/FS/FileSystem.h"
#include "Core/State.h"
#include "Core/System.h"
#include "Core/TitleDatabase.h"
#include "UICommon/GameFile.h"
#include "UICommon/GameFileCache.h"

namespace Sparking
{
namespace
{
std::string_view GameStatusString(NetPlay::SyncIdentifierComparison c)
{
  using C = NetPlay::SyncIdentifierComparison;
  switch (c)
  {
  case C::SameGame:
    return "ok";
  case C::DifferentHash:
    return "wrong_hash";
  case C::DifferentDiscNumber:
    return "wrong_disc";
  case C::DifferentRevision:
    return "wrong_revision";
  case C::DifferentRegion:
    return "wrong_region";
  case C::DifferentGame:
    return "not_found";
  default:
    return "unknown";
  }
}

std::string_view TraversalErrorString(Common::TraversalClient::FailureReason r)
{
  using R = Common::TraversalClient::FailureReason;
  switch (r)
  {
  case R::BadHost:
    return "bad_host";
  case R::VersionTooOld:
    return "version_too_old";
  case R::ServerForgotAboutUs:
    return "server_forgot";
  case R::SocketSendError:
    return "socket_send_error";
  case R::ResendTimeout:
    return "resend_timeout";
  default:
    return "unknown";
  }
}

// Control messages travel as NetPlay chat starting with this marker (ASCII unit separator, which
// nobody types). Version the payload so a future protocol change can't be misread.
constexpr std::string_view CONTROL_MARKER = "\x1fSPK1 ";

std::vector<std::string> SplitSpaces(std::string_view s)
{
  std::vector<std::string> out;
  size_t i = 0;
  while (i < s.size())
  {
    const size_t j = s.find(' ', i);
    const size_t end = j == std::string_view::npos ? s.size() : j;
    if (end > i)
      out.emplace_back(s.substr(i, end - i));
    i = end + 1;
  }
  return out;
}

std::optional<AutoMap> ParseAutoMap(std::string_view s)
{
  if (s == "wii" || s == "wiimote")
    return AutoMap::Wiimote;
  if (s == "gc" || s == "gamecube")
    return AutoMap::GameCube;
  if (s == "none" || s == "off")
    return AutoMap::None;
  return std::nullopt;
}
}  // namespace

bool IsSafeStateName(std::string_view name)
{
  if (name.empty() || name.size() > 96 || name.front() == '.')
    return false;
  // .sst is our naming; .sav is what regular Dolphin's "Save State to File" writes. Same format.
  if (name.size() < 5 ||
      (name.substr(name.size() - 4) != ".sst" && name.substr(name.size() - 4) != ".sav"))
    return false;
  for (const char c : name)
  {
    const bool ok = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') ||
                    c == '-' || c == '_' || c == '.';
    if (!ok)
      return false;
  }
  return name.find("..") == std::string_view::npos;
}

std::optional<std::string> HashFile(const std::string& path)
{
  File::IOFile f(path, "rb");
  if (!f.IsOpen())
    return std::nullopt;
  std::vector<u8> data(f.GetSize());
  if (!data.empty() && !f.ReadBytes(data.data(), data.size()))
    return std::nullopt;
  return Common::SHA1::DigestToString(Common::SHA1::CalculateDigest(data));
}

std::string HashWiiSave(u64 title_id)
{
  namespace fs = std::filesystem;
  const fs::path root = StringToPath(
      Common::GetTitleDataPath(title_id, Common::FromWhichRoot::Configured));
  std::error_code ec;
  if (!fs::is_directory(root, ec))
    return "missing";

  std::vector<fs::path> files;
  for (const auto& entry : fs::recursive_directory_iterator(root, ec))
  {
    if (entry.is_regular_file(ec))
      files.push_back(entry.path());
  }
  if (files.empty())
    return "missing";
  std::sort(files.begin(), files.end());

  // Hash relative path + size + contents of every file, in a stable order.
  auto ctx = Common::SHA1::CreateContext();
  for (const fs::path& file : files)
  {
    const std::string rel = PathToString(file.lexically_relative(root).generic_u8string());
    File::IOFile f(PathToString(file), "rb");
    std::vector<u8> data(f.IsOpen() ? f.GetSize() : 0);
    if (!data.empty() && !f.ReadBytes(data.data(), data.size()))
      data.clear();
    ctx->Update(rel);
    ctx->Update(fmt::format(":{}:", data.size()));
    ctx->Update(data);
  }
  return Common::SHA1::DigestToString(ctx->Finish());
}

NetPlaySession::NetPlaySession() = default;

NetPlaySession::~NetPlaySession()
{
  StopAutoTicker();
  *m_alive = false;
  Shutdown();
}

bool NetPlaySession::Start(const NetPlayOptions& options)
{
  m_nickname = options.nickname.empty() ? Config::Get(Config::NETPLAY_NICKNAME) : options.nickname;
  m_local_link = options.link.empty() ? DetectLinkType() : options.link;
  Emit("link", Json().Add("type", m_local_link));
  SetHudNetplayStats(-2, static_cast<int>(Config::Get(Config::NETPLAY_BUFFER_SIZE)));
  m_mode = IsValidLobbyMode(options.mode) ? options.mode : "any";
  // Buffer Training is a solo session: never listed, nobody else gets in.
  m_public = options.is_public && options.host_game_path.has_value() && m_mode != "training";
  m_region = options.region.empty() ? "NA" : options.region;
  m_public_address = options.public_address;
  m_automap = options.automap;
  m_spectate = options.spectate && !options.host_game_path;
  m_ranked = options.ranked && options.host_game_path.has_value() && m_mode != "training";
  m_koth = (options.koth || m_ranked) && m_mode != "training";
  if (m_ranked)
    m_public = false;  // listed by the ranked server instead
  m_koth_cap = m_mode == "team" ? 1 : 2;  // Team Battle: 1 win takes the set; otherwise first to 2
  m_state_dir = options.state_dir;
  m_port_gecko = options.port_gecko;
  m_gecko_defaults = options.gecko_defaults;

  // Build the candidate list used to match whatever game the host picks. We check the paths the
  // frontend passed explicitly first, then Dolphin's configured game folders.
  {
    std::vector<std::string> paths = options.game_paths;
    if (options.host_game_path)
      paths.insert(paths.begin(), *options.host_game_path);

    const std::vector<std::string> iso_dirs = Config::GetIsoPaths();
    const std::vector<std::string_view> dir_views(iso_dirs.begin(), iso_dirs.end());
    for (std::string& p :
         UICommon::FindAllGamePaths(dir_views, Config::Get(Config::MAIN_RECURSIVE_ISO_PATHS)))
    {
      paths.push_back(std::move(p));
    }

    for (const std::string& path : paths)
    {
      auto game = std::make_shared<const UICommon::GameFile>(path);
      if (game->IsValid())
        m_games.push_back(std::move(game));
    }
  }

  const std::string traversal_choice = Config::Get(Config::NETPLAY_TRAVERSAL_CHOICE);
  const std::string traversal_host = Config::Get(Config::NETPLAY_TRAVERSAL_SERVER);
  const u16 traversal_port = Config::Get(Config::NETPLAY_TRAVERSAL_PORT);
  const u16 traversal_port_alt = Config::Get(Config::NETPLAY_TRAVERSAL_PORT_ALT);

  std::string connect_host;
  u16 connect_port = 0;

  if (options.host_game_path)
  {
    const auto game = m_games.empty() ? nullptr : m_games.front();
    if (!game || game->GetFilePath() != *options.host_game_path)
    {
      Emit("error", Json().Add("code", "invalid_game").Add("path", *options.host_game_path));
      return false;
    }

    m_use_traversal = traversal_choice == "traversal";
    u16 host_port = Config::Get(Config::NETPLAY_HOST_PORT);
    if (m_use_traversal)
      host_port = Config::Get(Config::NETPLAY_LISTEN_PORT);

    m_server = std::make_unique<NetPlay::NetPlayServer>(
        host_port, Config::Get(Config::NETPLAY_USE_UPNP), this,
        NetPlay::NetTraversalConfig{m_use_traversal, traversal_host, traversal_port,
                                    traversal_port_alt});
    if (!m_server->is_connected)
    {
      Emit("error", Json().Add("code", "listen_failed").Add("port", host_port));
      m_server.reset();
      return false;
    }

    const Core::TitleDatabase title_db;
    m_host_game_name = game->GetNetPlayName(title_db);
    m_server->ChangeGame(game->GetSyncIdentifier(), m_host_game_name);

    const std::string network_mode = Config::Get(Config::NETPLAY_NETWORK_MODE);
    m_server->SetHostInputAuthority(network_mode == "hostinputauthority" ||
                                    network_mode == "golf");
    m_server->AdjustPadBufferSize(Config::Get(Config::NETPLAY_BUFFER_SIZE));

    connect_host = "127.0.0.1";
    connect_port = m_server->GetPort();
  }
  else if (options.join_target)
  {
    const std::string& target = *options.join_target;
    const size_t colon = target.rfind(':');
    if (colon != std::string::npos)
    {
      // Direct connection: "1.2.3.4:2626"
      m_use_traversal = false;
      connect_host = target.substr(0, colon);
      // Dolphin builds with -fno-exceptions, so parse without std::stoul.
      const char* first = target.data() + colon + 1;
      const char* last = target.data() + target.size();
      const auto [ptr, ec] = std::from_chars(first, last, connect_port);
      if (ec != std::errc() || ptr != last || connect_port == 0)
      {
        Emit("error", Json().Add("code", "bad_address").Add("target", target));
        return false;
      }
    }
    else
    {
      // Traversal room code
      m_use_traversal = true;
      connect_host = target;
      connect_port = Config::Get(Config::NETPLAY_CONNECT_PORT);
    }
  }
  else
  {
    Emit("error", Json().Add("code", "no_session_target"));
    return false;
  }

  Emit("lobby_opening", Json()
                            .Add("role", m_server ? "host" : "client")
                            .Add("traversal", m_use_traversal)
                            .Add("nickname", m_nickname)
                            .Add("known_games", static_cast<int64_t>(m_games.size())));

  m_client = std::make_unique<NetPlay::NetPlayClient>(
      connect_host, connect_port, this, m_nickname,
      NetPlay::NetTraversalConfig{m_server ? false : m_use_traversal, traversal_host,
                                  traversal_port});

  if (!m_client->IsConnected())
  {
    // OnConnectionError / OnTraversalError has already emitted the specific reason.
    Emit("error", Json().Add("code", "connect_failed"));
    Shutdown();
    return false;
  }

  Emit("lobby_ready", Json().Add("role", m_server ? "host" : "client"));
  m_players_dirty = true;
  return true;
}

void NetPlaySession::Shutdown()
{
  StopAutoTicker();
  *m_alive = false;
  if (m_index)
  {
    m_index->Remove();  // take the lobby off the public list first
    m_index.reset();
    m_index_added = false;
  }
  // Same order as the Qt frontend: client first, then server.
  m_client.reset();
  m_server.reset();
}

void NetPlaySession::Pump()
{
  if (!m_client)
    return;

  EmitRoom();

  if (m_server && m_rebroadcast_state.exchange(false))
    BroadcastBattleState();
  if (m_server && m_rebroadcast_save.exchange(false))
    BroadcastSaveCheck();
  if (m_rejected.exchange(false))
  {
    std::string reason;
    {
      std::lock_guard lk(m_links_mutex);
      reason = m_reject_reason;
    }
    Emit("error", Json().Add("code", reason.empty() ? "lobby_full" : reason));
    m_quit = true;
  }
  if (m_server && !m_kick_at.empty())
  {
    const auto now = std::chrono::steady_clock::now();
    std::map<NetPlay::PlayerId, std::string> present;
    for (const NetPlay::Player* p : m_client->GetPlayers())
      present[p->pid] = p->name;
    for (auto it = m_kick_at.begin(); it != m_kick_at.end();)
    {
      // Already gone (left on their own after the notice), or the number now belongs to someone
      // else: nothing more to do.
      const auto who = present.find(it->first);
      if (who == present.end() || (!it->second.name.empty() && who->second != it->second.name))
      {
        it = m_kick_at.erase(it);
        continue;
      }
      if (now >= it->second.kick_at)
      {
        m_server->KickPlayer(it->first);
        it = m_kick_at.erase(it);
        continue;
      }
      if (now >= it->second.next_notice)
      {
        SendControl(fmt::format("reject {} {}", static_cast<int>(it->first), it->second.reason));
        it->second.next_notice = now + std::chrono::milliseconds(250);
      }
      ++it;
    }
  }
  if (m_server)
  {
    PumpAutoBuffer();
    PumpKoth();
    ApplyModeBattleState();
    UpdatePublicListing();
  }
  if (m_rebroadcast_link.exchange(false))
  {
    {
      std::lock_guard lk(m_links_mutex);
      m_links[m_client->GetLocalPlayerId()] = m_local_link;
      m_roles[m_client->GetLocalPlayerId()] = m_spectate ? "spectator" : "player";
    }
    SendControl(std::string("role ") + (m_spectate ? "spectator" : "player"));
    SendControl("link " + m_local_link);
    PushHudPlayers();
    m_players_dirty = true;
  }

  const auto now = std::chrono::steady_clock::now();
  // Pings change constantly without an Update() callback, so also refresh once a second.
  if (m_players_dirty.exchange(false) || now - m_last_player_emit > std::chrono::seconds(1))
  {
    ApplyAutoMap();
    EmitPlayers();
    m_last_player_emit = now;
  }
}

void NetPlaySession::EmitPlayers()
{
  const auto players = m_client->GetPlayers();
  const auto& pad_map = m_client->GetPadMapping();
  const auto& gba = m_client->GetGBAConfig();
  const auto& wii_map = m_client->GetWiimoteMapping();

  std::map<NetPlay::PlayerId, LinkQuality> quality;
  for (const NetPlay::Player* p : players)
    quality[p->pid] = QualityOf(p->pid, p->ping);

  {
    std::lock_guard lk(m_links_mutex);
    for (const NetPlay::Player* p : players)
      m_names[p->pid] = p->name;
  }
  std::vector<std::string> list;
  list.reserve(players.size());
  for (const NetPlay::Player* p : players)
  {
    int gc_slot = -1, wii_slot = -1;
    for (int i = 0; i < 4; ++i)
    {
      if (pad_map[i] == p->pid && gc_slot < 0)
        gc_slot = i + 1;
      if (wii_map[i] == p->pid && wii_slot < 0)
        wii_slot = i + 1;
    }
    list.push_back(Json()
                       .Add("pid", static_cast<int>(p->pid))
                       .Add("name", p->name)
                       .Add("ping", p->ping)
                       .Add("status", GameStatusString(p->game_status))
                       .Add("is_host", p->IsHost())
                       .Add("gc_slot", gc_slot)
                       .Add("wii_slot", wii_slot)
                       .Add("mapping", NetPlay::GetPlayerMappingString(p->pid, pad_map, gba, wii_map))
                       .Add("revision", p->revision)
                       .Add("link", LinkOf(p->pid))
                       .Add("role", p->IsHost() ? std::string("player") : RoleOf(p->pid))
                       .Add("jitter", quality[p->pid].jitter_ms)
                       .Add("quality", quality[p->pid].rating)
                       .Add("state_status", [&]() -> std::string {
                         if (!m_server)
                           return "";
                         const auto it = m_state_acks.find(p->pid);
                         return it == m_state_acks.end() ? "pending" : it->second;
                       }())
                       .Add("save_status", [&]() -> std::string {
                         if (!m_server)
                           return "";
                         const auto it = m_save_acks.find(p->pid);
                         return it == m_save_acks.end() ? "pending" : it->second;
                       }())
                       .Str());
  }

  Emit("players", Json()
                      .AddRaw("players", JsonArray(list))
                      .Add("all_have_game", m_client->DoAllPlayersHaveGame())
                      .Add("in_game", m_game_running.load()));
}

void NetPlaySession::EmitRoom()
{
  if (!m_server)
    return;

  Json room;
  if (m_use_traversal)
  {
    if (!Common::g_TraversalClient)
      return;
    switch (Common::g_TraversalClient->GetState())
    {
    case Common::TraversalClient::State::Connecting:
      room.Add("type", "traversal").Add("state", "connecting");
      break;
    case Common::TraversalClient::State::Connected:
    {
      const auto host_id = Common::g_TraversalClient->GetHostID();
      room.Add("type", "traversal")
          .Add("state", "ready")
          .Add("code", std::string(host_id.begin(), host_id.end()));
      break;
    }
    case Common::TraversalClient::State::Failure:
      room.Add("type", "traversal").Add("state", "failed");
      break;
    }
  }
  else
  {
    std::vector<std::string> addrs;
    for (const std::string& iface : m_server->GetInterfaceSet())
      addrs.push_back(Json::Escape(m_server->GetInterfaceHost(iface)));
    room.Add("type", "direct")
        .Add("state", "ready")
        .Add("port", static_cast<int>(m_server->GetPort()))
        .AddRaw("addresses", JsonArray(addrs));
  }

  room.Add("public", m_public).Add("mode", m_mode);
  std::string json = room.Str();
  if (json == m_last_room_json)
    return;
  m_last_room_json = std::move(json);
  Emit("room", room);
}

void NetPlaySession::ApplyAutoMap()
{
  if (!m_server || m_automap == AutoMap::None || m_game_running)
    return;

  NetPlay::PadMappingArray map = m_automap == AutoMap::Wiimote ? m_server->GetWiimoteMapping() :
                                                                  m_server->GetPadMapping();
  bool changed = false;
  const auto now = std::chrono::steady_clock::now();
  auto players = m_client->GetPlayers();
  std::ranges::sort(players, {}, &NetPlay::Player::pid);  // first come, first served
  int spectators = 0;
  // Dolphin hands every newcomer a free port as they connect: only ports 1-2 are for playing.
  if (m_automap == AutoMap::GameCube)
  {
    for (size_t i = MAX_PLAYERS; i < map.size(); ++i)
    {
      if (map[i] != 0)
      {
        map[i] = 0;
        changed = true;
      }
    }
  }
  if (m_koth && m_automap == AutoMap::GameCube)
  {
    KothMap(map, changed, players);
  }
  else
  {
    for (const NetPlay::Player* p : players)
    {
      m_first_seen.try_emplace(p->pid, now);
      if (m_kick_at.contains(p->pid))
        continue;
      if (m_mode == "training" && !p->IsHost())
      {
        RejectPlayer(p->pid, "training_solo");
        continue;
      }
      std::string role = p->IsHost() ? "player" : RoleOf(p->pid);
      if (role == "pending")
      {
        // Older builds never say: after a few seconds they count as players.
        if (now - m_first_seen[p->pid] < std::chrono::seconds(3))
          continue;
        role = "player";
      }
      const auto mapped = std::find(map.begin(), map.end(), p->pid);
      if (role == "spectator")
      {
        if (mapped != map.end())  // spectators never hold a port
        {
          *mapped = 0;
          changed = true;
        }
        if (++spectators > MAX_SPECTATORS)
          RejectPlayer(p->pid, "spectators_full");
        continue;
      }
      if (mapped != map.end())
        continue;
      const auto ports = map.begin() + MAX_PLAYERS;  // GameCube ports 1-2 only
      const auto free_slot = std::find(map.begin(), ports, NetPlay::PlayerId{0});
      if (free_slot == ports)
      {
        RejectPlayer(p->pid, "lobby_full");
        continue;
      }
      *free_slot = p->pid;
      changed = true;
    }
  }
  for (auto it = m_first_seen.begin(); it != m_first_seen.end();)
  {
    const bool gone = std::ranges::none_of(players, [&](const NetPlay::Player* p) {
      return p->pid == it->first;
    });
    it = gone ? m_first_seen.erase(it) : std::next(it);
  }

  if (changed)
  {
    if (m_automap == AutoMap::Wiimote)
      m_server->SetWiimoteMapping(map);
    else
      m_server->SetPadMapping(map);
  }

  // Upstream gives every joiner BOTH a GC port and a Wii Remote. Clear the other kind so the game
  // only sees the controller type we chose (e.g. no stray Wii Remotes in GameCube mode).
  const NetPlay::PadMappingArray other = m_automap == AutoMap::Wiimote ?
                                             m_server->GetPadMapping() :
                                             m_server->GetWiimoteMapping();
  if (std::ranges::any_of(other, [](NetPlay::PlayerId pid) { return pid != 0; }))
  {
    const NetPlay::PadMappingArray empty{};
    if (m_automap == AutoMap::Wiimote)
      m_server->SetPadMapping(empty);
    else
      m_server->SetWiimoteMapping(empty);
  }
}

std::string NetPlaySession::RoleOf(NetPlay::PlayerId pid)
{
  std::lock_guard lk(m_links_mutex);
  const auto it = m_roles.find(pid);
  return it == m_roles.end() ? std::string("pending") : it->second;
}

void NetPlaySession::RejectPlayer(NetPlay::PlayerId pid, std::string_view reason)
{
  {
    // Player list first, then our lock (Dolphin calls OnPlayerDisconnect holding its own lock).
    const auto players = m_client->GetPlayers();
    std::lock_guard lk(m_links_mutex);
    for (const NetPlay::Player* p : players)
      m_names[p->pid] = p->name;
  }
  // Tell them why (repeated until then: a brand-new joiner may miss the first one), and remove
  // them a moment later.
  const auto now = std::chrono::steady_clock::now();
  std::string name;
  {
    std::lock_guard lk(m_links_mutex);
    if (const auto it = m_names.find(pid); it != m_names.end())
      name = it->second;
  }
  m_kick_at[pid] = PendingKick{std::string(reason), name, now + std::chrono::milliseconds(1500), now};
  Emit("player_rejected", Json().Add("pid", static_cast<int>(pid)).Add("reason", reason));
}

bool NetPlaySession::HandleCommand(const Command& cmd)
{
  if (!m_client)
    return false;

  const auto host_only = [&] {
    if (m_server)
      return true;
    Emit("error", Json().Add("code", "host_only").Add("command", cmd.name));
    return false;
  };

  if (cmd.name == "start")
  {
    if (host_only())
      CmdStart(cmd.arg == "force");
  }
  else if (cmd.name == "chat")
  {
    if (!cmd.arg.empty())
    {
      m_client->SendChatMessage(cmd.arg);
      Emit("chat", Json().Add("from", m_nickname).Add("text", cmd.arg).Add("self", true));
    }
  }
  else if (cmd.name == "stop")
  {
    // The King of the Hill host referees: its Stop ends the set for everyone, pad or not.
    if (m_game_running && m_koth && m_server)
      m_client->RequestStopGameForEveryone();
    else if (m_game_running)
      m_client->RequestStopGame();
  }
  else if (cmd.name == "buffer")
  {
    // "buffer <n>": manual (turns automatic off). "buffer auto": chosen from the pings at the
    // start of the match and again right after each KO.
    if (host_only())
    {
      if (cmd.arg == "auto")
      {
        m_auto_buffer = true;
        Emit("buffer_mode", Json().Add("auto", true));
      }
      else
      {
        const bool was_auto = m_auto_buffer.exchange(false);
        if (was_auto)
          Emit("buffer_mode", Json().Add("auto", false));
        m_server->AdjustPadBufferSize(static_cast<unsigned>(std::max(0, std::atoi(cmd.arg.c_str()))));
      }
    }
  }
  else if (cmd.name == "kick")
  {
    if (host_only())
      m_server->KickPlayer(static_cast<NetPlay::PlayerId>(std::atoi(cmd.arg.c_str())));
  }
  else if (cmd.name == "automap")
  {
    if (host_only())
    {
      if (const auto mode = ParseAutoMap(cmd.arg))
      {
        m_automap = *mode;
        m_players_dirty = true;
      }
      else
      {
        Emit("error", Json().Add("code", "bad_argument").Add("command", cmd.name));
      }
    }
  }
  else if (cmd.name == "save_check")
  {
    if (host_only())
      BroadcastSaveCheck();
  }
  else if (cmd.name == "battle_state")
  {
    if (host_only())
      CmdBattleState(cmd.arg);
  }
  else if (cmd.name == "players")
  {
    EmitPlayers();
  }
  else if (cmd.name == "quit" || cmd.name == "eof")
  {
    if (m_game_running)
      m_client->RequestStopGame();
    m_quit = true;
  }
  else
  {
    return false;
  }
  return true;
}

void NetPlaySession::CmdStart(bool force)
{
  if (m_game_running)
    return;

  if (m_koth)
  {
    ApplyAutoMap();  // pads 1-2 = the first two in line
    if (m_line.size() < 2)
    {
      Emit("error", Json().Add("code", "koth_need_two"));
      return;
    }
  }

  if (!force && !m_client->DoAllPlayersHaveGame())
  {
    Emit("error", Json().Add("code", "not_all_players_have_game"));
    return;
  }

  {
    std::lock_guard lk(m_game_mutex);
    if (!m_has_current_game || !FindGameFile(m_current_game))
    {
      Emit("error", Json().Add("code", "game_not_found"));
      return;
    }
  }

  bool has_battle_state;
  {
    std::lock_guard lk(m_game_mutex);
    has_battle_state = m_battle_state.has_value();
  }
  if (!force && !IsSaveDataReady())
  {
    Emit("error", Json().Add("code", "save_data_mismatch"));
    return;
  }

  if (!force && has_battle_state && !IsBattleStateReady())
  {
    Emit("error", Json().Add("code", "battle_state_not_ready"));
    return;
  }

  if (m_auto_buffer)
    ApplyAutoBuffer("match_start");
  m_seen_results = HudResultCount();
  m_auto_due.reset();
  if (m_koth)
  {
    m_koth_paused = false;
    m_next_set_at.reset();
    m_set_players = {m_line[0], m_line[1]};
    m_set_base = {HudPortWins(1), HudPortWins(2)};
    m_set_wins = {};
    m_set_decided = false;
    m_set_winner_port = 0;
    m_set_stop_at.reset();
    m_set_live = true;
  }
  if (!m_server->RequestStartGame())
  {
    m_set_live = false;
    Emit("error", Json().Add("code", "start_rejected"));
  }
  BroadcastKoth(true);
}

std::optional<NetPlaySession::AutoBufferChoice> NetPlaySession::AutoBufferTarget()
{
  // Worst player: the 90th percentile of its last ~10 pings (so short spikes are covered
  // without chasing them) plus its jitter, then ping / 12 (rounded up).
  std::map<NetPlay::PlayerId, std::vector<u32>> all;
  {
    std::lock_guard lk(m_quality_mutex);
    all = m_ping_samples;
  }
  // Only the players: a spectator's ping doesn't delay anyone's inputs (it sends none).
  std::set<NetPlay::PlayerId> playing;
  if (m_client)
  {
    for (const NetPlay::PlayerId pid : m_client->GetPadMapping())
    {
      if (pid > 0)
        playing.insert(pid);
    }
  }
  std::optional<AutoBufferChoice> worst;
  for (auto& [pid, samples] : all)
  {
    if (samples.size() < 3 || (!playing.empty() && !playing.contains(pid)))
      continue;
    const int jitter = QualityOf(pid, samples.back()).jitter_ms;
    std::ranges::sort(samples);
    const size_t at = std::min(samples.size() - 1, (samples.size() * 9 + 9) / 10 - 1);
    const u32 high = samples[at];
    const int buffer = std::clamp(static_cast<int>((high + std::max(jitter, 0) + 11) / 12), 2, 20);
    if (!worst || buffer > worst->buffer)
      worst = AutoBufferChoice{buffer, high, std::max(jitter, 0)};
  }
  return worst;
}

void NetPlaySession::ApplyAutoBuffer(std::string_view reason)
{
  if (!m_server)
    return;
  const auto choice = AutoBufferTarget();
  if (!choice)
  {
    Emit("buffer_auto", Json().Add("reason", reason).Add("skipped", "measuring"));
    return;
  }
  const int from = m_buffer;
  if (choice->buffer == from && reason != "match_start")
    return;
  Emit("buffer_auto", Json()
                          .Add("reason", reason)
                          .Add("from", from)
                          .Add("to", choice->buffer)
                          .Add("ping", static_cast<int>(choice->ping))
                          .Add("jitter", choice->jitter));
  if (choice->buffer != from)
    m_server->AdjustPadBufferSize(static_cast<unsigned>(choice->buffer));
}

void NetPlaySession::StartAutoTicker()
{
  StopAutoTicker();
  m_ticking = true;
  m_auto_ticker = std::thread([this, alive = m_alive] {
    while (m_ticking)
    {
      std::this_thread::sleep_for(std::chrono::milliseconds(250));
      if (m_ticking && (m_auto_buffer || m_koth))
      {
        Core::QueueHostJob([this, alive](Core::System&) {
          if (!*alive)
            return;
          PumpAutoBuffer();
          PumpKoth();
        });
      }
    }
  });
}

void NetPlaySession::StopAutoTicker()
{
  m_ticking = false;
  if (m_auto_ticker.joinable())
    m_auto_ticker.join();
}

void NetPlaySession::PumpAutoBuffer()
{
  if (!m_server || !m_auto_buffer || !m_game_running)
    return;
  const auto now = std::chrono::steady_clock::now();
  const int results = HudResultCount();
  if (results != m_seen_results)
  {
    // A KO was just counted: decide a moment later (the KO animation is playing), and only
    // within the next 20 s, before the next round starts.
    m_seen_results = results;
    m_auto_due = now + std::chrono::seconds(1);
    m_auto_deadline = now + std::chrono::seconds(20);
  }
  if (!m_auto_due || now < *m_auto_due)
    return;
  if (HudRoundLive() || now > *m_auto_deadline)
  {
    m_auto_due.reset();   // the next fight already started: leave it alone
    return;
  }
  m_auto_due.reset();
  ApplyAutoBuffer("between_rounds");
}

std::unique_ptr<BootParameters> NetPlaySession::TakePendingBoot()
{
  return std::move(m_pending_boot);
}

void NetPlaySession::OnGameEnded()
{
  // Mirrors NetPlayDialog: if the game ended locally (window closed etc.) rather than because
  // the server told us to stop, tell everyone else to stop too.
  if (m_client && !m_got_stop_request)
  {
    if (m_koth && m_server)
      m_client->RequestStopGameForEveryone();  // the host may be waiting in line (no pad)
    else
      m_client->RequestStopGame();
  }

  m_game_running = false;
  StopAutoTicker();
  m_got_stop_request = false;
  if (m_koth && m_server)
    OnSetEnded();
  if (m_index && m_index_added)
    m_index->SetInGame(false);
  m_players_dirty = true;
  Emit("game_stopped");
}

// ---------------------------------------------------------------------------------------------
// NetPlay::NetPlayUI. These are called from the netplay thread unless noted otherwise.

// Host thread (called from within NetPlayClient::StartGame, which we invoke on the host thread).
void NetPlaySession::BootGame(const std::string& filename,
                              std::unique_ptr<BootSessionData> boot_session_data)
{
  if (m_index && m_index_added)
    m_index->SetInGame(true);
  m_got_stop_request = false;
  m_game_running = true;
  if (m_server)
    StartAutoTicker();
  m_pending_boot = BootParameters::GenerateFromFile(
      filename, boot_session_data ? std::move(*boot_session_data) : BootSessionData());

  std::string state_name;
  {
    std::lock_guard lk(m_game_mutex);
    if (m_battle_state && m_battle_state_local_ok && m_pending_boot)
    {
      state_name = m_battle_state->name;
      m_pending_boot->boot_session_data.SetSavestateData(StatePath(state_name),
                                                         DeleteSavestateAfterBoot::No);
      // Every peer verified the same bytes, so this one load cannot desync the session.
      State::AllowNextNetPlayBootLoad();
    }
  }
  // Memory-watch events name players by their netplay username ("Goku_defeated").
  {
    std::array<std::string, 4> names;
    const auto& pad_map = m_client->GetPadMapping();
    for (const NetPlay::Player* p : m_client->GetPlayers())
    {
      for (int i = 0; i < 4; ++i)
      {
        if (pad_map[i] == p->pid)
          names[i] = p->name;
      }
    }
    SetPortNames(names);
  }
  // Gecko: all codes off except the ones assigned to the GameCube port this player landed on.
  {
    int port = 0;
    const auto& pad_map = m_client->GetPadMapping();
    for (int i = 0; i < 4 && port == 0; ++i)
    {
      if (pad_map[i] == m_client->GetLocalPlayerId())
        port = i + 1;
    }
    SetHudLocalPort(port);  // "YOU WIN"/"YOU LOSE" from this player's side (0 = spectator)
    PushHudPlayers();       // wired/Wi-Fi icons for whoever is on ports 1/2 this match
    std::shared_ptr<const UICommon::GameFile> game;
    {
      std::lock_guard lk(m_game_mutex);
      game = FindGameFile(m_current_game);
    }
    // Everyone: the game's default-on codes (never any per-port code). This player: + its port's.
    std::vector<std::string> all_port_names;
    for (const auto& [p, n] : m_port_gecko)
      all_port_names.insert(all_port_names.end(), n.begin(), n.end());
    std::vector<std::string> names;
    if (game && m_gecko_defaults)
      names = DefaultEnabledGeckoNames(game->GetGameID(), game->GetRevision(), all_port_names);
    if (const auto it = m_port_gecko.find(port); it != m_port_gecko.end())
      names.insert(names.end(), it->second.begin(), it->second.end());
    std::vector<std::string> missing;
    if (game)
      missing = ActivateExclusiveGeckoCodes(game->GetGameID(), game->GetRevision(), names);
    ApplyAspectForBoot();  // output stretch only, per player
    std::vector<std::string> active, miss;
    for (const auto& n : names)
    {
      if (std::ranges::find(missing, n) == missing.end())
        active.push_back(Json::Escape(n));
    }
    for (const auto& n : missing)
      miss.push_back(Json::Escape(n));
    Emit("gecko_active", Json()
                             .Add("port", port)
                             .AddRaw("codes", JsonArray(active))
                             .AddRaw("missing", JsonArray(miss)));
  }

  Emit("game_booting", Json().Add("path", filename).Add("battle_state", state_name));
}

void NetPlaySession::StopGame()
{
  if (m_got_stop_request.exchange(true))
    return;
  if (m_stop_game_callback)
    m_stop_game_callback();
}

bool NetPlaySession::IsHosting() const
{
  return m_server != nullptr;
}

void NetPlaySession::Update()
{
  m_players_dirty = true;
  // Netplay thread, right after a ping update: same thread that writes the player list.
  if (!m_client)
    return;
  // Netplay thread, right after a ping update: same thread that writes the player list.
  u32 ping = 0;  // the same figure Dolphin shows as "Ping": the highest player ping
  NetPlay::PlayerId worst = 0;
  const auto now = std::chrono::steady_clock::now();
  const auto players = m_client->GetPlayers();
  {
    std::lock_guard lk(m_quality_mutex);
    const bool sample = now - m_last_ping_sample >= std::chrono::milliseconds(900);
    if (sample)
      m_last_ping_sample = now;
    for (const NetPlay::Player* p : players)
    {
      if (sample)
      {
        auto& samples = m_ping_samples[p->pid];
        samples.push_back(p->ping);
        if (samples.size() > 10)  // ~10 seconds of history
          samples.erase(samples.begin());
      }
      if (p->ping >= ping)
      {
        ping = p->ping;
        worst = p->pid;
      }
    }
  }
  const LinkQuality q = QualityOf(worst, ping);
  SetHudNetplayStats(static_cast<int>(ping), -2);
  SetHudLinkQuality(q.jitter_ms, q.rating);
}

void NetPlaySession::AppendChat(const std::string& msg)
{
  // NetPlayClient formats remote chat as "name[pid]: text".
  const size_t marker = msg.find(CONTROL_MARKER);
  if (marker != std::string::npos)
  {
    const std::string prefix = msg.substr(0, marker);
    const size_t open = prefix.rfind('[');
    const size_t close = prefix.rfind(']');
    if (open != std::string::npos && close != std::string::npos && close > open + 1)
    {
      const int pid = std::atoi(prefix.substr(open + 1, close - open - 1).c_str());
      std::string body = msg.substr(marker + CONTROL_MARKER.size());
      Core::QueueHostJob(
          [this, pid, body = std::move(body)](Core::System&) {
            HandleControlMessage(static_cast<NetPlay::PlayerId>(pid), body);
          },
          /*run_during_stop=*/true);
    }
    return;  // never show control traffic as chat
  }
  Emit("chat", Json().Add("text", msg).Add("self", false));
}

void NetPlaySession::OnMsgChangeGame(const NetPlay::SyncIdentifier& sync_identifier,
                                     const std::string& netplay_name)
{
  {
    std::lock_guard lk(m_game_mutex);
    m_current_game = sync_identifier;
    m_current_game_name = netplay_name;
    m_has_current_game = true;
  }
  NetPlay::SyncIdentifierComparison found;
  FindGameFile(sync_identifier, &found);
  m_rebroadcast_save = true;  // saves are per game
  Emit("game_changed", Json()
                           .Add("name", netplay_name)
                           .Add("game_id", sync_identifier.game_id)
                           .Add("local_status", GameStatusString(found)));
}

void NetPlaySession::OnMsgChangeGBARom(int, const NetPlay::GBAConfig&)
{
}

void NetPlaySession::OnMsgStartGame()
{
  Emit("game_starting");
  // NetPlayClient::StartGame must run on the host ("GUI") thread, like in NetPlayDialog.
  Core::QueueHostJob(
      [this](Core::System&) {
        if (!m_client)
          return;
        std::shared_ptr<const UICommon::GameFile> game;
        {
          std::lock_guard lk(m_game_mutex);
          game = FindGameFile(m_current_game);
        }
        if (game)
          m_client->StartGame(game->GetFilePath());
        else
          Emit("error", Json().Add("code", "game_not_found"));
      },
      /*run_during_stop=*/true);
}

void NetPlaySession::OnMsgStopGame()
{
  Emit("game_stopping");
}

void NetPlaySession::OnMsgPowerButton()
{
}

void NetPlaySession::OnPlayerConnect(const std::string& player)
{
  m_players_dirty = true;
  m_rebroadcast_state = true;  // late joiners need the current battle-state selection
  m_rebroadcast_save = true;   // ...and must prove their save matches
  m_rebroadcast_link = true;   // ...and need to know everyone's wired/Wi-Fi status
  Emit("player_joined", Json().Add("name", player));
}

void NetPlaySession::OnPlayerDisconnect(const std::string& player)
{
  {
    // Dolphin reuses player numbers: forget what this one told us (role, link).
    std::lock_guard lk(m_links_mutex);
    for (auto it = m_names.begin(); it != m_names.end();)
    {
      if (it->second == player)
      {
        m_roles.erase(it->first);
        m_links.erase(it->first);
        it = m_names.erase(it);
      }
      else
      {
        ++it;
      }
    }
  }
  m_players_dirty = true;
  Emit("player_left", Json().Add("name", player));
}

void NetPlaySession::OnPadBufferChanged(u32 buffer)
{
  m_buffer = static_cast<int>(buffer);
  SetHudNetplayStats(-2, static_cast<int>(buffer));
  Emit("buffer_changed", Json().Add("buffer", buffer));
}

void NetPlaySession::OnHostInputAuthorityChanged(bool enabled)
{
  Emit("host_input_authority", Json().Add("enabled", enabled));
}

void NetPlaySession::OnDesync(u32 frame, const std::string& player)
{
  Emit("desync", Json().Add("frame", frame).Add("player", player));
}

void NetPlaySession::OnConnectionLost()
{
  Emit("connection_lost");
}

void NetPlaySession::OnConnectionError(const std::string& message)
{
  // NetPlayClient's text for ConnectionError::GameRunning.
  if (message == "The game is currently running.")
  {
    m_refused_game_running = true;
    Emit("error", Json().Add("code", "game_running"));
    return;
  }
  Emit("error", Json().Add("code", "connection_error").Add("message", message));
}

void NetPlaySession::OnTraversalError(Common::TraversalClient::FailureReason error)
{
  Emit("error", Json().Add("code", "traversal_error").Add("reason", TraversalErrorString(error)));
}

void NetPlaySession::OnTraversalStateChanged(Common::TraversalClient::State)
{
  // Picked up by EmitRoom() on the next Pump().
}

void NetPlaySession::OnGameStartAborted()
{
  m_game_running = false;
  StopAutoTicker();
  m_koth_start_aborted = true;
  Emit("game_start_aborted");
}

void NetPlaySession::OnGolferChanged(bool is_golfer, const std::string& golfer_name)
{
  Emit("golfer_changed", Json().Add("is_golfer", is_golfer).Add("name", golfer_name));
}

void NetPlaySession::OnTtlDetermined(u8)
{
}

bool NetPlaySession::IsRecording()
{
  return false;
}

// ---------------------------------------------------------------------------------------------
// Save-data check (host thread)

std::shared_ptr<const UICommon::GameFile> NetPlaySession::CurrentGame()
{
  std::lock_guard lk(m_game_mutex);
  if (!m_has_current_game)
    return nullptr;
  return FindGameFile(m_current_game);
}

u64 NetPlaySession::CurrentTitleID()
{
  const auto game = CurrentGame();
  return game ? game->GetTitleID() : 0;
}

std::string NetPlaySession::LocalSetupFingerprint()
{
  const auto game = CurrentGame();
  const std::string save = HashWiiSave(game ? game->GetTitleID() : 0);
  const std::string codes =
      game ? HashNetplayGeckoSetup(game->GetGameID(), game->GetRevision(), m_gecko_defaults,
                                   m_port_gecko) :
             "nogame";
  return save + "-" + codes;
}

void NetPlaySession::BroadcastSaveCheck()
{
  if (!m_client || m_game_running)
    return;
  m_host_save_hash = LocalSetupFingerprint();
  m_save_acks.clear();
  m_save_acks[m_client->GetLocalPlayerId()] = "ok";
  SendControl("save " + m_host_save_hash);
  m_players_dirty = true;
  EmitSaveData();
}

bool NetPlaySession::IsSaveDataReady()
{
  if (!m_server)
    return true;
  for (const NetPlay::Player* p : m_client->GetPlayers())
  {
    const auto it = m_save_acks.find(p->pid);
    if (it == m_save_acks.end() || it->second != "ok")
      return false;
  }
  return true;
}

void NetPlaySession::EmitSaveData()
{
  Json j;
  j.Add("host_hash", m_host_save_hash);
  if (m_server)
    j.Add("ready", IsSaveDataReady());
  else
    j.Add("local_status", m_save_local_status);
  Emit("save_data", j);
}

// ---------------------------------------------------------------------------------------------
// Battle-state sync (host thread)

std::string NetPlaySession::StatePath(const std::string& name) const
{
  return m_state_dir + "/" + name;
}

void NetPlaySession::SendControl(const std::string& body)
{
  m_client->SendChatMessage(std::string(CONTROL_MARKER) + body);
}

void NetPlaySession::CmdBattleState(const std::string& arg)
{
  if (m_game_running)
  {
    Emit("error", Json().Add("code", "not_allowed_in_game").Add("command", "battle_state"));
    return;
  }

  if (arg.empty() || arg == "none")
  {
    {
      std::lock_guard lk(m_game_mutex);
      m_battle_state.reset();
      m_battle_state_local_ok = false;
    }
    m_state_acks.clear();
    BroadcastBattleState();
    EmitBattleState();
    return;
  }

  if (!IsSafeStateName(arg) || m_state_dir.empty())
  {
    Emit("error", Json().Add("code", m_state_dir.empty() ? "no_state_dir" : "bad_state_name")
                      .Add("name", arg));
    return;
  }

  const std::optional<std::string> sha1 = HashFile(StatePath(arg));
  if (!sha1)
  {
    Emit("error", Json().Add("code", "state_file_missing").Add("name", arg));
    return;
  }

  {
    std::lock_guard lk(m_game_mutex);
    m_battle_state = BattleState{arg, *sha1};
    m_battle_state_local_ok = true;
  }
  m_state_acks.clear();
  m_state_acks[m_client->GetLocalPlayerId()] = "ok";
  BroadcastBattleState();
  EmitBattleState();
}

void NetPlaySession::BroadcastBattleState()
{
  std::optional<BattleState> state;
  {
    std::lock_guard lk(m_game_mutex);
    state = m_battle_state;
  }
  SendControl(state ? fmt::format("state {} {}", state->name, state->sha1) : "state none");
}

void NetPlaySession::HandleControlMessage(NetPlay::PlayerId from, const std::string& body)
{
  if (!m_client || from == m_client->GetLocalPlayerId())
    return;

  const std::vector<std::string> parts = SplitSpaces(body);
  if (parts.empty())
    return;

  if (parts[0] == "state" && !m_server)
  {
    // Only the host (pid 1) may select the battle state.
    if (from != 1)
      return;

    if (parts.size() == 2 && parts[1] == "none")
    {
      {
        std::lock_guard lk(m_game_mutex);
        m_battle_state.reset();
        m_battle_state_local_ok = false;
      }
      EmitBattleState();
      return;
    }
    if (parts.size() != 3 || !IsSafeStateName(parts[1]))
      return;

    const BattleState wanted{parts[1], parts[2]};
    const std::optional<std::string> local =
        m_state_dir.empty() ? std::nullopt : HashFile(StatePath(wanted.name));
    const std::string status = !local ? "missing" : (*local == wanted.sha1 ? "ok" : "mismatch");
    {
      std::lock_guard lk(m_game_mutex);
      m_battle_state = wanted;
      m_battle_state_local_ok = status == "ok";
    }
    SendControl(fmt::format("ack {} {}", wanted.sha1, status));
    EmitBattleState();
  }
  else if (parts[0] == "role" && parts.size() == 2)
  {
    {
      std::lock_guard lk(m_links_mutex);
      m_roles[from] = parts[1] == "spectator" ? "spectator" : "player";
    }
    m_players_dirty = true;
    return;
  }
  else if (parts[0] == "koth" && !m_server)
  {
    if (from != 1)
      return;
    if (const auto view = KothView::Parse(parts); view && body != m_last_koth)
    {
      m_last_koth = body;
      EmitKoth(*view);
    }
    return;
  }
  else if (parts[0] == "kothset" && parts.size() == 6 && !m_server)
  {
    if (from != 1)
      return;
    const auto name_of = [&](const std::string& pid) {
      for (const NetPlay::Player* p : m_client->GetPlayers())
      {
        if (p->pid == static_cast<NetPlay::PlayerId>(std::atoi(pid.c_str())))
          return p->name;
      }
      return std::string("?");
    };
    Emit("koth_set", Json()
                         .Add("winner", name_of(parts[1]))
                         .Add("loser", name_of(parts[2]))
                         .Add("streak", std::atoi(parts[3].c_str()))
                         .AddRaw("wins", fmt::format("[{},{}]", std::atoi(parts[4].c_str()),
                                                     std::atoi(parts[5].c_str()))));
    return;
  }
  else if (parts[0] == "reject" && parts.size() == 3 && !m_server)
  {
    if (from != 1 || std::atoi(parts[1].c_str()) != m_client->GetLocalPlayerId())
      return;
    {
      std::lock_guard lk(m_links_mutex);
      m_reject_reason = parts[2] == "spectators_full" || parts[2] == "training_solo" ||
                                parts[2] == "ranked_no_spectators" ?
                             std::string(parts[2]) :
                             "lobby_full";
    }
    m_rejected = true;
    return;
  }
  else if (parts[0] == "link" && parts.size() == 2)
  {
    static constexpr std::array<std::string_view, 4> known = {"wired", "wireless", "virtual",
                                                               "unknown"};
    {
      std::lock_guard lk(m_links_mutex);
      m_links[from] = std::ranges::find(known, parts[1]) != known.end() ? parts[1] : "unknown";
    }
    m_players_dirty = true;
    PushHudPlayers();
    return;
  }
  else if (parts[0] == "save" && !m_server && parts.size() == 2)
  {
    if (from != 1)
      return;
    // Fingerprint = "<save>-<gecko codes>"; report which half differs.
    const std::string local = LocalSetupFingerprint();
    const auto split = [](const std::string& f) {
      const size_t dash = f.rfind('-');
      return std::pair{f.substr(0, dash), dash == std::string::npos ? "" : f.substr(dash + 1)};
    };
    const auto [local_save, local_codes] = split(local);
    const auto [host_save, host_codes] = split(parts[1]);
    m_host_save_hash = parts[1];
    if (local == parts[1])
      m_save_local_status = "ok";
    else if (local_save != host_save)
      m_save_local_status = local_save == "missing" ? "missing" : "mismatch";
    else
      m_save_local_status = "codes_mismatch";
    SendControl(fmt::format("save_ack {} {}", parts[1], m_save_local_status));
    EmitSaveData();
    return;
  }
  else if (parts[0] == "save_ack" && m_server && parts.size() == 3)
  {
    if (parts[1] != m_host_save_hash)
      return;  // stale reply to an older check
    m_save_acks[from] = parts[2];
    m_players_dirty = true;
    EmitSaveData();
    return;
  }
  else if (parts[0] == "ack" && m_server && parts.size() == 3)
  {
    std::lock_guard lk(m_game_mutex);
    // Ignore acks for a selection that has since changed.
    if (!m_battle_state || parts[1] != m_battle_state->sha1)
      return;
    m_state_acks[from] = parts[2];
  }
  else
  {
    return;
  }

  if (m_server)
  {
    m_players_dirty = true;
    EmitBattleState();
  }
}

bool NetPlaySession::IsBattleStateReady()
{
  for (const NetPlay::Player* p : m_client->GetPlayers())
  {
    const auto it = m_state_acks.find(p->pid);
    if (it == m_state_acks.end() || it->second != "ok")
      return false;
  }
  return true;
}

void NetPlaySession::EmitBattleState()
{
  std::optional<BattleState> state;
  bool local_ok;
  {
    std::lock_guard lk(m_game_mutex);
    state = m_battle_state;
    local_ok = m_battle_state_local_ok;
  }

  Json j;
  j.Add("active", state.has_value());
  if (state)
    j.Add("name", state->name).Add("sha1", state->sha1).Add("local_ok", local_ok);
  if (m_server && state)
    j.Add("ready", IsBattleStateReady());
  Emit("battle_state", j);
}

std::shared_ptr<const UICommon::GameFile>
NetPlaySession::FindGameFile(const NetPlay::SyncIdentifier& sync_identifier,
                             NetPlay::SyncIdentifierComparison* found)
{
  NetPlay::SyncIdentifierComparison temp;
  if (!found)
    found = &temp;
  *found = NetPlay::SyncIdentifierComparison::DifferentGame;

  // m_games is immutable after Start(), so this is safe from any thread.
  for (const auto& game : m_games)
  {
    *found = std::min(*found, game->CompareSyncIdentifier(sync_identifier));
    if (*found == NetPlay::SyncIdentifierComparison::SameGame)
      return game;
  }
  return nullptr;
}

std::string NetPlaySession::FindGBARomPath(const std::array<u8, 20>&, std::string_view, int)
{
  return {};  // No GBA link support in the Sparking frontend.
}

void NetPlaySession::ShowGameDigestDialog(const std::string&)
{
}

void NetPlaySession::SetGameDigestProgress(int, int)
{
}

void NetPlaySession::SetGameDigestResult(int, const std::string&)
{
}

void NetPlaySession::AbortGameDigest()
{
}

void NetPlaySession::OnIndexAdded(bool, std::string)
{
}

void NetPlaySession::OnIndexRefreshFailed(std::string)
{
}

void NetPlaySession::ShowChunkedProgressDialog(const std::string& title, u64 data_size,
                                               std::span<const int>)
{
  // Save data / code sync before boot. Surfacing it lets the frontend show a loading bar.
  Emit("sync_begin", Json().Add("title", title).Add("bytes", static_cast<int64_t>(data_size)));
}

void NetPlaySession::HideChunkedProgressDialog()
{
  Emit("sync_end");
}

void NetPlaySession::SetChunkedProgress(int pid, u64 progress)
{
  Emit("sync_progress",
       Json().Add("pid", pid).Add("bytes", static_cast<int64_t>(progress)));
}

void NetPlaySession::SetHostWiiSyncData(std::vector<u64> titles, std::string redirect_folder)
{
  // Same as NetPlayDialog: lets the host write synced Wii saves back after the session.
  if (m_client)
    m_client->SetWiiSyncData(nullptr, std::move(titles), std::move(redirect_folder));
}

LinkQuality NetPlaySession::QualityOf(NetPlay::PlayerId pid, u32 current_ping)
{
  std::vector<u32> samples;
  {
    std::lock_guard lk(m_quality_mutex);
    if (const auto it = m_ping_samples.find(pid); it != m_ping_samples.end())
      samples = it->second;
  }
  LinkQuality q;
  if (samples.size() < 3)
  {
    q.rating = "measuring";
    return q;
  }
  u32 total = 0;
  for (size_t i = 1; i < samples.size(); ++i)
    total += samples[i] > samples[i - 1] ? samples[i] - samples[i - 1] : samples[i - 1] - samples[i];
  q.jitter_ms = static_cast<int>((total + (samples.size() - 1) / 2) / (samples.size() - 1));
  const u32 peak = *std::ranges::max_element(samples);
  // Thresholds for a 1-2 frame buffer fighting game: steady and low = good.
  if (current_ping <= 80 && q.jitter_ms <= 8 && peak <= 120)
    q.rating = "good";
  else if (current_ping <= 150 && q.jitter_ms <= 20 && peak <= 250)
    q.rating = "ok";
  else
    q.rating = "poor";
  return q;
}

void NetPlaySession::PushHudPlayers()
{
  if (!m_client)
    return;
  std::array<std::string, 2> links{"unknown", "unknown"};
  const auto& pad_map = m_client->GetPadMapping();
  for (int i = 0; i < 2; ++i)
    links[i] = LinkOf(pad_map[i]);
  SetHudLinks(links);
}

std::string NetPlaySession::LinkOf(NetPlay::PlayerId pid)
{
  std::lock_guard lk(m_links_mutex);
  const auto it = m_links.find(pid);
  return it == m_links.end() ? std::string("unknown") : it->second;
}

int NetPlaySession::PlayerCount()
{
  return m_client ? static_cast<int>(m_client->GetPlayers().size()) : 0;
}

int NetPlaySession::ListingCount()
{
  if (!m_client)
    return 0;
  if (m_koth && m_server)
  {
    // The 2 on pads count as players; the line and watchers as spectators.
    const int total = static_cast<int>(m_client->GetPlayers().size());
    const int pads = std::min<int>(static_cast<int>(m_line.size()), MAX_PLAYERS);
    return pads + 10 * std::clamp(total - pads, 0, 9);
  }
  int players = 0, spectators = 0;
  for (const NetPlay::Player* p : m_client->GetPlayers())
  {
    if (!p->IsHost() && RoleOf(p->pid) == "spectator")
      ++spectators;
    else
      ++players;
  }
  return std::min(players, 9) + 10 * spectators;
}

int NetPlaySession::LocalGcPort()
{
  if (!m_client)
    return 0;
  const auto& pad_map = m_client->GetPadMapping();
  for (int i = 0; i < 4; ++i)
  {
    if (pad_map[i] == m_client->GetLocalPlayerId())
      return i + 1;
  }
  return 0;
}

void NetPlaySession::UpdatePublicListing()
{
  if (!m_public || !m_server || m_index_failed)
    return;

  if (!m_index_added)
  {
    // What others use to join: the traversal room code, or (direct hosting) an address.
    std::string server_id;
    if (m_use_traversal)
    {
      if (!Common::g_TraversalClient ||
          Common::g_TraversalClient->GetState() != Common::TraversalClient::State::Connected)
      {
        return;  // try again on the next pump
      }
      const auto host_id = Common::g_TraversalClient->GetHostID();
      server_id.assign(host_id.begin(), host_id.end());
    }
    else
    {
      server_id = m_public_address;
      if (server_id.empty())
      {
        m_index_failed = true;
        Emit("public", Json().Add("listed", false).Add("error", "no_public_address"));
        return;
      }
    }

    ::NetPlaySession listing;
    listing.name = MakeLobbyName(m_mode, m_local_link, m_nickname, m_koth);
    listing.region = m_region;
    listing.method = m_use_traversal ? "traversal" : "direct";
    listing.server_id = server_id;
    {
      std::lock_guard lk(m_game_mutex);
      listing.game_id = !m_current_game_name.empty() ? m_current_game_name :
                        !m_host_game_name.empty()    ? m_host_game_name :
                                                       "UNKNOWN";
    }
    listing.player_count = ListingCount();
    listing.port = m_server->GetPort();
    listing.in_game = m_game_running;

    m_index = std::make_unique<NetPlayIndex>();
    if (!m_index->Add(listing))
    {
      m_index_failed = true;
      Emit("public", Json().Add("listed", false).Add("error", m_index->GetLastError()));
      m_index.reset();
      return;
    }
    m_index->SetErrorCallback([] { Emit("public", Json().Add("listed", false).Add("error", "lost")); });
    m_index_added = true;
    Emit("public", Json()
                       .Add("listed", true)
                       .Add("mode", m_mode)
                       .Add("region", m_region)
                       .Add("name", listing.name));
    return;
  }

  // Kept fresh by NetPlayIndex's own 5-second heartbeat.
  m_index->SetPlayerCount(ListingCount());
  std::lock_guard lk(m_game_mutex);
  if (!m_current_game_name.empty())
    m_index->SetGame(m_current_game_name);
}

void NetPlaySession::ApplyModeBattleState()
{
  if (m_mode_state_applied || m_mode == "any" || m_state_dir.empty())
    return;
  const auto game = CurrentGame();
  if (!game)
    return;
  m_mode_state_applied = true;
  // [Sparking.Modes] in the game ini: Single / Team / Training = <state file>
  const char* key = m_mode == "single" ? "Single" : m_mode == "team" ? "Team" : "Training";
  std::string file;
  for (const Common::IniFile& ini : {SConfig::LoadLocalGameIni(game->GetGameID(), game->GetRevision()),
                                     SConfig::LoadDefaultGameIni(game->GetGameID(), game->GetRevision())})
  {
    const Common::IniFile::Section* section = ini.GetSection("Sparking.Modes");
    if (section && section->Get(key, &file) && !file.empty())
      break;
    file.clear();
  }
  if (file.empty())
    return;
  Emit("mode", Json().Add("mode", m_mode).Add("battle_state", file));
  CmdBattleState(file);
}

// --- King of the Hill ----------------------------------------------------------------------

std::string NetPlaySession::KothView::ToControl() const
{
  std::string ids;
  for (const NetPlay::PlayerId pid : line)
    ids += (ids.empty() ? "" : ",") + std::to_string(static_cast<int>(pid));
  return fmt::format("koth {} {} {} {} {} {} {} {}", state, cap, streak, static_cast<int>(champion),
                     wins[0], wins[1], next_in, ids.empty() ? "-" : ids);
}

std::optional<NetPlaySession::KothView>
NetPlaySession::KothView::Parse(const std::vector<std::string>& parts)
{
  if (parts.size() != 9 || parts[0] != "koth")
    return std::nullopt;
  static constexpr std::array<std::string_view, 5> STATES = {"waiting", "ready", "next", "playing",
                                                             "decided"};
  if (std::ranges::find(STATES, parts[1]) == STATES.end())
    return std::nullopt;
  KothView v;
  v.state = parts[1];
  v.cap = std::atoi(parts[2].c_str());
  v.streak = std::atoi(parts[3].c_str());
  v.champion = static_cast<NetPlay::PlayerId>(std::atoi(parts[4].c_str()));
  v.wins = {std::atoi(parts[5].c_str()), std::atoi(parts[6].c_str())};
  v.next_in = std::atoi(parts[7].c_str());
  if (parts[8] != "-")
  {
    for (const std::string& id : SplitString(parts[8], ','))
    {
      if (v.line.size() < static_cast<size_t>(KOTH_MAX_PEOPLE))
        v.line.push_back(static_cast<NetPlay::PlayerId>(std::atoi(id.c_str())));
    }
  }
  return v;
}

void NetPlaySession::KothMap(NetPlay::PadMappingArray& map, bool& changed,
                             const std::vector<const NetPlay::Player*>& players)
{
  const auto now = std::chrono::steady_clock::now();
  const auto find_player = [&](NetPlay::PlayerId pid) -> const NetPlay::Player* {
    for (const NetPlay::Player* p : players)
    {
      if (p->pid == pid)
        return p;
    }
    return nullptr;
  };
  // Whoever left (or whose number now belongs to someone else) leaves the line.
  std::erase_if(m_line, [&](const LineEntry& e) {
    const NetPlay::Player* p = find_player(e.pid);
    return !p || p->name != e.name || (!p->IsHost() && RoleOf(e.pid) == "spectator");
  });

  int watchers = 0;
  for (const NetPlay::Player* p : players)
  {
    m_first_seen.try_emplace(p->pid, now);
    if (m_kick_at.contains(p->pid))
      continue;
    if (std::ranges::any_of(m_line, [&](const LineEntry& e) { return e.pid == p->pid; }))
      continue;
    std::string role = p->IsHost() ? "player" : RoleOf(p->pid);
    if (role == "pending")
    {
      if (now - m_first_seen[p->pid] < std::chrono::seconds(3))
        continue;
      role = "player";
    }
    if (role == "spectator")
    {
      // Watchers never get in line or on a pad. Ranked: nobody watches.
      if (m_ranked)
      {
        RejectPlayer(p->pid, "ranked_no_spectators");
        continue;
      }
      if (++watchers > MAX_SPECTATORS)
      {
        --watchers;
        RejectPlayer(p->pid, "spectators_full");
      }
      else if (static_cast<int>(m_line.size()) + watchers > KOTH_MAX_PEOPLE)
      {
        --watchers;
        RejectPlayer(p->pid, "lobby_full");
      }
      continue;
    }
    const int max_people = m_ranked ? MAX_PLAYERS : KOTH_MAX_PEOPLE;
    if (static_cast<int>(m_line.size()) + watchers >= max_people)
    {
      RejectPlayer(p->pid, "lobby_full");
      continue;
    }
    m_line.push_back({p->pid, p->name});  // newcomers wait at the back
  }

  // Pad 1 = champion, pad 2 = challenger; everyone else in line waits without a pad.
  for (int i = 0; i < MAX_PLAYERS; ++i)
  {
    const NetPlay::PlayerId want = i < static_cast<int>(m_line.size()) ? m_line[i].pid : 0;
    if (map[i] != want)
    {
      map[i] = want;
      changed = true;
    }
  }
}

bool NetPlaySession::KothReadyToStart()
{
  bool has_battle_state;
  {
    std::lock_guard lk(m_game_mutex);
    has_battle_state = m_battle_state.has_value();
  }
  return m_client->DoAllPlayersHaveGame() && IsSaveDataReady() &&
         (!has_battle_state || IsBattleStateReady());
}

NetPlaySession::KothView NetPlaySession::CurrentKothView()
{
  KothView v;
  v.cap = m_koth_cap;
  v.streak = m_streak;
  v.champion = m_champion;
  v.wins = m_set_wins;
  for (const LineEntry& e : m_line)
    v.line.push_back(e.pid);
  if (m_set_live)
  {
    v.state = m_set_decided ? "decided" : "playing";
    // The line during a set is the one it started with: pads 1-2 are the two fighting.
  }
  else if (m_line.size() < 2)
  {
    v.state = "waiting";
  }
  else if (m_koth_paused)
  {
    v.state = "ready";
  }
  else
  {
    v.state = "next";
    if (m_next_set_at)
    {
      const auto left = *m_next_set_at - std::chrono::steady_clock::now();
      v.next_in = std::max<int>(
          0, static_cast<int>(
                 (std::chrono::duration_cast<std::chrono::milliseconds>(left).count() + 999) / 1000));
    }
  }
  return v;
}

void NetPlaySession::BroadcastKoth(bool force)
{
  if (!m_koth || !m_server || !m_client)
    return;
  const KothView view = CurrentKothView();
  const std::string control = view.ToControl();
  const auto now = std::chrono::steady_clock::now();
  const bool changed = control != m_last_koth;
  // Re-sent every 2 s too, so newcomers learn the line without asking.
  if (force || changed || now - m_last_koth_send > std::chrono::seconds(2))
  {
    SendControl(control);
    m_last_koth_send = now;
  }
  if (changed || force)
  {
    m_last_koth = control;
    EmitKoth(view);
  }
}

void NetPlaySession::EmitKoth(const KothView& view)
{
  std::map<NetPlay::PlayerId, std::string> names;
  for (const NetPlay::Player* p : m_client->GetPlayers())
    names[p->pid] = p->name;
  const NetPlay::PlayerId me = m_client->GetLocalPlayerId();
  std::vector<std::string> line;
  int local_pos = -1;
  for (size_t i = 0; i < view.line.size(); ++i)
  {
    const auto it = names.find(view.line[i]);
    if (view.line[i] == me)
      local_pos = static_cast<int>(i);
    line.push_back(Json()
                       .Add("pid", static_cast<int>(view.line[i]))
                       .Add("name", it == names.end() ? std::string("?") : it->second)
                       .Add("pos", static_cast<int>(i))
                       .Str());
  }
  m_in_koth_line = local_pos >= 0;
  const auto champ = names.find(view.champion);
  Emit("koth", Json()
                   .Add("state", view.state)
                   .Add("cap", view.cap)
                   .Add("streak", view.streak)
                   .Add("champion", champ == names.end() || view.streak == 0 ? std::string() :
                                                                               champ->second)
                   .AddRaw("wins", fmt::format("[{},{}]", view.wins[0], view.wins[1]))
                   .Add("next_in", view.next_in)
                   .AddRaw("line", JsonArray(line))
                   .Add("local_pos", local_pos)
                   .Add("max", KOTH_MAX_PEOPLE));
}

void NetPlaySession::PumpKoth()
{
  if (!m_koth || !m_server || !m_client)
    return;
  const auto now = std::chrono::steady_clock::now();
  constexpr auto BREAK = std::chrono::seconds(10);  // between sets: time for people to join

  if (m_koth_start_aborted.exchange(false) && m_set_live && !m_game_running)
  {
    m_set_live = false;
    m_next_set_at = now + std::chrono::seconds(5);
  }

  if (m_set_live)
  {
    if (!m_set_decided)
    {
      m_set_wins = {HudPortWins(1) - m_set_base[0], HudPortWins(2) - m_set_base[1]};
      for (int i = 0; i < 2; ++i)
      {
        if (m_set_wins[i] < m_koth_cap)
          continue;
        // Set decided: let the KO play out, then end the game for everyone.
        m_set_decided = true;
        m_set_winner_port = i + 1;
        m_set_stop_at = now + std::chrono::seconds(4);
        const LineEntry& winner = m_set_players[i];
        const LineEntry& loser = m_set_players[1 - i];
        const int streak = i == 0 && m_streak > 0 && m_champion == winner.pid ? m_streak + 1 : 1;
        SendControl(fmt::format("kothset {} {} {} {} {}", static_cast<int>(winner.pid),
                                static_cast<int>(loser.pid), streak, m_set_wins[i],
                                m_set_wins[1 - i]));
        Emit("koth_set", Json()
                             .Add("winner", winner.name)
                             .Add("loser", loser.name)
                             .Add("streak", streak)
                             .AddRaw("wins", fmt::format("[{},{}]", m_set_wins[i],
                                                         m_set_wins[1 - i])));
        break;
      }
    }
    if (m_set_stop_at && now >= *m_set_stop_at)
    {
      m_set_stop_at.reset();
      if (m_game_running)
        m_client->RequestStopGameForEveryone();
    }
    BroadcastKoth(false);
    return;
  }

  // Between sets.
  if (!m_koth_paused)
  {
    if (m_line.size() < 2 || !m_next_set_at)
    {
      m_next_set_at = now + BREAK;  // a fresh break once there's someone to fight
    }
    else if (now >= *m_next_set_at && KothReadyToStart())
    {
      m_next_set_at.reset();
      CmdStart(false);
      return;
    }
  }
  BroadcastKoth(false);
}

void NetPlaySession::OnSetEnded()
{
  if (!m_set_live)
    return;
  m_set_live = false;
  m_set_stop_at.reset();
  const auto now = std::chrono::steady_clock::now();
  const auto players = m_client->GetPlayers();
  const auto present = [&](const LineEntry& e) {
    return std::ranges::any_of(players, [&](const NetPlay::Player* p) {
      return p->pid == e.pid && p->name == e.name;
    });
  };
  const auto remove = [&](const LineEntry& e) {
    std::erase_if(m_line, [&](const LineEntry& x) { return x.pid == e.pid; });
  };

  if (m_set_decided)
  {
    const int w = m_set_winner_port - 1;
    const LineEntry winner = m_set_players[w];
    const LineEntry loser = m_set_players[1 - w];
    // Winner keeps / takes pad 1, the loser goes to the back, the next in line gets pad 2.
    remove(winner);
    remove(loser);
    if (present(winner))
      m_line.insert(m_line.begin(), winner);
    if (present(loser))
      m_line.push_back(loser);
    m_streak = w == 0 && m_streak > 0 && m_champion == winner.pid ? m_streak + 1 : 1;
    m_champion = winner.pid;
    m_next_set_at = now + std::chrono::seconds(10);
    if (m_ranked)
    {
      // One ranked match per Start: back to the lobby, the host starts the next one.
      m_koth_paused = true;
      m_next_set_at.reset();
    }
  }
  else if (!present(m_set_players[0]) || !present(m_set_players[1]))
  {
    // Someone on a pad left: nobody won. The next in line steps up on its own.
    if (!present(m_set_players[0]) || m_champion != m_set_players[0].pid)
    {
      m_streak = 0;
      m_champion = 0;
    }
    m_next_set_at = now + std::chrono::seconds(10);
    if (m_ranked)
    {
      m_koth_paused = true;
      m_next_set_at.reset();
    }
  }
  else
  {
    // Stopped by hand: the ladder waits for the host's Start.
    m_koth_paused = true;
    m_next_set_at.reset();
  }
  m_set_decided = false;
  m_set_winner_port = 0;
  m_players_dirty = true;
  BroadcastKoth(true);
}

}  // namespace Sparking
