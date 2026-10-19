"""Widescreen HUD Gecko code for Budokai Tenkaichi 2 NTSC-J (RDBJAF): life bars at the screen edges.

BT2's battle HUD (module 0x800f0000-0x800fa300) draws each HUD element with one call of its
sprite-list function 0x800f5e9c: a list of 0x60-byte pieces (r23), all drawn after one
C_MTXOrtho(t=0, b=448, l=0, r=640) projection. The pieces' positions are in PS2 units, 512 wide
(the game multiplies x by 1.25 when it sends them). A second function, 0x800f7ec4, draws one
untextured piece (r31) the same way (the bars' second pass).

The code changes that projection's left / right edges per call, like the BT3 code:
  - an element on the left half keeps its true width, pinned to the left edge; one on the right
    half, pinned to the right edge; one on the middle line (within ~16 px: the timer), centred;
  - full-width ones (400+ px: frames of the whole screen, flashes, fades) are left as they are;
  - one call = one element, so a life bar's fill and the piece that slides over it to cut it to
    the health left always move together. The element is placed by its LAST visible piece: the
    bar's sliding piece comes first and pokes across the middle, the fill comes last.

Piece layout (0x60 bytes): +0 flags (bit 0x1 shown, bit 0x2 end of the list, bit 0x80000000
corners given), +4 / +8 x0 / x1 (halfwords, when no corners), +0x20 / +0x30 / +0x40 / +0x50 the
four corners' x (words, when given).

Usage: python3 widescreen_hud_bt2.py [squeeze]   (squeeze = game aspect / shown aspect, 16:9 = 0.75)
"""
from asm import *  # noqa: F403 (Tools/gecko/asm.py)
import sys

LIST_HOOK = 0x800f5f58    # lfs f4, -0x5d10(r2) (640.0) in 0x800f5e9c; r23 = the piece list
PIECE_HOOK = 0x800f7f28   # lfs f4, -0x5d10(r2) (640.0) in 0x800f7ec4; r31 = piece, r28 = corners?
ORTHO_R2 = -0x5d10        # the float 640.0

s = float(sys.argv[1]) if len(sys.argv) > 1 else 0.75
W = 640 / s

def andi_(ra, rs, i): return (28 << 26) | (rs << 21) | (ra << 16) | (i & 0xffff)      # andi.
def rlwinm_(ra, rs, sh, mb, me): return (21 << 26) | (rs << 21) | (ra << 16) | (sh << 11) | (mb << 6) | (me << 1) | 1
def add(rd, ra, rb): return (31 << 26) | (rd << 21) | (ra << 16) | (rb << 11) | (266 << 1)
def neg(rd, ra): return (31 << 26) | (rd << 21) | (ra << 16) | (104 << 1)


def extents(p, piece, corners_test):
    """r4 = min x, r5 = max x (512 units) of the piece at `piece`. corners_test(p) leaves cr0
    'ne' when the four corners are given."""
    corners_test(p)
    p.bc('ne', 'CORNERS')
    p(lha(4, 4, piece)); p(lha(5, 8, piece)); p.b('ORDER')
    p.label('CORNERS')
    p(lwz(4, 0x20, piece)); p(mr(5, 4))
    for i, off in enumerate((0x30, 0x40, 0x50)):
        p(lwz(6, off, piece))
        p(cmpw(6, 4)); p.bc('ge', f'NOTMIN{i}'); p(mr(4, 6)); p.label(f'NOTMIN{i}')
        p(cmpw(6, 5)); p.bc('le', f'NOTMAX{i}'); p(mr(5, 6)); p.label(f'NOTMAX{i}')
    p.label('ORDER')
    p(cmpw(4, 5)); p.bc('le', 'PLACE'); p(mr(6, 4)); p(mr(4, 5)); p(mr(5, 6))


def place(p):
    """From r4..r5 (512 units): set f3 / f4 (the projection's left / right) or leave them."""
    p.label('PLACE')
    p(subf(6, 4, 5)); p(cmpwi(6, 320)); p.bc('ge', 'END')        # 400+ px wide: as it is
    p.b('DATA', link=True)
    p(flt(W)); p(flt(640 - W)); p(flt(320 - W / 2)); p(flt(320 + W / 2))   # 0 4 8 12
    p.label('DATA')
    p(mflr(12))
    p(add(6, 4, 5)); p(addi(6, 6, -512))                           # 2 x (middle - 256)
    p(mr(7, 6)); p(cmpwi(7, 0)); p.bc('ge', 'POS'); p(neg(7, 7)); p.label('POS')
    p(cmpwi(7, 26)); p.bc('lt', 'CENTRE')                           # within ~16 px (640 units)
    p(cmpwi(6, 0)); p.bc('gt', 'RIGHT')
    p(lfs(4, 0, 12)); p.b('END')                                    # left edge, true width
    p.label('RIGHT')
    p(lfs(3, 4, 12)); p.b('END')                                    # right edge
    p.label('CENTRE')
    p(lfs(3, 8, 12)); p(lfs(4, 12, 12))                             # centred
    p.label('END')


def list_hook():
    p = Prog()
    p(lfs(4, ORTHO_R2, 2))                    # (the replaced instruction)
    # The last shown piece of the list (at most 64 pieces).
    p(mr(11, 23)); p(li(10, 0)); p(li(9, 64)); p(mtctr(9))
    p.label('LOOP')
    p(lwz(0, 0, 11)); p(andi_(9, 0, 2)); p.bc('ne', 'FOUND')
    p(andi_(9, 0, 1)); p.bc('eq', 'NEXT'); p(mr(10, 11))
    p.label('NEXT')
    p(addi(11, 11, 0x60)); p.bc('dnz', 'LOOP')
    p.label('FOUND')
    p(cmpwi(10, 0)); p.bc('eq', 'END')
    extents(p, 10, lambda p: (p(lwz(0, 0, 10)), p(rlwinm_(9, 0, 0, 0, 0))))
    place(p)
    return p.words()


def piece_hook():
    p = Prog()
    p(lfs(4, ORTHO_R2, 2))                    # (the replaced instruction)
    extents(p, 31, lambda p: p(cmpwi(28, 0)))
    place(p)
    return p.words()


print(c2(LIST_HOOK, list_hook()))
print(c2(PIECE_HOOK, piece_hook()))
