// Copyright 2026 Dolphin-Sparking Project
// SPDX-License-Identifier: GPL-2.0-or-later

// Output aspect ratio: 16:9 by default, also 21:9 or 4:3; F3 toggles between 4:3 and the wide
// one chosen. Wide = Dolphin's "Stretch to Window" (the picture fills the window / monitor,
// whatever its shape); 21:9 also turns on Dolphin's widescreen hack, so on a 21:9 screen the 3D
// view gets wider instead of only stretched (2D parts, the HUD, are stretched). 4:3 = forced 4:3.
// Presentation only (the GPU's projection), nothing the emulated game sees: each player picks
// their own in netplay. The game's own widescreen Gecko code (if enabled) keeps running.

#pragma once

#include <functional>
#include <optional>
#include <string_view>
#include <vector>

namespace Sparking
{
enum class Aspect
{
  Standard,   // 4:3
  Wide,       // 16:9 (stretch to window)
  Ultrawide,  // 21:9 (stretch to window + widescreen hack)
};
// "4:3" / "16:9" / "21:9" (also "standard", "wide", "ultrawide"); nullopt if none of them.
std::optional<Aspect> AspectFromString(std::string_view text);
const char* AspectName(Aspect aspect);

void SetDefaultAspect(Aspect aspect);

// Host thread, right before a boot: applies the current choice and emits an "aspect" event.
void ApplyAspectForBoot();

// Host thread. Emits an "aspect" event.
void SetAspect(Aspect aspect);
// 4:3 <-> the wide one last chosen (16:9 unless 21:9 was).
void ToggleAspect();

enum class HotkeyKey
{
  F1,
  F2,
  F3,
};
struct Hotkey
{
  HotkeyKey key;
  std::function<void()> action;  // runs on the host thread
};
// Netplay battles: the F1-F3 switches (graphics, buttons, aspect ratio) are locked for the whole
// session (the hotkeys and the "textures", "textures_cycle" and "aspect" commands). Buffer
// Training (solo) isn't locked. Any thread.
void SetPresentationLocked(bool locked);
bool PresentationLocked();

// Watches the keys while one of this process's windows (the game window) has focus. Windows
// only; the first call wins, later calls do nothing.
void StartHotkeys(std::vector<Hotkey> hotkeys);

// Game window geometry for the frontend's overlay window (Option 1: a transparent, click-through
// Godot window kept on top of the game window). Coordinates are the CLIENT area (the picture,
// without title bar/borders) in screen pixels. Emits a "window" event when anything changes.
struct WindowReport
{
  bool open = false;
  int x = 0, y = 0, width = 0, height = 0;
  bool focused = false;
  bool minimized = false;
  unsigned long long handle = 0;  // native window handle (HWND on Windows)
};
void ReportWindow(const WindowReport& report);

// Periodic "stats" event (fps, vps, speed) for the overlay HUD; 0 turns it off. Any thread.
void SetStatsInterval(int milliseconds);

}  // namespace Sparking
