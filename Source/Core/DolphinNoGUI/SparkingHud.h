// Copyright 2026 Dolphin-Sparking Project
// SPDX-License-Identifier: GPL-2.0-or-later

// Temporary in-game HUD (drawn by Dolphin itself, until the Godot overlay exists): each side's
// name + health % in the top corners, and a win/lose message when a side is defeated.
// Driven by the memory watcher: watches "p1_health_pct" / "p2_health_pct" and triggers
// "p1_defeated" / "p2_defeated" (see SparkingWatch.h).
//
// Also the source of the "match_result" event: one result per battle. A battle counts as running
// once both sides have health > 0; the first *_defeated after that is the result, and nothing
// more is reported until both sides are alive again (next battle). That filters out health
// values reset to 0 on menus/result screens.

#pragma once

#include <string>

namespace Sparking
{
// Once at startup. `enabled` = draw the HUD (the match_result event is sent either way).
void InitHud(bool enabled);
void SetHudEnabled(bool enabled);
// GameCube port of the local player (1-4; 0 = spectator / unknown), for "YOU WIN"/"YOU LOSE".
void SetHudLocalPort(int port);
// When a game starts/ends: forget values and results.
void ResetHud();

// From the memory watcher (CPU thread). `player` = display name of that port.
void HudOnWatch(const std::string& name, int port, const std::string& player, double value,
                bool valid);
void HudOnTrigger(const std::string& name, int port, const std::string& player);
}  // namespace Sparking
