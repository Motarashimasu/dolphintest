// Copyright 2009 Dolphin Emulator Project
// SPDX-License-Identifier: GPL-2.0-or-later

#include "VideoCommon/HiresTextures.h"

#include <fmt/format.h>
#include <algorithm>
#include <atomic>
#include <cctype>
#include <memory>
#include <mutex>
#include <string>
#include <string_view>
#include <unordered_map>
#include <utility>
#include <xxhash.h>

#include "Common/CommonPaths.h"
#include "Common/FileSearch.h"
#include "Common/FileUtil.h"
#include "Common/Logging/Log.h"
#include "Common/StringUtil.h"
#include "Core/ConfigManager.h"
#include "Core/System.h"
#include "VideoCommon/Assets/DirectFilesystemAssetLibrary.h"
#include "VideoCommon/Assets/CustomAssetLibrary.h"
#include "VideoCommon/OnScreenDisplay.h"
#include "VideoCommon/Resources/CustomResourceManager.h"
#include "VideoCommon/VideoConfig.h"

constexpr std::string_view s_format_prefix{"tex1_"};

static std::unordered_map<std::string, std::shared_ptr<HiresTexture>> s_hires_texture_cache;
static std::unordered_map<std::string, bool> s_hires_texture_id_to_arbmipmap;
// Texture name -> file currently mapped for it (needed to re-map on a variant switch).
static std::unordered_map<std::string, std::string> s_hires_texture_id_to_path;

static std::mutex s_variant_mutex;
static std::map<std::string, std::string> s_variant_selection;  // lowercase group -> lowercase option
static std::atomic<bool> s_variant_change_pending{false};

static auto s_file_library = std::make_shared<VideoCommon::DirectFilesystemAssetLibrary>();

