// Copyright 2026 Dolphin-Sparking Project
// SPDX-License-Identifier: GPL-2.0-or-later

#include "DolphinNoGUI/SparkingNetPlay.h"

#include <algorithm>
#include <charconv>
#include <string_view>

#include <fmt/format.h>

#include "Common/TraversalClient.h"
#include "Core/Boot/Boot.h"
#include "Core/Config/MainSettings.h"
#include "Core/Config/NetplaySettings.h"
#include "Core/Config/UISettings.h"
#include "Core/Core.h"
#include "Core/IOS/FS/FileSystem.h"
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

NetPlaySession::NetPlaySession() = default;

NetPlaySession::~NetPlaySession()
{
  Shutdown();
}

bool NetPlaySession::Start(const NetPlayOptions& options)
{
  m_nickname = options.nickname.empty() ? Config::Get(Config::NETPLAY_NICKNAME) : options.nickname;
  m_automap = options.automap;

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
    m_server->ChangeGame(game->GetSyncIdentifier(), game->GetNetPlayName(title_db));

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
  // Same order as the Qt frontend: client first, then server.
  m_client.reset();
  m_server.reset();
}

void NetPlaySession::Pump()
{
  if (!m_client)
    return;

  EmitRoom();

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
  for (const NetPlay::Player* p : m_client->GetPlayers())
  {
    if (std::find(map.begin(), map.end(), p->pid) != map.end())
      continue;
    const auto free_slot = std::find(map.begin(), map.end(), NetPlay::PlayerId{0});
    if (free_slot == map.end())
      break;  // More than 4 players; extras spectate.
    *free_slot = p->pid;
    changed = true;
  }

  if (!changed)
    return;
  if (m_automap == AutoMap::Wiimote)
    m_server->SetWiimoteMapping(map);
  else
    m_server->SetPadMapping(map);
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
    if (m_game_running)
      m_client->RequestStopGame();
  }
  else if (cmd.name == "buffer")
  {
    if (host_only())
      m_server->AdjustPadBufferSize(static_cast<unsigned>(std::max(0, std::atoi(cmd.arg.c_str()))));
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

  if (!m_server->RequestStartGame())
    Emit("error", Json().Add("code", "start_rejected"));
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
    m_client->RequestStopGame();

  m_game_running = false;
  m_got_stop_request = false;
  m_players_dirty = true;
  Emit("game_stopped");
}

// ---------------------------------------------------------------------------------------------
// NetPlay::NetPlayUI. These are called from the netplay thread unless noted otherwise.

// Host thread (called from within NetPlayClient::StartGame, which we invoke on the host thread).
void NetPlaySession::BootGame(const std::string& filename,
                              std::unique_ptr<BootSessionData> boot_session_data)
{
  m_got_stop_request = false;
  m_game_running = true;
  m_pending_boot = BootParameters::GenerateFromFile(
      filename, boot_session_data ? std::move(*boot_session_data) : BootSessionData());
  Emit("game_booting", Json().Add("path", filename));
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
}

void NetPlaySession::AppendChat(const std::string& msg)
{
  // NetPlayClient formats remote chat as "name[pid]: text"; pass it through verbatim.
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
  Emit("player_joined", Json().Add("name", player));
}

void NetPlaySession::OnPlayerDisconnect(const std::string& player)
{
  m_players_dirty = true;
  Emit("player_left", Json().Add("name", player));
}

void NetPlaySession::OnPadBufferChanged(u32 buffer)
{
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

}  // namespace Sparking
