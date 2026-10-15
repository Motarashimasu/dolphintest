"""Widescreen HUD Gecko code for BT3 PAL (RDSPAF): life bars at the screen edges.

The game draws every battle-HUD sprite through two functions (textured 0x80108970, flat
0x80108384) that each set a 2D projection of 0..512 x 0..448 (PS2 coordinates) right before
drawing. The code widens that projection per sprite, only for sprites drawn by the battle HUD
(caller in 0x80100000-0x80106000):
  - a sprite on the left half keeps its true width, pinned to the left edge;
  - one on the right half, pinned to the right edge;
  - one crossing the middle (the timer), centered at its true width;
  - full-width ones (400+ wide: flashes, fades) are left alone.
Usage: python3 widescreen_hud.py [squeeze]   (squeeze = game aspect / shown aspect; 16:9 = 0.75)
"""
from asm import *  # noqa: F403 (Tools/gecko/asm.py)
import sys
s=float(sys.argv[1]) if len(sys.argv)>1 else 0.75
W=512/s; W2=256/s
def hook(sreg):
    p=Prog()
    p(lfs(4,-0x6208,2))
    p(lwz(11,0,1)); p(lwz(11,4,11))
    p(lis(12,0x8010)); p(cmplw(11,12)); p.bc('lt','END')
    p(ori(12,12,0x6000)); p(cmplw(11,12)); p.bc('ge','END')
    p(lha(11,8,sreg)); p(lha(12,0xa,sreg))
    p(cmpw(11,12)); p.bc('le','NOSWAP')
    p(mr(0,11)); p(mr(11,12)); p(mr(12,0))
    p.label('NOSWAP')
    p(subf(0,11,12)); p(cmpwi(0,400)); p.bc('ge','END')
    p.b('DATA',link=True)
    p(flt(W)); p(flt(512-W)); p(flt(256-W2)); p(flt(256+W2))
    p.label('DATA')
    p(mflr(10))
    p(cmpwi(12,256)); p.bc('gt','NOTLEFT')
    p(lfs(4,0,10)); p.b('END')
    p.label('NOTLEFT')
    p(cmpwi(11,256)); p.bc('lt','CROSS')
    p(lfs(3,4,10)); p.b('END')
    p.label('CROSS')
    p(lfs(3,8,10)); p(lfs(4,12,10))
    p.label('END')
    return p.words()
out=[]
for addr,reg in ((0x801089d4,28),(0x801083d0,31)):
    w=hook(reg)
    out.append(c2(addr,w))
print('\n'.join(out))
