// Copyright 2026 Dolphin-Sparking Project
// SPDX-License-Identifier: GPL-2.0-or-later

#include "DolphinNoGUI/SparkingInput.h"

#include <OptionParser.h>
#include <atomic>
#include <chrono>
#include <map>
#include <string>
#include <thread>
#include <vector>

#ifdef _WIN32
#include <windows.h>
#endif

#include "Common/ScopeGuard.h"
#include "Common/WindowSystemInfo.h"
#include "DolphinNoGUI/SparkingIO.h"
#include "InputCommon/ControllerInterface/ControllerInterface.h"
#include "UICommon/UICommon.h"

namespace Sparking
{
namespace
{
// An input counts once it has been seen at rest, so buttons held while the test starts (or axes
// resting at an extreme) don't fire. Press above PRESS, release below RELEASE.
constexpr double REST = 0.25;
constexpr double PRESS = 0.6;
constexpr double RELEASE = 0.3;

struct Tracked
{
  bool rested = false;
  bool pressed = false;
};

std::string DevicesJson(const std::vector<std::shared_ptr<ciface::Core::Device>>& devices)
{
  std::vector<std::string> list;
  for (const auto& d : devices)
  {
    list.push_back(Json()
                       .Add("name", d->GetQualifiedName())
                       .Add("source", d->GetSource())
                       .Add("title", d->GetName())
                       .Add("inputs", static_cast<int>(d->Inputs().size()))
                       .Str());
  }
  return JsonArray(list);
}
}  // namespace

int RunInputTest(const optparse::Values& options)
{
  std::string user_directory;
  if (options.is_set("user"))
    user_directory = static_cast<const char*>(options.get("user"));
  UICommon::SetUserDirectory(user_directory);
  UICommon::Init();

  WindowSystemInfo wsi;
#ifdef _WIN32
  // DirectInput needs a window for its cooperative level; a hidden one is enough.
  HWND hwnd = CreateWindowExW(0, L"STATIC", L"", WS_OVERLAPPED, 0, 0, 1, 1, nullptr, nullptr,
                              GetModuleHandle(nullptr), nullptr);
  wsi = WindowSystemInfo(WindowSystemType::Windows, nullptr, hwnd, hwnd);
#endif
  g_controller_interface.Initialize(wsi);
  Common::ScopeGuard guard([&] {
    g_controller_interface.Shutdown();
#ifdef _WIN32
    if (hwnd)
      DestroyWindow(hwnd);
#endif
    UICommon::Shutdown();
  });

  std::atomic<bool> quit{false};
  std::atomic<bool> resend{false};
  StartLineReader(
      [&](const Command& cmd) {
        if (cmd.name == "quit" || cmd.name == "stop")
          quit = true;
        else if (cmd.name == "devices")
          resend = true;
      },
      [&] { quit = true; });

  Emit("ready", Json().Add("protocol", PROTOCOL_VERSION).Add("mode", "input_test"));

  std::map<std::string, Tracked> tracked;
  std::vector<std::string> last_names;
  bool first = true;
  while (!quit)
  {
    g_controller_interface.UpdateInput();
    const auto devices = g_controller_interface.GetAllDevices();

    std::vector<std::string> names;
    for (const auto& d : devices)
      names.push_back(d->GetQualifiedName());
    if (first || names != last_names || resend.exchange(false))
    {
      Emit("devices", Json().AddRaw("devices", DevicesJson(devices)));
      last_names = names;
      first = false;
    }

    for (const auto& d : devices)
    {
      const std::string dev = d->GetQualifiedName();
      for (ciface::Core::Device::Input* input : d->Inputs())
      {
        if (!input->IsDetectable())
          continue;
        const double v = input->GetState();
        Tracked& t = tracked[dev + "\n" + input->GetName()];
        if (!t.rested)
        {
          t.rested = v < REST;
          continue;
        }
        if (!t.pressed && v > PRESS)
        {
          t.pressed = true;
          Emit("input", Json()
                            .Add("device", dev)
                            .Add("input", input->GetName())
                            .Add("pressed", true));
        }
        else if (t.pressed && v < RELEASE)
        {
          t.pressed = false;
          Emit("input", Json()
                            .Add("device", dev)
                            .Add("input", input->GetName())
                            .Add("pressed", false));
        }
      }
    }
    std::this_thread::sleep_for(std::chrono::milliseconds(15));
  }
  Emit("exit", Json().Add("code", 0));
  return 0;
}
}  // namespace Sparking
