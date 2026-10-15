// Copyright 2026 Dolphin-Sparking
// SPDX-License-Identifier: GPL-2.0-or-later

#include "VideoCommon/SparkingSmoothMotion.h"

#include <algorithm>
#include <cstdlib>
#include <initializer_list>
#include <string_view>

#include <fmt/format.h>

#include "Common/CommonTypes.h"
#include "Common/FileUtil.h"
#include "Common/Logging/Log.h"
#include "VideoCommon/AbstractFramebuffer.h"
#include "VideoCommon/AbstractGfx.h"
#include "VideoCommon/AbstractPipeline.h"
#include "VideoCommon/AbstractShader.h"
#include "VideoCommon/AbstractTexture.h"
#include "VideoCommon/RenderState.h"
#include "VideoCommon/VertexManagerBase.h"
#include "VideoCommon/VideoConfig.h"

namespace VideoCommon
{
namespace
{
// Sizes in the game's own pixels.
constexpr u32 FINE_BLOCK = 8;     // fine motion: one vector per 8x8 block
constexpr u32 COARSE_BLOCK = 16;  // coarse motion: one per 16x16, found on a 1/4 size picture
constexpr u32 TINY = 4;           // the 1/4 size picture

constexpr u32 DivUp(u32 a, u32 b)
{
  return (a + b - 1) / b;
}

struct Uniforms
{
  float src_rect[4];  // capture: the XFB rectangle in the source texture (uv x, y, w, h)
  float px[4];        // one native pixel in uv (x, y), native size (z, w)
  float fine[4];      // fine grid size (x, y) and its inverse (z, w)
  float coarse[4];    // coarse grid size (x, y) and its inverse (z, w)
  float shrink[4];    // shrink: the 4 taps' offset in the source (uv x, y)
  s32 src_layer;
  s32 flip_y;
  s32 use_last;  // coarse pass: last time's motion is there to reuse
  s32 pad;
};
static_assert(sizeof(Uniforms) == 96);

constexpr std::string_view UNIFORMS = R"(
UBO_BINDING(std140, 1) uniform PSBlock {
  float4 src_rect;
  float4 px;
  float4 fine;
  float4 coarse;
  float4 shrink;
  int src_layer;
  int flip_y;
  int use_last;
  int pad;
};
)";

constexpr std::string_view VERTEX = R"(
VARYING_LOCATION(0) out float2 v_uv;
void main()
{
  float2 t = float2(float((gl_VertexID << 1) & 2), float(gl_VertexID & 2));
  v_uv = t;
  gl_Position = float4(t * float2(2.0, -2.0) + float2(-1.0, 1.0), 0.0, 1.0);
  if (flip_y != 0)
    gl_Position.y = -gl_Position.y;
}
)";

constexpr std::string_view PIXEL_HEADER = R"(
SAMPLER_BINDING(0) uniform sampler2DArray samp0;
SAMPLER_BINDING(1) uniform sampler2DArray samp1;
SAMPLER_BINDING(2) uniform sampler2DArray samp2;
VARYING_LOCATION(0) in float2 v_uv;
FRAGMENT_OUTPUT_LOCATION(0) out float4 ocol0;

float3 Prev(float2 uv) { return textureLod(samp0, float3(uv, 0.0), 0.0).rgb; }
float3 Next(float2 uv) { return textureLod(samp1, float3(uv, 0.0), 0.0).rgb; }
float4 Field(float2 uv) { return textureLod(samp2, float3(uv, 0.0), 0.0); }
float Diff(float3 a, float3 b) { float3 d = abs(a - b); return d.r + d.g + d.b; }

// How well previous(p - v/2) matches new(p + v/2) over size x size samples `step` native pixels
// apart around c (mean difference per color channel), plus a small cost for moving.
float Cost(float2 c, float2 v, int size, float step)
{
  float2 h = 0.5 * v * px.xy;
  float s = 0.0;
  float mid = (float(size) - 1.0) * 0.5;
  for (int y = 0; y < size; y++)
  {
    for (int x = 0; x < size; x++)
    {
      float2 o = (float2(float(x), float(y)) - mid) * step * px.xy;
      s += Diff(Prev(c + o - h), Next(c + o + h));
    }
  }
  return s / (3.0 * float(size * size)) + 0.0015 * length(v);
}
)";

// The XFB (one layer of it) copied as it is.
constexpr std::string_view CAPTURE = R"(
void main()
{
  float2 uv = src_rect.xy + v_uv * src_rect.zw;
  ocol0 = float4(textureLod(samp0, float3(uv, float(src_layer)), 0.0).rgb, 1.0);
}
)";

