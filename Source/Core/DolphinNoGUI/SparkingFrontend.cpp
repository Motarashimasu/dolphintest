// Copyright 2026 Dolphin-Sparking Project
// SPDX-License-Identifier: GPL-2.0-or-later

#include "DolphinNoGUI/SparkingFrontend.h"

#include <OptionParser.h>
#include <fmt/format.h>
#include <algorithm>
#include <atomic>
#include <chrono>
#include <cctype>
#include <charconv>
#include <cstdio>
#include <cstdlib>
#include <map>
#include <mutex>
#include <set>
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
#include "Core/Config/GraphicsSettings.h"
#include "Core/Config/UISettings.h"
#include "Core/Config/WiimoteSettings.h"
#include "Core/ConfigManager.h"
#include "Core/HW/SI/SI_Device.h"
#include "Core/HW/Wiimote.h"
#include "Core/BootManager.h"
#include "Core/Core.h"
#include "Core/PowerPC/MMU.h"
#include "Core/DolphinAnalytics.h"
#include "Core/NetPlayProto.h"
#include "Core/State.h"
#include "Core/System.h"
#include "DolphinNoGUI/Platform.h"
#include "Core/GeckoCode.h"
#include "DolphinNoGUI/SparkingDisplay.h"
#include "DolphinNoGUI/SparkingGecko.h"
#include "DolphinNoGUI/SparkingIO.h"
#include "UICommon/GameFile.h"
#include "VideoCommon/AsyncRequests.h"
#include "VideoCommon/HiresTextures.h"
#include "VideoCommon/OnScreenDisplay.h"
#include "VideoCommon/TextureCacheBase.h"
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

// "Group=Option" -> merged into the current texture variant selection. Empty option clears it.
bool ApplyTextureSpec(std::string_view spec, std::map<std::string, std::string>* selection)
{
  const size_t eq = spec.find('=');
  if (eq == std::string_view::npos || eq == 0)
    return false;
  // Same case-folding HiresTexture applies, so "Buttons" replaces an earlier "buttons".
  std::string group(spec.substr(0, eq));
  for (char& c : group)
    c = static_cast<char>(std::tolower(static_cast<unsigned char>(c)));
  const std::string option(spec.substr(eq + 1));
  if (option.empty())
    selection->erase(group);
  else
    (*selection)[group] = option;
  return true;
}

