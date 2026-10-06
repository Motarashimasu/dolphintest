// Copyright 2026 Dolphin-Sparking Project
// SPDX-License-Identifier: GPL-2.0-or-later

#include "DolphinNoGUI/SparkingDiscord.h"

#include <OptionParser.h>
#include <atomic>
#include <chrono>
#include <cstdint>
#include <deque>
#include <mutex>
#include <optional>
#include <string>
#include <thread>

#include <picojson.h>

#ifdef USE_DISCORD_PRESENCE
#include <discord_rpc.h>
#endif

#include "DolphinNoGUI/SparkingIO.h"

namespace Sparking
{
#ifdef USE_DISCORD_PRESENCE
namespace
{
// Strings kept alive for discord-rpc, which only copies them when the presence is sent.
struct Presence
{
  std::string details, state, large_image, large_text, small_image, small_text, party_id,
      join_secret, match_secret;
  int64_t start = 0, end = 0;
  int party_size = 0, party_max = 0;
};

std::string Str(const picojson::object& o, const char* key, size_t max)
{
  const auto it = o.find(key);
  if (it == o.end() || !it->second.is<std::string>())
    return {};
  std::string s = it->second.get<std::string>();
  if (s.size() > max)
  {
    s.resize(max);
    // Don't leave half a UTF-8 character at the end.
    while (!s.empty() && (static_cast<unsigned char>(s.back()) & 0xC0) == 0x80)
      s.pop_back();
    if (!s.empty() && static_cast<unsigned char>(s.back()) >= 0xC0)
      s.pop_back();
  }
  return s;
}

int64_t Num(const picojson::object& o, const char* key)
{
  const auto it = o.find(key);
  return it != o.end() && it->second.is<double>() ? static_cast<int64_t>(it->second.get<double>()) :
                                                    0;
}

std::optional<Presence> ParsePresence(const std::string& text)
{
  picojson::value v;
  const std::string err = picojson::parse(v, text);
  if (!err.empty() || !v.is<picojson::object>())
    return std::nullopt;
  const auto& o = v.get<picojson::object>();
  Presence p;
  p.details = Str(o, "details", 127);
  p.state = Str(o, "state", 127);
  p.large_image = Str(o, "large_image", 255);  // asset key, or an https:// image URL
  p.large_text = Str(o, "large_text", 127);
  p.small_image = Str(o, "small_image", 255);
  p.small_text = Str(o, "small_text", 127);
  p.party_id = Str(o, "party_id", 127);
  p.join_secret = Str(o, "join_secret", 127);
  p.match_secret = Str(o, "match_secret", 127);
  p.start = Num(o, "start");
  p.end = Num(o, "end");
  p.party_size = static_cast<int>(Num(o, "party_size"));
  p.party_max = static_cast<int>(Num(o, "party_max"));
  return p;
}

const char* OrNull(const std::string& s)
{
  return s.empty() ? nullptr : s.c_str();
}

void Send(const Presence& p)
{
  DiscordRichPresence rp{};
  rp.details = OrNull(p.details);
  rp.state = OrNull(p.state);
  rp.largeImageKey = OrNull(p.large_image);
  rp.largeImageText = OrNull(p.large_text);
  rp.smallImageKey = OrNull(p.small_image);
  rp.smallImageText = OrNull(p.small_text);
  rp.startTimestamp = p.start;
  rp.endTimestamp = p.end;
  rp.partyId = OrNull(p.party_id);
  rp.partySize = p.party_size;
  rp.partyMax = p.party_max;
  rp.joinSecret = OrNull(p.join_secret);
  rp.matchSecret = OrNull(p.match_secret);
  Discord_UpdatePresence(&rp);
}

std::string UserName(const DiscordUser* u)
{
  if (!u || !u->username)
    return {};
  std::string name = u->username;
  if (u->discriminator && std::string(u->discriminator) != "0" && u->discriminator[0])
    name += std::string("#") + u->discriminator;
  return name;
}
}  // namespace

int RunDiscordPresence(const optparse::Values& options)
{
  const std::string app_id = static_cast<const char*>(options.get("discord_presence"));

  std::mutex mutex;
  std::deque<Command> queue;
  std::atomic<bool> quit{false};
  StartLineReader(
      [&](const Command& cmd) {
        if (cmd.name == "quit" || cmd.name == "stop")
          quit = true;
        std::lock_guard lk(mutex);
        queue.push_back(cmd);
      },
      [&] { quit = true; });

  DiscordEventHandlers handlers{};
  handlers.ready = [](const DiscordUser* u) {
    Emit("connected", Json()
                          .Add("user_id", u && u->userId ? u->userId : "")
                          .Add("username", UserName(u)));
  };
  handlers.disconnected = [](int code, const char* message) {
    Emit("disconnected", Json().Add("code", code).Add("message", message ? message : ""));
  };
  handlers.errored = [](int code, const char* message) {
    Emit("error", Json()
                      .Add("code", "discord")
                      .Add("discord_code", code)
                      .Add("message", message ? message : ""));
  };
  handlers.joinGame = [](const char* secret) {
    Emit("join", Json().Add("secret", secret ? secret : ""));
  };
  handlers.joinRequest = [](const DiscordUser* u) {
    Emit("join_request", Json()
                             .Add("user_id", u && u->userId ? u->userId : "")
                             .Add("username", UserName(u)));
  };
  // autoRegister = 0: no protocol handler is written to the registry / ~/.local; joining from
  // Discord works while the frontend (and this helper) is running.
  Discord_Initialize(app_id.c_str(), &handlers, 0, nullptr);
  Emit("ready", Json().Add("protocol", PROTOCOL_VERSION).Add("mode", "discord").Add("enabled", true));

  std::optional<Presence> current;
  while (!quit)
  {
    std::deque<Command> todo;
    {
      std::lock_guard lk(mutex);
      todo.swap(queue);
    }
    for (const Command& cmd : todo)
    {
      if (cmd.name == "presence")
      {
        auto p = ParsePresence(cmd.arg);
        if (!p)
        {
          Emit("error", Json().Add("code", "bad_argument").Add("command", cmd.name));
          continue;
        }
        current = std::move(p);
        Send(*current);
        Emit("presence", Json().Add("details", current->details).Add("state", current->state));
      }
      else if (cmd.name == "clear")
      {
        current.reset();
        Discord_ClearPresence();
        Emit("presence", Json().Add("cleared", true));
      }
      else if (cmd.name == "respond")
      {
        const auto space = cmd.arg.find(' ');
        const std::string user = cmd.arg.substr(0, space);
        const std::string answer = space == std::string::npos ? "" : cmd.arg.substr(space + 1);
        if (user.empty() || (answer != "yes" && answer != "no" && answer != "ignore"))
        {
          Emit("error", Json().Add("code", "bad_argument").Add("command", cmd.name));
          continue;
        }
        Discord_Respond(user.c_str(), answer == "yes" ? DISCORD_REPLY_YES :
                                      answer == "no"  ? DISCORD_REPLY_NO :
                                                        DISCORD_REPLY_IGNORE);
      }
      else if (cmd.name != "quit" && cmd.name != "stop" && cmd.name != "eof")
      {
        Emit("error", Json().Add("code", "unknown_command").Add("command", cmd.name));
      }
    }
    Discord_RunCallbacks();
    std::this_thread::sleep_for(std::chrono::milliseconds(50));
  }
  // Give discord-rpc's IO thread a moment to send the clear (Discord also drops the presence
  // when the connection closes, this just makes it immediate).
  Discord_ClearPresence();
  for (int i = 0; i < 6; ++i)
  {
    Discord_RunCallbacks();
    std::this_thread::sleep_for(std::chrono::milliseconds(50));
  }
  Discord_Shutdown();
  return 0;
}
#else
int RunDiscordPresence(const optparse::Values&)
{
  StartLineReader([](const Command&) {}, [] {});
  Emit("ready",
       Json().Add("protocol", PROTOCOL_VERSION).Add("mode", "discord").Add("enabled", false));
  return 0;
}
#endif
}  // namespace Sparking