// A smaller copy: 4 bilinear taps (a small box filter).
constexpr std::string_view SHRINK = R"(
void main()
{
  float2 q = shrink.xy;
  float3 c = Prev(v_uv + float2(-q.x, -q.y)) + Prev(v_uv + float2(q.x, -q.y)) +
             Prev(v_uv + float2(-q.x, q.y)) + Prev(v_uv + float2(q.x, q.y));
  ocol0 = float4(c * 0.25, 1.0);
}
)";

// Coarse motion (1/4 size pictures, so fine repeating patterns are smoothed away and can't
// fool it): per 16x16 block, the motion v (native pixels, previous -> new) that best matches
// previous(p - v/2) with new(p + v/2) over the 32x32 pixels around it. A 4 px search over
// +-32 px, plus last time's motion here and next door (keeps up with fast, steady motion),
// then a 2 px refinement.
constexpr std::string_view COARSE = R"(
void main()
{
  float2 c = v_uv * coarse.xy * 16.0 * px.xy;  // the block's middle, in uv
  float2 best = float2(0.0, 0.0);
  float best_cost = Cost(c, best, 8, 4.0);
  for (int y = -8; y <= 8; y++)
  {
    for (int x = -8; x <= 8; x++)
    {
      float2 v = float2(float(x), float(y)) * 4.0;
      float k = Cost(c, v, 8, 4.0);
      if (k < best_cost)
      {
        best_cost = k;
        best = v;
      }
    }
  }
  if (use_last != 0)
  {
    for (int i = 0; i < 5; i++)
    {
      float2 d = i == 0 ? float2(0.0, 0.0) :
                 i == 1 ? float2(-1.0, 0.0) :
                 i == 2 ? float2(1.0, 0.0) :
                 i == 3 ? float2(0.0, -1.0) : float2(0.0, 1.0);
      float2 v = Field(clamp(v_uv + d * coarse.zw, coarse.zw * 0.5, 1.0 - coarse.zw * 0.5)).xy;
      float k = Cost(c, v, 8, 4.0);
      if (k < best_cost)
      {
        best_cost = k;
        best = v;
      }
    }
  }
  float2 around = best;
  for (int y = -1; y <= 1; y++)
  {
    for (int x = -1; x <= 1; x++)
    {
      float2 v = around + float2(float(x), float(y)) * 2.0;
      float k = Cost(c, v, 8, 4.0);
      if (k < best_cost)
      {
        best_cost = k;
        best = v;
      }
    }
  }
  ocol0 = float4(best, best_cost, 0.0);
}
)";

// Fine motion (native size pictures): per 8x8 block, starting from the coarse motion of the 4
// nearest coarse blocks (and "still"), refined in 2 and 1 px steps over the 16x16 pixels
// around it. Never more than 3 px from a coarse answer, so it can't slip a whole pattern.
constexpr std::string_view FINE = R"(
void main()
{
  float2 c = v_uv * fine.xy * 8.0 * px.xy;
  float2 cc = c * px.zw / 16.0 - 0.5;  // position on the coarse grid (cell middles at .0)
  float2 base = floor(cc);
  float2 best = float2(0.0, 0.0);
  float best_cost = Cost(c, best, 8, 2.0);
  for (int i = 0; i < 4; i++)
  {
    float2 cell = base + float2(float(i & 1), float(i >> 1));
    float2 tc = clamp((cell + 0.5) * coarse.zw, coarse.zw * 0.5, 1.0 - coarse.zw * 0.5);
    float2 v = Field(tc).xy;
    float k = Cost(c, v, 8, 2.0);
    if (k < best_cost)
    {
      best_cost = k;
      best = v;
    }
  }
  for (int pass = 0; pass < 2; pass++)
  {
    float step = pass == 0 ? 2.0 : 1.0;
    float2 around = best;
    for (int y = -1; y <= 1; y++)
    {
      for (int x = -1; x <= 1; x++)
      {
        float2 v = around + float2(float(x), float(y)) * step;
        float k = Cost(c, v, 8, 2.0);
        if (k < best_cost)
        {
          best_cost = k;
          best = v;
        }
      }
    }
  }
  ocol0 = float4(best, best_cost, 0.0);
}
)";

