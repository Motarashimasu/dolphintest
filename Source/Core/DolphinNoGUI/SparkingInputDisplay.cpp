// Copyright 2026 Dolphin-Sparking Project
// SPDX-License-Identifier: GPL-2.0-or-later

#include "DolphinNoGUI/SparkingInputDisplay.h"

#include <algorithm>
#include <array>
#include <atomic>
#include <cfloat>
#include <cmath>
#include <deque>
#include <memory>
#include <mutex>
#include <set>
#include <utility>
#include <vector>

#include <fmt/format.h>
#include <imgui.h>

#include "Common/CommonPaths.h"
#include "Common/FileUtil.h"
#include "Common/HookableEvent.h"
#include "Common/IniFile.h"
#include "Common/StringUtil.h"
#include "Core/ConfigManager.h"
#include "Core/HW/SI/SI_DeviceGCController.h"
#include "Core/NeoCode.h"
#include "Core/System.h"
#include "DolphinNoGUI/SparkingHud.h"
#include "DolphinNoGUI/SparkingIO.h"
#include "InputCommon/GCPadStatus.h"
#include "VideoCommon/AbstractGfx.h"
#include "VideoCommon/AbstractTexture.h"
#include "VideoCommon/Assets/CustomTextureData.h"
#include "VideoCommon/HiresTextures.h"
#include "VideoCommon/OnScreenDisplay.h"
#include "VideoCommon/Present.h"
#include "VideoCommon/TextureCacheBase.h"
#include "VideoCommon/TextureConfig.h"
#include "VideoCommon/TextureInfo.h"
#include "VideoCommon/VideoConfig.h"
#include "VideoCommon/VideoEvents.h"

