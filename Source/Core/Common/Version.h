// Copyright 2017 Dolphin Emulator Project
// SPDX-License-Identifier: GPL-2.0-or-later

#pragma once

#include <string>

namespace Common
{
const std::string& GetEmulatorName();
const std::string& GetScmDescStr();
// Dolphin-Sparking: what netplay compares (the connection handshake and the lobby list), instead
// of the git revision. Builds of the same Sparking release can play together whatever machine
// built them (Windows on the developer's PC, Linux on GitHub Actions: different git strings).
// Bump SPARKING_NETPLAY_VERSION (Version.cpp) when a change makes older builds unable to play
// with newer ones (netplay messages, emulation that changes the game's results, NEOcode).
const std::string& GetNetPlayVersionStr();
const std::string& GetScmBranchStr();
const std::string& GetScmRevStr();
const std::string& GetScmRevGitStr();
const std::string& GetUserAgentStr();
const std::string& GetScmDistributorStr();
const std::string& GetScmUpdateTrackStr();
const std::string& GetNetplayDolphinVer();
int GetScmCommitsAheadMaster();
}  // namespace Common