// Per native pixel: the best of its block's motion, the 8 neighbouring blocks' and "still",
// judged on the 3x3 pixels around it (things in front of moving ones, e.g. the HUD, stay still).
constexpr std::string_view SELECT = R"(
void main()
{
  float2 p = v_uv;
  float2 cell = floor(p * px.zw / 8.0);
  float2 best = float2(0.0, 0.0);
  float best_cost = Cost(p, best, 3, 1.0) - 0.004;
  for (int y = -1; y <= 1; y++)
  {
    for (int x = -1; x <= 1; x++)
    {
      float2 tc = clamp((cell + float2(float(x), float(y)) + 0.5) * fine.zw, fine.zw * 0.5,
                        1.0 - fine.zw * 0.5);
      float2 v = Field(tc).xy;
      float k = Cost(p, v, 3, 1.0);
      if (k < best_cost)
      {
        best_cost = k;
        best = v;
      }
    }
  }
  ocol0 = float4(best, max(best_cost, 0.0), 0.0);
}
)";

// Full resolution: both frames met halfway along the chosen motion. Where nothing matched
// (a cut, a flash, something appearing) the new frame is shown instead of a ghostly mix.
constexpr std::string_view BLEND = R"(
void main()
{
  float4 m = Field(v_uv);
  float2 h = 0.5 * m.xy * px.xy;
  float3 mid = 0.5 * (Prev(v_uv - h) + Next(v_uv + h));
  float3 now = Next(v_uv);
  float bad = smoothstep(0.05, 0.12, m.z);
  ocol0 = float4(mix(mid, now, bad), 1.0);
}
)";

void Bind(std::initializer_list<const AbstractTexture*> textures)
{
  u32 i = 0;
  for (const AbstractTexture* t : textures)
  {
    g_gfx->SetTexture(i, t);
    // The motion fields (slot 2) are read texel by texel; pictures smoothly.
    g_gfx->SetSamplerState(i, i == 2 ? RenderState::GetPointSamplerState() :
                                       RenderState::GetLinearSamplerState());
    ++i;
  }
}

void UnbindAll()
{
  for (u32 i = 0; i < 3; ++i)
    g_gfx->SetTexture(i, nullptr);
}

void SetGrid(float* out, u32 native_width, u32 native_height, u32 block)
{
  const float w = static_cast<float>(DivUp(native_width, block));
  const float h = static_cast<float>(DivUp(native_height, block));
  out[0] = w;
  out[1] = h;
  out[2] = 1.0f / w;
  out[3] = 1.0f / h;
}

s32 FlipY()
{
  // Same as the post-processing passes into intermediate textures.
  return (g_backend_info.api_type == APIType::Vulkan ||
          g_backend_info.api_type == APIType::OpenGL) ?
             1 :
             0;
}
}  // namespace

SmoothMotion::SmoothMotion()
{
  if (const char* dir = std::getenv("SPARKING_SMOOTH_DUMP"); dir && *dir)
  {
    m_dump_dir = dir;
    File::CreateFullPath(m_dump_dir + "/");
  }
}

SmoothMotion::~SmoothMotion() = default;

void SmoothMotion::Reset()
{
  m_have_motion = false;
  m_frame_count = 0;
  m_fields_since_new = 1000;
}

bool SmoothMotion::CompileShaders()
{
  const std::string uniforms(UNIFORMS);
  m_vertex_shader = g_gfx->CreateShaderFromSource(
      ShaderStage::Vertex, uniforms + std::string(VERTEX), nullptr, "Smooth Motion vertex shader");
  auto pixel = [&](std::string_view body, const char* name) {
    return g_gfx->CreateShaderFromSource(
        ShaderStage::Pixel, uniforms + std::string(PIXEL_HEADER) + std::string(body), nullptr,
        name);
  };
  m_shaders[CAPTURE_PASS] = pixel(CAPTURE, "Smooth Motion capture");
  m_shaders[SHRINK_PASS] = pixel(SHRINK, "Smooth Motion shrink");
  m_shaders[COARSE_PASS] = pixel(COARSE, "Smooth Motion coarse motion");
  m_shaders[FINE_PASS] = pixel(FINE, "Smooth Motion fine motion");
  m_shaders[SELECT_PASS] = pixel(SELECT, "Smooth Motion select");
  m_shaders[BLEND_PASS] = pixel(BLEND, "Smooth Motion blend");
  if (!m_vertex_shader)
    return false;

  for (int i = 0; i < NUM_PASSES; ++i)
  {
    if (!m_shaders[i])
      return false;
    const bool motion = i == COARSE_PASS || i == FINE_PASS || i == SELECT_PASS;
    AbstractPipelineConfig config = {};
    config.vertex_shader = m_vertex_shader.get();
    config.pixel_shader = m_shaders[i].get();
    config.rasterization_state = RenderState::GetNoCullRasterizationState(PrimitiveType::Triangles);
    config.depth_state = RenderState::GetNoDepthTestingDepthState();
    config.blending_state = RenderState::GetNoBlendingBlendState();
    config.framebuffer_state = RenderState::GetColorFramebufferState(
        motion ? AbstractTextureFormat::RGBA16F : AbstractTextureFormat::RGBA8);
    config.usage = AbstractPipelineUsage::Utility;
    m_pipelines[i] = g_gfx->CreatePipeline(config);
    if (!m_pipelines[i])
      return false;
  }
  return true;
}

