// Copyright 2026 Dolphin-Sparking Project
// SPDX-License-Identifier: GPL-2.0-or-later

// Ranked match replays (Dolphin input movies).
//
// Recording (--record-replays <dir>, given by the launcher for ranked lobbies): when the first
// round of the match starts (both health bars full), Dolphin saves a state and records every
// controller input from there (a .dtm "from save state"). Netplay already has every player's
// inputs, so this costs nothing on the network. When the match is decided ("kothset") and the
// game stops, three files are written to the folder:
//   <name>.dtm       the inputs
//   <name>.dtm.sav   the save state at the start of the first round
//   <name>.json      players, score, winner, mode, this player's Gecko codes, date, frames
// and a "replay_saved" event names them. Matches nobody won (left, stopped by hand) are dropped.
//
// Playback (--replay <file.dtm>, with -e <game>): loads the state, plays the inputs back, emits
// "replay_started" (frames) and "replay_progress", and stops the game ("replay_ended") when the
// inputs run out, like a demo.
#pragma once

#include <array>
#include <string>
#include <vector>

struct BootParameters;

namespace Sparking
{
// --record-replays <dir>. Empty = off.
void SetReplayDir(const std::string& dir);
bool ReplaysEnabled();

struct ReplayMatch
{
  std::string game_id;
  int revision = 0;
  std::string mode;                    // "single" / "team" / ...
  std::array<std::string, 2> players;  // names on GameCube ports 1 and 2
  int local_port = 0;                  // 1-2: this player's port (0 = not playing: no replay)
  std::vector<std::string> gecko;      // this player's active Gecko codes (for playback)
  std::string kind;                    // "ranked" / "battle_lounge" / "player_match"
  bool keep_undecided = false;         // saved when the game stops even without a set result
                                       // (Player Match: free play, no sets)
};

// A netplay game is booting (host thread). Arms the recorder for this game.
void ReplayArm(const ReplayMatch& match);
// A round started (any thread): the first one of an armed game starts the recording.
void ReplayOnRoundStarted();
// The match was decided (any thread): wins as [winner, loser].
void ReplaySetDecided(const std::string& winner, const std::string& loser, int winner_wins,
                      int loser_wins);
// The game is about to stop (host thread, emulation still up): save or drop the recording.
void ReplayFinish();

// Playback: before booting (--replay). Starts the movie and points the boot at its save state.
// False (with an "error" event) if the file can't be played.
bool PrepareReplayPlayback(const std::string& dtm_path, BootParameters* boot);
// Once per video field (CPU thread): progress, and the end of the inputs.
void ReplayOnField();
}  // namespace Sparking
