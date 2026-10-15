"""Widescreen HUD Gecko code for BT3 PAL (RDSPAF): life bars at the screen edges.

The game draws every battle-HUD sprite through two functions (textured 0x80108970, flat
0x80108384) that each set a 2D projection of 0..512 x 0..448 (PS2 coordinates) right before
drawing. The code widens that projection per sprite, only for sprites drawn by the battle HUD
(caller in the battle-only 2D modules, 0x80100000-0x80111000):
  - a sprite whose middle is left of the screen's middle keeps its true width, pinned to the
    left edge; one whose middle is right of it, pinned to the right edge;
  - one sitting on the middle line (within 16 px: the timer), centered at its true width;
  - the pieces of one HUD element (drawn at the same position, like a life bar's fill and the
    sliding piece that cuts it to the health left) follow the element's first piece;
  - full-width ones (400+ wide: flashes, fades) are left alone.
Usage: python3 widescreen_hud.py [squeeze] [--params GAME.json]
  squeeze = game aspect / shown aspect (16:9 = 0.75). Without --params: BT3 PAL (RDSPAF).
  Another build (NTSC-U, Japanese): python3 find_hud_sites.py mem1.raw > GAME.json first
  (see README.md).
"""
from asm import *  # noqa: F403 (Tools/gecko/asm.py)
import json
import sys

# BT3 PAL (RDSPAF), as find_hud_sites.py reports it.
P = {'hooks': [{'addr': 0x801089d4, 'sprite_reg': 28, 'scratch': 0xd0},
               {'addr': 0x801083d0, 'sprite_reg': 31, 'scratch': 0x90}],
     'matrix_r13': -0x6e7c, 'magic_r2': -0x6218, 'ortho_r2': -0x6208,
     'battle_lo': 0x80100000, 'battle_hi': 0x80111000}
args = [a for a in sys.argv[1:]]
if '--params' in args:
    i = args.index('--params')
    q = json.load(open(args[i + 1]))
    del args[i:i + 2]
    h0 = q['hooks'][0]
    P = {'hooks': q['hooks'], 'matrix_r13': h0['matrix_r13'], 'magic_r2': h0['magic_r2'],
         'ortho_r2': h0['ortho_r2'], 'battle_lo': q['battle_lo'], 'battle_hi': q['battle_hi']}
s = float(args[0]) if args else 0.75
W=512/s; W2=256/s
def hook(sreg, scratch):
    """At the draw function's `lfs f4, 512` (the ortho's right edge): f3 = left, f4 = right.
    sreg holds the sprite; scratch = a stack slot whose high word is already 0x43300000."""
    p=Prog()
    p(lfs(4,P['ortho_r2'],2))                 # (the replaced instruction)
    # Only battle 2D: the draw function's caller in the battle-only 2D modules, 0x80100000-0x80111000
    # (the HUD, its damage / flash effects, the combo counters; all set up when a fight starts).
    p(lwz(11,0,1)); p(lwz(11,4,11))
    lo, hi = P['battle_lo'], P['battle_hi']
    p(lis(12,lo>>16))
    if lo & 0xffff: p(ori(12,12,lo&0xffff))
    p(cmplw(11,12)); p.bc('lt','END')
    p(lis(12,hi>>16))
    if hi & 0xffff: p(ori(12,12,hi&0xffff))
    p(cmplw(11,12)); p.bc('ge','END')
    p.b('DATA',link=True)
    p(flt(W)); p(flt(512-W)); p(flt(256-W2)); p(flt(256+W2))     # 0 4 8 12
    p(flt(400.0)); p(flt(256.0)); p(flt(0.5)); p(flt(16.0))      # 16 20 24 28
    p(0); p(0); p(0); p(0)                    # 32: last piece group: x, y, left, right
    p.label('DATA')
    p(mflr(12))
    # Where the sprite lands on screen: the current matrix (each HUD element's position)
    # applied to its corners: x' = m0*x + m4*y + m8*z + m12, z = -1.
    p(lwz(10,P['matrix_r13'],13))                     # current matrix (column-major 4x4)
    p(lfd(8,P['magic_r2'],2))                       # int -> float magic
    def to_float(fd, off):
        p(lha(11,off,sreg)); p(xoris(11,11,0x8000)); p(stw(11,scratch+4,1))
        p(lfd(fd,scratch,1)); p(fsubs(fd,fd,8))
    to_float(9,0xc)                           # y0
    p(lfs(10,0x10,10)); p(lfs(11,0x30,10)); p(lfs(13,0x20,10))
    p(fmadds(11,10,9,11)); p(fsubs(11,11,13)) # m4*y + m12 - m8
    p(lfs(10,0,10))                           # m0
    to_float(9,0x8);  p(fmadds(12,10,9,11))   # X0
    to_float(9,0xa);  p(fmadds(13,10,9,11))   # X1
    p(fcmpu(12,13)); p.bc('le','ORDERED')
    p(fmr(9,12)); p(fmr(12,13)); p(fmr(13,9))
    p.label('ORDERED')                         # f12 = left x, f13 = right x
    p(fsubs(9,13,12)); p(lfs(10,16,12)); p(fcmpu(9,10)); p.bc('ge','END')   # full-width: as is
    # Pieces of one HUD element (same position: a life bar's fill and the sliding piece that cuts
    # it to the health left) move together: the element's first piece decides for all of them.
    p(lfs(9,0x30,10)); p(lfs(10,0x34,10))     # element position
    p(fcmpu(9,3)); p.bc('ne','GROUPED'); p(fcmpu(10,3)); p.bc('eq','DECIDE')   # (0,0): no group
    p.label('GROUPED')
    p(lfs(11,32,12)); p(fcmpu(9,11)); p.bc('ne','DECIDE')
    p(lfs(11,36,12)); p(fcmpu(10,11)); p.bc('ne','DECIDE')
    p(lfs(3,40,12)); p(lfs(4,44,12)); p.b('END')
    # Decide by the piece's middle: within 16 px of the screen's middle line (the timer) it stays
    # centered; otherwise it goes to its side, even if it pokes across the middle.
    p.label('DECIDE')
    p(fadds(9,12,13)); p(lfs(10,24,12)); p(fmuls(9,9,10))   # center
    p(lfs(10,20,12)); p(fsubs(11,9,10)); p(fabs_(11,11))
    p(lfs(10,28,12)); p(fcmpu(11,10)); p.bc('lt','CROSS')
    p(lfs(10,20,12)); p(fcmpu(9,10)); p.bc('gt','RIGHT')
    p(lfs(4,0,12)); p.b('STORE')              # left: true width at the left edge
    p.label('RIGHT')
    p(lfs(3,4,12)); p.b('STORE')              # right: at the right edge
    p.label('CROSS')
    p(lfs(3,8,12)); p(lfs(4,12,12))           # on the middle line: centered
    p.label('STORE')
    p(lfs(9,0x30,10)); p(stfs(9,32,12)); p(lfs(9,0x34,10)); p(stfs(9,36,12))
    p(stfs(3,40,12)); p(stfs(4,44,12))
    p.label('END')
    return p.words()

out=[]
for h in P['hooks']:
    addr=h['addr']; w=hook(h['sprite_reg'],h['scratch'])
    out.append(c2(addr,w))
print('\n'.join(out))
