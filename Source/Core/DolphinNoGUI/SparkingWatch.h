// Copyright 2026 Dolphin-Sparking Project
// SPDX-License-Identifier: GPL-2.0-or-later

// Memory watcher: named game-memory values read once per frame, reported to the frontend when they
// change, plus edge-triggered conditions on them (KO, match end, ...). Defined per game in its
// game ini:
//
//   [Sparking.Watch]
//   # name = type address [> offset > offset ...]   (types: u8 u16 u32 s8 s16 s32 f32)
//   p1_health_pct = f32 0x803D1024
//   p1_hp         = u32 0x80400000 > 0x1C          # follow a pointer: read u32 at 0x80400000,
//                                                  # add 0x1C, read the value there
//   p1_health_pct = u32 0x805F3210 > 0 > 0x11D8 / u32 0x805F3210 > 0 > 0x11E0 * 100
//                                                  # a ratio: the first value / the second
//                                                  # (x 100: a percentage); null if the second is 0
//   [Sparking.Trigger]
//   # name = watch op number [&& watch op number ...]   (ops: == != < <= > >=)
//   p1_ko = p1_health_pct <= 0
//
// Events: "watch" {name, value} when a value changes (all values once at game start), and
// "game_event" {name} when a trigger's condition goes from false to true. Names starting with
// "p1_".."p4_" also carry "port", "player" (that port's username, see SetPortNames) and "label"
// (the name with "p1" replaced by the username, e.g. "Goku_defeated").

#pragma once

#include <array>
#include <string>

#include "Common/CommonTypes.h"

namespace Sparking
{
// Once at startup (Sparking mode): hooks the per-frame read.
void InitWatcher();
// Host thread, when a game starts: loads that game's watches/triggers (none: watcher idle).
void LoadWatches(const std::string& game_id, u16 revision);
// When a game ends.
void ClearWatches();
// Who is on each GameCube port (index 0 = port 1): netplay usernames, or solo names. Watch and
// trigger names that start with "p1_".."p4_" are reported with that player's name. Any thread.
void SetPortNames(const std::array<std::string, 4>& names);
// Re-sends every current value as one "watch_values" event.
void EmitWatchValues();
// The watches' current values as a JSON object ({"p1_health_pct":100,...}).
std::string WatchValuesJson();
// NEOcode: the watcher's state (last values, triggers) at a field end, and back (CPU thread).
std::string SaveWatchState();
void LoadWatchState(const std::string& state);
}  // namespace Sparking
