#!/usr/bin/env python3
"""Check a Dolphin-Sparking battle state (.sav / .sst) before shipping it.

    python Tools/sparking_state_check.py SparkingData/states/RDSPAF-SingleBattle.sav [...]

Prints the game ID and the Dolphin build that saved it, and whether the version's default codes
were running when it was captured (states are captured with the defaults on, like netplay runs
them): BT3 PAL (RDSPAF) "PAL60 Mode + Black Bar Removal" (a state captured without it keeps every
DRAGON NET match at 25 fps: the game sets its video mode up before the menus, so the code can't
change it after the state loads), BT3 NTSC-J (RDSJAF) the widescreen HUD, BT2 NTSC-J (RDBJAF)
the 16:9 patch, the fog removal and the widescreen HUD.

Also: whether a splitscreen remover was running when it was captured. The removers are
insert-ASM codes: they patch branches into the game's code that point into the Gecko code list.
A state must be captured offline without them (they're netplay-only, per player); one captured
with them keeps those branches, and the plain-write version of the removers (tried in Oct 2026)
also left its patches in the game code (reported as "plain-write remover patches"). BT2's
removers are plain writes too (they nop the "2 players" flag setters): a state with those nops
was captured with a remover on. Pure Python, no packages.
"""
import struct
import sys

STATE_COOKIE = 0xBAADBB7E
MEM1_SIZE = 0x01800000

# Game ID -> [(check name, MEM1 offset, bytes expected when the code is on)]. bytes = None: an
# insert-ASM (C2) code, on when the game code there branches into the Gecko code area.
CHECKS = {
    "RDSPAF": [
        ("PAL60 Mode + Black Bar Removal (30 fps)", 0x391AA8, bytes.fromhex("00000014")),
    ],
    "RDSJAF": [
        ("Widescreen HUD", 0x10771C, None),
    ],
    "RDBJAF": [
        ("16:9 Widescreen Patch", 0x5F5A94, bytes.fromhex("3F400000")),
        ("Remove Bugged Fog/Shadow", 0x5F6064, bytes.fromhex("00000000")),
        ("Widescreen HUD", 0x0F5F58, None),
    ],
}

# Game ID -> MEM1 offsets the insert-ASM splitscreen removers hook (a branch there into the
# Gecko code area = captured while one was running).
OLD_HOOKS = {
    "RDSPAF": [0x09136C, 0x015264, 0x015274],
    "RDSJAF": [0x090B6C, 0x01529C, 0x0152AC],
}
GECKO_AREA = (0x80001800, 0x80003000)
# The plain-write removers (04 codes, Oct 2026, rolled back): what they wrote at 0x8001528C.
PLAIN_WRITE_REMOVER = {"RDSPAF": (0x01528C, bytes.fromhex("2C1F0000408200443860"))}
# BT2 NTSC-J's removers nop these "2 players" flag setters (the game has `ori r0,r0,2` there).
NOP_REMOVER = {"RDBJAF": [0x1530D4, 0x159064, 0x17B340, 0x204A98]}


def branches_into_codes(word: int, address: int) -> bool:
    """A PowerPC `b` (opcode 18, relative) from `address` landing in the Gecko code area."""
    if word >> 26 != 18 or word & 2:   # not b / ba
        return False
    disp = word & 0x03FFFFFC
    if disp & 0x02000000:
        disp -= 0x04000000
    target = (address + disp) & 0xFFFFFFFF
    return GECKO_AREA[0] <= target < GECKO_AREA[1]


def lz4_block(src: bytes) -> bytes:
    out = bytearray()
    i, n = 0, len(src)
    while i < n:
        token = src[i]
        i += 1
        lit = token >> 4
        if lit == 15:
            while True:
                b = src[i]
                i += 1
                lit += b
                if b != 255:
                    break
        out += src[i:i + lit]
        i += lit
        if i >= n:
            break
        offset = src[i] | (src[i + 1] << 8)
        i += 2
        match = token & 15
        if match == 15:
            while True:
                b = src[i]
                i += 1
                match += b
                if b != 255:
                    break
        match += 4
        start = len(out) - offset
        for k in range(match):   # may overlap itself
            out.append(out[start + k])
    return bytes(out)


