// Copyright 2026 Dolphin-Sparking Project
// SPDX-License-Identifier: GPL-2.0-or-later

// Input history, like a fighting game's training mode: a column down the side of the game
// picture per player, port 1 on the left, port 2 on the right, newest on top. Each row is one
// input held for some frames (video fields, 60/s): the frame count (at the outer edge), then the
// direction (numpad notation; 5 = neutral, drawn as a ring with a dot) and the buttons held.
// The local player's own column can always be shown; the other port's only when nobody else plays
// it (offline, Buffer Training), never in an online match.
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
// Ports 1 and 2 are recorded where the game reads them (after the netplay pad buffer), so it
// shows what the game got and when. NEOcode re-runs aren't recorded. "Own" = the port the HUD
// says is local (SetHudLocalPort; 1 offline; spectators have none).

#pragma once

#include <string>

namespace Sparking
{
// Once at startup. `enabled` = the local player's column, `other` = the other port's (1 <-> 2).
// Inputs are recorded either way.
void InitInputDisplay(bool enabled, bool other);
void SetInputDisplayEnabled(bool enabled);
bool InputDisplayEnabled();
// The other port's column. Refused ("not_allowed_online" error, false) in an online match: only
// your own inputs can be shown when someone else plays the other port.
bool SetInputDisplayOther(bool enabled);
bool InputDisplayOtherEnabled();
// Netplay: whether the other port's column may be shown (false while another player is on it;
// switching it off turns that column off). Offline: always allowed.
void SetInputDisplayOtherAllowed(bool allowed);
// Game start (CPU/host thread): read [Sparking.ButtonIcons] and forget the history.
void LoadInputDisplay(const std::string& game_id, unsigned revision);
void ClearInputDisplay();
// "input_history" event: the recorded entries, newest first (tests, tools).
void EmitInputHistory();
// Video thread, inside the ImGui frame (from the HUD's draw callback).
void DrawInputDisplay();
}  // namespace Sparking
