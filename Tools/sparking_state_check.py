#!/usr/bin/env python3
"""Check a Dolphin-Sparking battle state (.sav / .sst) before shipping it.

    python Tools/sparking_state_check.py SparkingData/states/RDSPAF-SingleBattle.sav [...]

Prints the game ID and the Dolphin build that saved it, and for BT3 PAL (RDSPAF) whether the
"PAL60 Mode + Black Bar Removal" code was running when it was captured. A state captured
without it keeps every DRAGON NET match at 25 fps (the game sets its video mode up before
the menus, so the code can't change it after the state loads). Pure Python, no packages.
"""
import struct
import sys

STATE_COOKIE = 0xBAADBB7E
MEM1_SIZE = 0x01800000

# Game ID -> (check name, MEM1 offset, bytes expected when the code is on)
CHECKS = {
    "RDSPAF": ("PAL60 Mode + Black Bar Removal (30 fps)", 0x391AA8, bytes.fromhex("00000014")),
}


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
        check = CHECKS.get(game_id)
        if not check:
            print("  (no code check for this game)")
            continue
        name, offset, expected = check
        mem1 = find_mem1(payload, game_id)
        if mem1 < 0 or mem1 + MEM1_SIZE > len(payload):
            print("  couldn't find the game's memory in the state")
            bad += 1
            continue
        actual = payload[mem1 + offset:mem1 + offset + len(expected)]
        if actual == expected:
            print(f"  OK   {name}: on")
        else:
            print(f"  BAD  {name}: off when this was captured ({actual.hex()} instead of {expected.hex()})")
            bad += 1
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
