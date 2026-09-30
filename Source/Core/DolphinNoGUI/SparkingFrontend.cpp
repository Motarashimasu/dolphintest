// Copyright 2026 Dolphin-Sparking Project
// SPDX-License-Identifier: GPL-2.0-or-later

#include "DolphinNoGUI/SparkingFrontend.h"

#include <OptionParser.h>
#include <atomic>
#include <chrono>
#include <cstdlib>
#include <string>
#include <string_view>
#include <thread>

#include "Common/MsgHandler.h"
#include "Common/ScopeGuard.h"
#include "Common/WindowSystemInfo.h"
#include "Core/Boot/Boot.h"
#include "Core/BootManager.h"
#include "Core/Core.h"
#include "Core/DolphinAnalytics.h"
#include "Core/NetPlayProto.h"
#include "Core/State.h"
#include "Core/System.h"
#include "DolphinNoGUI/Platform.h"
#include "DolphinNoGUI/SparkingIO.h"
#include "DolphinNoGUI/SparkingNetPlay.h"
#include "UICommon/UICommon.h"

namespace Sparking
{
namespace
{
std::atomic<bool> s_quit_requested{false};
std::atomic<bool> s_game_started{false};

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

// "game_started" fires on the first transition to Running (not when BootCore returns, which is
// before the emulation thread is up), so the frontend can hide itself and send commands safely.
void OnCoreStateChanged(Core::State state)
{
  if (state == Core::State::Running && !s_game_started.exchange(true))
    Emit("game_started");
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

void AddCommandLineOptions(optparse::OptionParser& parser)
{
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
  parser.add_option("--nickname").dest("nickname").action("store").help("NetPlay nickname");
  parser.add_option("--automap")
      .dest("automap")
      .action("store")
      .choices({"wii", "gc", "none"})
      .set_default("wii")
      .help("Host: auto-assign joining players to Wii Remote or GC slots: wii (default), gc, none");
}

bool IsNetPlayMode(const optparse::Values& options)
{
  return options.is_set("netplay_host") || options.is_set("netplay_join");
}

void InitFromOptions(const optparse::Values& options)
{
  const bool netplay = IsNetPlayMode(options);
  SetEnabled(netplay || options.is_set_by_user("sparking"));
  if (IsEnabled())
  {
    Common::RegisterMsgAlertHandler(EventMsgAlertHandler);
    // Deliberately never destroyed: avoids static-destruction-order issues with Core's event.
    static auto* const state_hook =
        new Common::EventHook(Core::AddOnStateChangedCallback(OnCoreStateChanged));
    (void)state_hook;
  }
  Emit("ready",
       Json().Add("protocol", PROTOCOL_VERSION).Add("mode", netplay ? "netplay" : "solo"));
}

void RequestQuit()
{
  s_quit_requested = true;
}

void StartSoloCommandReader(std::unique_ptr<Platform>& platform)
{
  if (!IsEnabled())
    return;
  StartCommandReader([&platform](const Command& cmd) { HandleGameCommand(cmd, platform); });
}

int RunNetPlay(const optparse::Values& options, const FrontendHooks& hooks)
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
  const std::string automap = static_cast<const char*>(options.get("automap"));
  np.automap = automap == "gc"   ? AutoMap::GameCube :
               automap == "none" ? AutoMap::None :
                                   AutoMap::Wiimote;

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
