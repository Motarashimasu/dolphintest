// Copyright 2026 Dolphin-Sparking Project
// SPDX-License-Identifier: GPL-2.0-or-later

// Temporary in-game HUD (drawn by Dolphin itself, until the Godot overlay exists):
//  - top corners: each side's name + health %;
//  - top center: a Fightcade-style score bar "Name1  W1  W2  Name2".
// Driven by the memory watcher's "p1_health_pct" / "p2_health_pct" watches (see SparkingWatch.h).
//
// Round counting (for now, from health alone):
//  - a round is live once BOTH sides are back at 100% health;
//  - when one side reaches 0% in a live round, the result waits ~0.75 s: if the other side is
//    still alive then, it's a KO (other side +1, "round_result"); if both are at 0% by then
//    (leaving a match, loading the next one: the game clears both values), the round is void
//    ("round_void", nobody scores). Nothing more counts until both are at 100% again.
// Scores are kept per player name while the game runs (all rematches in one boot) and reset when
// the game is (re)booted or closed.

#pragma once

#include <string>

namespace Sparking
{
// Once at startup. `enabled` = draw the HUD (round counting and events happen either way).
void InitHud(bool enabled);
void SetHudEnabled(bool enabled);
// GameCube port of the local player (1-4; 0 = spectator / unknown); reported in round_result.
void SetHudLocalPort(int port);
// When a game starts/ends: forget health values and scores.
void ResetHud();
// Scores back to 0-0.
void ResetScores();

// From the memory watcher (CPU thread). `player` = display name of that port.
void HudOnWatch(const std::string& name, int port, const std::string& player, double value,
                bool valid);
// Once per frame (CPU thread), after that frame's HudOnWatch calls.
void HudTick();
}  // namespace Sparking
