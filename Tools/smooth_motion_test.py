#!/usr/bin/env python3
"""Smooth Motion test: runs a GameCube program that shows a moving scene at 30 fps (a new picture
every other video field, like Budokai Tenkaichi 3's battles) with Smooth Motion on, saves every
picture Dolphin would show (SPARKING_SMOOTH_DUMP) and checks the in-between ones against the true
halfway pictures.

    python3 Tools/smooth_motion_test.py <dolphin-emu-nogui> [out_dir]

Needs a Vulkan driver; without a GPU, SwiftShader works (set VK_ICD_FILENAMES to its
vk_swiftshader_icd.json, e.g. the one inside Playwright's Chromium).

The scene (640 x 240, drawn here in Python, flipped through by the program):
  - a striped, textured background scrolling left 6 px per frame
  - a still "HUD" bar in the top left (must stay sharp, not dragged along)
  - a detailed box moving right 10 px and down 2 px per frame
  - frame CUT is a different scene (a cut: no ghostly mix of both)
"""
import glob
import os
import shutil
import struct
import subprocess
import sys
import tempfile
import time

import numpy as np
from PIL import Image

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "gecko"))
from asm import Prog, D, li, lis, ori, addi, cmpw, cmplw, mr  # noqa: E402

W, H = 640, 240
FRAMES = 16
CUT = 12
FRAME_STRIDE = 0x4B000                 # 640 * 240 * 2 bytes (YUYV)
FRAME_BASE = 0x80100000


_RNG = np.random.default_rng(7)
# A detailed background (noise, lightly blurred: sharp enough that a plain 50/50 mix of two
# frames shows it twice).
_TEX = _RNG.integers(0, 256, (H, W * 2, 3)).astype(np.float32)
_TEX = (_TEX + np.roll(_TEX, 1, 1) + np.roll(_TEX, 1, 0) + np.roll(_TEX, (1, 1), (0, 1))) / 4

# The box's own picture: bright, with its own detail.
_BOX = np.stack([np.full((56, 72), 230.0), 120 + 0.5 * (_TEX[:56, :72, 1] - 128) * 1.5,
                 40 + 0.3 * _TEX[:56, :72, 2]], -1)