namespace
{
std::pair<std::string, bool> GetNameArbPair(const TextureInfo& texture_info)
{
  if (s_hires_texture_id_to_arbmipmap.empty())
    return {"", false};

  const auto texture_name_details = texture_info.CalculateTextureName();
  // look for an exact match first
  const std::string full_name = texture_name_details.GetFullName();
  if (auto iter = s_hires_texture_id_to_arbmipmap.find(full_name);
      iter != s_hires_texture_id_to_arbmipmap.end())
  {
    return {full_name, iter->second};
  }

  // Single wildcard ignoring the tlut hash
  const std::string texture_name_single_wildcard_tlut =
      fmt::format("{}_{}_$_{}", texture_name_details.base_name, texture_name_details.texture_name,
                  texture_name_details.format_name);
  if (auto iter = s_hires_texture_id_to_arbmipmap.find(texture_name_single_wildcard_tlut);
      iter != s_hires_texture_id_to_arbmipmap.end())
  {
    return {texture_name_single_wildcard_tlut, iter->second};
  }

  // Single wildcard ignoring the texture hash
  const std::string texture_name_single_wildcard_tex =
      fmt::format("{}_${}_{}", texture_name_details.base_name, texture_name_details.tlut_name,
                  texture_name_details.format_name);
  if (auto iter = s_hires_texture_id_to_arbmipmap.find(texture_name_single_wildcard_tex);
      iter != s_hires_texture_id_to_arbmipmap.end())
  {
    return {texture_name_single_wildcard_tex, iter->second};
  }

  return {"", false};
}
std::string Lower(std::string_view s)
{
  std::string out(s);
  for (char& c : out)
    c = static_cast<char>(std::tolower(static_cast<unsigned char>(c)));
  return out;
}

std::vector<std::string_view> SplitComponents(std::string_view relative)
{
  std::vector<std::string_view> parts;
  size_t start = 0;
  for (size_t i = 0; i <= relative.size(); ++i)
  {
    if (i == relative.size() || relative[i] == '/' || relative[i] == '\\')
    {
      if (i > start)
        parts.push_back(relative.substr(start, i - start));
      start = i + 1;
    }
  }
  return parts;
}

// Where a texture file sits relative to the @group folders.
struct VariantPlace
{
  std::string group;     // innermost "@Group" folder (lowercase), empty if none
  bool selected = true;  // every @group on the way is on its selected option
  bool stray = false;    // directly inside an "@Group" folder, not in an option: never loaded
};

// `relative`: the file path relative to the texture directory.
VariantPlace ClassifyVariantPath(std::string_view relative,
                                 const std::map<std::string, std::string>& selection)
{
  const auto parts = SplitComponents(relative);
  VariantPlace place;
  // The last component is the file name itself, so only directories are checked.
  for (size_t i = 0; i + 1 < parts.size(); ++i)
  {
    if (parts[i].empty() || parts[i][0] != '@')
      continue;
    place.group = Lower(parts[i].substr(1));
    if (i + 2 >= parts.size())
    {
      place.stray = true;
      return place;
    }
    const auto it = selection.find(place.group);
    if (it == selection.end() || it->second != Lower(parts[i + 1]))
      place.selected = false;
  }
  return place;
}

struct FoundTexture
{
  std::string path;
  bool has_arbitrary_mipmaps = false;
};

// Texture name -> file, for the current game and variant selection.
//
// A texture name that appears anywhere inside a group's options is OWNED by that group: it is
// only ever loaded from that group's selected option, never from the base pack or another group.
// If the selected option doesn't have it, the game's original is used. So e.g. switching
// @Graphics between Enhanced/Legacy can never change a texture that @Buttons owns.
// A name owned by several groups belongs to the smallest group (fewest textures; ties by name),
// i.e. the more specific one: @Buttons beats @Graphics even if the HD pack also has buttons.
std::map<std::string, FoundTexture>
ScanTextures(const std::set<std::string>& texture_directories,
             const std::map<std::string, std::string>& selection)
{
  constexpr auto extensions = std::to_array<std::string_view>({".png", ".dds"});

  struct Candidate
  {
    FoundTexture texture;
    VariantPlace place;
  };
  std::map<std::string, std::vector<Candidate>> candidates;  // name -> files, in search order
  std::map<std::string, std::set<std::string>> group_names;  // group -> names it owns

  for (const auto& texture_directory : texture_directories)
  {
    for (const auto& path : Common::DoFileSearch(texture_directory, extensions, /*recursive*/ true))
    {
      std::string filename;
      SplitPath(path, nullptr, &filename, nullptr);
      if (filename.substr(0, s_format_prefix.length()) != s_format_prefix)
        continue;
      const size_t arb_index = filename.rfind("_arb");
      const bool has_arbitrary_mipmaps = arb_index != std::string::npos;
      if (has_arbitrary_mipmaps)
        filename.erase(arb_index, 4);

      const std::string_view relative =
          std::string_view(path).substr(std::min(path.size(), texture_directory.size()));
      VariantPlace place = ClassifyVariantPath(relative, selection);
      if (place.stray)
        continue;
      if (!place.group.empty())
        group_names[place.group].insert(filename);
      candidates[filename].push_back({{path, has_arbitrary_mipmaps}, std::move(place)});
    }
  }

  std::map<std::string, FoundTexture> found;
  for (auto& [name, files] : candidates)
  {
    // Owner: the smallest group that has this name in any of its options.
    const std::string* owner = nullptr;
    for (const Candidate& c : files)
    {
      if (c.place.group.empty())
        continue;
      if (!owner)
      {
        owner = &c.place.group;
        continue;
      }
      const size_t size = group_names[c.place.group].size();
      const size_t owner_size = group_names[*owner].size();
      if (size < owner_size || (size == owner_size && c.place.group < *owner))
        owner = &c.place.group;
    }

    for (Candidate& c : files)
    {
      const bool eligible = owner ? (c.place.group == *owner && c.place.selected) :
                                    c.place.group.empty();
      if (eligible)
      {
        found.emplace(name, std::move(c.texture));  // first one in search order wins
        break;
      }
    }
  }
  return found;
}

std::set<std::string> CurrentTextureDirectories()
{
  return GetTextureDirectoriesForFirstMatchingGameId(
      File::GetUserPath(D_HIRESTEXTURES_IDX), SConfig::GetInstance().GetGameIDsForTextures());
}

std::map<std::string, std::string> CurrentSelection()
{
  std::lock_guard lk(s_variant_mutex);
  return s_variant_selection;
}

void MapTexture(const std::string& name, const FoundTexture& texture)
{
  s_hires_texture_id_to_arbmipmap[name] = texture.has_arbitrary_mipmaps;
  s_hires_texture_id_to_path[name] = texture.path;
  // Since this is just a texture (single file) the mapper doesn't really matter
  // just provide a string
  s_file_library->SetAssetIDMapData(
      name, std::map<std::string, std::filesystem::path>{{"texture", StringToPath(texture.path)}});
}
}  // namespace

