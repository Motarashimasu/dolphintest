// Copyright 2026 Dolphin-Sparking
// SPDX-License-Identifier: GPL-2.0-or-later

#pragma once

#include <array>
#include <memory>
#include <string>

#include "Common/CommonTypes.h"
#include "Common/MathUtil.h"

class AbstractFramebuffer;
class AbstractPipeline;
class AbstractShader;
class AbstractTexture;

namespace VideoCommon
{
// Smooth Motion: frame interpolation for games that run at half the video rate (30 fps on a 60 Hz
// signal, 25 on 50). When a new game frame arrives, an in-between frame is shown first and the new
// frame one video field later, so the screen changes every field. That costs one field (~17 ms)
// of extra delay, and is only done while the game keeps a steady half-rate; full-rate frames
// (60 fps menus) are shown as they are.
//
// The in-between frame is made on the GPU from native-resolution copies of the two frames:
//   1. coarse motion, on 1/4 size copies (fine repeating patterns can't fool it): per 16x16
//      block, the motion v that best matches previous(p - v/2) with new(p + v/2) over the 32x32
//      pixels around it (search over +-32 px, plus last time's motion)
//   2. fine motion: per 8x8 block, the coarse answers refined by up to 3 px
//   3. select: per pixel, the best of its own block's motion, its 8 neighbours' and "still"
//      (still pictures in front of moving ones, e.g. the HUD, keep "still")
//   4. blend: at full resolution, the average of both frames along the chosen motion; where
//      nothing matches (cuts, flashes, things appearing) the new frame is used instead
// Presentation only: nothing here touches emulation, so netplay is unaffected.
class SmoothMotion
{
public:
  SmoothMotion();
  ~SmoothMotion();

  struct Output
  {
    const AbstractTexture* texture = nullptr;  // nullptr = show the XFB as it is
    MathUtil::Rectangle<int> rect;
    bool interpolated = false;
  };

  // Called on every video field (VI swap). `source`/`rect`: the XFB to show; `native_width/height`:
  // its size in the game's own pixels; `fresh`: a new frame from the game (not a repeat).
  // Must be called inside BeginUtilityDrawing / EndUtilityDrawing.
  Output Process(const AbstractTexture* source, const MathUtil::Rectangle<int>& rect,
                 u32 native_width, u32 native_height, bool fresh);

  // Forget the frame history (e.g. after it was turned off, or a non-field swap).
  void Reset();

private:
  struct Target
  {
    std::unique_ptr<AbstractTexture> texture;
    std::unique_ptr<AbstractFramebuffer> framebuffer;
  };
  enum Pass
  {
    CAPTURE_PASS,
    SHRINK_PASS,
    COARSE_PASS,
    FINE_PASS,
    SELECT_PASS,
    BLEND_PASS,
    NUM_PASSES
  };

  bool EnsureResources(u32 width, u32 height, u32 native_width, u32 native_height);
  bool CompileShaders();
  bool MakeTarget(Target* target, u32 width, u32 height, bool is_float, const char* name);
  void Draw(const Target& target, int pass, const void* uniforms, u32 uniforms_size);
  void Capture(const AbstractTexture* source, const MathUtil::Rectangle<int>& rect);
  void Interpolate();
  void DebugDump(const Output& output, bool fresh);

  bool m_failed = false;
  std::unique_ptr<AbstractShader> m_vertex_shader;
  std::array<std::unique_ptr<AbstractShader>, NUM_PASSES> m_shaders;
  std::array<std::unique_ptr<AbstractPipeline>, NUM_PASSES> m_pipelines;

  std::array<Target, 2> m_frames;  // full resolution: previous / newest (m_newest)
  std::array<Target, 2> m_small;   // the same at the game's own resolution
  std::array<Target, 2> m_tiny;    // ... and at 1/4 of that
  std::array<Target, 2> m_coarse;  // coarse motion: this time's / last time's (m_coarse_index)
  Target m_fine;                   // fine motion
  Target m_vectors;                // per native pixel: the chosen motion
  Target m_blend;                  // full resolution: the in-between frame

  u32 m_width = 0;
  u32 m_height = 0;
  u32 m_native_width = 0;
  u32 m_native_height = 0;
  int m_newest = 0;
  int m_coarse_index = 0;
  bool m_have_motion = false;
  int m_frame_count = 0;  // frames in the history (0..2)
  int m_fields_since_new = 1000;

  std::string m_dump_dir;  // SPARKING_SMOOTH_DUMP: save every shown frame as a PNG (testing)
  u32 m_dump_index = 0;
};
}  // namespace VideoCommon
