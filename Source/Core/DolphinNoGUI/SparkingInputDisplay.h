// Copyright 2026 Dolphin-Sparking Project
// SPDX-License-Identifier: GPL-2.0-or-later

// Input history bar, like a fighting game's training mode: a strip at the bottom of the game
// picture listing the local player's inputs, newest on the left. Each cell is one input held for
// some frames (video fields, 60/s): the frame count on top, then the direction (numpad notation;
// 5 = neutral, drawn as a ring with a dot) and the buttons held.
//
// Button pictures, first found wins:
//  1. the selected @Buttons texture pack option (PlayStation / Xbox ...): the replacement file of
//     the game's own button texture;
//  2. the game's own button texture, saved the first time the game draws it
//     (<User>/Sparking/ButtonIcons/<GameID>/<texture name>.png): Vanilla shows the game's icons;
//  3. a drawn icon in the style of the selected pack (GameCube colours, PlayStation shapes, Xbox
//     letters).
// The texture names come from the game ini, section [Sparking.ButtonIcons]:
//   A = tex1_32x32_ce62786fc1170192_70b585e07941e91c_8      (GameCube button -> texture name;
//   keys A B X Y Z L R Start; several names separated by commas, first found wins)
//
// Recorded from the GameCube port the HUD says is local (SetHudLocalPort; 1 offline), after the
// netplay pad buffer, so it shows what the game got and when. NEOcode re-runs aren't recorded.

#pragma once

#include <string>

namespace Sparking
{
// Once at startup. `enabled` = draw the bar (inputs are recorded either way).
void InitInputDisplay(bool enabled);
void SetInputDisplayEnabled(bool enabled);
bool InputDisplayEnabled();
// Game start (CPU/host thread): read [Sparking.ButtonIcons] and forget the history.
void LoadInputDisplay(const std::string& game_id, unsigned revision);
void ClearInputDisplay();
// "input_history" event: the recorded entries, newest first (tests, tools).
void EmitInputHistory();
// Video thread, inside the ImGui frame (from the HUD's draw callback).
void DrawInputDisplay();
}  // namespace Sparking