void HiresTexture::SetVariantSelection(std::map<std::string, std::string> group_to_option)
{
  std::map<std::string, std::string> normalized;
  for (const auto& [group, option] : group_to_option)
    normalized[Lower(group)] = Lower(option);
  {
    std::lock_guard lk(s_variant_mutex);
    if (normalized == s_variant_selection)
      return;
    s_variant_selection = std::move(normalized);
  }
  s_variant_change_pending = true;
}

std::map<std::string, std::string> HiresTexture::GetVariantSelection()
{
  return CurrentSelection();
}

bool HiresTexture::ApplyPendingVariantChange()
{
  if (!s_variant_change_pending.exchange(false))
    return false;
  if (!g_ActiveConfig.bHiresTextures)
    return false;  // picked up by the next Update()

  const auto found = ScanTextures(CurrentTextureDirectories(), CurrentSelection());
  auto& resource_manager = Core::System::GetInstance().GetCustomResourceManager();

  // Textures that no longer have a replacement fall back to the game's own.
  std::vector<std::string> removed;
  for (const auto& [name, path] : s_hires_texture_id_to_path)
  {
    if (!found.contains(name))
      removed.push_back(name);
  }
  for (const std::string& name : removed)
  {
    s_hires_texture_id_to_arbmipmap.erase(name);
    s_hires_texture_id_to_path.erase(name);
    s_hires_texture_cache.erase(name);
    s_file_library->SetAssetIDMapData(name, {});
  }

  // New or re-pointed textures: remap, and make any already-loaded copy reload from the new file.
  for (const auto& [name, texture] : found)
  {
    const auto it = s_hires_texture_id_to_path.find(name);
    if (it != s_hires_texture_id_to_path.end() && it->second == texture.path)
      continue;
    MapTexture(name, texture);
    resource_manager.MarkAssetDirty(name);
    s_hires_texture_cache.erase(name);
    if (g_ActiveConfig.bCacheHiresTextures)
    {
      auto hires_texture = std::make_shared<HiresTexture>(texture.has_arbitrary_mipmaps, name);
      static_cast<void>(hires_texture->LoadTexture());
      s_hires_texture_cache.try_emplace(name, std::move(hires_texture));
    }
  }
  return true;
}

std::string HiresTexture::GetMappedPath(const std::string& texture_name)
{
  const auto it = s_hires_texture_id_to_path.find(texture_name);
  return it == s_hires_texture_id_to_path.end() ? std::string() : it->second;
}

std::map<std::string, std::set<std::string>>
HiresTexture::ListVariantGroups(const std::string& game_id)
{
  std::map<std::string, std::set<std::string>> groups;
  const std::set<std::string> directories =
      GetTextureDirectoriesWithGameId(File::GetUserPath(D_HIRESTEXTURES_IDX), game_id);
  for (const auto& directory : directories)
  {
    const File::FSTEntry tree = File::ScanDirectoryTree(directory, /*recursive*/ true);
    // Depth-first over directories; "@Group" folders' child folders are its options.
    std::vector<const File::FSTEntry*> stack{&tree};
    while (!stack.empty())
    {
      const File::FSTEntry* entry = stack.back();
      stack.pop_back();
      for (const File::FSTEntry& child : entry->children)
      {
        if (!child.isDirectory)
          continue;
        if (!child.virtualName.empty() && child.virtualName[0] == '@')
        {
          auto& options = groups[child.virtualName.substr(1)];
          for (const File::FSTEntry& option : child.children)
          {
            if (option.isDirectory)
              options.insert(option.virtualName);
          }
        }
        stack.push_back(&child);
      }
    }
  }
  return groups;
}

void HiresTexture::Shutdown()
{
  Clear();
}

