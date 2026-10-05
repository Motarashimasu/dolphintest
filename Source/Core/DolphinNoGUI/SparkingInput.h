// Copyright 2026 Dolphin-Sparking Project
// SPDX-License-Identifier: GPL-2.0-or-later

// --input-test: the frontend's controller tester and button-binding helper. Lists the input
// devices Dolphin sees ("devices" event, again whenever that changes) and reports every
// button/axis that is pressed or released ("input" events) with Dolphin's own device and input
// names, exactly as a GameCube pad profile needs them. Runs until "quit" or stdin closes.

#pragma once

namespace optparse
{
class Values;
}

namespace Sparking
{
int RunInputTest(const optparse::Values& options);
}
