"""Find the widescreen-HUD hook sites in a BT3 memory dump (any region: PAL, NTSC-U, Japanese).

Usage: python3 find_hud_sites.py mem1.raw [GAMEID] > GAMEID.json
       python3 widescreen_hud.py 0.75 --params GAMEID.json

Take mem1.raw in Dolphin (debugging UI on, Memory tab > Dump MEM1) during a battle. The script
looks for the game's two HUD sprite draw functions by their shape: each sets up a
0..512 x 0..448 orthographic projection (C_MTXOrtho with t=0, b=448, l=0, r=512) and keeps the
sprite pointer from r3. Everything the Gecko code needs follows from them: the small-data bases
(r2 / r13), the hook addresses (the `lfs f4, 512` of each projection), the register holding
the sprite, a stack slot already holding 0x43300000 (int -> float), the current-matrix pointer
(r13 offset), the int -> float magic constant (r2 offset) and the battle 2D code range.
Check what it prints against Tools/gecko/README.md before using it.
"""
import json
import struct
import sys

BASE = 0x80000000
mem = open(sys.argv[1], 'rb').read()
game = sys.argv[2] if len(sys.argv) > 2 else mem[:6].decode('ascii', 'replace')
CODE_END = min(len(mem), 0x600000)


def w(a): return struct.unpack('>I', mem[a - BASE:a - BASE + 4])[0]
def f(a): return struct.unpack('>f', mem[a - BASE:a - BASE + 4])[0]
def op(x): return x >> 26
def rt(x): return (x >> 21) & 31
def ra(x): return (x >> 16) & 31
def simm(x): return (x & 0xffff) - 0x10000 if x & 0x8000 else x & 0xffff
def bl_target(a):
    x = w(a)
    if op(x) != 18: return None
    li = x & 0x03fffffc
    if li & 0x02000000: li -= 0x04000000
    return (a + li) & 0xffffffff


# --- r2 / r13: set next to each other by __init_registers (lis/ori pairs) -----------------
sets = {}
for a in range(BASE + 0x3000, BASE + 0x40000, 4):
    x, y = w(a), w(a + 4)
    if op(x) == 15 and ra(x) == 0 and rt(x) in (2, 13) and op(y) == 24 and rt(y) == rt(x):
        sets.setdefault(rt(x), []).append((a, ((x & 0xffff) << 16) | (y & 0xffff)))
r13_at, R13 = sets[13][0]
r2_at, R2 = min(sets[2], key=lambda t: abs(t[0] - r13_at))

# --- the 0..512 x 0..448 ortho setups -------------------------------------------------------
def r2f(x): return f(R2 + simm(x))
sites = []
for a in range(BASE + 0x3000, BASE + CODE_END, 4):
    x = w(a)
    # lfs f4, C(r2) with C = 512, preceded by fmr f3,f1 and lfs f2 = 448 / lfs f1 = 0
    if op(x) == 48 and rt(x) == 4 and ra(x) == 2 and r2f(x) == 512.0 and w(a - 4) == 0xFC600890:
        pre = [w(a - 4 * k) for k in range(2, 6)]
        if not any(op(p) == 48 and rt(p) == 2 and ra(p) == 2 and r2f(p) == 448.0 for p in pre):
            continue
        sites.append(a)

hooks = []
for a in sites:
    # function start: walk back to `stwux r1,r1,r11` (aligned frame) or `stwu r1,-N(r1)`
    s = a
    while not (w(s) == 0x7C21596E or (w(s) >> 16) == 0x9421):
        s -= 4
    if w(s) == 0x7C21596E:
        s -= 12  # clrlwi r11,r1 / mr r12,r1 / subfic
    body = [(b, w(b)) for b in range(s, a, 4)]
    sreg = next((rt(x) for b, x in body if (x & 0xFC1F07FE) == 0x7C030378 and ra(x) != 3
                 and ((x >> 11) & 31) == 3), None)   # mr rS, r3 (or rS, r3, r3)
    sreg = next((ra(x) for b, x in body if (x & 0xFC00FFFE) == 0x7C001B78 and rt(x) == 3
                 and ((x >> 11) & 31) == 3), sreg)
    magic_reg = next((rt(x) for b, x in body if op(x) == 15 and ra(x) == 0 and (x & 0xffff) == 0x4330), None)
    slots = sorted(simm(x) for b, x in body if op(x) == 36 and ra(x) == 1 and rt(x) == magic_reg)
    if sreg is None or not slots:
        continue  # a draw without a sprite (full-screen fill): not a hook site
    # the current-matrix pointer: a `bl` after the site to `lwz r4,-X(r13); b ...`
    mtx = None
    for b in range(a, a + 0x200, 4):
        t = bl_target(b)
        if t and BASE <= t < BASE + CODE_END and op(w(t)) == 32 and ra(w(t)) == 13 and op(w(t + 4)) == 18:
            mtx = simm(w(t))
            break
    # the int -> float magic: the first lfd from r2 in the function
    magic = next((simm(x) for b in range(s, a + 0x800, 4) for x in [w(b)] if op(x) == 50 and ra(x) == 2), None)
    hooks.append({'addr': a, 'func': s, 'sprite_reg': sreg, 'scratch': slots[0],
                  'matrix_r13': mtx, 'magic_r2': magic, 'ortho_r2': simm(w(a))})

# --- battle 2D range: who calls the draw functions (directly, or through a `b` wrapper) -----
funcs = {h['func'] for h in hooks}
wrappers = set()
for a in range(BASE + 0x3000, BASE + CODE_END, 4):
    x = w(a)
    if op(x) == 18 and not (x & 1):
        li = x & 0x03fffffc
        if li & 0x02000000: li -= 0x04000000
        if (a + li) & 0xffffffff in funcs:
            wrappers.add(a - 8)          # li r6 / li r7 / b draw
callers = sorted(a for a in range(BASE + 0x3000, BASE + CODE_END, 4)
                 if bl_target(a) in funcs | wrappers)
near = [c for c in callers if abs(c - min(funcs)) < 0x10000]
lo, hi = (min(near) & ~0xffff, (max(near) + 0x1000) & ~0xfff) if near else (0, 0)

out = {'game': game, 'r2': R2, 'r13': R13, 'hooks': hooks, 'battle_lo': lo, 'battle_hi': hi}
print(json.dumps(out, indent=1))
print(f"# {game}: r2={R2:#x} r13={R13:#x}; {len(hooks)} hook sites "
      f"({', '.join(hex(h['addr']) for h in hooks)}); battle 2D callers {lo:#x}-{hi:#x} "
      f"({len(near)} of {len(callers)} callers near the sprite library)", file=sys.stderr)
