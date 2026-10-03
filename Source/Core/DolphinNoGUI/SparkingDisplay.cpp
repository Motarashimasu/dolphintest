// Copyright 2026 Dolphin-Sparking Project
// SPDX-License-Identifier: GPL-2.0-or-later

#include "DolphinNoGUI/SparkingDisplay.h"

#include <algorithm>
#include <atomic>
#include <cmath>
#include <mutex>
#include <chrono>
#include <thread>

#include <fmt/format.h>

#include "Common/Config/Config.h"
#include "Core/Config/GraphicsSettings.h"
#include "Core/Core.h"
#include "Core/System.h"
#include "VideoCommon/PerformanceMetrics.h"
#include "DolphinNoGUI/SparkingIO.h"
#include "VideoCommon/VideoConfig.h"

#ifdef _WIN32
#include <windows.h>
#endif

namespace Sparking
{
namespace
{
std::atomic<bool> s_wide{true};

void Apply(bool wide)
{
  Config::SetCurrent(Config::GFX_ASPECT_RATIO,
                     wide ? AspectMode::ForceWide : AspectMode::ForceStandard);
  Emit("aspect", Json().Add("mode", wide ? "16:9" : "4:3"));
}
}  // namespace

void SetDefaultWidescreen(bool wide)
{
  s_wide = wide;
}

void ApplyAspectForBoot()
{
  Apply(s_wide);
}

void SetWidescreen(bool wide)
{
  s_wide = wide;
  Apply(wide);
}

void ToggleWidescreen()
{
  SetWidescreen(!s_wide);
}

void StartHotkeys(std::vector<Hotkey> hotkeys)
{
#ifdef _WIN32
  static std::atomic<bool> started{false};
  if (started.exchange(true))
    return;
  std::thread([hotkeys = std::move(hotkeys)] {
    std::vector<bool> was_down(hotkeys.size(), false);
    while (true)
    {
      std::this_thread::sleep_for(std::chrono::milliseconds(30));
      for (size_t i = 0; i < hotkeys.size(); ++i)
      {
        const int vk = hotkeys[i].key == HotkeyKey::F3 ? VK_F3 :
                       hotkeys[i].key == HotkeyKey::F4 ? VK_F4 :
                                                         VK_F5;
        const bool down = (GetAsyncKeyState(vk) & 0x8000) != 0;
        if (down && !was_down[i])
        {
          // Only when the focused window is ours (the game window), not Godot or anything else.
          DWORD pid = 0;
          GetWindowThreadProcessId(GetForegroundWindow(), &pid);
          if (pid == GetCurrentProcessId())
            Core::QueueHostJob([action = hotkeys[i].action](Core::System&) { action(); });
        }
        was_down[i] = down;
      }
    }
  }).detach();
#else
  (void)hotkeys;
#endif
}

void ReportWindow(const WindowReport& r)
{
  static std::mutex mutex;
  static WindowReport last;
  static bool any = false;
  {
    std::lock_guard lk(mutex);
    if (any && r.open == last.open && r.x == last.x && r.y == last.y && r.width == last.width &&
        r.height == last.height && r.focused == last.focused && r.minimized == last.minimized &&
        r.handle == last.handle)
    {
      return;
    }
    last = r;
    any = true;
  }
  Emit("window", Json()
                     .Add("open", r.open)
                     .Add("x", r.x)
                     .Add("y", r.y)
                     .Add("width", r.width)
                     .Add("height", r.height)
                     .Add("focused", r.focused)
                     .Add("minimized", r.minimized)
                     .Add("handle", static_cast<int64_t>(r.handle)));
}

void SetStatsInterval(int milliseconds)
{
  static std::atomic<int> s_interval{0};
  static std::atomic<bool> s_thread_started{false};
  s_interval = std::max(milliseconds, 0);
  if (s_interval == 0 || s_thread_started.exchange(true))
    return;
  std::thread([] {
    while (true)
    {
      const int interval = s_interval;
      std::this_thread::sleep_for(std::chrono::milliseconds(interval > 0 ? interval : 200));
      if (interval <= 0)
        continue;
      auto& system = Core::System::GetInstance();
      if (Core::GetState(system) != Core::State::Running)
        continue;
      const auto& perf = system.GetPerfMetrics();
      const auto round1 = [](double v) { return std::isfinite(v) ? std::round(v * 10) / 10 : 0.0; };
      Emit("stats", Json()
                        .AddRaw("fps", fmt::format("{}", round1(perf.GetFPS())))
                        .AddRaw("vps", fmt::format("{}", round1(perf.GetVPS())))
                        .AddRaw("speed", fmt::format("{}", round1(perf.GetSpeed() * 100.0))));
    }
  }).detach();
}

}  // namespace Sparking
