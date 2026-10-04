// Copyright 2026 Dolphin-Sparking Project
// SPDX-License-Identifier: GPL-2.0-or-later

#include "DolphinNoGUI/SparkingHud.h"

#include <algorithm>
#include <array>
#include <cfloat>
#include <atomic>
#include <chrono>
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
using Clock = std::chrono::steady_clock;
constexpr auto RESULT_SHOW_TIME = std::chrono::seconds(6);

struct Side
{
  std::string name;
  std::optional<double> health;  // percent
};

struct Result
{
  int winner_port = 0;
  std::string winner;
  std::string loser;
  Clock::time_point when;
};

std::mutex s_mutex;
std::atomic<bool> s_enabled{true};
std::atomic<int> s_local_port{1};
std::array<Side, 2> s_sides;  // P1, P2
bool s_battle_running = false;
std::optional<Result> s_result;

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
  const float o = std::max(1.0f, size / 14.0f);
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
  bool battle;
  std::optional<Result> result;
  {
    std::lock_guard lk(s_mutex);
    sides = s_sides;
    battle = s_battle_running;
    result = s_result;
  }
  const bool showing_result = result && Clock::now() - result->when < RESULT_SHOW_TIME;
  if (!battle && !showing_result)
    return;

  ImDrawList* dl = ImGui::GetForegroundDrawList();
  ImFont* font = ImGui::GetFont();
  const ImVec2 screen = ImGui::GetIO().DisplaySize;
  const float unit = screen.y / 1080.0f;  // scale with the window: sizes are for 1080p
  const float name_size = 34.0f * unit;
  const float pct_size = 52.0f * unit;
  const float margin = 28.0f * unit;

  for (int i = 0; i < 2; ++i)
  {
    const Side& side = sides[i];
    const std::string name = side.name.empty() ? fmt::format("P{}", i + 1) : side.name;
    const std::string pct = side.health ? fmt::format("{:.1f}%", *side.health) : "--";
    const ImU32 color = side.health ? HealthColor(*side.health) : IM_COL32(200, 200, 200, 255);
    const ImVec2 name_dim = TextSize(font, name_size, name);
    const ImVec2 pct_dim = TextSize(font, pct_size, pct);
    // P1 top-left, P2 top-right (right-aligned).
    const float name_x = i == 0 ? margin : screen.x - margin - name_dim.x;
    const float pct_x = i == 0 ? margin : screen.x - margin - pct_dim.x;
    OutlinedText(dl, font, name_size, ImVec2(name_x, margin), IM_COL32(255, 255, 255, 255), name);
    OutlinedText(dl, font, pct_size, ImVec2(pct_x, margin + name_dim.y), color, pct);
  }

  if (showing_result)
  {
    const std::string headline = fmt::format("{} WINS!", result->winner);
    const float big = 96.0f * unit;
    const ImVec2 dim = TextSize(font, big, headline);
    const float y = screen.y * 0.38f;
    OutlinedText(dl, font, big, ImVec2((screen.x - dim.x) / 2, y), IM_COL32(255, 215, 60, 255),
                 headline);

    const int local = s_local_port;
    if (local == 1 || local == 2)
    {
      const bool won = local == result->winner_port;
      const std::string sub = won ? "YOU WIN" : "YOU LOSE";
      const float mid = 64.0f * unit;
      const ImVec2 sub_dim = TextSize(font, mid, sub);
      OutlinedText(dl, font, mid, ImVec2((screen.x - sub_dim.x) / 2, y + dim.y + 10 * unit),
                   won ? IM_COL32(90, 220, 255, 255) : IM_COL32(240, 70, 60, 255), sub);
    }
  }
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
  s_battle_running = false;
  s_result.reset();
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
  // A battle is running once both sides are alive; that re-arms the result after the last one.
  if (!s_battle_running && s_sides[0].health > 0.0 && s_sides[1].health > 0.0)
  {
    s_battle_running = true;
    Emit("battle_started", Json()
                               .Add("p1", s_sides[0].name)
                               .Add("p2", s_sides[1].name));
  }
}

void HudOnTrigger(const std::string& name, int port, const std::string& player)
{
  if (port < 1 || port > 2 || name.find("_defeated") == std::string::npos)
    return;
  std::lock_guard lk(s_mutex);
  if (!s_battle_running)
    return;  // not in a battle (menu/result screen reset) or already decided
  s_battle_running = false;
  const int winner_port = port == 1 ? 2 : 1;
  const std::string winner = s_sides[winner_port - 1].name.empty() ?
                                 fmt::format("P{}", winner_port) :
                                 s_sides[winner_port - 1].name;
  s_result = Result{winner_port, winner, player, Clock::now()};

  Json json;
  json.Add("winner_port", winner_port)
      .Add("winner", winner)
      .Add("loser_port", port)
      .Add("loser", player);
  const int local = s_local_port;
  if (local == 1 || local == 2)
    json.Add("local_result", local == winner_port ? "win" : "lose");
  Emit("match_result", json);
}
}  // namespace Sparking
