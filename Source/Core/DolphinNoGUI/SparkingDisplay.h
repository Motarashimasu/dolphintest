// Copyright 2026 Dolphin-Sparking Project
// SPDX-License-Identifier: GPL-2.0-or-later

// Aspect ratio (16:9 default, F5 toggles 4:3) and the Gecko code set that goes with it.
//
// A game's widescreen Gecko code is named in its game ini:
//     [Sparking]
//     WidescreenCode = 16:9 aspect ratio
// 16:9 = that code on + Dolphin output forced to 16:9.
// 4:3  = that code off, the game's original values (read from the disc's main DOL) written back
//        over what the code patched, + Dolphin output forced to 4:3.

#pragma once

#include <string>
#include <vector>

#include "Common/CommonTypes.h"

namespace Sparking
{
void SetDefaultWidescreen(bool wide);

// Call on the host thread right before a boot, with the exact Gecko names about to be activated.
// Remembers them, sets Dolphin's output aspect, and returns `names` adjusted for the current
// aspect (widescreen code removed when in 4:3). Pass the result to ActivateExclusiveGeckoCodes.
std::vector<std::string> PrepareAspectForBoot(const std::string& game_path,
                                              const std::string& game_id, u16 revision,
                                              std::vector<std::string> names);

// Host thread, while a game is running. Emits an "aspect" event.
void SetWidescreen(bool wide);
void ToggleWidescreen();

// Watches for F5 while one of this process's windows has focus (Windows only).
void StartAspectHotkey();

}  // namespace Sparking
