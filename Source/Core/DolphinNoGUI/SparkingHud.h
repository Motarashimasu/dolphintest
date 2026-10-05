// Copyright 2026 Dolphin-Sparking Project
// SPDX-License-Identifier: GPL-2.0-or-later

// Temporary in-game HUD (drawn by Dolphin itself, until the Godot overlay exists):
//  - score bar in the centre of the game's top HUD: "[icon] Name1  W1 | W2  Name2 [icon]" (names
//    shrunk/cut so the bar never reaches the health bars; icons = wired/Wi-Fi in netplay),
//    health % in the window's top corners, and (netplay) ping ± jitter + buffer at the bottom.
//  - a see-through "PRE-ALPHA" watermark in the window's bottom-right corner, always shown.
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

#include <array>
#include <string>

namespace Sparking
{
// Once at startup. `enabled` = draw the score bar (+ netplay ping/buffer), `health` = draw the
// health % in the corners. Round counting and events happen either way.
void InitHud(bool enabled, bool health);
void SetHudEnabled(bool enabled);
void SetHudHealthEnabled(bool enabled);
// GameCube port of the local player (1-4; 0 = spectator / unknown); reported in round_result.
void SetHudLocalPort(int port);
// Netplay connection info for the bottom bar (any thread). Pass -1 to clear a value, -2 to leave
// it unchanged. The bar is only drawn while a ping is set (netplay).
void SetHudNetplayStats(int ping_ms, int buffer);
// Ping stability for the bottom bar: jitter in ms (-1 = not measured yet) and "good" / "ok" /
// "poor" / "measuring" (colors the ping text). Any thread.
void SetHudLinkQuality(int jitter_ms, const std::string& rating);
// Wired/Wi-Fi status of the players on ports 1 and 2 ("wired", "wireless", "virtual",
// "unknown"): an icon next to each name. Any thread.
void SetHudLinks(const std::array<std::string, 2>& links);
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
