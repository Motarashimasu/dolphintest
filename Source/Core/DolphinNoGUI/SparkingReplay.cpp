// Copyright 2026 Dolphin-Sparking Project
// SPDX-License-Identifier: GPL-2.0-or-later

#include "DolphinNoGUI/SparkingReplay.h"

#include <atomic>
#include <chrono>
#include <ctime>
#include <mutex>
#include <optional>
#include <thread>

#include <fmt/format.h>

#include "Common/CommonPaths.h"
#include "Common/FileUtil.h"
#include "Common/IOFile.h"
#include "Common/Version.h"
#include "Core/Boot/Boot.h"
#include "Core/Core.h"
#include "Core/Movie.h"
#include "Core/System.h"
#include "DolphinNoGUI/SparkingIO.h"

namespace Sparking
{
namespace
{
std::mutex s_mutex;
std::string s_dir;

// Recording (state under s_mutex).
std::optional<ReplayMatch> s_armed;  // this game, while it may be recorded
bool s_start_queued = false;
bool s_recording = false;
bool s_decided = false;
std::string s_winner, s_loser;
int s_winner_wins = 0, s_loser_wins = 0;
std::string s_started_at;  // local date/time the recording started
std::chrono::steady_clock::time_point s_started_clock;

// Playback.
std::atomic<bool> s_playing{false};
std::atomic<u64> s_play_total{0};
int s_progress_fields = 0;  // CPU thread only

// "Goku [EU]!" -> "Goku_EU" (file names on every system).
std::string SafeName(const std::string& name)
{
  std::string out;
  for (const char c : name)
  {
    const bool ok = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') ||
                    c == '-' || c == '_';
    if (ok)
      out += c;
    else if (!out.empty() && out.back() != '_')
      out += '_';
  }
  while (!out.empty() && out.back() == '_')
    out.pop_back();
  return out.empty() ? "Player" : out.substr(0, 24);
}

std::string LocalTime(const char* format)
{
  const std::time_t now = std::time(nullptr);
  std::tm tm{};
#ifdef _WIN32
  localtime_s(&tm, &now);
#else
  localtime_r(&now, &tm);
#endif
  char buf[64];
  std::strftime(buf, sizeof(buf), format, &tm);
  return buf;
}

// Host thread, game running.
void StartRecording()
{
  auto& system = Core::System::GetInstance();
  auto& movie = system.GetMovie();
  {
    std::lock_guard lk(s_mutex);
    s_start_queued = false;
    if (!s_armed || s_recording)
      return;
    if (!Core::IsRunning(system) || movie.IsMovieActive())
    {
      Emit("replay_error", Json().Add("code", "cannot_record"));
      s_armed.reset();
      return;
    }
  }
  // Ranked is always 2 players on GameCube ports 1 and 2.
  Movie::ControllerTypeArray controllers{};
  controllers[0] = controllers[1] = Movie::ControllerType::GC;
  File::CreateFullPath(File::GetUserPath(D_STATESAVES_IDX));  // where dtm.sav goes
  movie.SetSkipGameChecksum(true);
  movie.SetReadOnly(false);
  // Saves a state now (dtm.sav, written in the background) and records from it.
  const bool ok = movie.BeginRecordingInput(controllers, Movie::WiimoteEnabledArray{});
  std::lock_guard lk(s_mutex);
  if (!ok)
  {
    Emit("replay_error", Json().Add("code", "cannot_record"));
    s_armed.reset();
    return;
  }
  s_recording = true;
  s_started_at = LocalTime("%Y-%m-%d %H:%M:%S");
  s_started_clock = std::chrono::steady_clock::now();
  Emit("replay_recording", Json());
}

// The background state writer renames dtm.sav into place once it's complete.
bool WaitForStartState()
{
  const std::string path = File::GetUserPath(D_STATESAVES_IDX) + "dtm.sav";
  for (int i = 0; i < 200; ++i)  // up to 10 s
  {
    if (File::Exists(path) && File::GetSize(path) > 0)
      return true;
    std::this_thread::sleep_for(std::chrono::milliseconds(50));
  }
  return false;
}
}  // namespace

void SetReplayDir(const std::string& dir)
{
  std::lock_guard lk(s_mutex);
  s_dir = dir;
}

bool ReplaysEnabled()
{
  std::lock_guard lk(s_mutex);
  return !s_dir.empty();
}

void ReplayArm(const ReplayMatch& match)
{
  std::lock_guard lk(s_mutex);
  s_armed.reset();
  s_start_queued = s_recording = s_decided = false;
  if (s_dir.empty() || match.local_port < 1 || match.local_port > 2)
    return;
  s_armed = match;
}

void ReplayOnRoundStarted()
{
  std::lock_guard lk(s_mutex);
  if (!s_armed || s_recording || s_start_queued)
    return;
  s_start_queued = true;
  Core::QueueHostJob([](Core::System&) { StartRecording(); });
}

void ReplaySetDecided(const std::string& winner, const std::string& loser, int winner_wins,
                      int loser_wins)
{
  std::lock_guard lk(s_mutex);
  if (!s_armed)
    return;
  s_decided = true;
  s_winner = winner;
  s_loser = loser;
  s_winner_wins = winner_wins;
  s_loser_wins = loser_wins;
}

void ReplayFinish()
{
  auto& system = Core::System::GetInstance();
  auto& movie = system.GetMovie();
  std::optional<ReplayMatch> match;
  bool decided;
  std::string winner, dir, started_at;
  int seconds = 0;
  std::array<int, 2> wins{};
  {
    std::lock_guard lk(s_mutex);
    const bool recording = s_recording;
    match = s_armed;
    decided = s_decided;
    winner = s_winner;
    dir = s_dir;
    started_at = s_started_at;
    seconds = static_cast<int>(std::chrono::duration_cast<std::chrono::seconds>(
                                   std::chrono::steady_clock::now() - s_started_clock)
                                   .count());
    if (match)
    {
      for (int i = 0; i < 2; ++i)
      {
        if (match->players[i] == s_winner)
          wins[i] = s_winner_wins;
        else if (match->players[i] == s_loser)
          wins[i] = s_loser_wins;
      }
    }
    s_armed.reset();
    s_start_queued = s_recording = s_decided = false;
    if (!recording || !match)
      return;
  }
  if (!movie.IsRecordingInput())
    return;

  if (!decided && !match->keep_undecided)
  {
    Core::CPUThreadGuard guard(system);
    movie.EndPlayInput(false);
    Emit("replay_dropped", Json().Add("reason", "no_result"));
    return;
  }

  const std::string name =
      fmt::format("{}_{}_vs_{}", LocalTime("%Y-%m-%d_%H-%M-%S"), SafeName(match->players[0]),
                  SafeName(match->players[1]));
  File::CreateFullPath(dir + "/");
  const std::string dtm = dir + "/" + name + ".dtm";
  const bool state_ok = WaitForStartState();
  u64 frames = 0;
  {
    Core::CPUThreadGuard guard(system);
    frames = movie.GetTotalFrames();
    movie.SaveRecording(dtm);  // + <dtm>.sav (the state at the start)
    movie.EndPlayInput(false);
  }
  if (!state_ok || !File::Exists(dtm + ".sav"))
  {
    File::Delete(dtm);
    File::Delete(dtm + ".sav");
    Emit("replay_error", Json().Add("code", "state_not_saved"));
    return;
  }

  std::vector<std::string> codes;
  for (const auto& c : match->gecko)
    codes.push_back(Json::Escape(c));
  const std::string json =
      Json()
          .Add("version", 1)
          .Add("app", APP_NAME)
          .Add("dolphin", Common::GetScmDescStr())
          .Add("game_id", match->game_id)
          .Add("revision", match->revision)
          .Add("mode", match->mode)
          .Add("kind", match->kind)
          .AddRaw("players", JsonArray({Json::Escape(match->players[0]),
                                        Json::Escape(match->players[1])}))
          .AddRaw("wins", fmt::format("[{},{}]", wins[0], wins[1]))
          .Add("winner", winner)
          .Add("recorded_by_port", match->local_port)
          .AddRaw("gecko", JsonArray(codes))
          .Add("date", started_at)
          .Add("frames", static_cast<int64_t>(frames))
          .Add("seconds", seconds)
          .Add("dtm", name + ".dtm")
          .Str();
  const std::string meta = dir + "/" + name + ".json";
  if (!File::WriteStringToFile(meta, json))
  {
    Emit("replay_error", Json().Add("code", "write_failed").Add("path", meta));
    return;
  }
  Emit("replay_saved", Json()
                           .Add("dtm", dtm)
                           .Add("json", meta)
                           .Add("frames", static_cast<int64_t>(frames))
                           .Add("bytes", static_cast<int64_t>(File::GetSize(dtm) +
                                                               File::GetSize(dtm + ".sav"))));
}

bool PrepareReplayPlayback(const std::string& dtm_path, BootParameters* boot)
{
  auto& movie = Core::System::GetInstance().GetMovie();
  movie.SetSkipGameChecksum(true);
  movie.SetReadOnly(true);  // play to the end, then stop (don't continue recording)
  std::optional<std::string> state;
  if (!boot || !File::Exists(dtm_path) || !movie.PlayInput(dtm_path, &state))
  {
    Emit("error", Json().Add("code", "replay_unreadable").Add("path", dtm_path));
    return false;
  }
  if (!state)
  {
    movie.EndPlayInput(false);
    Emit("error", Json().Add("code", "replay_no_state").Add("path", dtm_path));
    return false;
  }
  boot->boot_session_data.SetSavestateData(*state, DeleteSavestateAfterBoot::No);
  s_play_total = movie.GetTotalFrames();
  s_progress_fields = 0;
  s_playing = true;
  Emit("replay_started", Json().Add("frames", static_cast<int64_t>(s_play_total.load())));
  return true;
}

void ReplayOnField()
{
  if (!s_playing)
    return;
  auto& system = Core::System::GetInstance();
  auto& movie = system.GetMovie();
  if (!movie.IsPlayingInput())
  {
    s_playing = false;
    Emit("replay_ended", Json().Add("frames", static_cast<int64_t>(s_play_total.load())));
    Core::QueueHostJob([](Core::System& sys) { Core::Stop(sys); });
    return;
  }
  if (++s_progress_fields >= 60)
  {
    s_progress_fields = 0;
    Emit("replay_progress", Json()
                                .Add("frame", static_cast<int64_t>(movie.GetCurrentFrame()))
                                .Add("frames", static_cast<int64_t>(s_play_total.load())));
  }
}
}  // namespace Sparking
