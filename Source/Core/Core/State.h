// Copyright 2008 Dolphin Emulator Project
// SPDX-License-Identifier: GPL-2.0-or-later

// Emulator state saving support.

#pragma once

#include <cstddef>
#include <functional>
#include <span>
#include <string>
#include <type_traits>

#include "Common/Buffer.h"
#include "Common/CommonTypes.h"

namespace Core
{
class System;
}

namespace State
{
// number of states
static const u32 NUM_STATES = 10;

struct StateHeaderLegacy
{
  char game_id[6];
  char reserved1[2];
  u32 lzo_size = 0;  // Must be zero for new states. Used to support legacy decompression algorithm.
  char reserved2[4];
  double time;
};
constexpr size_t STATE_HEADER_SIZE = sizeof(StateHeaderLegacy);
static_assert(STATE_HEADER_SIZE == 24);
static_assert(offsetof(StateHeaderLegacy, lzo_size) == 8);
static_assert(offsetof(StateHeaderLegacy, time) == 16);
static_assert(std::is_trivially_copyable_v<StateHeaderLegacy>);

struct StateHeaderVersion
{
  u32 version_cookie;
  u32 version_string_length;
};
static_assert(std::is_trivially_copyable_v<StateHeaderVersion>);

struct StateHeader
{
  StateHeaderLegacy legacy_header;
  StateHeaderVersion version_header;
  std::string version_string;
};

enum CompressionType : u16
{
  Uncompressed = 0,
  LZ4 = 1,
  // Add new compression types after this, as the compression type
  // is numerically stored in the state file.
};

struct StateExtendedBaseHeader
{
  u16 header_version;
  u16 compression_type;
  u32 payload_offset;
  u64 uncompressed_size;
};
constexpr size_t EXTENDED_BASE_HEADER_SIZE = sizeof(StateExtendedBaseHeader);
static_assert(EXTENDED_BASE_HEADER_SIZE == 16);
static_assert(offsetof(StateExtendedBaseHeader, payload_offset) == 4);
static_assert(offsetof(StateExtendedBaseHeader, uncompressed_size) == 8);
static_assert(std::is_trivially_copyable_v<StateExtendedBaseHeader>);

struct StateExtendedHeader
{
  StateExtendedBaseHeader base_header;
  // Feel free to add new fields here, adjusting COMPRESSED_DATA_OFFSET accordingly, as well as
  // CreateExtendedHeader(). Add the appropriate IOFile read/write calls within LoadFileStateData()
  // and WriteHeadersToFile()
};

void Init(Core::System& system);
void Shutdown();

// Returns a string containing information of the savestate in the given slot
// which can be presented to the user for identification purposes
std::string GetInfoStringOfSlot(u32 slot, bool translate = true);

// Returns when the savestate in the given slot was created, or 0 if the slot is empty.
u64 GetUnixTimeOfSlot(u32 slot);

// These don't happen instantly - they get scheduled as events.
// ...But only if we're not in the main CPU thread.
//    If we're in the main CPU thread then they run immediately instead.
void Save(Core::System& system, u32 slot);
void Load(Core::System& system, u32 slot);

void SaveAs(Core::System& system, std::string filename);
void LoadAs(Core::System& system, std::string filename);

// Dolphin-Sparking: permits exactly one state load while NetPlay is running -- the boot-time load
// of a state file every peer has verified to be byte-identical, so all peers start in sync.
// The permission is consumed by the next load attempt, whether or not it succeeds.
void AllowNextNetPlayBootLoad();
// Dolphin-Sparking: whether the most recent LoadAs/Load actually restored a state. Valid inside
// the after-load callback, which upstream invokes on failure too.
bool LastLoadSucceeded();

// Dolphin-Sparking (rollback test): the whole emulated state to / from memory, no files. CPU
// thread with the CPU stopped (a CPU-thread job), like the slot saves. Save returns the size
// (0 = failed); the buffer grows as needed.
// `skip_ram`: without MEM1 / MEM2 (the rollback test keeps those with
// MemoryManager::SparkingSnapshot); a state saved that way must be loaded that way.
// `gpu_caches` false: never the texture cache / EFB contents, whatever "Save Texture Cache to
// State" says (NEOcode saves every field: reading them back from the graphics card each time costs
// more the higher the resolution). Loading such a state starts the texture cache over.
std::size_t SaveToMemory(Core::System& system, Common::UniqueBuffer<u8>& buffer,
                         bool skip_ram = false, bool gpu_caches = true);
bool LoadFromMemory(Core::System& system, std::span<u8> buffer, bool skip_ram = false,
                    bool gpu_caches = true);
// Inside SaveToMemory / LoadFromMemory with skip_ram: a rollback state, kept in memory only, so
// parts can use a faster format (the IOS file system skips an unchanged /tmp).
bool IsRollbackState();
// "Save Texture Cache to State", unless the state being saved is one without the GPU caches.
bool SavesGpuCaches();

void LoadLastSaved(Core::System& system, int i = 1);
void SaveFirstSaved(Core::System& system);
void UndoSaveState(Core::System& system);
void UndoLoadState(Core::System& system);

// for calling back into UI code without introducing a dependency on it in core
using AfterLoadCallbackFunc = std::function<void()>;
void SetOnAfterLoadCallback(AfterLoadCallbackFunc callback);
}  // namespace State