bool SmoothMotion::MakeTarget(Target* target, u32 width, u32 height, bool is_float,
                              const char* name)
{
  const TextureConfig config(width, height, 1, 1, 1,
                             is_float ? AbstractTextureFormat::RGBA16F :
                                        AbstractTextureFormat::RGBA8,
                             AbstractTextureFlag_RenderTarget, AbstractTextureType::Texture_2DArray);
  target->framebuffer.reset();
  target->texture = g_gfx->CreateTexture(config, name);
  if (!target->texture)
    return false;
  target->framebuffer = g_gfx->CreateFramebuffer(target->texture.get(), nullptr);
  return target->framebuffer != nullptr;
}

bool SmoothMotion::EnsureResources(u32 width, u32 height, u32 native_width, u32 native_height)
{
  if (m_failed)
    return false;
  if (!m_pipelines[NUM_PASSES - 1] && !CompileShaders())
  {
    ERROR_LOG_FMT(VIDEO, "Smooth Motion: shaders failed to compile; turned off");
    m_failed = true;
    return false;
  }
  if (m_width == width && m_height == height && m_native_width == native_width &&
      m_native_height == native_height)
  {
    return true;
  }

  Reset();
  m_width = m_height = 0;
  bool ok = true;
  for (int i = 0; i < 2; ++i)
  {
    ok &= MakeTarget(&m_frames[i], width, height, false, "Smooth Motion frame");
    ok &= MakeTarget(&m_small[i], native_width, native_height, false, "Smooth Motion small frame");
    ok &= MakeTarget(&m_tiny[i], DivUp(native_width, TINY), DivUp(native_height, TINY), false,
                     "Smooth Motion tiny frame");
    ok &= MakeTarget(&m_coarse[i], DivUp(native_width, COARSE_BLOCK),
                     DivUp(native_height, COARSE_BLOCK), true, "Smooth Motion coarse motion");
  }
  ok &= MakeTarget(&m_fine, DivUp(native_width, FINE_BLOCK), DivUp(native_height, FINE_BLOCK),
                   true, "Smooth Motion fine motion");
  ok &= MakeTarget(&m_vectors, native_width, native_height, true, "Smooth Motion vectors");
  ok &= MakeTarget(&m_blend, width, height, false, "Smooth Motion in-between frame");
  if (!ok)
  {
    ERROR_LOG_FMT(VIDEO, "Smooth Motion: could not create its textures; turned off");
    m_failed = true;
    return false;
  }
  m_width = width;
  m_height = height;
  m_native_width = native_width;
  m_native_height = native_height;
  return true;
}

void SmoothMotion::Draw(const Target& target, int pass, const void* uniforms, u32 uniforms_size)
{
  g_gfx->UnbindTexture(target.texture.get());
  g_gfx->SetAndDiscardFramebuffer(target.framebuffer.get());
  g_gfx->SetViewportAndScissor(
      g_gfx->ConvertFramebufferRectangle(target.texture->GetRect(), target.framebuffer.get()));
  g_gfx->SetPipeline(m_pipelines[pass].get());
  g_vertex_manager->UploadUtilityUniforms(uniforms, uniforms_size);
  g_gfx->Draw(0, 3);
}

