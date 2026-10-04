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
//   [Sparking.Trigger]
//   # name = watch op number [&& watch op number ...]   (ops: == != < <= > >=)
//   p1_ko = p1_health_pct <= 0
//
// Events: "watch" {name, value} when a value changes (all values once at game start), and
// "game_event" {name} when a trigger's condition goes from false to true.

#pragma once

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
// Re-sends every current value as one "watch_values" event.
void EmitWatchValues();
}  // namespace Sparking
