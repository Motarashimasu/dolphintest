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
#include <thread>
#include <string>
#include <string_view>
#include <vector>

#include "Core/NetPlayClient.h"
#include "UICommon/NetPlayIndex.h"
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
  // Gecko codes per GameCube port (1-4). In netplay every other code is off; each player gets
  // only the codes for the port they end up on (e.g. a per-player splitscreen remover).
  std::map<int, std::vector<std::string>> port_gecko;
  // Also run the game's default-on codes (ini [Gecko_Enabled]) for everyone.
  bool gecko_defaults = true;
  // This PC's network link ("wired", "wireless", "virtual", "unknown"); empty = detect.
  std::string link;
  // Host: list the lobby publicly on Dolphin's lobby server (see SparkingLobby.h).
  bool is_public = false;
  std::string mode = "any";       // "single", "team", "any": shown in the browser, and picks the
                                  // battle state from the game ini's [Sparking.Modes]
  std::string region = "NA";      // lobby server region: EA CN EU NA SA OC AF
  std::string public_address;     // direct hosting only: address others join (traversal: room code)
  // Joiner: watch only. Spectators never get a controller port (not even if a player leaves),
  // and run the default codes without any per-port code.
  bool spectate = false;
};

// Lobby size: 2 players (GameCube ports 1-2) and up to 2 spectators.
constexpr int MAX_PLAYERS = 2;
constexpr int MAX_SPECTATORS = 2;

// Connection quality from ping samples (one per second): average change between consecutive
// pings (jitter) plus the ping itself.
struct LinkQuality
{
  int jitter_ms = -1;      // -1 until there are enough samples
  std::string rating;      // "good", "ok", "poor", or "measuring"
};

// Name + SHA-1 of the battle state everyone should boot into.
struct BattleState
{
  std::string name;
  std::string sha1;
};

// Validates a state file name received over the network (no paths, no spaces, .sst or .sav).
bool IsSafeStateName(std::string_view name);
// SHA-1 of a file as lowercase hex, or nullopt if it can't be read.
std::optional<std::string> HashFile(const std::string& path);
// Fingerprint of a Wii game's save in the configured NAND (every file under title/.../data, with
// its relative path), or "missing" if there is no save.
std::string HashWiiSave(u64 title_id);

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
  bool IsSpectating() const { return m_spectate; }
  // Host thread. Players in the lobby, and this player's GameCube port (0 = none / spectator).
  int PlayerCount();
  // Public listing's player_count: players + 10 x spectators (see SparkingLobby.h).
  int ListingCount();
  int LocalGcPort();

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

  // Save-data check: every player's netplay save must be byte-identical or the game desyncs.
  void BroadcastSaveCheck();  // host
  void EmitSaveData();
  bool IsSaveDataReady();  // host: every current player's save matches the host's
  u64 CurrentTitleID();
  std::shared_ptr<const UICommon::GameFile> CurrentGame();
  std::string LocalSetupFingerprint();  // "<save sha1>-<gecko sha1>"
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
  std::map<int, std::vector<std::string>> m_port_gecko;
  bool m_gecko_defaults = true;
  std::optional<BattleState> m_battle_state;       // guarded by m_game_mutex
  bool m_battle_state_local_ok = false;            // guarded by m_game_mutex
  std::map<NetPlay::PlayerId, std::string> m_state_acks;  // host: pid -> ok|missing|mismatch
  std::atomic<bool> m_rebroadcast_state{false};

  std::string m_host_save_hash;                          // last hash the host announced
  std::string m_save_local_status;                       // client: ok|mismatch|missing
  std::map<NetPlay::PlayerId, std::string> m_save_acks;  // host: pid -> ok|mismatch|missing
  std::atomic<bool> m_rebroadcast_save{false};

  // Wired/Wi-Fi: every player detects its own adapter and tells the others ("link <type>").
  std::string m_local_link;
  std::mutex m_links_mutex;
  std::map<NetPlay::PlayerId, std::string> m_links;  // guarded by m_links_mutex
  std::atomic<bool> m_rebroadcast_link{true};

  // Roles ("role player|spectator" control message, sent with "link" on joining). Host: a
  // joiner gets a port only once its role is known (or after a few seconds for older builds),
  // and anyone over the 2 + 2 limit is told why and removed.
  bool m_spectate = false;
  std::map<NetPlay::PlayerId, std::string> m_roles;  // guarded by m_links_mutex
  std::map<NetPlay::PlayerId, std::string> m_names;  // last player list, guarded by m_links_mutex
  std::string RoleOf(NetPlay::PlayerId pid);           // "player", "spectator" or "pending"
  std::map<NetPlay::PlayerId, std::chrono::steady_clock::time_point> m_first_seen;  // host thread
  struct PendingKick
  {
    std::string reason;
    std::string name;  // player numbers get reused: only ever act on this same player
    std::chrono::steady_clock::time_point kick_at, next_notice;
  };
  std::map<NetPlay::PlayerId, PendingKick> m_kick_at;  // host thread
  std::atomic<bool> m_rejected{false};  // this joiner was turned away (netplay thread sets it)
  std::string m_reject_reason;          // guarded by m_links_mutex
  void RejectPlayer(NetPlay::PlayerId pid, std::string_view reason);  // host thread
  void PushHudPlayers();  // any thread: names' link icons per GameCube port
  std::string LinkOf(NetPlay::PlayerId pid);

  // Ping stability, sampled on the netplay thread whenever pings update (throttled to 1/s).
  std::mutex m_quality_mutex;
  std::map<NetPlay::PlayerId, std::vector<u32>> m_ping_samples;
  std::chrono::steady_clock::time_point m_last_ping_sample{};
  LinkQuality QualityOf(NetPlay::PlayerId pid, u32 current_ping);

  // Automatic pad buffer (host, "buffer auto"): chosen from the ping history when the match
  // starts, and re-chosen once right after each KO (any number of steps), within 20 s and only
  // while no round is being fought. Never during a fight.
  struct AutoBufferChoice
  {
    int buffer;
    u32 ping;     // worst player's high ping (90th percentile of the last ~10 s)
    int jitter;
  };
  std::optional<AutoBufferChoice> AutoBufferTarget();
  void ApplyAutoBuffer(std::string_view reason);  // host thread
  void PumpAutoBuffer();                          // host thread
  std::atomic<bool> m_auto_buffer{false};
  std::atomic<int> m_buffer{-1};  // last pad buffer Dolphin reported
  int m_seen_results = 0;
  std::optional<std::chrono::steady_clock::time_point> m_auto_due, m_auto_deadline;
  // While a match runs the lobby loop is parked: a ticker hands PumpAutoBuffer to the host
  // thread (Core host jobs). `m_alive` keeps queued jobs from touching a destroyed session.
  void StartAutoTicker();
  void StopAutoTicker();
  std::thread m_auto_ticker;
  std::atomic<bool> m_ticking{false};
  std::shared_ptr<std::atomic<bool>> m_alive = std::make_shared<std::atomic<bool>>(true);

  // Public lobby (Dolphin lobby server).
  void UpdatePublicListing();  // host thread
  void ApplyModeBattleState();  // host thread, once
  bool m_public = false;
  std::string m_mode = "any";
  std::string m_region = "NA";
  std::string m_public_address;
  std::unique_ptr<NetPlayIndex> m_index;
  bool m_index_added = false;
  std::string m_host_game_name;  // host: netplay name of the game it opened with
  bool m_index_failed = false;
  bool m_mode_state_applied = false;

  std::string m_last_room_json;
  std::chrono::steady_clock::time_point m_last_player_emit{};
};

}  // namespace Sparking
