// Copyright 2026 Dolphin-Sparking Project
// SPDX-License-Identifier: GPL-2.0-or-later

#include "DolphinNoGUI/SparkingHud.h"

#include <algorithm>
#include <array>
#include <atomic>
#include <cfloat>
#include <map>
#include <mutex>
#include <optional>

#include <fmt/format.h>
#include <imgui.h>

#include "DolphinNoGUI/SparkingIO.h"
#include "VideoCommon/OnScreenDisplay.h"

namespace Sparking
{
namespace
{
// "Back to 100%" with a little float tolerance.
constexpr double FULL_HEALTH = 99.95;
// Frames (video fields, ~60/s) a 0% must hold, with the other side still alive, to count as a KO.
constexpr int CONFIRM_FRAMES = 45;

struct Side
{
  std::string name;
  std::optional<double> health;  // percent
};

std::mutex s_mutex;
std::atomic<bool> s_enabled{true};
std::atomic<int> s_local_port{1};
std::array<Side, 2> s_sides;          // P1, P2
bool s_round_live = false;            // both sides were at 100% and nobody has hit 0% since
int s_pending_loser = 0;              // port that hit 0%, waiting for confirmation (0 = none)
int s_pending_frames = 0;
std::map<std::string, int> s_wins;    // player name -> rounds won (this process)
int s_rounds = 0;

std::string DisplayName(const Side& side, int port)
{
  return side.name.empty() ? fmt::format("P{}", port) : side.name;
}

ImU32 HealthColor(double pct)
{
  if (pct > 50)
    return IM_COL32(80, 230, 90, 255);
  if (pct > 20)
    return IM_COL32(245, 205, 50, 255);
  return IM_COL32(240, 70, 60, 255);
}

// Text with a dark outline so it reads on any background.
void OutlinedText(ImDrawList* dl, ImFont* font, float size, ImVec2 pos, ImU32 color,
                  const std::string& text)
{
  const float o = std::max(1.0f, size / 16.0f);
  const ImU32 shadow = IM_COL32(0, 0, 0, 220);
  for (const ImVec2 d : {ImVec2(-o, 0), ImVec2(o, 0), ImVec2(0, -o), ImVec2(0, o), ImVec2(o, o)})
    dl->AddText(font, size, ImVec2(pos.x + d.x, pos.y + d.y), shadow, text.c_str());
  dl->AddText(font, size, pos, color, text.c_str());
}

ImVec2 TextSize(ImFont* font, float size, const std::string& text)
{
  return font->CalcTextSizeA(size, FLT_MAX, 0.0f, text.c_str());
}

// Video thread, inside the ImGui frame.
void Draw()
{
  if (!s_enabled)
    return;
  std::array<Side, 2> sides;
  std::array<int, 2> wins{};
  {
    std::lock_guard lk(s_mutex);
    sides = s_sides;
    for (int i = 0; i < 2; ++i)
    {
      const auto it = s_wins.find(DisplayName(sides[i], i + 1));
      wins[i] = it == s_wins.end() ? 0 : it->second;
    }
  }
  if (!sides[0].health && !sides[1].health)
    return;  // no health values (game without watches, or not read yet)

  ImDrawList* dl = ImGui::GetForegroundDrawList();
  ImFont* font = ImGui::GetFont();
  const ImVec2 screen = ImGui::GetIO().DisplaySize;
  const float unit = screen.y / 1080.0f;  // sizes are for 1080p, scaled to the window
  const float margin = 28.0f * unit;

  // Score bar, top center: "Name1  W1  W2  Name2" on a dark translucent strip (Fightcade-like).
  {
    const float size = 34.0f * unit;
    const float gap = 22.0f * unit;
    const float pad_x = 26.0f * unit, pad_y = 8.0f * unit;
    const std::string n1 = DisplayName(sides[0], 1), n2 = DisplayName(sides[1], 2);
    const std::string w1 = fmt::format("{}", wins[0]), w2 = fmt::format("{}", wins[1]);
    const ImVec2 d_n1 = TextSize(font, size, n1), d_n2 = TextSize(font, size, n2);
    const ImVec2 d_w1 = TextSize(font, size, w1), d_w2 = TextSize(font, size, w2);
    // Names sit on either side of the centre, the two scores next to each other in the middle.
    const float center = screen.x / 2;
    const float score_gap = 18.0f * unit;
    const float x_w1 = center - score_gap / 2 - d_w1.x;
    const float x_w2 = center + score_gap / 2;
    const float x_n1 = x_w1 - gap - d_n1.x;
    const float x_n2 = x_w2 + d_w2.x + gap;
    const float y = 10.0f * unit;
    dl->AddRectFilled(ImVec2(x_n1 - pad_x, y - pad_y),
                      ImVec2(x_n2 + d_n2.x + pad_x, y + d_n1.y + pad_y), IM_COL32(15, 15, 25, 190),
                      8.0f * unit);
    const ImU32 white = IM_COL32(235, 235, 240, 255);
    const ImU32 score = IM_COL32(90, 220, 140, 255);
    dl->AddText(font, size, ImVec2(x_n1, y), white, n1.c_str());
    dl->AddText(font, size, ImVec2(x_w1, y), score, w1.c_str());
    dl->AddText(font, size, ImVec2(x_w2, y), score, w2.c_str());
    dl->AddText(font, size, ImVec2(x_n2, y), white, n2.c_str());
  }

  // Health %, top corners (below the score bar line).
  for (int i = 0; i < 2; ++i)
  {
    const Side& side = sides[i];
    const std::string pct = side.health ? fmt::format("{:.1f}%", *side.health) : "--";
    const ImU32 color = side.health ? HealthColor(*side.health) : IM_COL32(200, 200, 200, 255);
    const float size = 52.0f * unit;
    const ImVec2 dim = TextSize(font, size, pct);
    const float x = i == 0 ? margin : screen.x - margin - dim.x;
    OutlinedText(dl, font, size, ImVec2(x, margin + 40.0f * unit), color, pct);
  }
}

// Caller holds s_mutex.
std::string ScoreJson()
{
  Json json;
  for (const auto& [name, wins] : s_wins)
    json.Add(name, wins);
  return json.Str();
}
}  // namespace

void InitHud(bool enabled)
{
  s_enabled = enabled;
  OSD::SetCustomDrawCallback(Draw);
}

void SetHudEnabled(bool enabled)
{
  s_enabled = enabled;
  Emit("hud", Json().Add("enabled", enabled));
}

void SetHudLocalPort(int port)
{
  s_local_port = port;
}

void ResetHud()
{
  std::lock_guard lk(s_mutex);
  s_sides = {};
  s_round_live = false;
  s_pending_loser = 0;
  s_wins.clear();
  s_rounds = 0;
}

void ResetScores()
{
  std::lock_guard lk(s_mutex);
  s_wins.clear();
  s_rounds = 0;
  Emit("score", Json().AddRaw("wins", ScoreJson()).Add("rounds", 0));
}

void HudOnWatch(const std::string& name, int port, const std::string& player, double value,
                bool valid)
{
  if (port < 1 || port > 2 || name.find("_health_pct") == std::string::npos)
    return;
  std::lock_guard lk(s_mutex);
  Side& side = s_sides[port - 1];
  side.name = player;
  side.health = valid ? std::optional<double>(value) : std::nullopt;

  const auto& h1 = s_sides[0].health;
  const auto& h2 = s_sides[1].health;
  if (!s_round_live)
  {
    // New round once both bars are full again.
    if (h1 && h2 && *h1 >= FULL_HEALTH && *h2 >= FULL_HEALTH)
    {
      s_round_live = true;
      Emit("round_started", Json()
                                .Add("round", s_rounds + 1)
                                .Add("p1", DisplayName(s_sides[0], 1))
                                .Add("p2", DisplayName(s_sides[1], 2)));
    }
    return;
  }

  // Live round: a side at 0% starts the confirmation (decided in HudTick).
  if (s_pending_loser == 0 && side.health && *side.health <= 0.0)
  {
    s_pending_loser = port;
    s_pending_frames = CONFIRM_FRAMES;
  }
}

void HudTick()
{
  std::lock_guard lk(s_mutex);
  if (!s_round_live || s_pending_loser == 0)
    return;
  const int loser_port = s_pending_loser;
  const int winner_port = loser_port == 1 ? 2 : 1;
  const auto& loser_health = s_sides[loser_port - 1].health;
  const auto& winner_health = s_sides[winner_port - 1].health;

  // Both at 0% (or unreadable): the game cleared the values (menu, next match). Nobody scores.
  if (!winner_health || *winner_health <= 0.0)
  {
    s_pending_loser = 0;
    s_round_live = false;
    Emit("round_void", Json()
                           .Add("round", s_rounds + 1)
                           .Add("reason", "both_health_zero"));
    return;
  }
  // The "loser" came back above 0% (shouldn't happen in a KO): keep playing.
  if (!loser_health || *loser_health > 0.0)
  {
    s_pending_loser = 0;
    return;
  }
  if (--s_pending_frames > 0)
    return;

  // Confirmed KO.
  s_pending_loser = 0;
  s_round_live = false;
  ++s_rounds;
  const std::string winner = DisplayName(s_sides[winner_port - 1], winner_port);
  const std::string loser = DisplayName(s_sides[loser_port - 1], loser_port);
  ++s_wins[winner];
  s_wins.try_emplace(loser, 0);

  Json json;
  json.Add("round", s_rounds)
      .Add("winner_port", winner_port)
      .Add("winner", winner)
      .Add("loser_port", loser_port)
      .Add("loser", loser)
      .AddRaw("wins", ScoreJson());
  const int local = s_local_port;
  if (local == 1 || local == 2)
    json.Add("local_result", local == winner_port ? "win" : "lose");
  Emit("round_result", json);
}
}  // namespace Sparking
