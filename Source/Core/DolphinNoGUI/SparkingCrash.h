// Copyright 2026 Dolphin-Sparking Project
// SPDX-License-Identifier: GPL-2.0-or-later

// Crash reports. If dolphin-emu-nogui crashes (access violation, abort, std::terminate, ...),
// it writes dolphin_crash_<date>_<time>.txt (what crashed, where, the stack, the last events)
// and, on Windows, a minidump (.dmp) next to it, into the crash folder, then prints
//   [SPARKING] {"event":"crash","report":"...","dump":"...","summary":"..."}
// so the launcher can add it to its own report and tell the player.
//
// Crash folder: $SPARKING_CRASH_DIR (the launcher sets it: SparkingData/logs), else
// <user folder>/Logs.

#pragma once

#include <string>
#include <string_view>

namespace Sparking
{
// As early as possible in main(). `user_dir`: the -u folder ("" = none given).
void InstallCrashHandler(const std::string& user_dir);

// Short "where are we" text kept for the report (game, netplay role, ...). Any thread.
void SetCrashContext(std::string_view text);

// Called by the event writer with every event line (kept: the last few, for the report).
void NoteEventForCrash(std::string_view line);

// Tests (--test-hooks): crash on purpose. `how`: "segv" (default) or "abort".
[[noreturn]] void CrashForTest(std::string_view how);
}  // namespace Sparking
