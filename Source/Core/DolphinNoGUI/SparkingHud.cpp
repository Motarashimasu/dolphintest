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
#include "VideoCommon/Present.h"
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
std::map<std::string, int> s_wins;    // player name -> rounds won (this boot)
std::atomic<int> s_ping{-1};          // netplay ping in ms (-1: not in netplay)
std::atomic<int> s_buffer{-1};        // netplay pad buffer (-1: unknown)
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

// Largest font size <= max_h at which `text` fits in max_w.
float FitSize(ImFont* font, const std::string& text, float max_w, float max_h)
{
  const float w = TextSize(font, max_h, text).x;
  return w <= max_w || w <= 0 ? max_h : max_h * max_w / w;
}

// A name that must stay inside its box: shrink down to 60% of the box height, then cut it with
// "..." so it can never run into the game's HUD.
std::pair<std::string, float> FitName(ImFont* font, std::string name, float max_w, float max_h)
{
  float size = FitSize(font, name, max_w, max_h);
  const float min_size = max_h * 0.6f;
  if (size >= min_size)
    return {name, size};
  size = min_size;
  while (!name.empty() && TextSize(font, size, name + "...").x > max_w)
    name.pop_back();
  return {name + "...", size};
}

struct Box
{
  float x0, y0, x1, y1;
  float w() const { return x1 - x0; }
  float h() const { return y1 - y0; }
};

// Video thread, inside the ImGui frame.
//
// Layout (fractions measured on BT3's HUD):
//  - score: centre of the game's top HUD, above the timer      (relative to the game picture)
//  - names: under each health bar, P1 left / P2 right          (relative to the game picture)
//  - health %: the very top corners of the window              (relative to the window)
//  - ping + buffer: bottom centre of the window, netplay only  (relative to the window)
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

  // The game picture inside the window (the window can be wider/taller than 16:9).
  Box pic{0, 0, screen.x, screen.y};
  if (g_presenter)
  {
    const auto& r = g_presenter->GetTargetRectangle();
    if (r.GetWidth() > 0 && r.GetHeight() > 0)
      pic = {float(r.left), float(r.top), float(r.right), float(r.bottom)};
  }
  const auto in_pic = [&](float fx0, float fy0, float fx1, float fy1) {
    return Box{pic.x0 + pic.w() * fx0, pic.y0 + pic.h() * fy0, pic.x0 + pic.w() * fx1,
               pic.y0 + pic.h() * fy1};
  };
  const auto in_win = [&](float fx0, float fy0, float fx1, float fy1) {
    return Box{screen.x * fx0, screen.y * fy0, screen.x * fx1, screen.y * fy1};
  };
  const ImU32 white = IM_COL32(240, 240, 245, 255);
  const ImU32 panel = IM_COL32(12, 12, 22, 200);

  // Score (blue box): "W1  W2" on a small dark panel in the centre of the top HUD.
  {
    Box box = in_pic(0.479f, 0.0f, 0.521f, 0.058f);
    const std::string w1 = fmt::format("{}", wins[0]), w2 = fmt::format("{}", wins[1]);
    const float size = box.h() * 0.82f;
    const float gap = box.h() * 0.45f;
    const float text_w = TextSize(font, size, w1).x + gap + TextSize(font, size, w2).x;
    const float pad = box.h() * 0.35f;
    if (text_w + 2 * pad > box.w())  // grow for double digits
    {
      const float c = (box.x0 + box.x1) / 2, half = text_w / 2 + pad;
      box.x0 = c - half;
      box.x1 = c + half;
    }
    dl->AddRectFilled(ImVec2(box.x0, box.y0), ImVec2(box.x1, box.y1), panel, box.h() * 0.2f);
    const float c = (box.x0 + box.x1) / 2;
    const float ty = box.y0 + (box.h() - size) / 2;
    const ImU32 score = IM_COL32(90, 225, 150, 255);
    dl->AddText(font, size, ImVec2(c - gap / 2 - TextSize(font, size, w1).x, ty), score, w1.c_str());
    dl->AddText(font, size, ImVec2(c + gap / 2, ty), score, w2.c_str());
  }

  // Names (red boxes): P1 left-aligned on the left, P2 right-aligned on the right.
  for (int i = 0; i < 2; ++i)
  {
    const Box box = i == 0 ? in_pic(0.141f, 0.124f, 0.262f, 0.178f) :
                             in_pic(0.762f, 0.124f, 0.865f, 0.178f);
    const auto [name, size] = FitName(font, DisplayName(sides[i], i + 1), box.w(), box.h());
    const float w = TextSize(font, size, name).x;
    const float x = i == 0 ? box.x0 : box.x1 - w;
    OutlinedText(dl, font, size, ImVec2(x, box.y0 + (box.h() - size) / 2), white, name);
  }

  // Health % (yellow boxes): the window's top corners.
  for (int i = 0; i < 2; ++i)
  {
    const Box box = i == 0 ? in_win(0.004f, 0.006f, 0.060f, 0.070f) :
                             in_win(0.940f, 0.006f, 0.996f, 0.070f);
    const Side& side = sides[i];
    const std::string pct = side.health ? fmt::format("{:.1f}%", *side.health) : "--";
    const ImU32 color = side.health ? HealthColor(*side.health) : IM_COL32(200, 200, 200, 255);
    const float size = FitSize(font, pct, box.w(), box.h());
    const float w = TextSize(font, size, pct).x;
    const float x = i == 0 ? box.x0 : box.x1 - w;
    OutlinedText(dl, font, size, ImVec2(x, box.y0 + (box.h() - size) / 2), color, pct);
  }

  // Ping + buffer (purple box): bottom centre of the window, netplay only.
  const int ping = s_ping, buffer = s_buffer;
  if (ping >= 0)
  {
    const Box box = in_win(0.397f, 0.905f, 0.631f, 0.988f);
    const std::string text = buffer >= 0 ? fmt::format("{} ms   |   Buffer {}", ping, buffer) :
                                           fmt::format("{} ms", ping);
    const float size = FitSize(font, text, box.w() * 0.88f, box.h() * 0.62f);
    const ImVec2 dim = TextSize(font, size, text);
    dl->AddRectFilled(ImVec2(box.x0, box.y0), ImVec2(box.x1, box.y1), panel, box.h() * 0.25f);
    const ImU32 ping_color = ping < 60   ? IM_COL32(90, 225, 150, 255) :
                             ping < 120  ? IM_COL32(245, 205, 50, 255) :
                                           IM_COL32(240, 90, 70, 255);
    dl->AddText(font, size,
                ImVec2(box.x0 + (box.w() - dim.x) / 2, box.y0 + (box.h() - dim.y) / 2),
                ping_color, text.c_str());
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

void SetHudNetplayStats(int ping_ms, int buffer)
{
  if (ping_ms >= -1)
    s_ping = ping_ms;
  if (buffer >= -1)
    s_buffer = buffer;
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
