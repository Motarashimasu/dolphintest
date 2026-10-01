// Copyright 2026 Dolphin-Sparking Project
// SPDX-License-Identifier: GPL-2.0-or-later

// A windowless NetPlay lobby for dolphin-emu-nogui.
//
// Implements NetPlay::NetPlayUI (the interface the Qt NetPlayDialog normally implements) and
// reports everything through SparkingIO events, so an external frontend can draw its own lobby.
// All public methods except the NetPlayUI overrides must be called on the host (main) thread.

#pragma once

#include <atomic>
#include <chrono>
#include <functional>
#include <map>
#include <memory>
#include <mutex>
#include <optional>
#include <string>
#include <string_view>
#include <vector>

#include "Core/NetPlayClient.h"
#include "Core/NetPlayProto.h"
#include "Core/NetPlayServer.h"
#include "DolphinNoGUI/SparkingIO.h"

struct BootParameters;

namespace UICommon
{
class GameFile;
}

namespace Sparking
{
enum class AutoMap
{
  None,
  Wiimote,
  GameCube,
};

struct NetPlayOptions
{
  // Exactly one of these is set.
  std::optional<std::string> host_game_path;
  std::optional<std::string> join_target;  // traversal room code, or "ip:port"

  std::string nickname;
  std::vector<std::string> game_paths;  // candidate files used to match the host's game
  AutoMap automap = AutoMap::GameCube;
  // Folder holding battle-entry save states (e.g. "BT3-SingleBattle.sst"). Every peer must have
  // byte-identical copies; the host only sends the file name and its SHA-1.
  std::string state_dir;
};

// Name + SHA-1 of the battle state everyone should boot into.
struct BattleState
{
  std::string name;
  std::string sha1;
};

// Validates a state file name received over the network (no paths, no spaces, ends in .sst).
bool IsSafeStateName(std::string_view name);
// SHA-1 of a file as lowercase hex, or nullopt if it can't be read.
std::optional<std::string> HashFile(const std::string& path);

class NetPlaySession final : public NetPlay::NetPlayUI
{
public:
  NetPlaySession();
  ~NetPlaySession() override;

  // Host thread. Creates server (if hosting) + client. Emits "error" and returns false on failure.
  bool Start(const NetPlayOptions& options);
  // Host thread. Tears down client and server.
  void Shutdown();

  // Host thread, call ~10x/s while in the lobby: room code, player list, auto slot mapping.
  void Pump();
  // Host thread. Returns true if the command was recognised.
  bool HandleCommand(const Command& cmd);

  // Host thread. The netplay client asked us to boot a game; the caller should create a window,
  // boot it, and run the platform loop.
  std::unique_ptr<BootParameters> TakePendingBoot();
  // Host thread. Called once the platform loop has exited and the core is shut down.
  void OnGameEnded();

  bool WantsQuit() const { return m_quit; }

  // Set by the frontend so netplay can stop a running game from any thread.
  void SetStopGameCallback(std::function<void()> cb) { m_stop_game_callback = std::move(cb); }

  // NetPlay::NetPlayUI
  void BootGame(const std::string& filename,
                std::unique_ptr<BootSessionData> boot_session_data) override;
  void StopGame() override;
  bool IsHosting() const override;

  void Update() override;
  void AppendChat(const std::string& msg) override;

  void OnMsgChangeGame(const NetPlay::SyncIdentifier& sync_identifier,
                       const std::string& netplay_name) override;
  void OnMsgChangeGBARom(int pad, const NetPlay::GBAConfig& config) override;
  void OnMsgStartGame() override;
  void OnMsgStopGame() override;
  void OnMsgPowerButton() override;
  void OnPlayerConnect(const std::string& player) override;
  void OnPlayerDisconnect(const std::string& player) override;
  void OnPadBufferChanged(u32 buffer) override;
  void OnHostInputAuthorityChanged(bool enabled) override;
  void OnDesync(u32 frame, const std::string& player) override;
  void OnConnectionLost() override;
  void OnConnectionError(const std::string& message) override;
  void OnTraversalError(Common::TraversalClient::FailureReason error) override;
  void OnTraversalStateChanged(Common::TraversalClient::State state) override;
  void OnGameStartAborted() override;
  void OnGolferChanged(bool is_golfer, const std::string& golfer_name) override;
  void OnTtlDetermined(u8 ttl) override;

  bool IsRecording() override;
  std::shared_ptr<const UICommon::GameFile>
  FindGameFile(const NetPlay::SyncIdentifier& sync_identifier,
               NetPlay::SyncIdentifierComparison* found = nullptr) override;
  std::string FindGBARomPath(const std::array<u8, 20>& hash, std::string_view title,
                             int device_number) override;
  void ShowGameDigestDialog(const std::string& title) override;
  void SetGameDigestProgress(int pid, int progress) override;
  void SetGameDigestResult(int pid, const std::string& result) override;
  void AbortGameDigest() override;

  void OnIndexAdded(bool success, std::string error) override;
  void OnIndexRefreshFailed(std::string error) override;

  void ShowChunkedProgressDialog(const std::string& title, u64 data_size,
                                 std::span<const int> players) override;
  void HideChunkedProgressDialog() override;
  void SetChunkedProgress(int pid, u64 progress) override;

  void SetHostWiiSyncData(std::vector<u64> titles, std::string redirect_folder) override;

private:
  // Battle-state sync. Control messages ride on NetPlay chat with a marker prefix, so no new
  // packet types are needed in Core; Sparking peers hide them from the chat log.
  void CmdBattleState(const std::string& arg);
  void SendControl(const std::string& body);
  void BroadcastBattleState();
  void HandleControlMessage(NetPlay::PlayerId from, const std::string& body);  // host thread
  void EmitBattleState();
  bool IsBattleStateReady();  // host: every current player verified the file
  std::string StatePath(const std::string& name) const;

  void EmitPlayers();
  void EmitRoom();
  void ApplyAutoMap();
  void CmdStart(bool force);

  std::unique_ptr<NetPlay::NetPlayServer> m_server;
  std::unique_ptr<NetPlay::NetPlayClient> m_client;

  std::vector<std::shared_ptr<const UICommon::GameFile>> m_games;  // immutable after Start()
  AutoMap m_automap = AutoMap::GameCube;
  bool m_use_traversal = false;
  std::string m_nickname;

  std::mutex m_game_mutex;
  NetPlay::SyncIdentifier m_current_game;
  std::string m_current_game_name;
  bool m_has_current_game = false;

  std::unique_ptr<BootParameters> m_pending_boot;
  std::function<void()> m_stop_game_callback;

  std::atomic<bool> m_players_dirty{true};
  std::atomic<bool> m_game_running{false};
  std::atomic<bool> m_got_stop_request{false};
  bool m_quit = false;

  std::string m_state_dir;
  std::optional<BattleState> m_battle_state;       // guarded by m_game_mutex
  bool m_battle_state_local_ok = false;            // guarded by m_game_mutex
  std::map<NetPlay::PlayerId, std::string> m_state_acks;  // host: pid -> ok|missing|mismatch
  std::atomic<bool> m_rebroadcast_state{false};

  std::string m_last_room_json;
  std::chrono::steady_clock::time_point m_last_player_emit{};
};

}  // namespace Sparking
