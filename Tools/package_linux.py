#!/usr/bin/env python3
"""Packs a Linux build into the .tar.gz players download (Docs/LINUX.md).

    python Tools/package_linux.py <linux build folder> <output .tar.gz> [--config release.json]

Works on Windows too. The archive holds exactly the files a Linux update would (release.json's
include_linux / exclude_linux, else the defaults), so a fresh install is already up to date,
inside one folder, "DRAGON BALL Sparking! Collection". The launcher and Dolphin's programs are
marked executable in the archive (Windows' own tar can't do that), the rest read/write.
No packages needed.
"""
import argparse
import io
import os
import sys
import tarfile
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import sparking_release as release  # noqa: E402

TOP = "DRAGON BALL Sparking! Collection"

README = """DRAGON BALL Sparking! Collection (Linux)

Start: double-click "{launcher}" (or run ./"{launcher}" in a terminal).
Updates arrive by themselves once you're logged in to DRAGON NET.

Needs: a 64-bit Linux desktop with X11 or Wayland (XWayland), OpenGL 3.3 or Vulkan graphics,
PulseAudio / PipeWire or ALSA sound. Steam Deck: Desktop Mode, or add the launcher to Steam as a
non-Steam game.
Keep this folder somewhere you can write to (your home folder, not /opt or /usr).
"""


def is_executable(rel: str) -> bool:
    """Same rule as the launcher's updater (scripts/updater.gd is_executable)."""
    name = rel.rsplit("/", 1)[-1]
    return rel.endswith(".x86_64") or rel.endswith(".sh") \
        or (rel.startswith("Dolphin/") and rel.count("/") == 1 and "." not in name)


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("build")
    ap.add_argument("output")
    ap.add_argument("--config", help="release.json, for include_linux / exclude_linux / launcher_linux")
    args = ap.parse_args()
    build = os.path.abspath(args.build)
    if not os.path.isdir(build):
        raise SystemExit(f"The build folder doesn't exist: {build}")
    cfg = {}
    if args.config:
        import json
        with open(args.config, encoding="utf-8") as f:
            cfg = json.load(f)   # (only include_linux / exclude_linux / launcher_linux are used)
    include, exclude, launcher = release.platform_settings(cfg, "linux")
    launcher = launcher or "DRAGON BALL Sparking! Collection.x86_64"
    files = []
    for root, dirs, names in os.walk(build):
        dirs.sort()
        for name in sorted(names):
            rel = os.path.relpath(os.path.join(root, name), build).replace(os.sep, "/")
            if release.matches(rel, include) and not release.matches(rel, exclude):
                files.append(rel)
    if any(f.endswith(".exe") for f in files):
        raise SystemExit("A .exe in the build: is this the Windows build folder?")
    if launcher not in files:
        raise SystemExit(f"The launcher \"{launcher}\" isn't in the build.")
    if "Dolphin/dolphin-emu-nogui" not in files:
        raise SystemExit("Dolphin/dolphin-emu-nogui isn't in the build (the Linux Dolphin: Docs/LINUX.md).")
    now = int(time.time())
    total = 0
    with tarfile.open(args.output, "w:gz", format=tarfile.PAX_FORMAT) as tar:
        def add_dir(path):
            info = tarfile.TarInfo(path)
            info.type, info.mode, info.mtime = tarfile.DIRTYPE, 0o755, now
            tar.addfile(info)
        add_dir(TOP)
        seen = {TOP}
        for rel in files:
            parts = rel.split("/")[:-1]
            for i in range(1, len(parts) + 1):
                d = TOP + "/" + "/".join(parts[:i])
                if d not in seen:
                    seen.add(d)
                    add_dir(d)
            full = os.path.join(build, rel)
            info = tar.gettarinfo(full, arcname=f"{TOP}/{rel}")
            info.mode = 0o755 if is_executable(rel) else 0o644
            info.uid = info.gid = 0
            info.uname = info.gname = ""
            with open(full, "rb") as f:
                tar.addfile(info, f)
            total += info.size
        data = README.format(launcher=launcher).encode()
        info = tarfile.TarInfo(f"{TOP}/README.txt")
        info.size, info.mode, info.mtime = len(data), 0o644, now
        tar.addfile(info, io.BytesIO(data))
    print(f"{args.output}: {len(files)} files, {total / 1048576:.1f} MB "
          f"({os.path.getsize(args.output) / 1048576:.1f} MB packed)")


if __name__ == "__main__":
    main()