std::string TextureSelectionJson()
{
  Json json;
  for (const auto& [group, option] : HiresTexture::GetVariantSelection())
    json.Add(group, option);
  return json.Str();
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
      .Add("custom_textures", Config::Get(Config::GFX_HIRES_TEXTURES))
      .Add("dolphin_osd_messages", Config::Get(Config::MAIN_OSD_MESSAGES))
      .Add("background_input", Config::Get(Config::MAIN_INPUT_BACKGROUND_INPUT))
      .AddRaw("textures", TextureSelectionJson())
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

// Every Dolphin on-screen message, as an "osd" event for the frontend's overlay. Repeated
// identical typed messages (netplay ping/buffer refreshes) are only sent when they change.
void ForwardOsdMessage(OSD::MessageType type, const std::string& message, u32 ms, u32 argb)
{
  const char* kind = type == OSD::MessageType::NetPlayPing   ? "netplay_ping" :
                     type == OSD::MessageType::NetPlayBuffer ? "netplay_buffer" :
                                                               "message";
  if (type != OSD::MessageType::Typeless)
  {
    static std::mutex mutex;
    static std::map<OSD::MessageType, std::string> last;
    std::lock_guard lk(mutex);
    if (last[type] == message)
      return;
    last[type] = message;
  }
  Emit("osd", Json()
                  .Add("kind", kind)
                  .Add("text", message)
                  .Add("ms", static_cast<int64_t>(ms))
                  .Add("color", fmt::format("#{:06X}", argb & 0xFFFFFF)));
}

// Host thread. Stores the selection and applies it to the running game.
void SetTextureSelection(std::map<std::string, std::string> selection)
{
  auto& system = Core::System::GetInstance();
  HiresTexture::SetVariantSelection(std::move(selection));
  // Applied at the next frame end anyway; also queue it to the video thread right away so it
  // lands even while the game isn't presenting frames (loading screens, paused). The CPU thread
  // is paused while queueing, which keeps the video-event queue single-producer.
  if (Core::IsRunning(system))
  {
    Core::RunOnCPUThread(system, [] {
      AsyncRequests::GetInstance()->PushEvent([] {
        if (g_texture_cache && HiresTexture::ApplyPendingVariantChange())
          g_texture_cache->Invalidate();
      });
    });
  }
  Emit("textures", Json().AddRaw("selection", TextureSelectionJson()));
}

// Host thread. Selects the next option (alphabetical, wrapping) of the running game's
// "@<group>" texture folder. False if the game has no such group.
bool CycleTextureVariant(const std::string& group)
{
  std::map<std::string, std::set<std::string>> groups;
  for (const std::string& id : SConfig::GetInstance().GetGameIDsForTextures())
  {
    groups = HiresTexture::ListVariantGroups(id);
    if (!groups.empty())
      break;
  }
  const auto lower = [](std::string v) {
    for (char& c : v)
      c = static_cast<char>(std::tolower(static_cast<unsigned char>(c)));
    return v;
  };
  const auto it = std::ranges::find_if(groups, [&](const auto& g) {
    return lower(g.first) == lower(group);
  });
  if (it == groups.end() || it->second.empty())
    return false;

  const std::vector<std::string> options(it->second.begin(), it->second.end());
  auto selection = HiresTexture::GetVariantSelection();  // keys/values already lowercase
  const std::string key = lower(it->first);
  size_t next = 0;
  if (const auto cur = selection.find(key); cur != selection.end())
  {
    const auto pos = std::ranges::find_if(options, [&](const std::string& o) {
      return lower(o) == cur->second;
    });
    if (pos != options.end())
      next = (static_cast<size_t>(pos - options.begin()) + 1) % options.size();
  }
  selection[key] = options[next];
  SetTextureSelection(std::move(selection));
  // Custom textures may have been off (no --textures at launch): turn them on for this run.
  if (!Config::Get(Config::GFX_HIRES_TEXTURES))
    Config::SetCurrent(Config::GFX_HIRES_TEXTURES, true);
  return true;
}

// F3 = next @Graphics option, F4 = next @Buttons option, F5 = 16:9 / 4:3 (game window only).
void StartSparkingHotkeys()
{
  StartHotkeys({
      {HotkeyKey::F3, [] { CycleTextureVariant("Graphics"); }},
      {HotkeyKey::F4, [] { CycleTextureVariant("Buttons"); }},
      {HotkeyKey::F5, [] { ToggleWidescreen(); }},
  });
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

  // Presentation only, so allowed in netplay too (each player picks their own).
  if (cmd.name == "aspect")
  {
    if (cmd.arg == "16:9" || cmd.arg == "wide")
      SetWidescreen(true);
    else if (cmd.arg == "4:3" || cmd.arg == "standard")
      SetWidescreen(false);
    else if (cmd.arg.empty() || cmd.arg == "toggle")
      ToggleWidescreen();
    else
      Emit("error", Json().Add("code", "bad_argument").Add("command", cmd.name));
    return;
  }

  if (cmd.name == "stats")  // "stats 500" = a stats event every 500 ms in game, "stats 0" = off
  {
    int ms = 0;
    const auto [ptr, ec] = std::from_chars(cmd.arg.data(), cmd.arg.data() + cmd.arg.size(), ms);
    if (ec != std::errc() || ms < 0)
    {
      Emit("error", Json().Add("code", "bad_argument").Add("command", cmd.name));
      return;
    }
    SetStatsInterval(ms);
    return;
  }

  // Texture variants are presentation only too: "textures Buttons=Xbox" ("Buttons=" = none).
  if (cmd.name == "textures")
  {
    auto selection = HiresTexture::GetVariantSelection();
    if (!ApplyTextureSpec(cmd.arg, &selection))
    {
      Emit("error", Json().Add("code", "bad_argument").Add("command", cmd.name));
      return;
    }
    SetTextureSelection(std::move(selection));
    return;
  }
  if (cmd.name == "textures_cycle")  // same as the F3 / F4 hotkeys: next option of a group
  {
    if (!CycleTextureVariant(cmd.arg))
      Emit("error", Json().Add("code", "no_such_group").Add("command", cmd.name).Add("group", cmd.arg));
    return;
  }
  if (cmd.name == "texture_path")  // debug: which file a texture name maps to right now
  {
    Emit("texture_path",
         Json().Add("name", cmd.arg).Add("path", HiresTexture::GetMappedPath(cmd.arg)));
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
  else if (cmd.name == "peek")
  {
    // Debug: read a 32-bit word of game memory, e.g. "peek 8062BA44" (hex).
    u32 address = 0;
    const auto [ptr, ec] = std::from_chars(cmd.arg.data(), cmd.arg.data() + cmd.arg.size(),
                                           address, 16);
    if (ec != std::errc() || !Core::IsRunning(system))
    {
      Emit("error", Json().Add("code", "bad_argument").Add("command", cmd.name));
      return;
    }
    Core::CPUThreadGuard guard(system);
    const u32 value = PowerPC::MMU::HostRead<u32>(guard, address);
    Emit("peek", Json()
                     .Add("address", fmt::format("{:08X}", address))
                     .Add("value", fmt::format("{:08X}", value)));
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

  // Display: 1080p internal resolution (3x native) and 16:9 output; F5 / "aspect" flip to 4:3.
  {
    const int scale = std::clamp(std::atoi(static_cast<const char*>(options.get("resolution"))), 1, 8);
    layer->Set(Config::GFX_EFB_SCALE, scale);
    const bool wide = std::string_view(static_cast<const char*>(options.get("aspect"))) != "4:3";
    layer->Set(Config::GFX_ASPECT_RATIO, wide ? AspectMode::ForceWide : AspectMode::ForceStandard);
    SetDefaultWidescreen(wide);
    const std::string window = static_cast<const char*>(options.get("window"));
    int w = 0, h = 0;
    if (std::sscanf(window.c_str(), "%dx%d", &w, &h) == 2 && w > 0 && h > 0)
    {
      layer->Set(Config::MAIN_RENDER_WINDOW_WIDTH, w);
      layer->Set(Config::MAIN_RENDER_WINDOW_HEIGHT, h);
    }
  }

  // Overlay (the frontend draws the UI on its own window over the game window): Dolphin's own
  // on-screen messages off unless asked for, and pads keep working while the overlay has focus.
  layer->Set(Config::MAIN_OSD_MESSAGES,
             std::string_view(static_cast<const char*>(options.get("osd_messages"))) == "on");
  layer->Set(Config::MAIN_INPUT_BACKGROUND_INPUT,
             std::string_view(static_cast<const char*>(options.get("background_input"))) != "off");
  SetStatsInterval(std::atoi(static_cast<const char*>(options.get("stats_interval"))));

  // Texture variants (@Group/Option folders in the custom texture pack).
  if (options.is_set("textures"))
  {
    std::map<std::string, std::string> selection;
    for (const std::string& spec : options.all("textures"))
    {
      if (!ApplyTextureSpec(spec, &selection))
        Emit("error", Json().Add("code", "bad_argument").Add("textures", spec));
    }
    HiresTexture::SetVariantSelection(std::move(selection));
    layer->Set(Config::GFX_HIRES_TEXTURES, true);
  }

  // Dolphin runs no Gecko code at all unless "Enable Cheats" is on (default off). Sparking decides
  // exactly which codes run (--gecko / --no-gecko / ini defaults / --netplay-gecko), so the master
  // switch must be on. In netplay the host's value is pushed to every player.
  layer->Set(Config::MAIN_ENABLE_CHEATS, true);

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
  parser.add_option("--textures")
      .dest("textures")
      .action("append")
      .help("Sparking mode: texture variant GROUP=OPTION, i.e. folder @GROUP/OPTION in the game's "
            "texture pack (repeatable). Turns custom textures on.");
  parser.add_option("--textures-dir")
      .dest("textures_dir")
      .action("store")
      .help("Sparking mode: custom texture folder (holds <GAMEID>/ folders) instead of "
            "<user>/Load/Textures, so several profiles can share one texture library");
  parser.add_option("--list-textures")
      .dest("list_textures")
      .action("store")
      .metavar("GAMEID")
      .help("Print the texture variant groups (@folders) for a game as JSON, then exit");
  parser.add_option("--osd-messages")
      .dest("osd_messages")
      .action("store")
      .choices({"on", "off"})
      .set_default("off")
      .help("Sparking mode: draw Dolphin's own on-screen messages (default off: they are sent to "
            "the frontend as \"osd\" events for its overlay)");
  parser.add_option("--background-input")
      .dest("background_input")
      .action("store")
      .choices({"on", "off"})
      .set_default("on")
      .help("Sparking mode: controllers keep working while another window (the frontend's "
            "overlay) has focus (default on)");
  parser.add_option("--stats-interval")
      .dest("stats_interval")
      .action("store")
      .set_default("0")
      .help("Sparking mode: emit a \"stats\" event (fps, vps, speed) every N ms in game; 0 = off");
  parser.add_option("--aspect")
      .dest("aspect")
      .action("store")
      .choices({"16:9", "4:3"})
      .set_default("16:9")
      .help("Sparking mode starting aspect ratio (F5 toggles in game): 16:9 (default) or 4:3");
  parser.add_option("--resolution")
      .dest("resolution")
      .action("store")
      .set_default("3")
      .help("Sparking mode internal resolution as a multiple of native (3 = 1080p, default)");
  parser.add_option("--window")
      .dest("window")
      .action("store")
      .set_default("1280x720")
      .help("Sparking mode render window size WxH (default 1280x720; rendering stays 1080p)");
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
  return IsNetPlayMode(options) || options.is_set("list_gecko") || options.is_set("list_textures");
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

// After UICommon::Init (which derives the texture path from the user folder).
static void ApplyTexturesDir(const optparse::Values& options)
{
  if (options.is_set("textures_dir"))
  {
    File::SetUserPath(D_HIRESTEXTURES_IDX,
                      std::string(static_cast<const char*>(options.get("textures_dir"))));
  }
}

static int RunListTextures(const optparse::Values& options)
{
  std::string user_directory;
  if (options.is_set("user"))
    user_directory = static_cast<const char*>(options.get("user"));
  UICommon::SetUserDirectory(user_directory);
  UICommon::Init();
  Common::ScopeGuard guard([] { UICommon::Shutdown(); });
  ApplyTexturesDir(options);

  const std::string id = static_cast<const char*>(options.get("list_textures"));
  std::vector<std::string> groups;
  for (const auto& [group, options_found] : HiresTexture::ListVariantGroups(id))
  {
    std::vector<std::string> names;
    for (const std::string& option : options_found)
      names.push_back(Json::Escape(option));
    groups.push_back(Json().Add("name", group).AddRaw("options", JsonArray(names)).Str());
  }
  Emit("texture_groups", Json().Add("game_id", id).AddRaw("groups", JsonArray(groups)));
  Emit("exit", Json().Add("code", 0));
  return 0;
}

static int RunNetPlay(const optparse::Values& options, const FrontendHooks& hooks);

int RunMain(const optparse::Values& options, const FrontendHooks& hooks)
{
  if (options.is_set("list_gecko"))
    return RunListGecko(options);
  if (options.is_set("list_textures"))
    return RunListTextures(options);
  return RunNetPlay(options, hooks);
}

void InitFromOptions(const optparse::Values& options)
{
  const bool netplay = IsNetPlayMode(options);
  const bool listing = options.is_set("list_gecko") || options.is_set("list_textures");
  SetEnabled(netplay || options.is_set_by_user("sparking") || listing);
  if (options.is_set("state_dir"))
    s_state_dir = static_cast<const char*>(options.get("state_dir"));
  if (IsEnabled())
  {
    ApplySessionOverrides(options, netplay);
    Common::RegisterMsgAlertHandler(EventMsgAlertHandler);
    OSD::SetMessageObserver(ForwardOsdMessage);
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
           .Add("mode", netplay ? "netplay" : (listing ? "list" : "solo")));
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

  StartSparkingHotkeys();
  ApplyAspectForBoot();
  ApplyTexturesDir(options);

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
  ApplyTexturesDir(options);
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

  StartSparkingHotkeys();
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
