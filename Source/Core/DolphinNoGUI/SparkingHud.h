// Copyright 2026 Dolphin-Sparking Project
// SPDX-License-Identifier: GPL-2.0-or-later

// Temporary in-game HUD (drawn by Dolphin itself, until the Godot overlay exists):
//  - top corners: each side's name + health %;
//  - top center: a Fightcade-style score bar "Name1  W1  W2  Name2".
// Driven by the memory watcher's "p1_health_pct" / "p2_health_pct" watches (see SparkingWatch.h).
//
// Round counting (for now, from health alone):
//  - a round is live once BOTH sides are back at 100% health;
//  - the first side to reach 0% in a live round loses it: the other side gets +1 win and a
//    "round_result" event is sent; nothing more counts until both are at 100% again.
// Scores are kept per player name for the life of the process (all rematches in one netplay
// session), so they follow players even if they swap ports.

#pragma once

#include <string>

namespace Sparking
{
// Once at startup. `enabled` = draw the HUD (round counting and events happen either way).
void InitHud(bool enabled);
void SetHudEnabled(bool enabled);
// GameCube port of the local player (1-4; 0 = spectator / unknown); reported in round_result.
void SetHudLocalPort(int port);
// When a game starts/ends: forget health values (scores are kept).
void ResetHud();
// Scores back to 0-0.
void ResetScores();

// From the memory watcher (CPU thread). `player` = display name of that port.
void HudOnWatch(const std::string& name, int port, const std::string& player, double value,
                bool valid);
}  // namespace Sparking
