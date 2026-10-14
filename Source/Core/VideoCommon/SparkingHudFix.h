// Copyright 2026 Dolphin-Sparking Project
// SPDX-License-Identifier: GPL-2.0-or-later

// Sparking HUD fix: the game draws its HUD (life bars, portraits, ki gauges) for a 4:3 screen.
// When the picture is shown wider (16:9), that 4:3 HUD is stretched with it: oval portraits,
// wide bars reaching in to the timer. This pulls the HUD back to its true shape, pinned to its
// side of the screen, like a widescreen HUD:
//   - HUD draws are found by their textures (the life-bar frame, fill and gauge textures,
//     listed in the game ini's [Sparking.HudFix] Textures), never by screen position alone, so
//     the 3D scene is never touched;
//   - anything else drawn inside the area those textures covered (the portraits, the
//     ki-bar numbers) moves with them;
//   - a piece (one quad) entirely on the left half is narrowed by (game aspect / shown aspect)
//     towards the left edge, one on the right half towards the right edge; pieces crossing the
//     middle (the timer) are left alone.
// Visual only (vertex positions on their way to the GPU): it can't affect emulation or netplay.
// Set by the Sparking frontend; read on the video thread.

#pragma once

#include <atomic>
#include <mutex>
#include <string>
#include <vector>

#include "Common/CommonTypes.h"

namespace SparkingHudFix
{
inline std::atomic<bool> enabled{false};

// HUD textures, by the texture hash in their custom-texture name
// (tex1_256x64_<hash>_..._9: the <hash> part). Bumping the generation re-checks every texture.
inline std::mutex textures_mutex;
inline std::vector<std::string> textures;
inline std::atomic<u32> textures_generation{1};

inline void SetTextures(std::vector<std::string> hashes)
{
  std::lock_guard lock(textures_mutex);
  textures = std::move(hashes);
  textures_generation.fetch_add(1);
}

// Is this texture name (TextureInfo::CalculateTextureName().GetFullName()) one of the HUD's?
inline bool IsHudTexture(const std::string& name)
{
  if (name.empty())
    return false;
  std::lock_guard lock(textures_mutex);
  for (const std::string& hash : textures)
  {
    if (!hash.empty() && name.find("_" + hash + "_") != std::string::npos)
      return true;
  }
  return false;
}
}  // namespace SparkingHudFix
