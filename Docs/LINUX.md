# Linux

The launcher (Godot) and Dolphin-Sparking both run on Linux, with automatic updates (Docs/UPDATES.md)
like Windows. Players get one `.tar.gz`: unpack it anywhere in their home folder and start
`DRAGON BALL Sparking! Collection.x86_64`. Runs on most Linux desktops of the last years (Ubuntu
22.04+, Debian 12+, Fedora 36+, Arch, SteamOS 3 / Steam Deck): X11 or Wayland (via XWayland),
OpenGL 3.3 or Vulkan, PulseAudio / PipeWire or ALSA.

## The pieces

| What | Where it comes from |
|---|---|
| `DRAGON BALL Sparking! Collection.x86_64` + `.pck` | Godot editor: Export > Linux (below) |
| `Dolphin/dolphin-emu-nogui` + `Dolphin/Sys` | GitHub Actions: "Linux build" (below) |
| `SparkingData/states`, `textures`, `saves/netplay` | the same as the Windows build (copy them) |

### Dolphin: GitHub Actions

`.github/workflows/linux.yml` builds Dolphin-Sparking on GitHub's Ubuntu 22.04 machines, so it
runs on older systems too. It uses Dolphin's own copies of its libraries and a static C++ runtime,
and fails if the result links anything a player might not have.

- It runs by itself on every push that changes Dolphin (`Source/`, `Data/Sys/`, ...) on a
  `sparking/...` branch. To run it by hand: Actions > "Linux build" > Run workflow (GitHub only
  shows that button for workflows on the default branch, `master`; on other branches, open the
  last run and "Re-run all jobs").
- The result: open the run, **Artifacts** > `dolphin-sparking-linux-x86_64`. It's a zip holding
  `dolphin-sparking-linux-x86_64.tar.gz`, which holds the `Dolphin` folder. Kept 30 days.
- The run's "Check what it needs from the system" step lists the libraries and the newest glibc
  it needs.

### The launcher: Godot export

In the editor: Project > Export > **Add... > Linux**:
- Name it "Linux". Export Path: e.g. `../../../SparkingRelease-Linux/DRAGON BALL Sparking! Collection.x86_64`.
- Options: **Binary Format > Embed PCK off** (as on Windows: launcher updates are then just the
  `.pck`), Architecture x86_64.
- Resources: the same filters as Windows (**Filters to export non-resource files**:
  `*.ini, *.json, *.txt, *.pem`; exclude `tests/*`).
- Export Project with **Export With Debug unticked**.

Encryption (optional, as on Windows: Frontend/Godot/README.md > "Protecting the .pck"): the Linux
template has to be built with your key too. Add the repository secret **GODOT_PCK_KEY** (GitHub >
Settings > Secrets and variables > Actions > New repository secret: the 64 characters of
`godot_pck_key.txt`), run "Linux build", download the artifact `godot-template-linux-encrypted`,
and in the Linux preset set Custom Template > Release to it, plus the same Encryption settings
and key as Windows. Without the secret, export the Linux launcher unencrypted.

### Put the build together

A folder next to the Windows one, e.g. `E:\SparkDol\DBZSC-linux`:

```
DRAGON BALL Sparking! Collection.x86_64     (Godot export)
DRAGON BALL Sparking! Collection.pck        (Godot export)
Dolphin\dolphin-emu-nogui                   (from the Actions artifact)
Dolphin\Sys\...                             (from the Actions artifact)
SparkingData\states\...                     (copy from the Windows build)
SparkingData\textures\...                   (copy from the Windows build)
SparkingData\saves\netplay\...              (copy from the Windows build)
```

The `.tar.gz` from the artifact can be unpacked on Windows with `tar -xzf file.tar.gz` (built into
Windows 10/11) or 7-Zip. Windows drops Linux's "executable" mark on the way: that's fine, the
package script and the launcher's updater put it back.

### Publish (automatic updates) and package (new players)

```
python Tools\sparking_release.py publish E:\SparkDol\DBZSC-linux --config C:\SparkingKeys\release.json --version 210 --platform linux
python Tools\sparking_release.py publish E:\SparkDol\DBZSC-linux --config C:\SparkingKeys\release.json --version 210 --platform linux --dry-run
python Tools\package_linux.py E:\SparkDol\DBZSC-linux E:\SparkDol\DBZSC-linux-210.tar.gz --config C:\SparkingKeys\release.json
```

- Linux launchers ask for the Linux list (`manifest-linux.json`), Windows ones for theirs. The
  files share one store: states, textures and saves both builds have are uploaded once.
- `release.json`: Linux reads `include_linux` / `exclude_linux` / `launcher_linux` when they're
  there, else defaults (the Windows ones with `*.x86_64` for `*.exe` / `*.ico`, and `exclude`).
- `package_linux.py` packs exactly what a Linux update holds (so a fresh install is up to date),
  in a folder "DRAGON BALL Sparking! Collection", with the launcher and Dolphin marked executable
  and a README for players. It refuses a Windows build folder.

## Trying it without a Linux PC

Windows 11 runs Linux apps with windows and sound through WSL: in PowerShell (admin)
`wsl --install -d Ubuntu-22.04`, restart, open "Ubuntu 22.04", then:

```
cd ~ && tar -xzf "/mnt/e/SparkDol/DBZSC-linux-210.tar.gz"
cd "DRAGON BALL Sparking! Collection" && ./"DRAGON BALL Sparking! Collection.x86_64"
```

(`/mnt/e/...` is the E: drive. Controllers aren't passed through to WSL; keyboard works.) A Steam
Deck in Desktop Mode is the best real test: unpack to the home folder, run it, then Steam > Add a
Non-Steam Game for Game Mode.

## What's different on Linux

- The launcher's own update finishes through a small shell script (instead of PowerShell): it
  waits for the launcher to close, copies the new `.x86_64` / `.pck` in, marks them executable,
  starts the launcher again (detached) and logs to `SparkingData/update/finish_update.log`.
- After every update the launcher marks `*.x86_64`, `*.sh` and Dolphin's programs executable, and
  makes Dolphin executable before starting it if it isn't.
- Online: Windows and Linux PCs play together (same x86-64 emulation). Keep both builds on the
  same Dolphin-Sparking version: publish them together.
- Not yet: a desktop menu entry / icon (players start the `.x86_64` directly), Wayland without
  XWayland, ARM Linux.
