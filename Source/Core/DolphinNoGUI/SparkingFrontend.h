// Copyright 2026 Dolphin-Sparking Project
// SPDX-License-Identifier: GPL-2.0-or-later

// Glue between MainNoGUI.cpp and the Sparking subsystem. Keeps the upstream entry point's diff
// down to a handful of hook calls so merging upstream Dolphin stays painless.

#pragma once

#include <functional>
#include <memory>

class Platform;

namespace optparse
{
class OptionParser;
class Values;
}  // namespace optparse

namespace Sparking
{
struct FrontendHooks
{
  // MainNoGUI's s_platform. Null while sitting in a netplay lobby (no window).
  std::unique_ptr<Platform>& platform;
  std::function<std::unique_ptr<Platform>()> create_platform;
  std::function<void()> install_signal_handlers;
};

void AddCommandLineOptions(optparse::OptionParser& parser);

// Enables the event channel if requested and emits "ready". Call right after parsing.
void InitFromOptions(const optparse::Values& options);

bool IsNetPlayMode(const optparse::Values& options);

// Runs a whole netplay session: lobby -> (boot game -> window -> game ends)* -> exit code.
int RunNetPlay(const optparse::Values& options, const FrontendHooks& hooks);

// Solo mode: accept in-game commands on stdin (no-op unless --sparking).
void StartSoloCommandReader(std::unique_ptr<Platform>& platform);

// Set by SIGINT/SIGTERM when there is no platform to forward the request to.
void RequestQuit();

}  // namespace Sparking