def scene(t):
    """RGB picture at time t (in frames; t + 0.5 = the true in-between picture)."""
    y, x = np.mgrid[0:H, 0:W]
    if t == CUT:
        img = np.stack([np.full((H, W), 40.0), 90 + 60 * np.sin(x / 23.0), np.full((H, W), 160.0)], -1)
        return np.clip(img, 0, 255).astype(np.uint8)
    shift = int(round(6 * t))
    img = _TEX[:, shift:shift + W].copy()
    bx, by = int(round(60 + 10 * t)), int(round(110 + 2 * t))
    inside = (x >= bx) & (x < bx + 72) & (y >= by) & (y < by + 56)
    bxy = (np.clip(y - by, 0, 55), np.clip(x - bx, 0, 71))
    box = _BOX[bxy]
    img = np.where(inside[..., None], box, img)
    hud = (x >= 24) & (x < 260) & (y >= 12) & (y < 34)
    hud_c = np.stack([30 + 0 * x, 200 + 50 * ((x // 12) % 2), 60 + 0 * x], -1).astype(np.float32)
    img = np.where(hud[..., None], hud_c, img)
    return np.clip(img, 0, 255).astype(np.uint8)


def to_yuyv(rgb):
    r, g, b = [rgb[..., i].astype(np.float32) for i in range(3)]
    yy = 16 + 0.257 * r + 0.504 * g + 0.098 * b
    uu = 128 - 0.148 * r - 0.291 * g + 0.439 * b
    vv = 128 + 0.439 * r - 0.368 * g - 0.071 * b
    out = np.empty((H, W * 2), np.uint8)
    out[:, 0::4] = np.clip(yy[:, 0::2], 0, 255)
    out[:, 1::4] = np.clip((uu[:, 0::2] + uu[:, 1::2]) / 2, 0, 255)
    out[:, 2::4] = np.clip(yy[:, 1::2], 0, 255)
    out[:, 3::4] = np.clip((vv[:, 0::2] + vv[:, 1::2]) / 2, 0, 255)
    return out.tobytes()


def make_dol(path):
    def sth(r, d, ra): return D(44, r, ra, d)
    def lhz(r, d, ra): return D(40, r, ra, d)

    p = Prog()
    p(lis(1, 0x8000)); p(ori(1, 1, 0x4000))
    p(lis(3, 0xCC00)); p(ori(3, 3, 0x2000))          # VI registers
    p(li(4, (240 << 4) | 6)); p(sth(4, 0x00, 3))       # 240 active lines per field
    p(li(4, (40 << 8) | 40)); p(sth(4, 0x48, 3))       # 640 px wide, stride 640
    p(li(5, 0))                                        # frame number
    p(lis(9, (FRAME_BASE & 0x01FFFFFF) >> 16))         # physical address of frame 0
    p(mr(6, 9))
    p.label("frame")
    # Both fields show this frame (top and bottom XFB address).
    p(D(21, 6, 4, (16 << 11) | (16 << 6) | (31 << 1)))  # rlwinm r4,r6,16,16,31 (high half)
    p(sth(4, 0x1C, 3)); p(sth(6, 0x1E, 3))
    p(sth(4, 0x24, 3)); p(sth(6, 0x26, 3))
    # Wait for the beam to wrap (once per video frame = 2 fields): 30 pictures a second.
    p(lhz(7, 0x2C, 3))
    p.label("wait")
    p(lhz(8, 0x2C, 3))
    p(cmplw(8, 7))
    p(mr(7, 8))
    p.bc("ge", "wait")
    p(addi(5, 5, 1))
    p(lis(10, FRAME_STRIDE >> 16)); p(ori(10, 10, FRAME_STRIDE & 0xFFFF))
    p((31 << 26) | (6 << 21) | (6 << 16) | (10 << 11) | (266 << 1))  # add r6,r6,r10
    p(cmpwi_(5, FRAMES))
    p.bc("lt", "frame")
    p(li(5, 0)); p(mr(6, 9))
    p.b("frame")
    code = b"".join(struct.pack(">I", w) for w in p.words())

    data = b"".join(to_yuyv(scene(i)) for i in range(FRAMES))
    header = bytearray(0x100)
    text_off = 0x100
    data_off = text_off + len(code)
    struct.pack_into(">I", header, 0x00, text_off)
    struct.pack_into(">I", header, 0x48, 0x80003100)
    struct.pack_into(">I", header, 0x90, len(code))
    struct.pack_into(">I", header, 0x1C, data_off)
    struct.pack_into(">I", header, 0x64, FRAME_BASE)
    struct.pack_into(">I", header, 0xAC, len(data))
    struct.pack_into(">I", header, 0xD8, 0x80005000)
    struct.pack_into(">I", header, 0xDC, 0)
    struct.pack_into(">I", header, 0xE0, 0x80003100)
    with open(path, "wb") as f:
        f.write(bytes(header) + code + data)


def cmpwi_(ra, i):
    return D(11, 0, ra, i)


def psnr(a, b):
    mse = np.mean((a.astype(np.float32) - b.astype(np.float32)) ** 2)
    return 99.0 if mse == 0 else 10 * np.log10(255.0 ** 2 / mse)


def main():
    exe = os.path.abspath(sys.argv[1])
    out = os.path.abspath(sys.argv[2]) if len(sys.argv) > 2 else tempfile.mkdtemp(prefix="smooth-")
    work = tempfile.mkdtemp(prefix="smooth-work-")
    dump = os.path.join(out, "dump")
    shutil.rmtree(dump, ignore_errors=True)
    os.makedirs(dump)
    dol = os.path.join(work, "scene.dol")
    make_dol(dol)
    env = dict(os.environ, SPARKING_SMOOTH_DUMP=dump)
    scale = os.environ.get("SMOOTH_SCALE", "2")
    cmd = [exe, "-p", "headless", "-v", "Vulkan", "--sparking", "-u", os.path.join(work, "user"),
           "--nand", os.path.join(work, "nand"), "--resolution", scale, "--smooth-motion", "on",
           "-e", dol]
    os.makedirs(os.path.join(work, "user", "Config"))
    proc = subprocess.Popen(cmd, env=env, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                            stderr=subprocess.STDOUT, text=True)
    deadline = time.time() + float(os.environ.get("SMOOTH_SECONDS", "90"))
    while time.time() < deadline and len(glob.glob(os.path.join(dump, "*.png"))) < 140:
        time.sleep(1)
        if proc.poll() is not None:
            break
    proc.kill()
    log = proc.communicate()[0]
    shots = sorted(glob.glob(os.path.join(dump, "*.png")))[:-1]  # (the last may be half written)
    print(f"{len(shots)} pictures shown")
    if not shots:
        print(log[-3000:])
        print("SMOOTH MOTION TEST FAILED")
        return 1

    # Which scene frame is each "new" picture? (best match against the true frames)
    truth = [scene(i) for i in range(FRAMES)]
    small = lambda f: np.asarray(Image.open(f).convert("RGB").resize((W, H), Image.BILINEAR))
    kinds = [os.path.basename(s).split("_")[1][:-4] for s in shots]
    failures = []
    seq = "".join({"mid": "m", "new": "n", "same": "s"}[k] for k in kinds)
    print("sequence:", seq)
    # Steady 30 fps: after warm-up every new frame is preceded by its in-between picture.
    steady = seq[10:]
    if "mid" not in kinds:
        failures.append("no in-between pictures at all")
    if "ns" in steady or "nn" in steady:
        failures.append("new frames shown without an in-between picture (cadence not detected)")

    report = []
    for i, (f, k) in enumerate(zip(shots, kinds)):
        if k != "mid" or i + 1 >= len(shots):
            continue
        # The picture after an in-between one is the new frame it leads to.
        nxt = small(shots[i + 1])
        n = int(np.argmax([psnr(nxt, t) for t in truth]))
        if n == 0 or n == CUT or n == CUT + 1:
            continue  # wrap-around or the cut: checked separately
        mid = small(f)
        true_mid = scene(n - 0.5)
        blend = ((truth[n - 1].astype(np.float32) + truth[n]) / 2).astype(np.uint8)
        p_mid, p_blend = psnr(mid, true_mid), psnr(blend, true_mid)
        hud = (slice(12, 34), slice(24, 260))
        p_hud = psnr(mid[hud], true_mid[hud])
        bx, by = int(round(60 + 10 * (n - 0.5))), int(round(110 + 2 * (n - 0.5)))
        box = (slice(by + 4, by + 52), slice(bx + 4, bx + 68))
        p_box = psnr(mid[box], true_mid[box])
        floor = psnr(nxt, truth[n])   # how close a real frame gets (YUV color loss)
        report.append((n, p_mid, p_blend, p_hud, p_box, floor))
        if len(report) == 1:
            Image.fromarray(np.concatenate([truth[n - 1], mid, truth[n], blend], 0)).save(
                os.path.join(out, "example_prev_mid_new_plainblend.png"))
    for n, p_mid, p_blend, p_hud, p_box, floor in report[:8]:
        print(f"  frame {n:2}: in-between {p_mid:5.1f} dB vs true halfway (plain 50/50 mix "
              f"{p_blend:5.1f}, a real frame {floor:5.1f}), HUD {p_hud:5.1f}, box {p_box:5.1f}")
    if not report:
        failures.append("no in-between pictures to check")
    else:
        avg = np.mean([r[1] for r in report])
        avg_blend = np.mean([r[2] for r in report])
        hud = np.min([r[3] for r in report])
        box = np.mean([r[4] for r in report])
        floor = np.mean([r[5] for r in report])
        print(f"average: {avg:.1f} dB (plain mix {avg_blend:.1f}, real frames {floor:.1f}), "
              f"worst HUD {hud:.1f}, box {box:.1f}")
        if avg < avg_blend + 4:
            failures.append("in-between pictures not clearly better than a plain mix")
        if avg < floor - 4:
            failures.append("in-between pictures far from the real frames' quality")
        if box < 18:
            failures.append("the moving box is broken up")
        if hud < 30:
            failures.append("HUD not kept still")

    # The cut: the in-between picture before the cut frame must be the cut frame, not a mix.
    for i, k in enumerate(kinds):
        if k == "mid" and i + 1 < len(shots):
            nxt = small(shots[i + 1])
            if int(np.argmax([psnr(nxt, t) for t in truth])) == CUT:
                p = psnr(small(shots[i]), truth[CUT])
                print(f"  cut: in-between vs the new scene {p:.1f} dB")
                if p < 25:
                    failures.append("a cut shows a mix of both scenes")
                break

    for f in failures:
        print("FAIL", f)
    print("SMOOTH MOTION TEST " + ("FAILED" if failures else "PASSED"))
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
