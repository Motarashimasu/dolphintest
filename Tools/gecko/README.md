# Gecko codes made for Dolphin-Sparking

Tools that generate the widescreen Gecko codes in `Data/Sys/GameSettings/RDSPAF.ini`, and the
notes needed to port them to another build of BT3 (NTSC-U, the Japanese release, ...).

| File | What it is |
|---|---|
| `asm.py` | A tiny PowerPC assembler, just enough for Gecko `C2` (insert-asm) codes. |
| `widescreen_hud.py` | **Widescreen HUD (life bars at the screen edges).** Tested and working on RDSPAF. |
| `find_hud_sites.py` | Finds everything `widescreen_hud.py` needs in a memory dump of another build. |
| `widescreen_css.py` | Widescreen character select (1P strip left, COM/2P strip right). First version, **not tested yet**. |

## How the HUD code works (BT3 PAL, RDSPAF)

The battle HUD is drawn in PS2 coordinates: 512 x 448, centre x = 256. Every HUD sprite goes
through one of two draw functions in the HUD's sprite library (around `0x80108000`):

| | Draw function | Hook (`lfs f4, 512` of the projection) | Sprite in | Stack slot holding 0x43300000 |
|---|---|---|---|---|
| textured | `0x80108970` | `0x801089d4` | r28 | `0xd0(r1)` |
| flat (bar fills) | `0x80108384` | `0x801083d0` | r31 | `0x90(r1)` |

Each one builds its own orthographic projection (`C_MTXOrtho(t=0, b=448, l=0, r=512)`) right
before drawing, then draws the sprite through the **current matrix** of the game's PS2-style
matrix stack (`lwz rX, -0x6e7c(r13)`; column-major 4x4; on screen `x' = m0*x + m4*y - m8 + m12`).
Each HUD element has its own position in that matrix; the sprite rectangles are local to it.

The code replaces the projection's left/right edges per sprite:

- **left side** (sprite's middle < 256): `l = 0, r = 512/s`, true width pinned to the left edge
- **right side**: `l = 512 - 512/s, r = 512`, pinned to the right edge
- **on the middle line** (within 16 px: the timer): `l = 256 - 256/s, r = 256 + 256/s`, centred
- **full-width** sprites (400+ wide on screen: flashes, fades): left as they are
- **pieces of one element** (same matrix position) follow the element's first piece. This
  matters for the life bars: a bar is a fixed 160 px fill piece plus a piece that slides with
  the health and masks the fill. If they're placed one by one, the sliding piece goes to the
  wrong edge while its middle is past 256, and the bar doesn't seem to drop until half the
  health is gone.

`s` = game aspect / shown aspect (4:3 HUD on a 16:9 screen = 0.75).

Only sprites drawn from the **battle 2D modules** are touched: the draw function's caller must be
in `0x80100000-0x80111000` (the HUD, its damage / flash effects and the combo counters; all set
up together when a fight starts, from `0x800c71b0-0x800c71e0`). Menus also use the sprite
library and are left alone.

Values used from the small-data areas (r2 = `0x806338c0`, r13 = `0x80631320` on RDSPAF):

| | RDSPAF | What it is |
|---|---|---|
| `ortho_r2` | `-0x6208` | the float 512.0 (the instruction the hook replaces) |
| `magic_r2` | `-0x6218` | the double 0x4330000080000000 (int to float) |
| `matrix_r13` | `-0x6e7c` | the current-matrix pointer |

### What went wrong on the way (so a port can check for it)

1. Classifying sprites by their raw rectangle: P2's side moved left. The rectangles are local
   to each element, so the matrix has to be applied first.
2. Only the HUD module (`0x80100000-0x80106000`): the hit effects are drawn by the modules next
   to it and stayed stretched. The range now covers all battle 2D modules.
3. "Crossing the middle = timer": P2's damage chunk pokes across the middle (more so with the
   hit shake) and was pulled toward the centre. Sprites are now placed by their middle.
4. Placing pieces one by one: the bar didn't drop until halfway (see above). Pieces now follow
   their element.

## Porting to another build (e.g. the Japanese release)

1. In a full Dolphin build (`Dolphin.exe`, debugging UI on), start a battle, pause, and use
   **Memory > Dump MEM1** (and MEM2). A screenshot of the same moment helps.
2. `python3 find_hud_sites.py mem1.raw > GAME.json`. It looks for the two draw functions by their
   shape (the 0..512 x 0..448 projection that keeps the sprite from r3) and reports the hook
   addresses, the sprite registers, the stack slots, the r2/r13 offsets and a battle 2D range.
   On RDSPAF it reports exactly the values above, with the range `0x80100000-0x80110000`.
3. Check the report against this file: two hooks, the same kind of registers and slots, and a
   battle range just around the sprite library. If the range looks off, set `battle_lo` /
   `battle_hi` in the JSON by hand (callers of the draw functions near the library).
4. `python3 widescreen_hud.py 0.75 --params GAME.json` prints the code. Add it to that game's
   `Data/Sys/GameSettings/<GAMEID>.ini` under `[Gecko]` (and `[Gecko_Enabled]` to have it on).
5. Test: both players taking hits, each bar layer dropping from the first hit, the timer, the
   combo counters, and the pause menu (should be untouched).

## Character select (`widescreen_css.py`, untested)

The character select is drawn by the menu layout system instead (640 x 512 menu screen, centre
x = 320). Each piece is a node whose matrix is loaded by `0x80013948`; the code narrows a copy of
that matrix when the caller is the layout node drawer (`0x8002e000-0x8002f000`) and the
character select is up (its work pointer `r13-0x6c48` is set; cleared at `0x8006f9a8` on exit).
Top strip (y < 128, 1P) goes left, bottom strip (y > 384, COM/2P) goes right, the rest by half.
The big character pictures are drawn by a tiled-image function (`0x80026ab4`) and are not
covered yet.