def load(path: str):
    with open(path, "rb") as f:
        data = f.read()
    game_id = data[:6].decode("ascii", "replace")
    cookie, vlen = struct.unpack_from("<II", data, 24)
    if cookie != STATE_COOKIE:
        raise ValueError("not a Dolphin save state")
    version = data[32:32 + vlen].decode("utf-8", "replace")
    pos = 32 + vlen
    _hv, compression, _po, size = struct.unpack_from("<HHIQ", data, pos)
    pos += 16
    if compression == 0:
        payload = data[pos:pos + size]
    else:
        parts = []
        while pos < len(data):
            (clen,) = struct.unpack_from("<i", data, pos)
            pos += 4
            parts.append(lz4_block(data[pos:pos + clen]))
            pos += clen
        payload = b"".join(parts)
    return game_id, version, payload


def find_mem1(payload: bytes, game_id: str) -> int:
    # MEM1 starts with the disc header: game ID at 0x00, Wii magic at 0x18 (GameCube at 0x1C).
    start = 0
    needle = game_id.encode()
    while True:
        at = payload.find(needle, start)
        if at < 0:
            return -1
        if payload[at + 0x18:at + 0x1C] == bytes.fromhex("5D1C9EA3") or \
           payload[at + 0x1C:at + 0x20] == bytes.fromhex("C2339F3D"):
            return at
        start = at + 1


def main() -> int:
    if len(sys.argv) < 2:
        print(__doc__)
        return 2
    bad = 0
    for path in sys.argv[1:]:
        print(path)
        try:
            game_id, version, payload = load(path)
        except (OSError, ValueError, IndexError, struct.error) as e:
            print(f"  can't read it: {e}")
            bad += 1
            continue
        print(f"  game {game_id}, saved by {version}")
        checks = CHECKS.get(game_id)
        if not checks:
            print("  (no code check for this game)")
            continue
        mem1 = find_mem1(payload, game_id)
        if mem1 < 0 or mem1 + MEM1_SIZE > len(payload):
            print("  couldn't find the game's memory in the state")
            bad += 1
            continue
        for name, offset, expected in checks:
            if expected is None:   # an insert-ASM code: its hook branch
                (word,) = struct.unpack_from(">I", payload, mem1 + offset)
                if branches_into_codes(word, 0x80000000 + offset):
                    print(f"  OK   {name}: on")
                else:
                    print(f"  BAD  {name}: off when this was captured (no hook at 0x{0x80000000 + offset:08X})")
                    bad += 1
                continue
            actual = payload[mem1 + offset:mem1 + offset + len(expected)]
            if actual == expected:
                print(f"  OK   {name}: on")
            else:
                print(f"  BAD  {name}: off when this was captured ({actual.hex()} instead of {expected.hex()})")
                bad += 1
        hooked = []
        for off in OLD_HOOKS.get(game_id, []):
            (word,) = struct.unpack_from(">I", payload, mem1 + off)
            if branches_into_codes(word, 0x80000000 + off):
                hooked.append(f"0x{0x80000000 + off:08X}")
        if hooked:
            print(f"  BAD  splitscreen remover hooks in the game code ({', '.join(hooked)}):"
                  " recapture this state offline, without the removers")
            bad += 1
        elif game_id in OLD_HOOKS:
            print("  OK   no splitscreen remover hooks")
        nopped = [f"0x{0x80000000 + off:08X}" for off in NOP_REMOVER.get(game_id, [])
                  if payload[mem1 + off:mem1 + off + 4] == bytes.fromhex("60000000")]
        if nopped:
            print(f"  BAD  splitscreen remover writes in the game code ({', '.join(nopped)}):"
                  " recapture this state offline, without the removers")
            bad += 1
        elif game_id in NOP_REMOVER:
            print("  OK   no splitscreen remover writes")
        plain = PLAIN_WRITE_REMOVER.get(game_id)
        if plain and payload[mem1 + plain[0]:mem1 + plain[0] + len(plain[1])] == plain[1]:
            print("  BAD  plain-write remover patches in the game code: recapture this state"
                  " offline, without the removers")
            bad += 1
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
