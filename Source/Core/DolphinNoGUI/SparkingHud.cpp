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
std::atomic<bool> s_enabled{true};         // score bar + netplay ping/buffer
std::atomic<bool> s_health_enabled{true};  // health % in the corners
std::atomic<int> s_local_port{1};
std::array<Side, 2> s_sides;          // P1, P2
bool s_round_live = false;            // both sides were at 100% and nobody has hit 0% since
int s_pending_loser = 0;              // port that hit 0%, waiting for confirmation (0 = none)
int s_pending_frames = 0;
std::map<std::string, int> s_wins;    // player name -> rounds won (this boot)
std::atomic<int> s_ping{-1};          // netplay ping in ms (-1: not in netplay)
std::atomic<int> s_buffer{-1};        // netplay pad buffer (-1: unknown)
std::atomic<int> s_jitter{-1};        // ping jitter in ms (-1: not measured yet)
std::string s_rating;                 // guarded by s_mutex: good/ok/poor/measuring
std::array<std::string, 2> s_links;   // guarded by s_mutex: wired/wireless/virtual/unknown, "" = none
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

// Small connection icon centred in a square of side `size`: Wi-Fi arcs, a network plug, or "?".
void DrawLinkIcon(ImDrawList* dl, ImFont* font, ImVec2 c, float size, const std::string& link)
{
  const ImU32 shadow = IM_COL32(0, 0, 0, 220);
  if (link == "wireless")
  {
    const ImU32 col = IM_COL32(245, 205, 50, 255);
    const ImVec2 base(c.x, c.y + size * 0.32f);
    for (const ImU32 color : {shadow, col})
    {
      const float t = color == shadow ? size * 0.16f : size * 0.09f;
      for (int i = 1; i <= 3; ++i)
      {
        dl->PathArcTo(base, size * 0.2f * i, -2.36f, -0.79f, 12);
        dl->PathStroke(color, 0, t);
      }
      dl->AddCircleFilled(base, color == shadow ? size * 0.1f : size * 0.07f, color);
    }
  }
  else if (link == "wired")
  {
    const ImU32 col = IM_COL32(90, 225, 150, 255);
    // Ethernet plug: body, three contacts, cable.
    const ImVec2 a(c.x - size * 0.3f, c.y - size * 0.32f), b(c.x + size * 0.3f, c.y + size * 0.12f);
    dl->AddRectFilled(ImVec2(a.x - 1, a.y - 1), ImVec2(b.x + 1, b.y + 1), shadow, size * 0.06f);
    dl->AddRectFilled(a, b, col, size * 0.06f);
    for (int i = -1; i <= 1; ++i)
    {
      const float x = c.x + i * size * 0.14f;
      dl->AddLine(ImVec2(x, a.y + size * 0.06f), ImVec2(x, a.y + size * 0.2f), shadow,
                  size * 0.06f);
    }
    dl->AddRectFilled(ImVec2(c.x - size * 0.09f, b.y), ImVec2(c.x + size * 0.09f, c.y + size * 0.44f),
                      col);
  }
  else
  {
    const float t = size * 0.8f;
    const ImVec2 dim = TextSize(font, t, "?");
    OutlinedText(dl, font, t, ImVec2(c.x - dim.x / 2, c.y - dim.y / 2), IM_COL32(190, 190, 190, 255),
                 "?");
  }
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
void DrawHud()
{
  const bool hud = s_enabled, health = s_health_enabled;
  if (!hud && !health)
    return;
  std::array<Side, 2> sides;
  std::array<int, 2> wins{};
  std::array<std::string, 2> links;
  std::string rating;
  {
    std::lock_guard lk(s_mutex);
    sides = s_sides;
    links = s_links;
    rating = s_rating;
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
  const ImU32 panel = IM_COL32(12, 12, 22, 120);  // score panel: see-through

  // Score bar, centre of the game's top HUD: "[icon] Name1  W1 | W2  Name2 [icon]" on one
  // see-through panel. The scores stay centred; names grow outwards, shrink to fit their slot and
  // get cut with "..." so the bar never reaches the health bars. Netplay: wired/Wi-Fi icons on the
  // outer ends.
  if (hud)
  {
    const Box row = in_pic(0.479f, 0.0f, 0.521f, 0.050f);
    const float h = row.h();
    const float c = (row.x0 + row.x1) / 2;
    const float score_size = h * 0.82f, name_size = h * 0.62f;
    const ImU32 score_col = IM_COL32(90, 225, 150, 255);
    const ImU32 sep_col = IM_COL32(200, 200, 210, 200);

    // Centre: "W1 | W2"
    const std::string w1 = fmt::format("{}", wins[0]), w2 = fmt::format("{}", wins[1]);
    const float sep_gap = h * 0.28f;
    const float bar_w = TextSize(font, score_size, "|").x;
    const float half_center =
        std::max(TextSize(font, score_size, w1).x, TextSize(font, score_size, w2).x) + sep_gap +
        bar_w / 2;

    // Name slots: at most 12% of the picture width each, outside the scores.
    const float name_gap = h * 0.45f;
    const float icon = links[0].empty() && links[1].empty() ? 0.0f : h * 0.8f;
    const float icon_gap = icon > 0 ? h * 0.2f : 0.0f;
    const float slot = pic.w() * 0.12f;
    std::array<std::pair<std::string, float>, 2> names;
    std::array<float, 2> name_w{};
    for (int i = 0; i < 2; ++i)
    {
      names[i] = FitName(font, DisplayName(sides[i], i + 1), slot, name_size);
      name_w[i] = TextSize(font, names[i].second, names[i].first).x;
    }
    const float left_w = name_gap + name_w[0] + (links[0].empty() ? 0 : icon_gap + icon);
    const float right_w = name_gap + name_w[1] + (links[1].empty() ? 0 : icon_gap + icon);
    const float pad = h * 0.35f;
    const float x0 = c - half_center - left_w - pad, x1 = c + half_center + right_w + pad;
    dl->AddRectFilled(ImVec2(x0, row.y0), ImVec2(x1, row.y1), panel, h * 0.2f);

    const float score_y = row.y0 + (h - score_size) / 2;
    dl->AddText(font, score_size,
                ImVec2(c - bar_w / 2 - sep_gap - TextSize(font, score_size, w1).x, score_y),
                score_col, w1.c_str());
    dl->AddText(font, score_size, ImVec2(c - bar_w / 2, score_y), sep_col, "|");
    dl->AddText(font, score_size, ImVec2(c + bar_w / 2 + sep_gap, score_y), score_col, w2.c_str());

    for (int i = 0; i < 2; ++i)
    {
      const auto& [name, size] = names[i];
      const float y = row.y0 + (h - size) / 2;
      const float x = i == 0 ? c - half_center - name_gap - name_w[0] : c + half_center + name_gap;
      dl->AddText(font, size, ImVec2(x, y), white, name.c_str());
      if (!links[i].empty())
      {
        const float icon_x =
            i == 0 ? x - icon_gap - icon / 2 : x + name_w[1] + icon_gap + icon / 2;
        DrawLinkIcon(dl, font, ImVec2(icon_x, row.y0 + h / 2), icon, links[i]);
      }
    }
  }

  // Health % (yellow boxes): the window's top corners. Its own switch (--hud-health).
  for (int i = 0; i < 2 && health; ++i)
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

  // Ping + buffer (purple box): bottom centre of the window, netplay only. No panel, outlined text.
  const int ping = s_ping, buffer = s_buffer;
  if (hud && ping >= 0)
  {
    const Box box = in_win(0.397f, 0.905f, 0.631f, 0.988f);
    const int jitter = s_jitter;
    // "42 ms ±3": ping and how much it varies (Wi-Fi / busy connections jump around).
    const std::string ping_text =
        jitter >= 0 ? fmt::format("{} ms \xC2\xB1{}", ping, jitter) : fmt::format("{} ms", ping);
    const std::string text = buffer >= 0 ? fmt::format("{}   |   Buffer {}", ping_text, buffer) :
                                           ping_text;
    const float size = FitSize(font, text, box.w() * 0.88f, box.h() * 0.62f);
    const ImVec2 dim = TextSize(font, size, text);
    // Colour = connection quality once measured (ping + stability), else ping alone.
    const ImU32 good = IM_COL32(90, 225, 150, 255), ok = IM_COL32(245, 205, 50, 255),
                poor = IM_COL32(240, 90, 70, 255);
    const ImU32 ping_color = rating == "good" ? good :
                             rating == "ok"   ? ok :
                             rating == "poor" ? poor :
                             ping < 60        ? good :
                             ping < 120       ? ok :
                                                poor;
    OutlinedText(dl, font, size,
                 ImVec2(box.x0 + (box.w() - dim.x) / 2, box.y0 + (box.h() - dim.y) / 2),
                 ping_color, text);
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

// "PRE-ALPHA" in the bottom-right corner of the window, see-through, always (test builds).
void DrawWatermark()
{
  ImDrawList* dl = ImGui::GetForegroundDrawList();
  ImFont* font = ImGui::GetFont();
  const ImVec2 screen = ImGui::GetIO().DisplaySize;
  if (screen.x <= 0 || screen.y <= 0)
    return;
  static const std::string text = "PRE-ALPHA";
  const float size = std::max(14.0f, screen.y * 0.035f);
  const ImVec2 t = TextSize(font, size, text);
  const float margin = screen.y * 0.02f;
  const ImVec2 pos(screen.x - t.x - margin, screen.y - t.y - margin);
  dl->AddText(font, size, ImVec2(pos.x + 1.5f, pos.y + 1.5f), IM_COL32(0, 0, 0, 70), text.c_str());
  dl->AddText(font, size, pos, IM_COL32(255, 255, 255, 90), text.c_str());
}

void Draw()
{
  DrawHud();
  DrawWatermark();
}
}  // namespace

void InitHud(bool enabled, bool health)
{
  s_enabled = enabled;
  s_health_enabled = health;
  OSD::SetCustomDrawCallback(Draw);
}

void SetHudEnabled(bool enabled)
{
  s_enabled = enabled;
  Emit("hud", Json().Add("enabled", enabled));
}

void SetHudHealthEnabled(bool enabled)
{
  s_health_enabled = enabled;
  Emit("hud_health", Json().Add("enabled", enabled));
}

void SetHudNetplayStats(int ping_ms, int buffer)
{
  if (ping_ms >= -1)
    s_ping = ping_ms;
  if (buffer >= -1)
    s_buffer = buffer;
}

void SetHudLinkQuality(int jitter_ms, const std::string& rating)
{
  s_jitter = jitter_ms;
  std::lock_guard lk(s_mutex);
  s_rating = rating;
}

void SetHudLinks(const std::array<std::string, 2>& links)
{
  std::lock_guard lk(s_mutex);
  s_links = links;
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
