// Copyright 2026 Dolphin-Sparking Project
// SPDX-License-Identifier: GPL-2.0-or-later

// What kind of network link this PC uses to reach the internet, from the OS's adapter list:
// the adapter that carries the default route (Windows: GetBestInterfaceEx + GetAdaptersAddresses;
// Linux: /proc/net/route + /sys/class/net). Only this PC's own adapter is visible: a cable into a
// Wi-Fi extender/powerline/mesh node reads as "wired".

#pragma once

#include <string>

namespace Sparking
{
// "wired", "wireless", "virtual" (VPN / tunnel / virtual adapter: real link unknown) or "unknown".
std::string DetectLinkType();
}  // namespace Sparking
