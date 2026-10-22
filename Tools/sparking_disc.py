#!/usr/bin/env python3
"""Disc recipes: how the launcher builds the collection's version of a game (e.g. Sparking! 4.0)
from the player's own original disc, without the game itself ever being shipped (Docs/DISCS.md).

    python Tools/sparking_release.py disc --original <clean disc> [--modded <your version>]
        --name "4.0" --out <build>/SparkingData/discs/<ID> --dolphin-tool <DolphinTool.exe>

A recipe is a folder with:
  recipe.json  every file of the original disc (path, size, SHA-1): the launcher's check that a
               player's disc is exactly that original, in whatever format they have it (ISO,
               WBFS, RVZ, NKit...: the files inside are the same in every good copy); and for
               every file of your version, how it's made: ranges copied from the original's files
               and ranges of new bytes.
  data.bin     the new bytes: only what isn't anywhere in the same file on the original disc,
               i.e. your own changes. None of the original game is in it.

Without --modded the recipe is the original itself (no data.bin): the launcher then only checks
the disc and copies it in (e.g. NTSC-J as it is).

The launcher (dolphin-tool sparking-disc) checks the player's disc against the list and writes
the version out as one RVZ: built from the files only, so it's byte-identical for every player.
Uses DolphinTool's "extract" for both discs (any format Dolphin reads); needs free space for
both discs' files while it runs. No packages needed.
"""
from __future__ import annotations

import datetime
import hashlib
import json
import os
import shutil
import subprocess
import tempfile

FORMAT = 1
SYS_FILES = ["sys/boot.bin", "sys/bi2.bin", "sys/apploader.img", "sys/main.dol"]


def masked(path: str, data: bytes) -> bytes:
    """The bytes that differ between good copies of one disc are zeroed before hashing:
    boot.bin's NKit data (0x200-0x21B) and DOL / FST positions (0x420-0x42F). Same as
    SparkingDiscCommand.cpp's MaskedHeader."""
    if path != "sys/boot.bin":
        return data
    b = bytearray(data)
    b[0x200:0x21C] = bytes(len(b[0x200:0x21C]))
    b[0x420:0x430] = bytes(len(b[0x420:0x430]))
    return bytes(b)


def sha1_file(path: str, rel: str) -> str:
    if rel == "sys/boot.bin":
        with open(path, "rb") as f:
            return hashlib.sha1(masked(rel, f.read())).hexdigest()
    h = hashlib.sha1()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


# --- Reading a disc --------------------------------------------------------------------------

class Disc:
    """A disc's game partition, extracted by DolphinTool: files by "sys/..." / "files/..."."""

    def __init__(self, root: str):
        self.root = root
        boot = os.path.join(root, "sys", "boot.bin")
        with open(boot, "rb") as f:
            head = f.read(8)
        self.game_id = head[:6].decode("ascii", "replace")
        self.revision = head[7]
        self.files: dict[str, str] = {}     # rel -> path on disk
        self.empty_dirs: list[str] = []
        for rel in SYS_FILES:
            p = os.path.join(root, *rel.split("/"))
            if not os.path.isfile(p):
                raise SystemExit(f"The extracted disc has no {rel}: {root}")
            self.files[rel] = p
        files = os.path.join(root, "files")
        for dirpath, dirs, names in os.walk(files):
            dirs.sort()
            rel_dir = os.path.relpath(dirpath, files).replace(os.sep, "/")
            prefix = "files/" if rel_dir == "." else f"files/{rel_dir}/"
            if not dirs and not names and prefix != "files/":
                self.empty_dirs.append(prefix)
            for n in sorted(names):
                self.files[prefix + n] = os.path.join(dirpath, n)
        self._hashes: dict[str, str] = {}

    def size(self, rel: str) -> int:
        return os.path.getsize(self.files[rel])

    def sha1(self, rel: str) -> str:
        if rel not in self._hashes:
            self._hashes[rel] = sha1_file(self.files[rel], rel)
        return self._hashes[rel]

    def read(self, rel: str) -> bytes:
        with open(self.files[rel], "rb") as f:
            return f.read()

    def entries(self) -> list[list]:
        return [[rel, self.size(rel), self.sha1(rel)] for rel in sorted(self.files)]


def extract(tool: str, disc: str, out: str) -> Disc:
    """DolphinTool extract (game partition only); returns the extracted disc."""
    if not os.path.isfile(disc):
        raise SystemExit(f"The disc doesn't exist: {disc}")
    r = subprocess.run([tool, "extract", "-i", disc, "-o", out, "-g", "-q"],
                       capture_output=True, text=True)
    root = os.path.join(out, "DATA")
    if not os.path.isdir(root):
        # (GameCube discs have no partitions: extracted as the folder itself)
        root = out if os.path.isdir(os.path.join(out, "sys")) else root
    if not os.path.isfile(os.path.join(root, "sys", "boot.bin")):
        raise SystemExit(f"DolphinTool couldn't extract {disc}:\n{r.stdout}{r.stderr}")
    return Disc(root)


