#!/usr/bin/env python3
"""Tests disc recipes end to end with made-up Wii discs (no game data):

    python3 Tools/sparking_disc_test.py <dolphin-tool> [work folder]

Makes an "original" Wii disc and a "modded" one (changed, added, moved and removed files, a
changed main.dol and boot.bin), packs the original as ISO, RVZ, GCZ and WBFS (scrubbed, like
real WBFS copies), makes the recipe with sparking_release.py disc, then checks that:
  - every format of the original builds the same image, byte for byte, holding exactly the
    modded disc's files;
  - the recipe's data holds only the new bytes;
  - other games / versions, other revisions, modified or damaged copies, and broken recipes are
    refused with the right error;
  - a recipe without --modded (the original as it is) works too;
  - the launcher's disc-ID reader finds the ID in ISO, RVZ and WBFS.
"""
from __future__ import annotations

import hashlib
import json
import os
import random
import shutil
import struct
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import sparking_disc  # noqa: E402

FAILS = []


def check(cond: bool, what: str, extra="") -> None:
    print(f"  {'ok  ' if cond else 'FAIL'} {what}" + (f" {extra}" if extra and not cond else ""))
    if not cond:
        FAILS.append(what)


def rnd(seed: int, n: int) -> bytes:
    return random.Random(seed).randbytes(n)


# --- A made-up Wii disc (folder in DirectoryBlob layout, converted by dolphin-tool) -----------

def make_dol(text: bytes) -> bytes:
    header = bytearray(0x100)
    struct.pack_into(">I", header, 0x00, 0x100)         # text0 file offset
    struct.pack_into(">I", header, 0x48, 0x80004000)    # text0 address
    struct.pack_into(">I", header, 0x90, len(text))     # text0 size
    struct.pack_into(">I", header, 0xE0, 0x80004000)    # entry
    return bytes(header) + text


def sig_header() -> bytearray:
    b = bytearray(0x180)
    struct.pack_into(">I", b, 0, 0x10001)                     # RSA-2048
    b[0x140:0x140 + 26] = b"Root-CA00000001-XS00000003"
    return b


def make_wii_folder(root: str, game_id: str, revision: int, title: str, files: dict,
                    dol_text: bytes, empty_dirs=()) -> None:
    data = os.path.join(root, "DATA")
    os.makedirs(os.path.join(data, "sys"), exist_ok=True)
    boot = bytearray(0x440)
    boot[0:6] = game_id.encode()
    boot[7] = revision
    struct.pack_into(">I", boot, 0x18, 0x5D1C9EA3)           # Wii disc
    boot[0x20:0x20 + len(title)] = title.encode()
    sys_files = {
        "boot.bin": bytes(boot),
        "bi2.bin": bytes(0x2000),
        "apploader.img": b"2007/10/04".ljust(0x10, b"\0") + struct.pack(">III", 0x81200000, 0x40, 0)
                         .ljust(0x10, b"\0") + rnd(7, 0x40),
        "main.dol": make_dol(dol_text),
    }
    for name, content in sys_files.items():
        with open(os.path.join(data, "sys", name), "wb") as f:
            f.write(content)
    title_id = struct.pack(">I", 0x00010000) + game_id[:4].encode()
    ticket = sig_header() + bytearray(0x2A4 - 0x180)
    ticket[0x1BF:0x1CF] = rnd(11, 16)                         # (encrypted) title key
    ticket[0x1DC:0x1E4] = title_id
    tmd = sig_header() + bytearray(0x1E4 - 0x180 + 0x24)
    tmd[0x18C:0x194] = title_id
    struct.pack_into(">H", tmd, 0x1DE, 1)                     # one content
    with open(os.path.join(data, "ticket.bin"), "wb") as f:
        f.write(ticket)
    with open(os.path.join(data, "tmd.bin"), "wb") as f:
        f.write(tmd)
    with open(os.path.join(data, "cert.bin"), "wb") as f:
        f.write(bytes(0x400))
    for rel, content in files.items():
        p = os.path.join(data, "files", *rel.split("/"))
        os.makedirs(os.path.dirname(p), exist_ok=True)
        with open(p, "wb") as f:
            f.write(content)
    for d in empty_dirs:
        os.makedirs(os.path.join(data, "files", *d.split("/")), exist_ok=True)
    os.makedirs(os.path.join(data, "files"), exist_ok=True)


