// Copyright 2026 Dolphin-Sparking Project
// SPDX-License-Identifier: GPL-2.0-or-later

// In-game menu button: holding a controller's Select/Back button (not part of a GameCube pad, so
// it never reaches the game) asks the frontend to open its in-game menu ("menu_request" event).
// Read straight from the physical controllers once per video field, so it works with any pad
// mapping and while the Godot overlay has focus.

#pragma once

#include <string>
#include <vector>

namespace Sparking
{
// Once at startup (Sparking mode). `buttons`: input names as Dolphin's controller backends call
// them (XInput / SDL: "Back"). `hold_ms`: how long to hold.
void InitMenuButton(std::vector<std::string> buttons, int hold_ms);
}  // namespace Sparking
