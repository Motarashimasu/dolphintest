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

}  // namespace Sparking
