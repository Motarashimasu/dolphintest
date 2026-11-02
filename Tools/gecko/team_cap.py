"""Team Battle: up to N characters per team (BT3 PAL, RDSPAF). Prints the Gecko code.

    python Tools/gecko/team_cap.py [N]      (default 3)

How the team character select works (found from MEM1 dumps with 1 / 2 / 3 picks per team and
the code that uses them; global at r13-0x6B50 = 0x8062A7D0 -> the select screen's state, in MEM2):
  state + 0x8E8 + 4*side -> that side's team: +0x12C cursor (0..4 = team slots, 5 = OK),
  +0x134 how many characters are picked, slots at +0x30*i.
  The cursor can reach slots 0..count (slot `count` is the empty "add one" slot) and 5 (OK):
    Up    0x800B6098  lwz r3,0x134(r4)   cursor-- ; past count -> count
    Down  0x800B6198  lwz r0,0x134(r4)   cursor++ ; past count -> OK (5)
    Pick  0x800B5EB0  stw r0,0x12C(r3)   picking on the empty slot: count++, cursor = count
  The game's own limit is that the cursor's last slot is 4. This code makes "count" read at most
  N-1 for the cursor (so the empty slot after N picks can't be reached) and, after the Nth pick,
  puts the cursor on OK instead of the next empty slot. Fewer than N is still fine (up to N).
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from asm import Prog, c2, cmpwi, li, D  # noqa: E402

UP, DOWN, PICK = 0x800B6098, 0x800B6198, 0x800B5EB0
ORIGINAL = {UP: 0x80640134, DOWN: 0x80040134, PICK: 0x9003012C}   # checked by the tests


def lwz(r, d, ra):
    return D(32, r, ra, d)


def stw(r, d, ra):
    return D(36, r, ra, d)


def clamp_load(reg, base, cap):
    """lwz reg,0x134(base), then reg = min(reg, cap-1)."""
    p = Prog()
    p(lwz(reg, 0x134, base))
    p(cmpwi(reg, cap - 1))
    p.bc('le', 'ok')
    p(li(reg, cap - 1))
    p.label('ok')
    return p.words()


def pick(cap):
    """r0 = the new count, r3 = the team: cursor = count, or OK (5) once the team is full."""
    p = Prog()
    p(cmpwi(0, cap))
    p.bc('lt', 'ok')
    p(li(0, 5))
    p.label('ok')
    p(stw(0, 0x12C, 3))
    return p.words()


def code(cap=3):
    return "\n".join([c2(UP, clamp_load(3, 4, cap)), c2(DOWN, clamp_load(0, 4, cap)), c2(PICK, pick(cap))])


if __name__ == "__main__":
    print(code(int(sys.argv[1]) if len(sys.argv) > 1 else 3))
