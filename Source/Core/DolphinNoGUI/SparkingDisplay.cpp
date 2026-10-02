// Copyright 2026 Dolphin-Sparking Project
// SPDX-License-Identifier: GPL-2.0-or-later

#include "DolphinNoGUI/SparkingDisplay.h"

#include <algorithm>
#include <array>
#include <atomic>
#include <chrono>
#include <mutex>
#include <optional>
#include <thread>
#include <utility>

#include "Common/CommonFuncs.h"
#include "Common/Config/Config.h"
#include "Common/IOFile.h"
#include "Common/IniFile.h"
#include "Common/Swap.h"
#include "Core/Config/GraphicsSettings.h"
#include "Core/ConfigManager.h"
#include "Core/Core.h"
#include "Core/GeckoCode.h"
#include "Core/GeckoCodeConfig.h"
#include "Core/PowerPC/MMU.h"
#include "Core/System.h"
#include "DiscIO/DiscUtils.h"
#include "DiscIO/Volume.h"
#include "DolphinNoGUI/SparkingIO.h"
#include "VideoCommon/VideoConfig.h"

#ifdef _WIN32
#include <windows.h>
#endif

namespace Sparking
{
namespace
{
struct Session
{
  std::string game_id;
  u16 revision = 0;
  std::vector<std::string> names;  // every code this boot wants, incl. the widescreen one
  std::string widescreen_code;     // empty: game has no [Sparking] WidescreenCode
  std::vector<std::pair<u32, u32>> originals;  // (address, original value) for 4:3 restore
  size_t widescreen_writes = 0;                // 32-bit writes in the widescreen code
};

std::mutex s_mutex;
Session s_session;
std::atomic<bool> s_wide{true};

std::string ReadWidescreenCodeName(const std::string& game_id, u16 revision)
{
  std::string name;
  for (const Common::IniFile& ini : {SConfig::LoadLocalGameIni(game_id, revision),
                                     SConfig::LoadDefaultGameIni(game_id, revision)})
  {
    const Common::IniFile::Section* section = ini.GetSection("Sparking");
    if (section && section->Get("WidescreenCode", &name) && !name.empty())
      return name;
  }
  return {};
}

// Gecko 04/05 lines ("write 32 bits") of the named code: the addresses it patches.
std::vector<u32> WidescreenWriteAddresses(const std::string& game_id, u16 revision,
                                          const std::string& code_name)
{
  std::vector<u32> addresses;
  const auto codes = Gecko::LoadCodes(SConfig::LoadDefaultGameIni(game_id, revision),
                                      SConfig::LoadLocalGameIni(game_id, revision));
  const auto it = std::ranges::find_if(codes, [&](const auto& c) { return c.name == code_name; });
  if (it == codes.end())
    return addresses;
  for (const Gecko::GeckoCode::Code& line : it->codes)
  {
    const u32 type = line.address >> 24;
    if (type == 0x04 || type == 0x05)  // 32-bit write, ba / ba+0x01000000
      addresses.push_back(0x80000000u | (line.address & 0x01FFFFFFu));
  }
  return addresses;
}

// Looks up `addresses` in a DOL image, given a reader for it. 18 sections: file offsets at
// header[0..17], load addresses at [18..35], sizes at [36..53]. Addresses outside the DOL (e.g. in
// RELs or heap) are skipped.
template <typename ReadFn>
std::vector<std::pair<u32, u32>> ReadFromDol(const std::vector<u32>& addresses, ReadFn read)
{
  std::vector<std::pair<u32, u32>> out;
  std::array<u32, 0x100 / 4> header{};
  if (!read(0, sizeof(header), reinterpret_cast<u8*>(header.data())))
    return out;
  for (u32& v : header)
    v = Common::swap32(v);
  for (const u32 address : addresses)
  {
    for (int s = 0; s < 18; ++s)
    {
      const u32 file_offset = header[s], load = header[18 + s], size = header[36 + s];
      if (size == 0 || address < load || address + 4 > load + size)
        continue;
      u32 value = 0;
      if (read(file_offset + (address - load), 4, reinterpret_cast<u8*>(&value)))
        out.emplace_back(address, Common::swap32(value));
      break;
    }
  }
  return out;
}

// The game's own values at `addresses` (what the code overwrites), from the main DOL of the disc
// image, or from the file itself when booting a bare .dol.
std::vector<std::pair<u32, u32>> ReadOriginalsFromDisc(const std::string& path,
                                                       const std::vector<u32>& addresses)
{
  if (const std::unique_ptr<DiscIO::Volume> volume = DiscIO::CreateVolume(path))
  {
    const DiscIO::Partition partition = volume->GetGamePartition();
    const std::optional<u64> dol = DiscIO::GetBootDOLOffset(*volume, partition);
    if (!dol)
      return {};
    return ReadFromDol(addresses, [&](u64 offset, u64 length, u8* buffer) {
      return volume->Read(*dol + offset, length, buffer, partition);
    });
  }
  if (!path.ends_with(".dol") && !path.ends_with(".DOL"))
    return {};
  File::IOFile file(path, "rb");
  return ReadFromDol(addresses, [&](u64 offset, u64 length, u8* buffer) {
    return file.Seek(static_cast<s64>(offset), File::SeekOrigin::Begin) &&
           file.ReadBytes(buffer, length);
  });
}

std::vector<std::string> NamesForAspect(const Session& s, bool wide)
{
  std::vector<std::string> names = s.names;
  if (!wide && !s.widescreen_code.empty())
    std::erase(names, s.widescreen_code);
  return names;
}

void ApplyOutputAspect(bool wide)
{
  Config::SetCurrent(Config::GFX_ASPECT_RATIO,
                     wide ? AspectMode::ForceWide : AspectMode::ForceStandard);
}

void EmitAspect(const Session& s, bool wide, bool live)
{
  Json json;
  if (live)  // codes the game is running now (only meaningful once it has booted)
    json.Add("gecko_active_count", static_cast<int64_t>(Gecko::CountEnabledCodes()));
  Emit("aspect", json
                     .Add("mode", wide ? "16:9" : "4:3")
                     .Add("widescreen_code", s.widescreen_code)
                     .Add("restorable", static_cast<int64_t>(s.originals.size()))
                     .Add("code_writes", static_cast<int64_t>(s.widescreen_writes)));
}
}  // namespace

void SetDefaultWidescreen(bool wide)
{
  s_wide = wide;
}

std::vector<std::string> PrepareAspectForBoot(const std::string& game_path,
                                              const std::string& game_id, u16 revision,
                                              std::vector<std::string> names)
{
  std::lock_guard lk(s_mutex);
  s_session = Session{};
  s_session.game_id = game_id;
  s_session.revision = revision;
  s_session.names = std::move(names);
  s_session.widescreen_code = ReadWidescreenCodeName(game_id, revision);
  if (!s_session.widescreen_code.empty())
  {
    const std::vector<u32> addresses =
        WidescreenWriteAddresses(game_id, revision, s_session.widescreen_code);
    s_session.widescreen_writes = addresses.size();
    s_session.originals = ReadOriginalsFromDisc(game_path, addresses);
  }

  const bool wide = s_wide;
  ApplyOutputAspect(wide);
  EmitAspect(s_session, wide, false);
  return NamesForAspect(s_session, wide);
}

void SetWidescreen(bool wide)
{
  s_wide = wide;
  auto& system = Core::System::GetInstance();
  ApplyOutputAspect(wide);

  std::lock_guard lk(s_mutex);
  const Session& s = s_session;
  if (Core::IsRunning(system) && !s.widescreen_code.empty() && !s.game_id.empty())
  {
    // Swap the active code list (the code handler reinstalls it on its next run)...
    std::vector<Gecko::GeckoCode> codes;
    const auto all = Gecko::LoadCodes(SConfig::LoadDefaultGameIni(s.game_id, s.revision),
                                      SConfig::LoadLocalGameIni(s.game_id, s.revision));
    for (const std::string& name : NamesForAspect(s, wide))
    {
      const auto it = std::ranges::find_if(all, [&](const auto& c) { return c.name == name; });
      if (it != all.end())
      {
        Gecko::GeckoCode code = *it;
        code.enabled = true;
        codes.push_back(std::move(code));
      }
    }
    Gecko::SetActiveCodes(codes, s.game_id, s.revision);

    // ...and for 4:3 undo what the widescreen code already wrote.
    if (!wide && !s.originals.empty())
    {
      Core::RunOnCPUThread(system, [&system, originals = s.originals] {
        Core::CPUThreadGuard guard(system);
        for (const auto& [address, value] : originals)
          PowerPC::MMU::HostWrite<u32>(guard, value, address);
      });
    }
  }
  EmitAspect(s, wide, Core::IsRunning(system));
}

void ToggleWidescreen()
{
  SetWidescreen(!s_wide);
}

void StartAspectHotkey()
{
#ifdef _WIN32
  std::thread([] {
    bool was_down = false;
    while (true)
    {
      std::this_thread::sleep_for(std::chrono::milliseconds(30));
      const bool down = (GetAsyncKeyState(VK_F5) & 0x8000) != 0;
      if (down && !was_down)
      {
        // Only when the focused window is ours (the game window), not Godot or anything else.
        DWORD pid = 0;
        GetWindowThreadProcessId(GetForegroundWindow(), &pid);
        if (pid == GetCurrentProcessId())
          Core::QueueHostJob([](Core::System&) { ToggleWidescreen(); });
      }
      was_down = down;
    }
  }).detach();
#endif
}

}  // namespace Sparking
