// Copyright 2026 Dolphin-Sparking Project
// SPDX-License-Identifier: GPL-2.0-or-later

// Output aspect ratio: 16:9 by default, F5 toggles 4:3. Only Dolphin's output stretch changes;
// the game's own widescreen Gecko code (if enabled) keeps running either way.

#pragma once

namespace Sparking
{
void SetDefaultWidescreen(bool wide);

// Host thread, right before a boot: applies the current choice and emits an "aspect" event.
void ApplyAspectForBoot();

// Host thread. Emits an "aspect" event.
void SetWidescreen(bool wide);
void ToggleWidescreen();

// Watches for F5 while one of this process's windows has focus (Windows only).
void StartAspectHotkey();

}  // namespace Sparking
