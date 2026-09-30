// Copyright 2026 Dolphin-Sparking Project
// SPDX-License-Identifier: GPL-2.0-or-later

// Machine-readable I/O channel between dolphin-emu-nogui and an external frontend (the
// Sparking Godot app).
//
//  * Events go to stdout, one per line:   [SPARKING] {"event":"players","players":[...]}
//  * Commands come from stdin, one per line, plain text:   start | chat hello | stop | ...
//
// Anything else Dolphin prints to stdout is ignored by the frontend because it lacks the prefix.

#pragma once

#include <cstdint>
#include <functional>
#include <string>
#include <string_view>
#include <vector>

namespace Sparking
{
constexpr std::string_view EVENT_PREFIX = "[SPARKING] ";
constexpr int PROTOCOL_VERSION = 1;

// Tiny JSON object builder. Values are escaped; nested objects/arrays can be added raw.
class Json
{
public:
  Json& Add(std::string_view key, std::string_view value);
  Json& Add(std::string_view key, const char* value) { return Add(key, std::string_view(value)); }
  Json& Add(std::string_view key, const std::string& value)
  {
    return Add(key, std::string_view(value));
  }
  Json& Add(std::string_view key, int64_t value);
  Json& Add(std::string_view key, int value) { return Add(key, static_cast<int64_t>(value)); }
  Json& Add(std::string_view key, unsigned value) { return Add(key, static_cast<int64_t>(value)); }
  Json& Add(std::string_view key, bool value);
  // `raw_json` must already be valid JSON (an object or array built elsewhere).
  Json& AddRaw(std::string_view key, std::string_view raw_json);

  std::string Str() const { return "{" + m_body + "}"; }

  static std::string Escape(std::string_view s);

private:
  void Key(std::string_view key);
  std::string m_body;
};

// Joins already-serialised JSON values into an array.
std::string JsonArray(const std::vector<std::string>& items);

void SetEnabled(bool enabled);
bool IsEnabled();

// Thread-safe. No-op unless enabled.
void Emit(std::string_view event, const Json& fields = {});

// A parsed command line: "chat hello there" -> {name: "chat", arg: "hello there"}.
struct Command
{
  std::string name;
  std::string arg;
};

// Starts a detached thread reading stdin. Each non-empty line is parsed and delivered to
// `handler` ON THE HOST THREAD (via Core::QueueHostJob), so handlers may touch Core/NetPlay
// objects the same way the Qt UI thread does.
// "hello" is answered directly with a "hello" event and marks the frontend as attached; after
// that, EOF on stdin (frontend exited/crashed) delivers a synthetic "eof" command.
void StartCommandReader(std::function<void(const Command&)> handler);

}  // namespace Sparking
