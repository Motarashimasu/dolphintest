// Copyright 2026 Dolphin-Sparking Project
// SPDX-License-Identifier: GPL-2.0-or-later

#include "DolphinNoGUI/SparkingFrontend.h"

#include <OptionParser.h>
#include <algorithm>
#include <atomic>
#include <chrono>
#include <cstdlib>
#include <string>
#include <string_view>
#include <thread>

#include "Common/Config/Config.h"
#include "Common/FileUtil.h"
#include "Common/MsgHandler.h"
#include "Common/ScopeGuard.h"
#include "Common/WindowSystemInfo.h"
#include "Core/Boot/Boot.h"
#include "Core/Config/MainSettings.h"
#include "Core/Config/NetplaySettings.h"
#include "Core/Config/UISettings.h"
#include "Core/Config/WiimoteSettings.h"
#include "Core/ConfigManager.h"
#include "Core/HW/SI/SI_Device.h"
#include "Core/HW/Wiimote.h"
#include "Core/BootManager.h"
#include "Core/Core.h"
#include "Core/DolphinAnalytics.h"
#include "Core/NetPlayProto.h"
#include "Core/State.h"
#include "Core/System.h"
#include "DolphinNoGUI/Platform.h"
#include "Core/GeckoCode.h"
#include "DolphinNoGUI/SparkingGecko.h"
#include "DolphinNoGUI/SparkingIO.h"
#include "UICommon/GameFile.h"
#include "DolphinNoGUI/SparkingNetPlay.h"
#include "UICommon/UICommon.h"

