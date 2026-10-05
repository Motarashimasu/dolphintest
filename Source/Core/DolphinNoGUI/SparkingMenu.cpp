// Copyright 2026 Dolphin-Sparking Project
// SPDX-License-Identifier: GPL-2.0-or-later

#include "DolphinNoGUI/SparkingMenu.h"

#include <algorithm>
#include <chrono>
#include <optional>

#include "Common/HookableEvent.h"
#include "Core/NetPlayProto.h"
#include "Core/System.h"
#include "DolphinNoGUI/SparkingIO.h"
#include "InputCommon/ControllerInterface/ControllerInterface.h"
#include "VideoCommon/VideoEvents.h"

namespace Sparking
{
namespace
{
using Clock = std::chrono::steady_clock;

std::vector<std::string> s_buttons;
std::chrono::milliseconds s_hold{1000};
std::optional<Clock::time_point> s_down_since;  // CPU thread only
bool s_fired = false;                           // until the button is released

// Name of the device + input currently held, or empty.
std::string HeldButton()
{
  for (const std::string& device_string : g_controller_interface.GetAllDeviceStrings())
  {
    ciface::Core::DeviceQualifier qualifier;
    qualifier.FromString(device_string);
    const auto device = g_controller_interface.FindDevice(qualifier);
    if (!device)
      continue;
    for (const auto* input : device->Inputs())
    {
      if (input->GetState() > 0.5 &&
          std::ranges::find(s_buttons, input->GetName()) != s_buttons.end())
      {
        return device_string + ":" + input->GetName();
      }
    }
  }
  return {};
}

void OnField()
{
  const std::string held = HeldButton();
  if (held.empty())
  {
    s_down_since.reset();
    s_fired = false;
    return;
  }
  const auto now = Clock::now();
  if (!s_down_since)
    s_down_since = now;
  if (!s_fired && now - *s_down_since >= s_hold)
  {
    s_fired = true;
    Emit("menu_request", Json().Add("button", held).Add("netplay", NetPlay::IsNetPlayRunning()));
  }
}
}  // namespace

void InitMenuButton(std::vector<std::string> buttons, int hold_ms)
{
  s_buttons = std::move(buttons);
  s_hold = std::chrono::milliseconds(std::max(hold_ms, 100));
  if (s_buttons.empty())
    return;
  // Deliberately never destroyed (same reason as the other hooks).
  static auto* const hook = new Common::EventHook(
      Core::System::GetInstance().GetVideoEvents().vi_end_field_event.Register([] { OnField(); }));
  (void)hook;
}
}  // namespace Sparking
