// Copyright 2026 Dolphin-Sparking Project
// SPDX-License-Identifier: GPL-2.0-or-later

// Sparking HUD fix: the game draws its 2D HUD (life bars, portraits, ki gauges) for a 4:3
// screen. When the picture is shown wider (16:9), that 4:3 HUD is stretched with it: oval
// portraits, wide bars sitting inward. This pulls each HUD piece back to its true shape and pins
// it to its side of the screen, like a widescreen HUD:
//   - only flat 2D drawing (orthographic projection), only during a battle, only pieces inside
//     the HUD strips at the top (and optionally the bottom) of the screen;
//   - a piece entirely on the left half is narrowed by (game aspect / shown aspect) towards the
//     left edge, a piece on the right half towards the right edge; pieces crossing the middle
//     (the timer) are left alone;
//   - a "piece" is one connected primitive (a quad), so mirrored / shared textures and every
//     character's portrait are handled by where they're drawn, not by texture names.
// Visual only (vertex positions on their way to the GPU): it can't affect emulation or netplay.
// Set by the Sparking frontend; read on the video thread.

#pragma once

#include <atomic>

namespace SparkingHudFix
{
inline std::atomic<bool> enabled{false};
// A battle is on screen (the frontend's health watches are live): menus are never touched.
inline std::atomic<bool> in_battle{false};
// HUD strips, as a fraction of the screen height: from the top, and from the bottom (0 = none).
inline std::atomic<float> band_top{0.30f};
inline std::atomic<float> band_bottom{0.0f};
}  // namespace SparkingHudFix