namespace Sparking
{
namespace
{
std::atomic<bool> s_quit_requested{false};
std::atomic<bool> s_game_started{false};
std::string s_state_dir;  // set once from --state-dir before any thread starts

std::string_view StateName(Core::State state)
{
  switch (state)
  {
  case Core::State::Uninitialized:
    return "uninitialized";
  case Core::State::Paused:
    return "paused";
  case Core::State::Running:
    return "running";
  case Core::State::Stopping:
    return "stopping";
  case Core::State::Starting:
    return "starting";
  }
  return "unknown";
}

// Effective settings for this boot (after Dolphin's own netplay overrides), for debugging the
// frontend's controller / save-profile setup.
std::string SessionSummary()
{
  std::vector<std::string> pads, wiimotes;
  for (int i = 0; i < 4; ++i)
  {
    const auto dev = Config::Get(Config::GetInfoForSIDevice(i));
    pads.push_back(Json::Escape(dev == SerialInterface::SIDEVICE_GC_CONTROLLER ? "gc" :
                                dev == SerialInterface::SIDEVICE_NONE          ? "none" :
                                                                                 "other"));
    const auto src = Config::Get(Config::GetInfoForWiimoteSource(i));
    wiimotes.push_back(Json::Escape(src == WiimoteSource::None     ? "none" :
                                    src == WiimoteSource::Emulated ? "emulated" :
                                                                     "real"));
  }
  return Json()
      .AddRaw("pads", JsonArray(pads))
      .AddRaw("wiimotes", JsonArray(wiimotes))
      .Add("nand", File::GetUserPath(D_WIIROOT_IDX))
      .Add("dolphin_discord", Config::Get(Config::MAIN_USE_DISCORD_PRESENCE))
      .Add("netplay_save_load", Config::Get(Config::NETPLAY_SAVEDATA_LOAD))
      .Add("netplay_save_write", Config::Get(Config::NETPLAY_SAVEDATA_WRITE))
      .Add("gecko_active_count", static_cast<int64_t>(Gecko::CountEnabledCodes()))
      .Str();
}

// "game_started" fires on the first transition to Running (not when BootCore returns, which is
// before the emulation thread is up), so the frontend can hide itself and send commands safely.
void OnCoreStateChanged(Core::State state)
{
  if (state == Core::State::Running && !s_game_started.exchange(true))
  {
    // What the frontend needs for Discord Rich Presence / UI without parsing Dolphin's title.
    const SConfig& sc = SConfig::GetInstance();
    Emit("game_info", Json()
                          .Add("game_id", sc.GetGameID())
                          .Add("title", sc.GetTitleDescription())
                          .Add("revision", static_cast<int>(sc.GetRevision()))
                          .Add("netplay", NetPlay::IsNetPlayRunning())
                          .AddRaw("session", SessionSummary()));
    Emit("game_started");
  }
  else if (state == Core::State::Uninitialized)
    s_game_started = false;
  Emit("emulation_state", Json().Add("state", StateName(state)));
}

WindowSystemInfo HeadlessWSI()
{
  WindowSystemInfo wsi;
  wsi.type = WindowSystemType::Headless;
  return wsi;
}

void ReinitControllers(const WindowSystemInfo& wsi)
{
  UICommon::ShutdownControllers();
  UICommon::InitControllers(wsi);
}

// Upstream's no-GUI alert handler pops a native message box on Windows and answers "no" (which
// usually aborts) elsewhere. With a frontend attached, report the alert and keep running instead.
bool EventMsgAlertHandler(const char* caption, const char* text, bool yes_no, Common::MsgType style)
{
  std::string_view severity = "info";
  if (style == Common::MsgType::Warning)
    severity = "warning";
  else if (style == Common::MsgType::Critical)
    severity = "critical";
  else if (style == Common::MsgType::Question)
    severity = "question";
  Emit("alert", Json()
                    .Add("severity", severity)
                    .Add("caption", caption ? caption : "")
                    .Add("text", text ? text : "")
                    .Add("auto_answer", yes_no ? "yes" : "ok"));
  return true;
}

// In-game commands shared by solo and netplay mode. Host thread.
void HandleGameCommand(const Command& cmd, std::unique_ptr<Platform>& platform)
{
  auto& system = Core::System::GetInstance();

  if (cmd.name == "stop" || cmd.name == "quit" || cmd.name == "eof")
  {
    if (platform)
      platform->RequestShutdown();  // graceful (Wii power button) first, like SIGINT
    if (cmd.name != "stop")
      s_quit_requested = true;
    return;
  }

  // Everything below would desync a netplay session.
  if (NetPlay::IsNetPlayRunning())
  {
    Emit("error", Json().Add("code", "not_allowed_in_netplay").Add("command", cmd.name));
    return;
  }

  if (cmd.name == "pause")
  {
    Core::SetState(system, Core::State::Paused);
  }
  else if (cmd.name == "resume")
  {
    Core::SetState(system, Core::State::Running);
  }
  else if (cmd.name == "save_state_file" || cmd.name == "load_state_file")
  {
    // Capture/replay battle-entry states by name in --state-dir (see battle_state in netplay).
    if (s_state_dir.empty() || !IsSafeStateName(cmd.arg))
    {
      Emit("error", Json()
                        .Add("code", s_state_dir.empty() ? "no_state_dir" : "bad_state_name")
                        .Add("command", cmd.name));
      return;
    }
    const Core::State state = Core::GetState(system);
    if (state != Core::State::Running && state != Core::State::Paused)
    {
      Emit("error", Json().Add("code", "not_running").Add("command", cmd.name));
      return;
    }
    const std::string path = s_state_dir + "/" + cmd.arg;
    if (cmd.name == "load_state_file")
    {
      State::LoadAs(system, path);  // "state_applied" fires once it has actually loaded
      return;
    }
    State::SaveAs(system, path);
    // Compression + write happen on a worker; wait for it off the host thread, then report the
    // hash the netplay host will advertise for this file.
    std::thread([name = cmd.arg, path] {
      UICommon::FlushUnsavedData();
      const auto sha1 = HashFile(path);
      if (sha1)
        Emit("state_file_saved", Json().Add("name", name).Add("sha1", *sha1));
      else
        Emit("error", Json().Add("code", "state_save_failed").Add("name", name));
    }).detach();
  }
  else if (cmd.name == "save_state" || cmd.name == "load_state")
  {
    const Core::State state = Core::GetState(system);
    if (state != Core::State::Running && state != Core::State::Paused)
    {
      Emit("error", Json().Add("code", "not_running").Add("command", cmd.name));
      return;
    }
    const int slot = std::atoi(cmd.arg.c_str());
    if (slot < 1 || slot > static_cast<int>(State::NUM_STATES))
    {
      Emit("error", Json().Add("code", "bad_argument").Add("command", cmd.name));
      return;
    }
    if (cmd.name == "save_state")
      State::Save(system, slot);
    else
      State::Load(system, slot);
    Emit(cmd.name == "save_state" ? "state_saved" : "state_loaded", Json().Add("slot", slot));
  }
  else
  {
    Emit("error", Json().Add("code", "unknown_command").Add("command", cmd.name));
  }
}

// Creates the render window, boots, runs until the game ends, then destroys the window so the
// frontend's lobby is visible again. Host thread.
void RunNetPlayGame(const FrontendHooks& hooks, std::unique_ptr<BootParameters> boot)
{
  hooks.platform = hooks.create_platform();
  if (!hooks.platform || !hooks.platform->Init())
  {
    hooks.platform.reset();
    Emit("error", Json().Add("code", "platform_init_failed"));
    return;
  }

  const WindowSystemInfo wsi = hooks.platform->GetWindowSystemInfo();
  ReinitControllers(wsi);

  auto& system = Core::System::GetInstance();
  if (BootManager::BootCore(system, std::move(boot), wsi))
    hooks.platform->MainLoop();
  else
  {
    Emit("error", Json().Add("code", "boot_failed"));
  }

  Core::Stop(system);
  Core::Shutdown(system);
  hooks.platform.reset();
  ReinitControllers(HeadlessWSI());
}
}  // namespace

// Session-wide setting overrides. They go into the command-line config layer rather than the
// "current run" layer because Dolphin clears the latter after every game, and a netplay session
// boots many games in one process. Nothing here is written to the user's Dolphin.ini.
static void ApplySessionOverrides(const optparse::Values& options, bool netplay)
{
  const auto layer = Config::GetLayer(Config::LayerType::CommandLine);
  if (!layer)
    return;

  // The frontend owns Discord Rich Presence (with its own app ID, across menus and matches), so
  // Dolphin's built-in "Playing on Dolphin" presence must never connect.
  layer->Set(Config::MAIN_USE_DISCORD_PRESENCE, false);

  // Separate save data: point the Wii NAND (where Wii game saves live) at a profile folder.
  if (options.is_set("nand"))
    layer->Set(Config::MAIN_FS_PATH, std::string(static_cast<const char*>(options.get("nand"))));

  // Controllers: GameCube pads in the first N ports, no Wii Remotes. In netplay Dolphin's own
  // netplay layer assigns ports from the GC slot mapping, which overrides this.
  const std::string pads = static_cast<const char*>(options.get("pads"));
  if (pads == "gc")
  {
    int local_players = std::atoi(static_cast<const char*>(options.get("local_players")));
    local_players = std::clamp(local_players, 1, 4);
    for (int i = 0; i < 4; ++i)
    {
      layer->Set(Config::GetInfoForSIDevice(i), i < local_players ?
                                                    SerialInterface::SIDEVICE_GC_CONTROLLER :
                                                    SerialInterface::SIDEVICE_NONE);
    }
    for (int i = 0; i < 5; ++i)  // 4 Wii Remotes + Balance Board
      layer->Set(Config::GetInfoForWiimoteSource(i), WiimoteSource::None);
    layer->Set(Config::MAIN_WIIMOTE_CONTINUOUS_SCANNING, false);
  }

  // Netplay saves: everyone plays on the HOST's save (the supplied all-unlocked one), and nothing
  // is ever written back, so that save stays pristine forever.
  if (netplay && std::string_view(static_cast<const char*>(options.get("netplay_saves"))) ==
                     "host-readonly")
  {
    layer->Set(Config::NETPLAY_SAVEDATA_LOAD, true);
    layer->Set(Config::NETPLAY_SAVEDATA_WRITE, false);
    layer->Set(Config::NETPLAY_SAVEDATA_SYNC_ALL_WII, false);
  }

  // Hosting gets a room code from Dolphin's traversal server (stun.dolphin-emu.org) unless the
  // frontend explicitly asks for direct IP hosting. Upstream's default is "direct".
  if (netplay)
  {
    layer->Set(Config::NETPLAY_TRAVERSAL_CHOICE,
               std::string(options.is_set_by_user("netplay_direct") ? "direct" : "traversal"));
  }

  // Each player runs their own per-port Gecko codes (see --netplay-gecko), so the host's codes
  // must not be pushed onto everyone.
  if (netplay)
    layer->Set(Config::NETPLAY_SYNC_CODES, false);

  Config::OnConfigChanged();
}

void AddCommandLineOptions(optparse::OptionParser& parser)
{
  parser.add_option("--gecko")
      .dest("gecko")
      .action("append")
      .metavar("NAME")
      .help("Solo: enable exactly these Gecko codes (repeatable); all others off for this run");
  parser.add_option("--no-gecko")
      .dest("no_gecko")
      .action("store_true")
      .help("Solo: all Gecko/Action Replay codes off for this run");
  parser.add_option("--netplay-gecko")
      .dest("netplay_gecko")
      .action("append")
      .metavar("PORT=NAME")
      .help("Netplay: enable code NAME only for the player on GameCube port PORT (repeatable)");
  parser.add_option("--netplay-gecko-defaults")
      .dest("netplay_gecko_defaults")
      .action("store")
      .choices({"on", "off"})
      .set_default("on")
      .help("Netplay: also run the game's default-on codes for everyone (default on)");
  parser.add_option("--list-gecko")
      .dest("list_gecko")
      .action("store")
      .metavar("GAMEID[:REV]")
      .help("Print the game's Gecko codes as a [SPARKING] gecko_codes event and exit");
  parser.add_option("--nand")
      .dest("nand")
      .action("store")
      .metavar("DIR")
      .help("Wii NAND folder for this session (separate save data per profile)");
  parser.add_option("--pads")
      .dest("pads")
      .action("store")
      .choices({"gc", "keep"})
      .set_default("gc")
      .help("Sparking mode controllers: gc (GameCube pads, no Wii Remotes; default) or keep");
  parser.add_option("--local-players")
      .dest("local_players")
      .action("store")
      .set_default("1")
      .help("Solo: number of local GameCube pads (1-4, default 1)");
  parser.add_option("--netplay-saves")
      .dest("netplay_saves")
      .action("store")
      .choices({"host-readonly", "keep"})
      .set_default("host-readonly")
      .help("Netplay: everyone uses the host's save, never written back (default), or keep");
  parser.add_option("--sparking")
      .dest("sparking")
      .action("store_true")
      .help("Emit [SPARKING] JSON events on stdout and accept commands on stdin");
  parser.add_option("--netplay-host")
      .dest("netplay_host")
      .action("store")
      .metavar("GAME")
      .help("Host a NetPlay session for GAME (implies --sparking)");
  parser.add_option("--netplay-join")
      .dest("netplay_join")
      .action("store")
      .metavar("CODE|IP:PORT")
      .help("Join a NetPlay session by traversal room code or address (implies --sparking)");
  parser.add_option("--netplay-game")
      .dest("netplay_game")
      .action("append")
      .metavar("PATH")
      .help("Extra game file to match against the host's game (repeatable)");
  parser.add_option("--state-dir")
      .dest("state_dir")
      .action("store")
      .metavar("DIR")
      .help("Folder of battle-entry save states for battle_state / save_state_file");
  parser.add_option("--netplay-direct")
      .dest("netplay_direct")
      .action("store_true")
      .help("Host by IP:port instead of a traversal room code (needs port forwarding)");
  parser.add_option("--nickname").dest("nickname").action("store").help("NetPlay nickname");
  parser.add_option("--automap")
      .dest("automap")
      .action("store")
      .choices({"wii", "gc", "none"})
      .set_default("gc")
      .help("Host: auto-assign joining players to GC (default) or Wii Remote slots: gc, wii, none");
}

static bool IsNetPlayMode(const optparse::Values& options)
{
  return options.is_set("netplay_host") || options.is_set("netplay_join");
}

bool OwnsMain(const optparse::Values& options)
{
  return IsNetPlayMode(options) || options.is_set("list_gecko");
}

static int RunListGecko(const optparse::Values& options)
{
  std::string user_directory;
  if (options.is_set("user"))
    user_directory = static_cast<const char*>(options.get("user"));
  UICommon::SetUserDirectory(user_directory);
  UICommon::Init();
  Common::ScopeGuard guard([] { UICommon::Shutdown(); });

  std::string id = static_cast<const char*>(options.get("list_gecko"));
  std::optional<u16> revision;
  if (const size_t colon = id.find(':'); colon != std::string::npos)
  {
    revision = static_cast<u16>(std::atoi(id.c_str() + colon + 1));
    id.resize(colon);
  }
  Emit("gecko_codes", Json().Add("game_id", id).AddRaw("codes", ListGeckoCodesJson(id, revision)));
  Emit("exit", Json().Add("code", 0));
  return 0;
}

static int RunNetPlay(const optparse::Values& options, const FrontendHooks& hooks);

int RunMain(const optparse::Values& options, const FrontendHooks& hooks)
{
  if (options.is_set("list_gecko"))
    return RunListGecko(options);
  return RunNetPlay(options, hooks);
}

void InitFromOptions(const optparse::Values& options)
{
  const bool netplay = IsNetPlayMode(options);
  SetEnabled(netplay || options.is_set_by_user("sparking") || options.is_set("list_gecko"));
  if (options.is_set("state_dir"))
    s_state_dir = static_cast<const char*>(options.get("state_dir"));
  if (IsEnabled())
  {
    ApplySessionOverrides(options, netplay);
    Common::RegisterMsgAlertHandler(EventMsgAlertHandler);
    State::SetOnAfterLoadCallback([] {
      if (State::LastLoadSucceeded())
        Emit("state_applied");
      else
        Emit("error", Json().Add("code", "state_load_failed"));
    });
    // Deliberately never destroyed: avoids static-destruction-order issues with Core's event.
    static auto* const state_hook =
        new Common::EventHook(Core::AddOnStateChangedCallback(OnCoreStateChanged));
    (void)state_hook;
  }
  Emit("ready",
       Json().Add("protocol", PROTOCOL_VERSION)
           .Add("mode", netplay ? "netplay" : (options.is_set("list_gecko") ? "list" : "solo")));
}

void RequestQuit()
{
  s_quit_requested = true;
}

void BeforeSoloBoot(const optparse::Values& options, std::unique_ptr<Platform>& platform)
{
  if (!IsEnabled())
    return;
  StartCommandReader([&platform](const Command& cmd) { HandleGameCommand(cmd, platform); });

  const bool no_gecko = options.is_set_by_user("no_gecko");
  if (!no_gecko && !options.is_set("gecko"))
    return;  // leave Dolphin's per-game ini selection alone
  if (!options.is_set("exec"))
  {
    Emit("error", Json().Add("code", "gecko_needs_exec"));
    return;
  }
  const UICommon::GameFile game(options.all("exec").front());
  if (!game.IsValid())
    return;
  std::vector<std::string> names;
  if (!no_gecko)
  {
    for (const std::string& n : options.all("gecko"))
      names.push_back(n);
  }
  const std::vector<std::string> missing =
      ActivateExclusiveGeckoCodes(game.GetGameID(), game.GetRevision(), names);
  std::vector<std::string> active, miss;
  for (const auto& n : names)
  {
    if (std::ranges::find(missing, n) == missing.end())
      active.push_back(Json::Escape(n));
  }
  for (const auto& n : missing)
    miss.push_back(Json::Escape(n));
  Emit("gecko_active",
       Json().Add("port", 0).AddRaw("codes", JsonArray(active)).AddRaw("missing", JsonArray(miss)));
}

static int RunNetPlay(const optparse::Values& options, const FrontendHooks& hooks)
{
  NetPlayOptions np;
  if (options.is_set("netplay_host"))
    np.host_game_path = static_cast<const char*>(options.get("netplay_host"));
  else
    np.join_target = static_cast<const char*>(options.get("netplay_join"));
  if (options.is_set("nickname"))
    np.nickname = static_cast<const char*>(options.get("nickname"));
  // Values::all() const dereferences find() unchecked, so only call it for options that are set.
  if (options.is_set("netplay_game"))
  {
    for (const std::string& path : options.all("netplay_game"))
      np.game_paths.push_back(path);
  }
  if (options.is_set("exec"))
  {
    for (const std::string& path : options.all("exec"))
      np.game_paths.push_back(path);
  }
  np.state_dir = s_state_dir;
  np.gecko_defaults =
      std::string_view(static_cast<const char*>(options.get("netplay_gecko_defaults"))) != "off";
  if (options.is_set("netplay_gecko"))
  {
    for (const std::string& spec : options.all("netplay_gecko"))
    {
      const size_t eq = spec.find('=');
      const int port = eq == std::string::npos ? 0 : std::atoi(spec.substr(0, eq).c_str());
      if (port < 1 || port > 4)
      {
        Emit("error", Json().Add("code", "bad_argument").Add("netplay_gecko", spec));
        continue;
      }
      np.port_gecko[port].push_back(spec.substr(eq + 1));
    }
  }
  const std::string automap = static_cast<const char*>(options.get("automap"));
  np.automap = automap == "wii"  ? AutoMap::Wiimote :
               automap == "none" ? AutoMap::None :
                                   AutoMap::GameCube;

  std::string user_directory;
  if (options.is_set("user"))
    user_directory = static_cast<const char*>(options.get("user"));

  UICommon::SetUserDirectory(user_directory);
  UICommon::Init();
  UICommon::InitControllers(HeadlessWSI());
  Common::ScopeGuard ui_common_guard([] {
    UICommon::ShutdownControllers();
    UICommon::Shutdown();
  });

  auto core_state_changed_hook =
      Core::AddOnStateChangedCallback([&platform = hooks.platform](const Core::State state) {
        if (state == Core::State::Uninitialized && platform)
          platform->Stop();
      });

  hooks.install_signal_handlers();
  DolphinAnalytics::Instance().ReportDolphinStart("nogui-sparking");

  auto& system = Core::System::GetInstance();
  NetPlaySession session;

  // Netplay may ask us to stop from its own thread; hop to the host thread to touch the window.
  session.SetStopGameCallback([&platform = hooks.platform] {
    Core::QueueHostJob(
        [&platform](Core::System&) {
          if (platform)
            platform->Stop();
        },
        /*run_during_stop=*/true);
  });

  StartCommandReader([&session, &platform = hooks.platform](const Command& cmd) {
    if (!session.HandleCommand(cmd))
      HandleGameCommand(cmd, platform);
    else if ((cmd.name == "quit" || cmd.name == "eof") && platform)
      platform->Stop();  // spectators have no pad mapped, so also stop locally
  });

  if (!session.Start(np))
  {
    Emit("exit", Json().Add("code", 1));
    return 1;
  }

  while (!session.WantsQuit() && !s_quit_requested)
  {
    Core::HostDispatchJobs(system);

    if (auto boot = session.TakePendingBoot())
    {
      RunNetPlayGame(hooks, std::move(boot));
      session.OnGameEnded();
      continue;
    }

    session.Pump();
    std::this_thread::sleep_for(std::chrono::milliseconds(50));
  }

  session.Shutdown();
  Emit("exit", Json().Add("code", 0));
  return 0;
}

}  // namespace Sparking