def run(tool: str, *args, user: str) -> subprocess.CompletedProcess:
    return subprocess.run([tool, *args, "-u", user], capture_output=True, text=True)


def convert(tool: str, src: str, out: str, fmt: str, user: str) -> None:
    extra = {"iso": [], "rvz": ["-c", "zstd", "-l", "5", "-b", "131072"],
             "gcz": ["-b", "32768"]}[fmt]
    r = run(tool, "convert", "-i", src, "-o", out, "-f", fmt, *extra, user=user)
    if not os.path.isfile(out):
        raise SystemExit(f"dolphin-tool convert to {fmt} failed:\n{r.stdout}{r.stderr}")


def make_wbfs(iso: str, out: str) -> None:
    """A scrubbed WBFS of an ISO, as WBFS tools write it: 2 MiB clusters, empty ones left out."""
    cluster = 1 << 21
    blocks = (143432 * 2 * 0x8000 + cluster - 1) // cluster
    wlba = [0] * blocks
    with open(iso, "rb") as src, open(out, "wb") as dst:
        head = src.read(256)
        src.seek(0)
        dst.write(bytes(cluster))                                 # cluster 0: the header
        used = 0
        for c in range(blocks):
            chunk = src.read(cluster)
            if not chunk:
                break
            if chunk.count(0) == len(chunk):
                continue
            used += 1
            wlba[c] = used
            dst.write(chunk.ljust(cluster, b"\0"))
        size = (used + 1) * cluster
        dst.seek(0)
        dst.write(b"WBFS" + struct.pack(">IBBxx", size // 512, 9, 21) + b"\x01")
        dst.seek(512)
        dst.write(head + b"".join(struct.pack(">H", w) for w in wlba))


def read_disc_id(path: str) -> str:
    """The launcher's reader (settings.gd read_disc_id), in Python."""
    with open(path, "rb") as f:
        magic = f.read(4)
        at = 0
        if magic == b"WBFS":
            f.seek(8)
            at = 1 << f.read(1)[0]
        elif magic in (b"WIA\x01", b"RVZ\x01"):
            at = 0x58
        elif magic == b"CISO":
            at = 0x8000
        f.seek(at)
        return f.read(6).decode("ascii", "replace")


def sparking(tool: str, disc: str, recipe: str, out: str, user: str, *extra) -> tuple[int, list]:
    r = run(tool, "sparking-disc", "-i", disc, "-r", recipe, "-o", out, *extra, user=user)
    return r.returncode, r.stdout.splitlines()


def error_of(lines: list) -> str:
    for line in lines:
        if line.startswith("error "):
            return line
    return ""


def sha256(path: str) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def main() -> None:
    tool = os.path.abspath(sys.argv[1])
    work = sys.argv[2] if len(sys.argv) > 2 else tempfile.mkdtemp(prefix="disc_test_")
    shutil.rmtree(work, ignore_errors=True)
    os.makedirs(work)
    user = os.path.join(work, "user")
    j = lambda *p: os.path.join(work, *p)   # noqa: E731

    big = rnd(1, 3_000_000)
    files = {
        "data/big.pak": big,
        "data/model.bin": rnd(2, 200_000),
        "data/old.bin": rnd(3, 50_000),
        "sound/bgm.brstm": rnd(4, 700_000),
        "readme.txt": b"original\n",
    }
    dol_text = rnd(5, 64_000)
    make_wii_folder(j("orig"), "RDSPAF", 0, "TEST GAME", files, dol_text, empty_dirs=["empty"])

    modded = dict(files)
    modded["data/big.pak"] = big[:1_000_000] + b"NEW!" * 5000 + big[1_000_000:2_500_000] + big[2_600_000:]
    modded["data/model.bin"] = bytes(b ^ 0xFF if 1000 <= i < 1100 else b for i, b in enumerate(files["data/model.bin"]))
    del modded["data/old.bin"]
    modded["data/moved/bgm_copy.brstm"] = files["sound/bgm.brstm"]       # a copy, elsewhere
    modded["mod/new_stage.bin"] = rnd(6, 120_000)                       # the mod's own file
    modded["readme.txt"] = b"Sparking! 4.0\n"
    mod_text = bytearray(dol_text)
    mod_text[100:108] = b"\x60\x00\x00\x00" * 2                         # a code change
    make_wii_folder(j("mod"), "RDSPAF", 0, "TEST GAME 4.0", modded, bytes(mod_text), empty_dirs=["empty"])

    print("Making the discs...")
    convert(tool, j("orig", "DATA", "sys", "main.dol"), j("orig.iso"), "iso", user)
    convert(tool, j("mod", "DATA", "sys", "main.dol"), j("mod.iso"), "iso", user)
    convert(tool, j("orig.iso"), j("orig.rvz"), "rvz", user)
    convert(tool, j("orig.iso"), j("orig.gcz"), "gcz", user)
    make_wbfs(j("orig.iso"), j("orig.wbfs"))
    formats = {f: j("orig." + f) for f in ("iso", "rvz", "gcz", "wbfs")}

    print("Disc IDs (the launcher's reader):")
    for f, p in formats.items():
        if f != "gcz":   # (GCZ is compressed from the start: the launcher leaves it to dolphin-tool)
            check(read_disc_id(p) == "RDSPAF", f"{f}: ID read")

    print("The recipe:")
    r = subprocess.run([sys.executable, os.path.join(HERE, "sparking_release.py"), "disc",
                        "--original", formats["wbfs"], "--modded", j("mod.iso"), "--name", "4.0",
                        "--out", j("recipe"), "--dolphin-tool", tool, "--temp", work],
                       capture_output=True, text=True)
    print("    " + (r.stdout + r.stderr).strip().replace("\n", "\n    "))
    check(r.returncode == 0, "sparking_release.py disc ran")
    recipe_path = j("recipe", "recipe.json")
    with open(recipe_path) as f:
        recipe = json.load(f)
    data_size = recipe.get("data_size", 0)
    expected_new = 20000 + 100 + 120_000 + len(modded["readme.txt"]) + 8
    check(data_size <= expected_new + 1024, f"data.bin holds only the new bytes ({data_size} <= ~{expected_new})")
    with open(j("recipe", "data.bin"), "rb") as f:
        data = f.read()
    check(big[:4096] not in data and files["sound/bgm.brstm"][:4096] not in data,
          "no original file data in data.bin")
    check(recipe["files"]["files/data/moved/bgm_copy.brstm"][0][0] == "s",
          "a moved original file is copied from the original, not stored")

    print("Building from every format of the original:")
    outputs = {}
    for f, p in formats.items():
        code, lines = sparking(tool, p, recipe_path, j(f"out_{f}.rvz"), user)
        check(code == 0 and lines and lines[-1].startswith("done "), f"{f}: built", str(lines[-3:]))
        check(any(l.startswith("progress ") for l in lines), f"{f}: progress reported")
        if code == 0:
            outputs[f] = sha256(j(f"out_{f}.rvz"))
    check(len(set(outputs.values())) == 1 and len(outputs) == len(formats),
          "every format gives the same image, byte for byte", str(outputs))

    print("What was built:")
    built = sparking_disc.extract(tool, j("out_iso.rvz"), j("x_out"))
    want = sparking_disc.extract(tool, j("mod.iso"), j("x_mod"))
    check(built.entries() == want.entries(), "exactly the modded disc's files (and sizes, hashes)")
    check(built.empty_dirs == ["files/empty/"], "the empty folder is kept", str(built.empty_dirs))
    check(built.game_id == "RDSPAF", "disc ID")
    code, lines = sparking(tool, j("out_iso.rvz"), recipe_path, j("x.rvz"), user, "--check")
    check(error_of(lines).startswith("error modified"), "the built image isn't taken as an original")

    code, lines = sparking(tool, formats["iso"], recipe_path, j("out.iso"), user, "-f", "iso")
    check(code == 0 and os.path.getsize(j("out.iso")) > 0, "ISO output works too")

    print("Refusals:")
    make_wii_folder(j("us"), "RDSE70", 0, "TEST GAME", files, dol_text, empty_dirs=["empty"])
    convert(tool, j("us", "DATA", "sys", "main.dol"), j("us.iso"), "iso", user)
    code, lines = sparking(tool, j("us.iso"), recipe_path, j("no.rvz"), user)
    check(code != 0 and error_of(lines) == "error wrong_game RDSE70", "another version: wrong_game", error_of(lines))
    check(not os.path.exists(j("no.rvz")), "nothing written")

    make_wii_folder(j("rev1"), "RDSPAF", 1, "TEST GAME", files, dol_text, empty_dirs=["empty"])
    convert(tool, j("rev1", "DATA", "sys", "main.dol"), j("rev1.iso"), "iso", user)
    code, lines = sparking(tool, j("rev1.iso"), recipe_path, j("no.rvz"), user)
    check(error_of(lines) == "error wrong_revision 1", "another revision: wrong_revision", error_of(lines))

    code, lines = sparking(tool, j("mod.iso"), recipe_path, j("no.rvz"), user)
    check(error_of(lines).startswith("error modified"), "an already modded disc: modified", error_of(lines))

    changed = dict(files)
    changed["sound/bgm.brstm"] = files["sound/bgm.brstm"][:-1] + b"\0"
    make_wii_folder(j("bad"), "RDSPAF", 0, "TEST GAME", changed, dol_text, empty_dirs=["empty"])
    convert(tool, j("bad", "DATA", "sys", "main.dol"), j("bad.iso"), "iso", user)
    code, lines = sparking(tool, j("bad.iso"), recipe_path, j("no.rvz"), user)
    check(error_of(lines) == "error modified files/sound/bgm.brstm isn't the original's",
          "one changed byte: modified, naming the file", error_of(lines))

    with open(formats["iso"], "rb") as f:
        head = f.read(4 << 20)
    with open(j("cut.iso"), "wb") as f:
        f.write(head)
    code, lines = sparking(tool, j("cut.iso"), recipe_path, j("no.rvz"), user)
    check(code != 0 and error_of(lines) != "", "a cut-off copy is refused", error_of(lines))

    code, lines = sparking(tool, j("readme_missing.iso"), recipe_path, j("no.rvz"), user)
    check(error_of(lines).startswith("error open"), "no such file: open", error_of(lines))

    shutil.copytree(j("recipe"), j("recipe_cut"))
    with open(j("recipe_cut", "data.bin"), "r+b") as f:
        f.truncate(100)
    code, lines = sparking(tool, formats["iso"], j("recipe_cut", "recipe.json"), j("no.rvz"), user)
    check(error_of(lines).startswith("error bad_recipe"), "a half-downloaded data.bin: bad_recipe", error_of(lines))

    print("The original as it is (no --modded):")
    r = subprocess.run([sys.executable, os.path.join(HERE, "sparking_release.py"), "disc",
                        "--original", formats["rvz"], "--name", "NTSC-J", "--out", j("plain"),
                        "--dolphin-tool", tool, "--temp", work], capture_output=True, text=True)
    check(r.returncode == 0 and not os.path.exists(j("plain", "data.bin")), "recipe without data.bin", r.stderr)
    plain = []
    for f in ("iso", "wbfs"):
        code, lines = sparking(tool, formats[f], j("plain", "recipe.json"), j(f"plain_{f}.rvz"), user)
        check(code == 0, f"{f}: built", str(lines[-2:]))
        plain.append(sha256(j(f"plain_{f}.rvz")) if code == 0 else f)
    check(len(set(plain)) == 1, "the same image from both")
    same = sparking_disc.extract(tool, j("plain_iso.rvz"), j("x_plain"))
    check(same.entries() == sparking_disc.extract(tool, formats["iso"], j("x_orig")).entries(),
          "exactly the original's files")

    if FAILS:
        print(f"DISC TEST FAILED ({len(FAILS)}): " + "; ".join(FAILS))
        sys.exit(1)
    print("DISC TEST PASSED")


if __name__ == "__main__":
    main()