void HiresTexture::Update()
{
  if (!g_ActiveConfig.bHiresTextures)
  {
    Clear();
    return;
  }

  const std::set<std::string> texture_directories = CurrentTextureDirectories();

  // Watch these directories for any texture reloads
  for (const auto& texture_directory : texture_directories)
    s_file_library->Watch(texture_directory);

  s_variant_change_pending = false;  // this scan already uses the current selection
  for (const auto& [name, texture] : ScanTextures(texture_directories, CurrentSelection()))
  {
    if (s_hires_texture_id_to_arbmipmap.contains(name))
      continue;
    MapTexture(name, texture);

    if (g_ActiveConfig.bCacheHiresTextures)
    {
      auto hires_texture = std::make_shared<HiresTexture>(texture.has_arbitrary_mipmaps, name);
      static_cast<void>(hires_texture->LoadTexture());
      s_hires_texture_cache.try_emplace(hires_texture->GetId(), hires_texture);
    }
  }

  const std::vector<std::string> game_ids_for_textures =
      SConfig::GetInstance().GetGameIDsForTextures();
  const std::string game_id_display = fmt::format("{}", fmt::join(game_ids_for_textures, "' or '"));

  std::string message;
  if (g_ActiveConfig.bCacheHiresTextures)
  {
    message = fmt::format("Preloading '{}' custom textures for '{}'", s_hires_texture_cache.size(),
                          game_id_display);
  }
  else
  {
    message = fmt::format("Found '{}' custom textures for '{}'",
                          s_hires_texture_id_to_arbmipmap.size(), game_id_display);
  }
  OSD::AddMessage(message, 10000);
}

void HiresTexture::Clear()
{
  s_hires_texture_cache.clear();
  s_hires_texture_id_to_arbmipmap.clear();
  s_hires_texture_id_to_path.clear();
  s_file_library = std::make_shared<VideoCommon::DirectFilesystemAssetLibrary>();
}

std::shared_ptr<HiresTexture> HiresTexture::Search(const TextureInfo& texture_info)
{
  auto [base_filename, has_arb_mipmaps] = GetNameArbPair(texture_info);
  if (base_filename == "")
    return nullptr;

  if (auto iter = s_hires_texture_cache.find(base_filename); iter != s_hires_texture_cache.end())
  {
    return iter->second;
  }
  else
  {
    auto hires_texture = std::make_shared<HiresTexture>(has_arb_mipmaps, std::move(base_filename));
    if (g_ActiveConfig.bCacheHiresTextures)
    {
      s_hires_texture_cache.try_emplace(hires_texture->GetId(), hires_texture);
    }
    return hires_texture;
  }
}

HiresTexture::HiresTexture(bool has_arbitrary_mipmaps, std::string id)
    : m_has_arbitrary_mipmaps(has_arbitrary_mipmaps), m_id(std::move(id))
{
}

VideoCommon::TextureDataResource* HiresTexture::LoadTexture() const
{
  auto& system = Core::System::GetInstance();
  auto& custom_resource_manager = system.GetCustomResourceManager();
  return custom_resource_manager.GetTextureDataFromAsset(m_id, s_file_library);
}

std::set<std::string> GetTextureDirectoriesWithGameId(const std::string& root_directory,
                                                      const std::string& game_id)
{
  std::set<std::string> result;
  const std::string texture_directory = root_directory + game_id;

  if (File::Exists(texture_directory))
  {
    result.insert(texture_directory);
  }
  else
  {
    // If there's no directory with the region-specific ID, look for a 3-character region-free one
    const std::string region_free_directory = root_directory + game_id.substr(0, 3);

    if (File::Exists(region_free_directory))
    {
      result.insert(region_free_directory);
    }
  }

  const auto match_gameid_or_all = [game_id](const std::string& filename) {
    std::string basename;
    SplitPath(filename, nullptr, &basename, nullptr);
    return basename == game_id || basename == game_id.substr(0, 3) || basename == "all";
  };

  // Look for any other directories that might be specific to the given gameid
  const auto files = Common::DoFileSearch(root_directory, ".txt", true);
  for (const auto& file : files)
  {
    if (match_gameid_or_all(file))
    {
      // The following code is used to calculate the top directory
      // of a found gameid.txt file
      // ex:  <root directory>/My folder/gameids/<gameid>.txt
      // would insert "<root directory>/My folder"
      const auto directory_path = file.substr(root_directory.size());
      const std::size_t first_path_separator_position = directory_path.find_first_of(DIR_SEP_CHR);
      result.insert(root_directory + directory_path.substr(0, first_path_separator_position));
    }
  }

  return result;
}

std::set<std::string>
GetTextureDirectoriesForFirstMatchingGameId(const std::string& root_directory,
                                            const std::vector<std::string>& game_ids)
{
  for (const auto& game_id : game_ids)
  {
    auto directories = GetTextureDirectoriesWithGameId(root_directory, game_id);
    if (!directories.empty())
      return directories;
  }
  return {};
}
