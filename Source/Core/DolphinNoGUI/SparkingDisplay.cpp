// Copyright 2026 Dolphin-Sparking Project
// SPDX-License-Identifier: GPL-2.0-or-later

#include "DolphinNoGUI/SparkingDisplay.h"

#include <atomic>
#include <chrono>
#include <thread>

#include "Common/Config/Config.h"
#include "Core/Config/GraphicsSettings.h"
#include "Core/Core.h"
#include "Core/System.h"
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

}  // namespace Sparking
