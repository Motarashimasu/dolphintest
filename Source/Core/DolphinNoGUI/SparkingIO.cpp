// Copyright 2026 Dolphin-Sparking Project
// SPDX-License-Identifier: GPL-2.0-or-later

#include "DolphinNoGUI/SparkingIO.h"

#include <atomic>
#include <cstdio>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

#include <fmt/format.h>

#include "Core/Core.h"
#include "Core/System.h"

#ifdef _WIN32
#include <windows.h>
#else
#include <cerrno>
#include <unistd.h>
#endif

namespace Sparking
{
namespace
{
std::atomic<bool> s_enabled{false};
std::mutex s_emit_mutex;

std::string_view Trim(std::string_view s)
{
  while (!s.empty() && (s.front() == ' ' || s.front() == '\t'))
    s.remove_prefix(1);
  while (!s.empty() && (s.back() == ' ' || s.back() == '\t' || s.back() == '\r' || s.back() == '\n'))
    s.remove_suffix(1);
  return s;
}

// Reads stdin through the raw OS handle rather than std::cin/stdio. A thread blocked inside a
// stdio read holds the FILE lock for stdin, and Dolphin's shutdown path calls fflush(NULL), which
// takes every stream lock -- so a std::cin reader deadlocks process exit.
class RawLineReader
{
public:
  // Returns false on EOF or error.
  bool ReadLine(std::string* out)
  {
    while (true)
    {
      const size_t nl = m_buffer.find('\n');
      if (nl != std::string::npos)
      {
        *out = m_buffer.substr(0, nl);
        m_buffer.erase(0, nl + 1);
        return true;
      }

      char chunk[512];
#ifdef _WIN32
      DWORD n = 0;
      if (!ReadFile(GetStdHandle(STD_INPUT_HANDLE), chunk, sizeof(chunk), &n, nullptr) || n == 0)
        return FlushRemainder(out);
#else
      const ssize_t n = ::read(STDIN_FILENO, chunk, sizeof(chunk));
      if (n < 0 && errno == EINTR)
        continue;
      if (n <= 0)
        return FlushRemainder(out);
#endif
      m_buffer.append(chunk, static_cast<size_t>(n));
    }
  }

private:
  bool FlushRemainder(std::string* out)
  {
    if (m_buffer.empty())
      return false;
    *out = std::move(m_buffer);
    m_buffer.clear();
    return true;
  }

  std::string m_buffer;
};

Command ParseCommand(std::string_view line)
{
  line = Trim(line);
  Command cmd;
  const size_t space = line.find(' ');
  if (space == std::string_view::npos)
  {
    cmd.name = std::string(line);
  }
  else
  {
    cmd.name = std::string(line.substr(0, space));
    cmd.arg = std::string(Trim(line.substr(space + 1)));
  }
  return cmd;
}
}  // namespace

std::string Json::Escape(std::string_view s)
{
  std::string out;
  out.reserve(s.size() + 2);
  out.push_back('"');
  for (const char c : s)
  {
    switch (c)
    {
    case '"':
      out += "\\\"";
      break;
    case '\\':
      out += "\\\\";
      break;
    case '\n':
      out += "\\n";
      break;
    case '\r':
      out += "\\r";
      break;
    case '\t':
      out += "\\t";
      break;
    default:
      if (static_cast<unsigned char>(c) < 0x20)
        out += fmt::format("\\u{:04x}", static_cast<unsigned>(static_cast<unsigned char>(c)));
      else
        out.push_back(c);  // UTF-8 passes through untouched
    }
  }
  out.push_back('"');
  return out;
}

void Json::Key(std::string_view key)
{
  if (!m_body.empty())
    m_body.push_back(',');
  m_body += Escape(key);
  m_body.push_back(':');
}

Json& Json::Add(std::string_view key, std::string_view value)
{
  Key(key);
  m_body += Escape(value);
  return *this;
}

Json& Json::Add(std::string_view key, int64_t value)
{
  Key(key);
  m_body += std::to_string(value);
  return *this;
}

Json& Json::Add(std::string_view key, bool value)
{
  Key(key);
  m_body += value ? "true" : "false";
  return *this;
}

Json& Json::AddRaw(std::string_view key, std::string_view raw_json)
{
  Key(key);
  m_body += raw_json;
  return *this;
}

std::string JsonArray(const std::vector<std::string>& items)
{
  std::string out = "[";
  for (size_t i = 0; i < items.size(); ++i)
  {
    if (i)
      out.push_back(',');
    out += items[i];
  }
  out.push_back(']');
  return out;
}

void SetEnabled(bool enabled)
{
  s_enabled = enabled;
}

bool IsEnabled()
{
  return s_enabled;
}

void Emit(std::string_view event, const Json& fields)
{
  if (!s_enabled)
    return;

  // Put "event" first so frontends can cheaply switch on it.
  std::string body = fields.Str();
  std::string line = fmt::format("{}{{\"event\":{}{}{}\n", EVENT_PREFIX, Json::Escape(event),
                                 body.size() > 2 ? "," : "", body.substr(1));

  std::lock_guard lk(s_emit_mutex);
  std::fwrite(line.data(), 1, line.size(), stdout);
  std::fflush(stdout);
}

void StartCommandReader(std::function<void(const Command&)> handler)
{
  std::thread([handler = std::move(handler)] {
    RawLineReader reader;
    std::string line;
    bool attached = false;
    while (reader.ReadLine(&line))
    {
      Command cmd = ParseCommand(line);
      if (cmd.name.empty())
        continue;
      if (cmd.name == "hello")
      {
        // Handshake: from now on, stdin closing means the frontend went away.
        attached = true;
        Emit("hello", Json().Add("protocol", PROTOCOL_VERSION));
        continue;
      }
      Core::QueueHostJob([handler, cmd](Core::System&) { handler(cmd); },
                         /*run_during_stop=*/true);
    }
    // Only treat EOF as "quit" if a frontend actually attached; a process launched without a
    // stdin pipe sees EOF immediately and must keep running.
    if (attached)
      Core::QueueHostJob([handler](Core::System&) { handler(Command{"eof", ""}); }, true);
  }).detach();
}

}  // namespace Sparking