# --- The delta -------------------------------------------------------------------------------

def _common_prefix(a: bytes, ai: int, b: bytes, bi: int) -> int:
    """How many bytes a[ai:] and b[bi:] share from the start (big steps, then narrowing)."""
    n = 0
    limit = min(len(a) - ai, len(b) - bi)
    step = 1 << 16
    while n < limit:
        s = min(step, limit - n)
        if a[ai + n:ai + n + s] == b[bi + n:bi + n + s]:
            n += s
            continue
        if s == 1:
            break
        step = max(1, s // 2)
    return n


def delta(src: bytes, dst: bytes) -> list[tuple]:
    """dst as ("s", offset in src, length) / ("n", offset in dst, length) ranges, in order.
    "s" ranges are at least one block long; everything else is "n" (new bytes)."""
    if not src:
        return [("n", 0, len(dst))] if dst else []
    block = 64
    while len(src) // block > 2_000_000:
        block *= 2
    index: dict[bytes, int] = {}
    for off in range(0, len(src) - block + 1, block):
        index.setdefault(src[off:off + block], off)

    out: list[tuple] = []
    pending = 0           # start of the new bytes not yet written out
    i = 0
    guess = 0             # where in src the next bytes probably are (the last match's end)
    last_end = 0
    unmatched_since = 0
    n_dst = len(dst)

    def emit(s_off: int, d_off: int, length: int) -> None:
        nonlocal pending, i, guess, last_end, unmatched_since
        if d_off > pending:
            out.append(("n", pending, d_off - pending))
        out.append(("s", s_off, length))
        i = pending = last_end = unmatched_since = d_off + length
        guess = s_off + length

    while i + block <= n_dst:
        # Same place as the last match continued (also: bytes replaced by as many new ones).
        g = guess + (i - last_end)
        if (i - last_end) % block == 0 and 0 <= g and g + block <= len(src) and \
                src[g:g + block] == dst[i:i + block]:
            s = g
        else:
            s = index.get(dst[i:i + block], -1)
        if s >= 0:
            # Back over new bytes that match too, then forward as far as it goes.
            while i > pending and s > 0 and dst[i - 1] == src[s - 1]:
                i -= 1
                s -= 1
            emit(s, i, _common_prefix(src, s, dst, i))
            continue
        # No match here. Byte by byte normally; in long new stretches (over 8 MiB) only every
        # block, with a byte-by-byte window each MiB so a later match still lines up.
        if i - unmatched_since > (8 << 20) and (i - unmatched_since) % (1 << 20) >= block:
            i += block
        else:
            i += 1
    if pending < n_dst:
        out.append(("n", pending, n_dst - pending))
    # Merge neighbours (an "s" right after an "s" that continues it).
    merged: list[tuple] = []
    for seg in out:
        if merged and merged[-1][0] == seg[0] and merged[-1][1] + merged[-1][2] == seg[1]:
            merged[-1] = (seg[0], merged[-1][1], merged[-1][2] + seg[2])
        else:
            merged.append(seg)
    return merged


# --- Making a recipe -------------------------------------------------------------------------

def make_recipe(original: Disc, modded: Disc | None, name: str, out_dir: str,
                log=print) -> dict:
    os.makedirs(out_dir, exist_ok=True)
    source = original.entries()
    index = {e[0]: i for i, e in enumerate(source)}
    by_hash: dict[tuple, int] = {}
    for i, e in enumerate(source):
        by_hash.setdefault((e[1], e[2]), i)

    target_disc = modded or original
    target = target_disc.entries()
    files: dict[str, list] = {}
    data_path = os.path.join(out_dir, "data.bin")
    data_size = 0
    data_hash = hashlib.sha1()
    new_by_file: list[tuple[int, str]] = []
    with open(data_path, "wb") as data:
        for rel, size, sha in target:
            i = index.get(rel)
            if i is not None and source[i][1] == size and source[i][2] == sha:
                continue                                  # the original's file
            same = by_hash.get((size, sha))
            if same is not None and rel != "sys/boot.bin":
                files[rel] = [["s", same, 0, size]]       # moved / copied original file
                continue
            dst = target_disc.read(rel)
            src = original.read(rel) if i is not None else b""
            segs = []
            new = 0
            for kind, off, length in delta(src, dst):
                if kind == "s":
                    segs.append(["s", i, off, length])
                else:
                    segs.append(["n", data_size, length])
                    chunk = dst[off:off + length]
                    data.write(chunk)
                    data_hash.update(chunk)
                    data_size += length
                    new += length
            files[rel] = segs
            new_by_file.append((new, rel))
    recipe = {
        "format": FORMAT,
        "name": name,
        "game_id": original.game_id,
        "revision": original.revision,
        "target_id": target_disc.game_id,
        "made": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%d %H:%M UTC"),
        "source": source,
        "target": target,
        "empty_dirs": target_disc.empty_dirs,
        "files": files,
    }
    if data_size:
        recipe["data"] = "data.bin"
        recipe["data_size"] = data_size
        recipe["data_sha1"] = data_hash.hexdigest()
    else:
        os.remove(data_path)
    with open(os.path.join(out_dir, "recipe.json"), "w", encoding="utf-8") as f:
        json.dump(recipe, f, separators=(",", ":"))
    check_recipe(recipe, original, target_disc, out_dir)

    total = sum(e[1] for e in target)
    log(f"{name}: {original.game_id} revision {original.revision}, {len(source)} files on the original, "
        f"{len(target)} in {name}, {len(files)} changed or new")
    log(f"  new bytes (data.bin): {data_size / 1048576:.2f} MB of {total / 1048576:.0f} MB")
    for new, rel in sorted(new_by_file, reverse=True)[:8]:
        if new:
            log(f"    {new / 1048576:9.2f} MB  {rel}")
    removed = sorted(set(e[0] for e in source) - set(e[0] for e in target))
    if removed:
        log(f"  not in {name}: {len(removed)} of the original's files (e.g. {removed[0]})")
    if target_disc.game_id != original.game_id:
        log(f"  note: {name}'s disc ID is {target_disc.game_id}, the original's {original.game_id}")
    return recipe


def check_recipe(recipe: dict, original: Disc, target_disc: Disc, out_dir: str) -> None:
    """Rebuilds every changed file from the recipe and compares: the recipe is exactly right."""
    data = b""
    if recipe.get("data"):
        with open(os.path.join(out_dir, recipe["data"]), "rb") as f:
            data = f.read()
    cache: dict[str, bytes] = {}
    for rel, segs in recipe["files"].items():
        parts = []
        for seg in segs:
            if seg[0] == "s":
                src_rel = recipe["source"][seg[1]][0]
                if src_rel not in cache:
                    cache.clear()
                    cache[src_rel] = original.read(src_rel)
                parts.append(cache[src_rel][seg[2]:seg[2] + seg[3]])
            else:
                parts.append(data[seg[1]:seg[1] + seg[2]])
        built = b"".join(parts)
        if hashlib.sha1(masked(rel, built)).hexdigest() != target_disc.sha1(rel):
            raise SystemExit(f"Internal error: the recipe doesn't rebuild {rel} exactly.")


def cmd_disc(args) -> None:
    tool = args.dolphin_tool
    if not tool or not os.path.isfile(tool):
        raise SystemExit("--dolphin-tool: the path to DolphinTool.exe (built with Dolphin: "
                         "cmake --build ... --target dolphin-tool)")
    work = tempfile.mkdtemp(prefix="sparking_disc_", dir=args.temp or None)
    try:
        print("Extracting the original disc...")
        original = extract(tool, args.original, os.path.join(work, "original"))
        modded = None
        if args.modded:
            print(f"Extracting {args.name}...")
            modded = extract(tool, args.modded, os.path.join(work, "modded"))
        if os.path.isdir(args.out):
            for n in ("recipe.json", "data.bin"):
                if os.path.exists(os.path.join(args.out, n)):
                    os.remove(os.path.join(args.out, n))
        make_recipe(original, modded, args.name, args.out)
        print(f"Recipe written to {args.out} (publish the build to send it to players)")
    finally:
        shutil.rmtree(work, ignore_errors=True)


def add_parser(sub) -> None:
    d = sub.add_parser("disc", help="make the recipe that builds your version from a player's disc")
    d.add_argument("--original", required=True, help="a clean copy of the original disc (any format)")
    d.add_argument("--modded", help="your version's disc (any format); leave out to use the original as is")
    d.add_argument("--name", required=True, help='what players see, e.g. "4.0" or "NTSC-J"')
    d.add_argument("--out", required=True, help="the recipe folder, e.g. <build>/SparkingData/discs/RDSPAF")
    d.add_argument("--dolphin-tool", required=True, help="DolphinTool.exe (dolphin-tool on Linux)")
    d.add_argument("--temp", help="where to extract the discs while it runs (default: the system's temp folder)")
    d.set_defaults(func=cmd_disc)
