"""Widescreen character select for BT3 PAL (RDSPAF): menu pieces at their true shape.

The character select's plates, chips and strips are menu-layout nodes; each is drawn after
0x80013948 loads its matrix (PS2 4x4, column-major) for the 640 x 512 menu screen. While the
character select is up (its work pointer r13-0x6c48 is set) and the caller is the layout
library's node drawer (0x8002e000-0x8002f000), the code draws the node from a copy of its
matrix narrowed to its true width:
  - the top strip (y < 128, the "1P" side): pinned to the left edge;
  - the bottom strip (y > 384, the "COM"/"2P" side): pinned to the right edge;
  - between them: by the node's x, left half to the left edge, right half to the right edge,
    and nodes centered on the screen (within 8 px) stay centered.
Usage: python3 widescreen_css.py [squeeze]   (squeeze = game aspect / shown aspect; 16:9 = 0.75)
"""
import sys
from asm import *  # noqa: F403 (Tools/gecko/asm.py)

s = float(sys.argv[1]) if len(sys.argv) > 1 else 0.75
p = Prog()
p(mflr(12))                                   # who is loading this matrix
p(lis(11, 0x8002)); p(ori(11, 11, 0xe000)); p(cmplw(12, 11)); p.bc('lt', 'DONE')
p(ori(11, 11, 0xf000)); p(cmplw(12, 11)); p.bc('ge', 'DONE')
p(lwz(11, -0x6c48, 13)); p(cmpwi(11, 0)); p.bc('eq', 'DONE')   # character select is up
p.b('DATA', link=True)
consts = [s, 0.0, 640 * (1 - s), 320 * (1 - s), 128.0, 384.0, 320.0, 8.0]
for c in consts: p(flt(c))
SCR = 4 * len(consts)
for _ in range(16): p(0)                       # the narrowed matrix copy
p.label('DATA')
p(mflr(10))
p(addi(9, 10, SCR))                           # copy the matrix: the original stays as it is
p(addi(7, 3, -4)); p(addi(6, 9, -4)); p(li(8, 16)); p(mtctr(8))
p.label('COPY')
p(lwzu(0, 4, 7)); p(stwu(0, 4, 6)); p.bc('dnz', 'COPY')
p(addi(3, 9, 0))                              # draw from the copy
p(lfs(1, 0x30, 3)); p(lfs(2, 0x34, 3))        # node position x, y
p(lfs(5, 4, 10))                              # offset: 0 (left)
p(lfs(0, 16, 10)); p(fcmpu(2, 0)); p.bc('lt', 'APPLY')          # top strip: left
p(lfs(5, 8, 10))                              # offset: right edge
p(lfs(0, 20, 10)); p(fcmpu(2, 0)); p.bc('gt', 'APPLY')          # bottom strip: right
p(lfs(0, 24, 10)); p(fsubs(3, 1, 0)); p(fabs_(3, 3))
p(lfs(0, 28, 10)); p(fcmpu(3, 0)); p.bc('ge', 'SIDE')
p(lfs(5, 12, 10)); p.b('APPLY')               # centered
p.label('SIDE')
p(lfs(0, 24, 10)); p(fcmpu(1, 0)); p.bc('ge', 'APPLY')          # right half (offset set)
p(lfs(5, 4, 10))                              # left half
p.label('APPLY')
p(lfs(6, 0, 10))
for k in (0x0, 0x10, 0x20, 0x30):
    p(lfs(0, k, 3)); p(fmuls(0, 0, 6)); p(stfs(0, k, 3))
p(lfs(0, 0x30, 3)); p(fadds(0, 0, 5)); p(stfs(0, 0x30, 3))
p.label('DONE')
p(stwu(1, -0x40, 1))                          # (the replaced instruction)
print(c2(0x80013948, p.words()))
