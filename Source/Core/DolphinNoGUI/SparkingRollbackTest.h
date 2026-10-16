// Copyright 2026 Dolphin-Sparking Project
// SPDX-License-Identifier: GPL-2.0-or-later

// Rollback test mode (--rollback-test <fields>): the first step toward rollback netplay. While
// the game is played offline it keeps doing what rollback netcode would do, then checks the
// result:
//   1. at a video field, save the whole emulated state to memory (timed);
//   2. play on normally for <fields> fields, recording every controller poll;
//   3. copy the game's memory (MEM1 + ARAM), rewind to the saved state (timed) and play the same
//      fields again as fast as possible with the recorded inputs (timed);
//   4. compare the memory with the copy. Any difference means something the game depends on
//      isn't restored by a rewind (or isn't deterministic): those addresses are reported.
// Repeats every <gap> fields. Emulation is kept deterministic (as in netplay) while it runs.
//
// Events: "rollback_test" (started, settings), "rollback_mismatch" (a cycle that didn't match:
// field, differing MEM1 ranges, ARAM bytes, input problems), "rollback_test_stats" (running
// totals: cycles, mismatches, save / load / re-run times, state size, and how many fields this
// PC could re-run within one field). Everything is also appended to --rollback-log (JSON lines).
#pragma once

#include <string>
#include <vector>

#include "Common/CommonTypes.h"

namespace Sparking
{
// Before booting. `fields` = how far back each test rewinds (1-16 video fields; BT3 runs its
// game logic every 2 fields), `gap` = fields between tests.
// `trace`: words whose values are logged field by field with each mismatch (the first
// differing spots of every mismatch are added automatically).
// `keep_jit`: keep the compiled code across rewinds (else recompile after each, like a normal
// state load).
void InitRollbackTest(int fields, int gap, const std::string& log_path,
                      const std::vector<u32>& trace = {}, bool keep_jit = true);
bool RollbackTestActive();
}  // namespace Sparking
