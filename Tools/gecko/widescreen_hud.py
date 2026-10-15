"""Widescreen HUD Gecko code for BT3 PAL (RDSPAF): life bars at the screen edges.

The game draws every battle-HUD sprite through two functions (textured 0x80108970, flat
0x80108384) that each set a 2D projection of 0..512 x 0..448 (PS2 coordinates) right before
drawing. The code widens that projection per sprite, only for sprites drawn by the battle HUD
(caller in the battle-only 2D modules, 0x80100000-0x80111000):
  - a sprite whose middle is left of the screen's middle keeps its true width, pinned to the
    left edge; one whose middle is right of it, pinned to the right edge;
  - one sitting on the middle line (within 16 px: the timer), centered at its true width;
  - full-width ones (400+ wide: flashes, fades) are left alone.
Usage: python3 widescreen_hud.py [squeeze]   (squeeze = game aspect / shown aspect; 16:9 = 0.75)
"""
from asm import *  # noqa: F403 (Tools/gecko/asm.py)
import sys
s=float(sys.argv[1]) if len(sys.argv)>1 else 0.75
W=512/s; W2=256/s
def hook(sreg, scratch):
    """At the draw function's `lfs f4, 512` (the ortho's right edge): f3 = left, f4 = right.
    sreg holds the sprite; scratch = a stack slot whose high word is already 0x43300000."""
    p=Prog()
    p(lfs(4,-0x6208,2))                       # (the replaced instruction)
    # Only battle 2D: the draw function's caller in the battle-only 2D modules, 0x80100000-0x80111000
    # (the HUD, its damage / flash effects, the combo counters; all set up when a fight starts).
    p(lwz(11,0,1)); p(lwz(11,4,11))
    p(lis(12,0x8010)); p(cmplw(11,12)); p.bc('lt','END')
    p(lis(12,0x8011)); p(ori(12,12,0x1000)); p(cmplw(11,12)); p.bc('ge','END')
    # Where the sprite lands on screen: the current matrix (the HUD mirrors P2's side with it)
    # applied to its corners: x' = m0*x + m4*y + m8*z + m12, z = -1.
    p(lwz(10,-0x6e7c,13))                     # current matrix (column-major 4x4)
    p(lfd(8,-0x6218,2))                       # int -> float magic
    def to_float(fd, off):
        p(lha(11,off,sreg)); p(xoris(11,11,0x8000)); p(stw(11,scratch+4,1))
        p(lfd(fd,scratch,1)); p(fsubs(fd,fd,8))
    to_float(9,0xc)                           # y0
    p(lfs(10,0x10,10)); p(lfs(11,0x30,10)); p(lfs(12,0x20,10))
    p(fmadds(11,10,9,11)); p(fsubs(11,11,12)) # m4*y + m12 - m8
    p(lfs(10,0,10))                           # m0
    to_float(9,0x8);  p(fmadds(12,10,9,11))   # X0
    to_float(9,0xa);  p(fmadds(13,10,9,11))   # X1
    p(fcmpu(12,13)); p.bc('le','ORDERED')
    p(fmr(9,12)); p(fmr(12,13)); p(fmr(13,9))
    p.label('ORDERED')                         # f12 = left x, f13 = right x
    p.b('DATA',link=True)
    p(flt(W)); p(flt(512-W)); p(flt(256-W2)); p(flt(256+W2))
    p(flt(400.0)); p(flt(256.0)); p(flt(0.5)); p(flt(16.0))
    p.label('DATA')
    p(mflr(12))
    p(fsubs(9,13,12)); p(lfs(10,16,12)); p(fcmpu(9,10)); p.bc('ge','END')   # full-width: as is
    # Decide by the piece's middle: pieces sitting on the screen's middle line (the timer) stay
    # centered; anything else goes to its side, even if it pokes across the middle (P2's damage
    # chunk does, more so while the hit shake jiggles it).
    p(fadds(9,12,13)); p(lfs(10,24,12)); p(fmuls(9,9,10))   # center
    p(lfs(10,20,12)); p(fsubs(11,9,10)); p(fabs_(11,11))
    p(lfs(10,28,12)); p(fcmpu(11,10)); p.bc('lt','CROSS')
    p(lfs(10,20,12)); p(fcmpu(9,10)); p.bc('gt','RIGHT')
    p(lfs(4,0,12)); p.b('END')                # left: true width at the left edge
    p.label('RIGHT')
    p(lfs(3,4,12)); p.b('END')                # right: at the right edge
    p.label('CROSS')
    p(lfs(3,8,12)); p(lfs(4,12,12))           # on the middle line: centered
    p.label('END')
    return p.words()
out=[]
for addr,reg,scratch in ((0x801089d4,28,0xd0),(0x801083d0,31,0x90)):
    w=hook(reg,scratch)
    out.append(c2(addr,w))
print('\n'.join(out))