void SmoothMotion::Interpolate()
{
  Uniforms u = {};
  u.px[0] = 1.0f / m_native_width;
  u.px[1] = 1.0f / m_native_height;
  u.px[2] = static_cast<float>(m_native_width);
  u.px[3] = static_cast<float>(m_native_height);
  SetGrid(u.fine, m_native_width, m_native_height, FINE_BLOCK);
  SetGrid(u.coarse, m_native_width, m_native_height, COARSE_BLOCK);
  u.flip_y = FlipY();
  const int prev = 1 - m_newest;
  const Target& coarse = m_coarse[m_coarse_index];
  const Target& last_coarse = m_coarse[1 - m_coarse_index];

  UnbindAll();
  u.use_last = m_have_motion ? 1 : 0;
  Bind({m_tiny[prev].texture.get(), m_tiny[m_newest].texture.get(), last_coarse.texture.get()});
  Draw(coarse, COARSE_PASS, &u, sizeof(u));
  u.use_last = 0;

  UnbindAll();
  Bind({m_small[prev].texture.get(), m_small[m_newest].texture.get(), coarse.texture.get()});
  Draw(m_fine, FINE_PASS, &u, sizeof(u));

  UnbindAll();
  Bind({m_small[prev].texture.get(), m_small[m_newest].texture.get(), m_fine.texture.get()});
  Draw(m_vectors, SELECT_PASS, &u, sizeof(u));

  UnbindAll();
  Bind({m_frames[prev].texture.get(), m_frames[m_newest].texture.get(), m_vectors.texture.get()});
  Draw(m_blend, BLEND_PASS, &u, sizeof(u));
  UnbindAll();

  m_coarse_index = 1 - m_coarse_index;
  m_have_motion = true;
}

void SmoothMotion::Capture(const AbstractTexture* source, const MathUtil::Rectangle<int>& rect)
{
  Uniforms u = {};
  u.src_rect[0] = static_cast<float>(rect.left) / source->GetWidth();
  u.src_rect[1] = static_cast<float>(rect.top) / source->GetHeight();
  u.src_rect[2] = static_cast<float>(rect.GetWidth()) / source->GetWidth();
  u.src_rect[3] = static_cast<float>(rect.GetHeight()) / source->GetHeight();
  u.flip_y = FlipY();

  // The XFB as it is (the game may reuse it), ...
  UnbindAll();
  g_gfx->SetTexture(0, source);
  g_gfx->SetSamplerState(0, RenderState::GetPointSamplerState());
  Draw(m_frames[m_newest], CAPTURE_PASS, &u, sizeof(u));

  // ... at the game's own size (taps a quarter native pixel out), ...
  UnbindAll();
  u.shrink[0] = 0.25f / m_native_width;
  u.shrink[1] = 0.25f / m_native_height;
  Bind({m_frames[m_newest].texture.get()});
  Draw(m_small[m_newest], SHRINK_PASS, &u, sizeof(u));

  // ... and at 1/4 of that (taps one native pixel out: a 4x4 average).
  UnbindAll();
  u.shrink[0] = 1.0f / m_native_width;
  u.shrink[1] = 1.0f / m_native_height;
  Bind({m_small[m_newest].texture.get()});
  Draw(m_tiny[m_newest], SHRINK_PASS, &u, sizeof(u));
  UnbindAll();
}

SmoothMotion::Output SmoothMotion::Process(const AbstractTexture* source,
                                           const MathUtil::Rectangle<int>& rect, u32 native_width,
                                           u32 native_height, bool fresh)
{
  Output out;
  const u32 width = static_cast<u32>(std::max(rect.GetWidth(), 1));
  const u32 height = static_cast<u32>(std::max(rect.GetHeight(), 1));
  native_width = std::clamp(native_width, 1u, width);
  native_height = std::clamp(native_height, 1u, height);
  if (!source || !EnsureResources(width, height, native_width, native_height))
    return out;

  m_fields_since_new = std::min(m_fields_since_new + 1, 1000);
  if (fresh || m_frame_count == 0)
  {
    const int interval = m_fields_since_new;
    m_fields_since_new = 0;
    m_newest = m_frame_count == 0 ? 0 : 1 - m_newest;
    m_frame_count = std::min(m_frame_count + 1, 2);
    Capture(source, rect);

    // A steady half-rate game: show the in-between frame now and this frame next field.
    if (interval != 2)
      m_have_motion = false;  // last time's motion only helps from one frame to the next
    if (m_frame_count == 2 && interval == 2)
    {
      Interpolate();
      out.texture = m_blend.texture.get();
      out.interpolated = true;
    }
  }

  if (!out.texture)
    out.texture = m_frames[m_newest].texture.get();
  out.rect = out.texture->GetRect();
  if (!m_dump_dir.empty())
    DebugDump(out, fresh);
  return out;
}

void SmoothMotion::DebugDump(const Output& output, bool fresh)
{
  const char* kind = output.interpolated ? "mid" : (fresh ? "new" : "same");
  output.texture->Save(fmt::format("{}/{:05}_{}.png", m_dump_dir, m_dump_index++, kind), 0, 1);
}
}  // namespace VideoCommon
