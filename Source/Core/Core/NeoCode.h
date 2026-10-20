// Copyright 2026 Dolphin-Sparking Project
// SPDX-License-Identifier: GPL-2.0-or-later

// NEOcode: netplay where nobody waits for the other player's inputs.
//
// Delay netplay (Dolphin's) makes every controller poll wait until the other player's input for
// that poll has arrived, so the game runs `delay` polls behind. NEOcode keeps that delay as a
// minimum and, past it, guesses the missing input (the last one received) and plays on. Real
// inputs arriving later are checked against the guesses: when one was wrong, the game rewinds to
// the field before that poll and re-runs to where it was, unthrottled and without drawing, with
// the real inputs. The re-run's fields aren't shown; the player sees the corrected game.
//
// How (all on the CPU thread):
//  - every controller poll gets an index per pad; the log keeps each poll's input, confirmed (the
//    real one) or guessed;
//  - at the end of every field the state is saved (memory pages the game changed, the rest of the
//    state, the frontend's game-side state: watches, HUD), with each pad's poll index;
//  - a wrong guess rewinds to the latest saved field before it and re-runs to the present;
//  - guessing stops (the game waits, as in delay netplay) once the oldest unconfirmed input is
//    MAX_ROLLBACK_FIELDS old, so a rewind never has to go further back than what's saved;
//  - a field is final once every input before it is confirmed. The frontend holds back what the
//    game "did" (events, results) until it's final, and drops it when a rewind takes it back;
//  - every CHECKSUM_FIELDS fields the memory's checksum is taken, and passed to the frontend once
//    final, so the players can compare.
#pragma once

#include <array>
#include <functional>
#include <string>
#include <utility>
#include <vector>

#include "Common/CommonTypes.h"
#include "InputCommon/GCPadStatus.h"

namespace NeoCode
{
constexpr int MAX_ROLLBACK_FIELDS = 12;  // 6 BT3 frames, 200 ms
constexpr int START_FIELDS = 60;          // fields after the start before guessing begins
constexpr u64 CHECKSUM_FIELDS = 120;

struct Stats
{
  u64 field = 0;
  u64 rollbacks = 0;            // since the start
  int rollback_fields = 0;      // the biggest rewind since the last stats (fields)
  u64 rollback_fields_total = 0;
  u64 stalls = 0;               // waits because the other side was too far behind
  double save_ms = 0;           // average of the saves since the last stats
  double load_ms = 0;
  double resim_ms = 0;          // the longest re-run since the last stats (real time: the hitch)
  bool guessing = false;        // past the start, saves working
  u64 polls = 0;                // controller polls so far (all pads)
  u64 guesses = 0;              // inputs played with a guess
  u64 wrong_guesses = 0;
  u64 queued = 0;               // most inputs any pad has received and not played yet
  u64 saves_skipped = 0;        // re-run fields not saved (nothing could rewind to them)
};

struct Callbacks
{
  // The frontend's game-side state (watches, HUD) at a field end, and back.
  std::function<std::string()> save_side;
  std::function<void(const std::string&)> load_side;
  // Emulated time (CoreTiming ticks): everything up to `ticks` is final / a rewind went back to
  // `ticks` (what happened after it didn't happen).
  std::function<void(u64 ticks)> final_until;
  std::function<void(u64 ticks)> rewound_to;
  // The memory checksum at the start of `field`, now final.
  std::function<void(u64 field, u64 checksum)> checksum;
  // Every ~60 fields.
  std::function<void(const Stats&)> stats;
  // Something broke (can't save / rewind): the match goes on as delay netplay.
  std::function<void(const std::string& reason)> failed;
};

// Match start / end (any thread; Start before the game boots). `drain` moves the inputs received
// so far into the log (calls Confirm for each), CPU thread.
void Start(std::function<void()> drain, Callbacks callbacks);
// MEM1 bytes ({physical offset, size}) the sync checksum leaves out besides the Gecko code area:
// what the per-port codes write (each player runs only their own port's). Before Start.
void SetChecksumSkip(std::vector<std::pair<u32, u32>> ranges);
void Stop();
bool IsActive();

// CPU thread (NetPlayClient::GetNetPads).
bool IsResimulating();
// The next real input of `pad`, in order.
void Confirm(int pad, const GCPadStatus& status);
// The input for this poll of `pad`: confirmed, or a guess. False: too far ahead, wait for input.
bool GetInput(int pad, GCPadStatus* status);
// A local controller's input before it's sent / played: analog values that wobble by a few steps
// (every real stick and trigger does) keep their last value, near-centre sticks snap to the
// centre, near-released / near-full triggers to 0 / 255. Each wobble would otherwise be a new
// input the other side guessed wrong: a rewind every few frames while a stick is held.
void Stabilize(int pad, GCPadStatus* status);
// Real inputs of `pad` received and not played yet (the local pad's: its pad buffer).
u64 Queued(int pad);
// For the frontend: the emulated time now (to stamp what the game does).
u64 NowTicks();
}  // namespace NeoCode
