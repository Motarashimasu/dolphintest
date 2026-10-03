// Copyright 2026 Dolphin-Sparking Project
// SPDX-License-Identifier: GPL-2.0-or-later

// Output aspect ratio: 16:9 by default, F5 toggles 4:3. Only Dolphin's output stretch changes;
// the game's own widescreen Gecko code (if enabled) keeps running either way.

#pragma once

#include <functional>
#include <vector>

namespace Sparking
{
void SetDefaultWidescreen(bool wide);

// Host thread, right before a boot: applies the current choice and emits an "aspect" event.
void ApplyAspectForBoot();

// Host thread. Emits an "aspect" event.
void SetWidescreen(bool wide);
void ToggleWidescreen();

enum class HotkeyKey
{
  F3,
  F4,
  F5,
};
struct Hotkey
{
  HotkeyKey key;
  std::function<void()> action;  // runs on the host thread
};
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