namespace Sparking
{
namespace
{
enum Button
{
  BTN_A,
  BTN_B,
  BTN_X,
  BTN_Y,
  BTN_Z,
  BTN_L,
  BTN_R,
  BTN_START,
  BTN_COUNT
};
// [Sparking.ButtonIcons] keys, in drawing order.
constexpr std::array<const char*, BTN_COUNT> BUTTON_KEYS = {"A", "B", "X", "Y",
                                                            "Z", "L", "R", "Start"};
constexpr std::size_t MAX_ENTRIES = 40;
constexpr int NEUTRAL = 5;  // numpad notation: 5 = neutral, 8 = up, 6 = right, 3 = down-right...

struct Input
{
  int dir = NEUTRAL;   // main stick
  int cdir = NEUTRAL;  // C-stick
  int dpad = NEUTRAL;
  u16 buttons = 0;  // 1 << Button
  bool operator==(const Input&) const = default;
};

struct Entry
{
  Input input;
  u32 frames = 1;  // video fields held
};

// --- Recording (CPU thread), drawing copies under the lock ----------------------------------
std::mutex s_mutex;
std::deque<Entry> s_history;  // front = newest
Input s_latest;
bool s_have_latest = false;  // the local port was polled since the game started
std::atomic<bool> s_enabled{false};

// --- Texture names from the game ini (any thread, under s_names_mutex) -----------------------
std::mutex s_names_mutex;
std::array<std::vector<std::string>, BTN_COUNT> s_names;
std::set<std::string> s_wanted;          // every name above
std::set<std::pair<u32, u32>> s_dims;    // their sizes ("tex1_32x32_..."), to skip the rest fast
std::string s_game_id;

// --- Icons (video thread only) ----------------------------------------------------------------
struct Icon
{
  std::string path;
  std::unique_ptr<AbstractTexture> texture;
};
std::array<Icon, BTN_COUNT> s_icons;
std::string s_style = "vanilla";  // selected @Buttons option (lowercase): drawn fallbacks' look
int s_refresh_in = 0;
std::atomic<bool> s_refresh_now{true};

int StickDirection(u8 x, u8 y, int dead_zone)
{
  const int dx = int(x) - GCPadStatus::MAIN_STICK_CENTER_X;
  const int dy = int(y) - GCPadStatus::MAIN_STICK_CENTER_Y;
  if (dx * dx + dy * dy < dead_zone * dead_zone)
    return NEUTRAL;
  // 8 sectors of 45 degrees, counter-clockwise from right.
  constexpr double SECTOR = 3.14159265358979323846 / 4;
  const int sector = static_cast<int>(std::lround(std::atan2(double(dy), double(dx)) / SECTOR)) & 7;
  static constexpr std::array<int, 8> NUMPAD = {6, 9, 8, 7, 4, 1, 2, 3};
  return NUMPAD[sector];
}

int DpadDirection(u16 b)
{
  const int dx = ((b & PAD_BUTTON_RIGHT) ? 1 : 0) - ((b & PAD_BUTTON_LEFT) ? 1 : 0);
  const int dy = ((b & PAD_BUTTON_UP) ? 1 : 0) - ((b & PAD_BUTTON_DOWN) ? 1 : 0);
  return NEUTRAL + dx + 3 * dy;
}

Input Sample(const GCPadStatus& s)
{
  Input in;
  in.dir = StickDirection(s.stickX, s.stickY, 38);  // ~30% of the stick's reach
  in.cdir = StickDirection(s.substickX, s.substickY, 50);
  in.dpad = DpadDirection(s.button);
  const auto set = [&](Button b, bool on) {
    if (on)
      in.buttons |= u16(1u << b);
  };
  set(BTN_A, (s.button & PAD_BUTTON_A) != 0);
  set(BTN_B, (s.button & PAD_BUTTON_B) != 0);
  set(BTN_X, (s.button & PAD_BUTTON_X) != 0);
  set(BTN_Y, (s.button & PAD_BUTTON_Y) != 0);
  set(BTN_Z, (s.button & PAD_TRIGGER_Z) != 0);
  set(BTN_L, (s.button & PAD_TRIGGER_L) || s.triggerLeft >= 0xC0);
  set(BTN_R, (s.button & PAD_TRIGGER_R) || s.triggerRight >= 0xC0);
  set(BTN_START, (s.button & PAD_BUTTON_START) != 0);
  return in;
}

// CPU thread, every pad poll.
void OnPad(int device_number, const GCPadStatus& status)
{
  if (device_number + 1 != HudLocalPort() || NeoCode::IsResimulating())
    return;
  const Input input = Sample(status);
  std::lock_guard lk(s_mutex);
  s_latest = input;
  s_have_latest = true;
}

// CPU thread, once per video field: the input the game had this field.
void OnField()
{
  if (NeoCode::IsResimulating())
    return;  // a NEOcode re-run of fields already recorded
  std::lock_guard lk(s_mutex);
  if (!s_have_latest)
    return;
  if (!s_history.empty() && s_history.front().input == s_latest)
  {
    ++s_history.front().frames;
    return;
  }
  s_history.push_front({s_latest, 1});
  if (s_history.size() > MAX_ENTRIES)
    s_history.pop_back();
}

std::string CaptureDir(const std::string& game_id)
{
  return File::GetUserPath(D_USER_IDX) + "Sparking/ButtonIcons/" + game_id + "/";
}

// Video thread: a game texture was decoded from memory (not replaced by a pack). Keeps the game's
// own button icons the first time the game draws them.
void OnTextureDecoded(const TextureInfo& info, const AbstractTexture& texture)
{
  std::string game_id;
  {
    std::lock_guard lk(s_names_mutex);
    if (!s_dims.contains({info.GetRawWidth(), info.GetRawHeight()}))
      return;
    game_id = s_game_id;
  }
  const std::string name = info.CalculateTextureName().GetFullName();
  {
    std::lock_guard lk(s_names_mutex);
    if (!s_wanted.contains(name))
      return;
  }
  const std::string path = CaptureDir(game_id) + name + ".png";
  if (File::Exists(path))
    return;
  File::CreateFullPath(path);
  if (texture.Save(path, 0))
  {
    s_refresh_now = true;
    Emit("button_icon_saved", Json().Add("name", name).Add("path", path));
  }
}

std::unique_ptr<AbstractTexture> LoadIcon(const std::string& path)
{
  if (!g_gfx)
    return nullptr;
  VideoCommon::CustomTextureData::ArraySlice::Level level;
  std::string ext;
  SplitPath(path, nullptr, nullptr, &ext);
  Common::ToLower(&ext);
  const bool ok = ext == ".dds" ? VideoCommon::LoadDDSTexture(&level, path, 0) :
                                  VideoCommon::LoadPNGTexture(&level, path);
  if (!ok || level.width == 0 || level.height == 0)
    return nullptr;
  if (level.format == AbstractTextureFormat::BPTC && !g_backend_info.bSupportsBPTCTextures)
    return nullptr;
  if (AbstractTexture::IsCompressedFormat(level.format) &&
      level.format != AbstractTextureFormat::BPTC && !g_backend_info.bSupportsST3CTextures)
    return nullptr;
  const TextureConfig config(level.width, level.height, 1, 1, 1, level.format, 0,
                             AbstractTextureType::Texture_2DArray);
  auto texture = g_gfx->CreateTexture(config, "Sparking input display icon");
  if (texture)
  {
    texture->Load(0, level.width, level.height, level.row_length, level.data.data(),
                  level.data.size());
  }
  return texture;
}

// Video thread: which picture each button uses now (pack option, the game's own, or drawn).
void RefreshIcons()
{
  std::array<std::vector<std::string>, BTN_COUNT> names;
  std::string game_id;
  {
    std::lock_guard lk(s_names_mutex);
    names = s_names;
    game_id = s_game_id;
  }
  const bool packs = g_ActiveConfig.bHiresTextures;
  s_style = "vanilla";
  if (packs)
  {
    const auto selection = HiresTexture::GetVariantSelection();
    for (const auto& [group, option] : selection)
    {
      std::string g = group, o = option;
      Common::ToLower(&g);
      Common::ToLower(&o);
      if (g == "buttons")
        s_style = o;
    }
  }
  for (int b = 0; b < BTN_COUNT; ++b)
  {
    std::string path;
    for (const std::string& name : names[b])
    {
      if (packs)
        path = HiresTexture::GetMappedPath(name);
      if (!path.empty())
        break;
    }
    for (const std::string& name : names[b])
    {
      if (!path.empty())
        break;
      const std::string saved = CaptureDir(game_id) + name + ".png";
      if (File::Exists(saved))
        path = saved;
    }
    Icon& icon = s_icons[b];
    if (path == icon.path)
      continue;
    icon.path = path;
    icon.texture = path.empty() ? nullptr : LoadIcon(path);
  }
}

// --- Drawing ----------------------------------------------------------------------------------

ImU32 Fade(ImU32 color, float alpha)
{
  const u32 a = (color >> IM_COL32_A_SHIFT) & 0xFF;
  return (color & ~IM_COL32_A_MASK) |
         (static_cast<u32>(static_cast<float>(a) * alpha) << IM_COL32_A_SHIFT);
}

ImVec2 TextSize(ImFont* font, float size, const char* text)
{
  return font->CalcTextSizeA(size, FLT_MAX, 0.0f, text);
}

void CenteredText(ImDrawList* dl, ImFont* font, ImVec2 c, float max_w, float max_h, ImU32 color,
                  const char* text, float alpha, bool outline)
{
  float size = max_h;
  const float w = TextSize(font, size, text).x;
  if (w > max_w && w > 0)
    size *= max_w / w;
  const ImVec2 dim = TextSize(font, size, text);
  const ImVec2 pos(c.x - dim.x / 2, c.y - dim.y / 2);
  if (outline)
  {
    const float o = std::max(1.0f, size / 14.0f);
    const ImU32 shadow = Fade(IM_COL32(0, 0, 0, 220), alpha);
    for (const ImVec2 d : {ImVec2(-o, 0), ImVec2(o, 0), ImVec2(0, -o), ImVec2(0, o)})
      dl->AddText(font, size, ImVec2(pos.x + d.x, pos.y + d.y), shadow, text);
  }
  dl->AddText(font, size, pos, Fade(color, alpha), text);
}

// Numpad direction -> unit vector on screen (y down).
ImVec2 DirVector(int dir)
{
  const float dx = static_cast<float>((dir - 1) % 3 - 1);
  const float dy = static_cast<float>(-((dir - 1) / 3 - 1));
  const float len = std::sqrt(dx * dx + dy * dy);
  return len > 0 ? ImVec2(dx / len, dy / len) : ImVec2(0, 0);
}

void Arrow(ImDrawList* dl, ImVec2 c, float r, int dir, ImU32 color)
{
  const ImVec2 u = DirVector(dir);
  const ImVec2 perp(-u.y, u.x);
  const ImVec2 tip(c.x + u.x * r * 0.78f, c.y + u.y * r * 0.78f);
  const ImVec2 base(tip.x - u.x * r * 0.68f, tip.y - u.y * r * 0.68f);
  const ImVec2 tail(c.x - u.x * r * 0.62f, c.y - u.y * r * 0.62f);
  dl->AddLine(tail, base, color, r * 0.3f);
  dl->AddTriangleFilled(tip, ImVec2(base.x + perp.x * r * 0.5f, base.y + perp.y * r * 0.5f),
                        ImVec2(base.x - perp.x * r * 0.5f, base.y - perp.y * r * 0.5f), color);
}

// Main stick: an arrow in a ring, or the neutral mark (ring + dot) like a fighting game.
void DrawDirection(ImDrawList* dl, ImVec2 c, float r, int dir, float alpha, bool newest)
{
  dl->AddCircleFilled(c, r, Fade(IM_COL32(0, 0, 0, 150), alpha));
  dl->AddCircle(c, r * 0.94f, Fade(IM_COL32(190, 190, 205, 210), alpha), 0,
                std::max(1.0f, r * 0.11f));
  if (dir == NEUTRAL)
  {
    dl->AddCircleFilled(c, r * 0.24f, Fade(IM_COL32(160, 160, 175, 255), alpha));
    return;
  }
  Arrow(dl, c, r, dir,
        Fade(newest ? IM_COL32(255, 222, 80, 255) : IM_COL32(245, 245, 250, 255), alpha));
}

// C-stick: a small coloured disc with a dark arrow.
void DrawCStick(ImDrawList* dl, ImVec2 c, float r, int dir, float alpha)
{
  const ImU32 fill = s_style == "vanilla" ? IM_COL32(235, 200, 40, 255) : IM_COL32(120, 120, 135, 255);
  dl->AddCircleFilled(c, r * 0.9f, Fade(fill, alpha));
  Arrow(dl, c, r * 0.85f, dir, Fade(IM_COL32(25, 25, 30, 255), alpha));
}

void DrawDpad(ImDrawList* dl, ImVec2 c, float r, int dir, float alpha)
{
  const float t = r * 0.36f, e = r * 0.92f;
  const ImU32 off = Fade(IM_COL32(95, 95, 110, 255), alpha);
  const ImU32 on = Fade(IM_COL32(245, 245, 250, 255), alpha);
  dl->AddRectFilled(ImVec2(c.x - e, c.y - t), ImVec2(c.x + e, c.y + t), off, t * 0.4f);
  dl->AddRectFilled(ImVec2(c.x - t, c.y - e), ImVec2(c.x + t, c.y + e), off, t * 0.4f);
  const int dx = (dir - 1) % 3 - 1, dy = (dir - 1) / 3 - 1;
  if (dx > 0)
    dl->AddRectFilled(ImVec2(c.x + t, c.y - t), ImVec2(c.x + e, c.y + t), on, t * 0.4f);
  if (dx < 0)
    dl->AddRectFilled(ImVec2(c.x - e, c.y - t), ImVec2(c.x - t, c.y + t), on, t * 0.4f);
  if (dy > 0)
    dl->AddRectFilled(ImVec2(c.x - t, c.y - e), ImVec2(c.x + t, c.y - t), on, t * 0.4f);
  if (dy < 0)
    dl->AddRectFilled(ImVec2(c.x - t, c.y + t), ImVec2(c.x + t, c.y + e), on, t * 0.4f);
}

struct DrawnButton
{
  const char* label;
  ImU32 color;
  bool pill;  // shoulder / Start: rounded rectangle instead of a disc
};

// The drawn look of each GameCube button in the selected pack's style. The labels follow the
// launcher's controller presets (GameCube A = Square / Xbox X, B = Cross / A, Z = L2 / LT, ...).
DrawnButton Drawn(int b)
{
  const ImU32 grey = IM_COL32(165, 165, 180, 255);
  if (s_style == "playstation")
  {
    static constexpr std::array<const char*, BTN_COUNT> L = {"", "", "", "", "L2", "R2", "R1",
                                                             "ST"};
    const std::array<ImU32, 4> face = {IM_COL32(235, 125, 200, 255), IM_COL32(120, 165, 245, 255),
                                       IM_COL32(240, 85, 85, 255), IM_COL32(80, 210, 160, 255)};
    return {L[b], b < 4 ? face[b] : grey, b >= 4};
  }
  if (s_style == "xbox")
  {
    static constexpr std::array<const char*, BTN_COUNT> L = {"X", "A", "B", "Y", "LT", "RT", "RB",
                                                             "ST"};
    const std::array<ImU32, 4> face = {IM_COL32(70, 130, 245, 255), IM_COL32(95, 205, 75, 255),
                                       IM_COL32(225, 65, 55, 255), IM_COL32(240, 200, 45, 255)};
    return {L[b], b < 4 ? face[b] : grey, b >= 4};
  }
  static constexpr std::array<const char*, BTN_COUNT> L = {"A", "B", "X", "Y", "Z", "L", "R", "S"};
  const std::array<ImU32, BTN_COUNT> col = {
      IM_COL32(40, 195, 125, 255), IM_COL32(230, 55, 55, 255),   IM_COL32(205, 205, 215, 255),
      IM_COL32(205, 205, 215, 255), IM_COL32(125, 85, 225, 255), grey, grey, grey};
  return {L[b], col[b], b >= 4 && b != BTN_Z};
}

void DrawButton(ImDrawList* dl, ImFont* font, int b, ImVec2 p0, float s, float alpha)
{
  const ImVec2 p1(p0.x + s, p0.y + s);
  if (const auto& tex = s_icons[b].texture)
  {
    // Pack / game button pictures have a transparent margin: drawn a bit larger.
    const float m = s * 0.12f;
    dl->AddImage(*tex, ImVec2(p0.x - m, p0.y - m), ImVec2(p1.x + m, p1.y + m), ImVec2(0, 0),
                 ImVec2(1, 1), Fade(IM_COL32_WHITE, alpha));
    return;
  }
  const ImVec2 c(p0.x + s / 2, p0.y + s / 2);
  const float r = s * 0.46f;
  const DrawnButton d = Drawn(b);
  const ImU32 dark = Fade(IM_COL32(20, 20, 28, 235), alpha);
  if (d.pill)
  {
    dl->AddRectFilled(ImVec2(p0.x, c.y - r * 0.72f), ImVec2(p1.x, c.y + r * 0.72f), dark, r * 0.4f);
    dl->AddRect(ImVec2(p0.x, c.y - r * 0.72f), ImVec2(p1.x, c.y + r * 0.72f), Fade(d.color, alpha),
                r * 0.4f, 0, std::max(1.0f, s * 0.06f));
    CenteredText(dl, font, c, s * 0.82f, s * 0.5f, d.color, d.label, alpha, false);
    return;
  }
  if (s_style == "playstation" && b < 4)
  {
    // Dark disc with the coloured shape.
    dl->AddCircleFilled(c, r, dark);
    const ImU32 col = Fade(d.color, alpha);
    const float k = r * 0.48f, t = std::max(1.5f, s * 0.08f);
    switch (b)
    {
    case BTN_A:  // square
      dl->AddRect(ImVec2(c.x - k * 0.85f, c.y - k * 0.85f), ImVec2(c.x + k * 0.85f, c.y + k * 0.85f),
                  col, 0, 0, t);
      break;
    case BTN_B:  // cross
      dl->AddLine(ImVec2(c.x - k, c.y - k), ImVec2(c.x + k, c.y + k), col, t);
      dl->AddLine(ImVec2(c.x - k, c.y + k), ImVec2(c.x + k, c.y - k), col, t);
      break;
    case BTN_X:  // circle
      dl->AddCircle(c, k, col, 0, t);
      break;
    default:  // triangle
      dl->AddTriangle(ImVec2(c.x, c.y - k), ImVec2(c.x + k, c.y + k * 0.75f),
                      ImVec2(c.x - k, c.y + k * 0.75f), col, t);
      break;
    }
    return;
  }
  if (s_style == "xbox" && b < 4)
  {
    dl->AddCircleFilled(c, r, dark);
    CenteredText(dl, font, c, s * 0.7f, s * 0.62f, d.color, d.label, alpha, false);
    return;
  }
  // GameCube: coloured disc with a dark letter.
  dl->AddCircleFilled(c, r, Fade(d.color, alpha));
  dl->AddCircle(c, r, Fade(IM_COL32(0, 0, 0, 160), alpha), 0, std::max(1.0f, s * 0.05f));
  CenteredText(dl, font, c, s * 0.7f, s * 0.6f, IM_COL32(20, 20, 25, 255), d.label, alpha, false);
}

void DrawBar()
{
  std::vector<Entry> history;
  {
    std::lock_guard lk(s_mutex);
    const std::size_t n = std::min<std::size_t>(s_history.size(), 24);
    history.assign(s_history.begin(), s_history.begin() + static_cast<std::ptrdiff_t>(n));
  }
  if (history.empty())
    return;

  ImDrawList* dl = ImGui::GetForegroundDrawList();
  ImFont* font = ImGui::GetFont();
  const ImVec2 screen = ImGui::GetIO().DisplaySize;
  float px0 = 0, py0 = 0, pw = screen.x, ph = screen.y;
  if (g_presenter)
  {
    const auto& r = g_presenter->GetTargetRectangle();
    if (r.GetWidth() > 0 && r.GetHeight() > 0)
    {
      px0 = static_cast<float>(r.left);
      py0 = static_cast<float>(r.top);
      pw = static_cast<float>(r.GetWidth());
      ph = static_cast<float>(r.GetHeight());
    }
  }
  if (pw <= 0 || ph <= 0)
    return;

  // The strip: bottom centre of the game picture, above the netplay ping line.
  const float x0 = px0 + pw * 0.19f, x1 = px0 + pw * 0.81f;
  const float y0 = py0 + ph * 0.822f, y1 = py0 + ph * 0.898f;
  const float h = y1 - y0;
  const float pad = h * 0.1f;
  const float num_h = h * 0.3f;
  const float s = h * 0.5f;          // icon size
  const float gap = s * 0.12f;
  dl->AddRectFilled(ImVec2(x0, y0), ImVec2(x1, y1), IM_COL32(8, 8, 18, 140), h * 0.18f);

  float x = x0 + pad;
  for (std::size_t i = 0; i < history.size(); ++i)
  {
    const Entry& e = history[i];
    const bool newest = i == 0;
    const float alpha = newest ? 1.0f : std::max(0.4f, 1.0f - static_cast<float>(i) * 0.055f);

    std::vector<int> buttons;
    for (int b = 0; b < BTN_COUNT; ++b)
    {
      if (e.input.buttons & (1u << b))
        buttons.push_back(b);
    }
    const int count = 1 + static_cast<int>(buttons.size()) + (e.input.cdir != NEUTRAL) +
                      (e.input.dpad != NEUTRAL);
    const float icons_w = static_cast<float>(count) * s + static_cast<float>(count - 1) * gap;
    const std::string frames = e.frames > 999 ? std::string("999+") : fmt::format("{}", e.frames);
    const float text_w = TextSize(font, num_h, frames.c_str()).x;
    const float cw = std::max(icons_w, text_w) + pad * 2;
    if (x + cw > x1 - pad * 0.5f)
      break;  // older inputs don't fit

    if (newest)
    {
      dl->AddRectFilled(ImVec2(x, y0 + pad * 0.4f), ImVec2(x + cw, y1 - pad * 0.4f),
                        IM_COL32(255, 255, 255, 26), h * 0.12f);
    }
    CenteredText(dl, font, ImVec2(x + cw / 2, y0 + pad * 0.5f + num_h / 2), cw, num_h,
                 newest ? IM_COL32(255, 222, 80, 255) : IM_COL32(235, 235, 242, 255),
                 frames.c_str(), alpha, true);

    const float iy = y1 - pad - s;
    float ix = x + (cw - icons_w) / 2;
    DrawDirection(dl, ImVec2(ix + s / 2, iy + s / 2), s / 2, e.input.dir, alpha, newest);
    ix += s + gap;
    for (const int b : buttons)
    {
      DrawButton(dl, font, b, ImVec2(ix, iy), s, alpha);
      ix += s + gap;
    }
    if (e.input.cdir != NEUTRAL)
    {
      DrawCStick(dl, ImVec2(ix + s / 2, iy + s / 2), s / 2, e.input.cdir, alpha);
      ix += s + gap;
    }
    if (e.input.dpad != NEUTRAL)
      DrawDpad(dl, ImVec2(ix + s / 2, iy + s / 2), s / 2, e.input.dpad, alpha);

    x += cw;
    if (x < x1 - pad)
    {
      dl->AddLine(ImVec2(x, y0 + pad), ImVec2(x, y1 - pad), IM_COL32(255, 255, 255, 40),
                  std::max(1.0f, h * 0.02f));
    }
  }
}

// Video backend shutdown (g_gfx still exists): free the icons.
void FreeIcons()
{
  for (Icon& icon : s_icons)
  {
    icon.texture.reset();
    icon.path.clear();
  }
  s_refresh_now = true;
}
}  // namespace

void InitInputDisplay(bool enabled)
{
  s_enabled = enabled;
  g_sparking_pad_observer = &OnPad;
  g_sparking_texture_decoded = &OnTextureDecoded;
  OSD::SetCustomShutdownCallback(FreeIcons);
  // Deliberately never destroyed (same reason as the core state hook).
  static auto* const hook = new Common::EventHook(
      Core::System::GetInstance().GetVideoEvents().vi_end_field_event.Register([] { OnField(); }));
  (void)hook;
}

void SetInputDisplayEnabled(bool enabled)
{
  s_enabled = enabled;
  Emit("input_display", Json().Add("enabled", enabled));
}

bool InputDisplayEnabled()
{
  return s_enabled;
}

void ClearInputDisplay()
{
  std::lock_guard lk(s_mutex);
  s_history.clear();
  s_have_latest = false;
  s_latest = {};
}

void LoadInputDisplay(const std::string& game_id, unsigned revision)
{
  ClearInputDisplay();
  std::array<std::vector<std::string>, BTN_COUNT> names;
  // The local game ini replaces a bundled key.
  for (const Common::IniFile& ini :
       {SConfig::LoadDefaultGameIni(game_id, static_cast<u16>(revision)),
        SConfig::LoadLocalGameIni(game_id, static_cast<u16>(revision))})
  {
    const auto* section = ini.GetSection("Sparking.ButtonIcons");
    if (!section)
      continue;
    for (const auto& [key, value] : section->GetValues())
    {
      for (int b = 0; b < BTN_COUNT; ++b)
      {
        std::string k = key, want = BUTTON_KEYS[b];
        Common::ToLower(&k);
        Common::ToLower(&want);
        if (k != want)
          continue;
        names[b].clear();
        for (const std::string& part : SplitString(value, ','))
        {
          const std::string name(StripWhitespace(part));
          if (!name.empty())
            names[b].push_back(name);
        }
      }
    }
  }
  std::lock_guard lk(s_names_mutex);
  s_names = names;
  s_game_id = game_id;
  s_wanted.clear();
  s_dims.clear();
  for (const auto& list : names)
  {
    for (const std::string& name : list)
    {
      s_wanted.insert(name);
      // "tex1_32x32_..." -> 32 x 32
      const auto parts = SplitString(name, '_');
      if (parts.size() < 2)
        continue;
      const auto size = SplitString(parts[1], 'x');
      u32 w = 0, h = 0;
      if (size.size() == 2 && TryParse(size[0], &w) && TryParse(size[1], &h))
        s_dims.insert({w, h});
    }
  }
  s_refresh_now = true;
}

void EmitInputHistory()
{
  std::vector<std::string> items;
  {
    std::lock_guard lk(s_mutex);
    for (const Entry& e : s_history)
    {
      std::vector<std::string> buttons;
      for (int b = 0; b < BTN_COUNT; ++b)
      {
        if (e.input.buttons & (1u << b))
          buttons.push_back(Json::Escape(BUTTON_KEYS[b]));
      }
      items.push_back(Json()
                          .Add("dir", e.input.dir)
                          .Add("c", e.input.cdir)
                          .Add("dpad", e.input.dpad)
                          .AddRaw("buttons", JsonArray(buttons))
                          .Add("frames", static_cast<int>(e.frames))
                          .Str());
    }
  }
  Emit("input_history", Json().Add("enabled", s_enabled.load()).AddRaw("entries", JsonArray(items)));
}

void DrawInputDisplay()
{
  if (!s_enabled)
    return;
  if (s_refresh_now.exchange(false) || --s_refresh_in <= 0)
  {
    RefreshIcons();
    s_refresh_in = 60;
  }
  DrawBar();
}
}  // namespace Sparking
