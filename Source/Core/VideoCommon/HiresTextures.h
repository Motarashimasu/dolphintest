// Copyright 2008 Dolphin Emulator Project
// SPDX-License-Identifier: GPL-2.0-or-later

#pragma once

#include <fmt/ranges.h>
#include <map>
#include <memory>
#include <set>
#include <string>
#include <vector>

#include "VideoCommon/TextureInfo.h"

namespace VideoCommon
{
class TextureDataResource;
}

enum class TextureFormat;

std::set<std::string> GetTextureDirectoriesWithGameId(const std::string& root_directory,
                                                      const std::string& game_id);

// Tries each id in priority order, returning the directories for the first id that matches
// anything. Returns an empty set if none of the ids match.
std::set<std::string>
GetTextureDirectoriesForFirstMatchingGameId(const std::string& root_directory,
                                            const std::vector<std::string>& game_ids);

class HiresTexture
{
public:
  static void Update();
  static void Clear();
  static void Shutdown();
  static std::shared_ptr<HiresTexture> Search(const TextureInfo& texture_info);

  // Switchable texture variants (Dolphin-Sparking). Inside a game's texture folder, any folder
  // named "@<Group>" is a variant group and each of its subfolders is one option, e.g.
  //   Load/Textures/RDSPAF/@Buttons/PlayStation/..., .../@Buttons/Xbox/...
  // Only the selected option of each group is loaded, and its textures take priority over
  // same-named textures anywhere else in the pack. Unselected options are ignored; a group with
  // no selection (or a selection with no folder, e.g. "Vanilla") loads none of its options.
  // Group and option names are matched case-insensitively.
  static void SetVariantSelection(std::map<std::string, std::string> group_to_option);
  static std::map<std::string, std::string> GetVariantSelection();
  // Video thread, once per frame: applies a selection changed while the game runs. Returns true
  // if the texture cache must be invalidated.
  static bool ApplyPendingVariantChange();
  // Debug: the file currently mapped for a texture name ("" if none).
  static std::string GetMappedPath(const std::string& texture_name);
  // Group -> options found in the texture folders for `game_id`.
  static std::map<std::string, std::set<std::string>>
  ListVariantGroups(const std::string& game_id);

  HiresTexture(bool has_arbitrary_mipmaps, std::string id);

  bool HasArbitraryMipmaps() const { return m_has_arbitrary_mipmaps; }
  VideoCommon::TextureDataResource* LoadTexture() const;
  const std::string& GetId() const { return m_id; }

private:
  bool m_has_arbitrary_mipmaps = false;
  std::string m_id;
};
