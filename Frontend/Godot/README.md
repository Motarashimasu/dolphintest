# DRAGON BALL Sparking! Collection — Godot frontend (test build)

A test frontend for one game, **Budokai Tenkaichi 3 PAL (RDSPAF)**. It drives the
Dolphin-Sparking build (`DolphinNoGUI.exe`) through its `[SPARKING]` stdin/stdout protocol
(`Docs/SPARKING.md`).

## Run it

1. Install **Godot 4.3 or newer** (the standard build, not .NET).
2. Rebuild Dolphin-Sparking from this branch. Borderless fullscreen and the in-game menu's
   "controller paused while the menu is open" need the new `DolphinNoGUI.exe`.
3. In Godot, use **Import** and pick `Frontend/Godot/project.godot`, then press **Run** (F5).
   - A newer Godot asks to convert the project once; say yes.
4. The first time, **Files & Folders** opens. Set:
   - `DolphinNoGUI.exe` (default `E:\SparkDol\dolphin-sparking\build\release\x64\Binaries`);
   - your BT3 game file;
   - the `SparkingData` folder (the one with `settings.bat`, `user`, `saves`, `states`, `textures`);
   - your netplay name and region.

Settings are saved in Godot's user folder (`%APPDATA%\Godot\app_userdata\DRAGON BALL Sparking! Collection PC\sparking.cfg`).

## Menus

```
Main Menu   Budokai Tenkaichi 3 > Play Offline
                                  Netplay > Lobby Browser
                                            Player Match > Host  (lobby options > Lobby)
                                                           Find  (Single / Team / Any > Lobby)
                                            Ranked Match (work in progress)
                                  Controller Setup (presets)
                                  Modifications (Gecko codes, offline)
                                  Tenkaichi Terminology > Movement / Offense / ... / Tech
            Video Settings  (renderer, resolution, window size / borderless)
            Options         (graphics, button prompts, aspect, HUD, FPS, Files & Folders)
            Exit
```

Controls: Up/Down move, Left/Right change a value, A / Enter / Space select, B / Escape back.
Mouse works too: wheel turns the carousel; click a value's left or right half to change it.

**Lobby.** Shows the room code or address, the players (slot, ping ± jitter, wired/Wi-Fi,
quality dot) and messages. You can also send a message, change the pad buffer (host), Start
Match (host), copy the room code, and Leave Lobby. Press B once to jump to Leave Lobby, and
press B again to leave.

**In game.** Hold **Select / Back / Share** for about 1 s. This window shrinks to a small menu
on top of the game:
- Netplay: messages, pad buffer, and **Stop Match** (ends the match for everyone and goes back
  to the lobby).
- Offline: graphics, button prompts, aspect ratio, and Stop Game.

While that menu is open, the game ignores the controller. "Back to the game" (or B) returns.

**Controller Setup.** Scroll through presets with Left/Right. The one you pick is written into
`SparkingData\user\Config\GCPadNew.ini` as `[GCPad1]` right away, and again before every
game. It's used offline and in netplay.
- **Auto** (the default) picks the preset that matches the first connected controller. If none
  matches, it leaves the mapping alone.
- Built-in presets: Xbox (your current mapping) and PlayStation 4/5 (the same layout through
  SDL; their device names aren't confirmed yet).
- Add your own: "Save current mapping as", or drop Dolphin GameCube pad profiles (`.ini`) into
  `SparkingData\controllers`.
- An optional `[Sparking]` section with `Match = word, word` tells Auto when to pick a preset.

Gecko codes always come from the build's own `Sys\GameSettings\RDSPAF.ini`. Nothing is taken
from regular Dolphin except `GCPadNew.ini` (once, by `1_setup.bat`).

**Tenkaichi Terminology.** Pick a category, then scroll through its terms; they can't be
selected. The definition shows at the bottom and the demo GIF on the right. Terms with a video
tutorial open it on A.
- Text: `data/terminology.json`, taken from the community doc.
- GIFs: downloaded from the doc the first time a term (or its category) is shown, into
  `SparkingData\terminology`, and played from there afterwards.
- To add or replace a demo, put a GIF named after the term in that folder, e.g.
  `dragon-dash.gif`, or `blast-2-boost_2.gif` for a second one.
- Godot can't play GIFs on its own, so `scripts/util/gif.gd` decodes them on a background
  thread.

**Splash.** `splash/splash.png` is shown in two places: as Godot's boot splash while the
engine starts, then for 2 s over the menu before fading out. Any button skips it. It's blank
(black) for now: replace that file, keeping the name, with your own image. 1920×1080 works
best; it's scaled to cover the window.

**Music.** Each menu has a track:

| Track | Plays on |
|---|---|
| `main_menu` | Main Menu, Video Settings, Options, Files & Folders. Also used for any track that has no file. |
| `game_menu` | the Budokai Tenkaichi 3 menu, Controller Setup, Modifications |
| `netplay` | Netplay, Player Match, Host, Find, Lobby Browser |
| `lobby` | the lobby screen |
| `terminology` | Tenkaichi Terminology |

- Put files named after them in `music/` (`main_menu.ogg`, ...; ogg, mp3 or wav), or in
  `SparkingData\music` (ogg or mp3; these override the ones in `music/` without re-exporting).
- Moving between screens with the same track keeps it playing; a different track crossfades.
- The music fades out when a game starts (offline or netplay) and resumes from the same spot
  when the game closes.
- Volume: Options > Music volume (0 = off).

## Tests

`tests/run_ui_tour.py` walks every screen with a real `dolphin-emu-nogui`. It sets up a fake
lobby server, has a second player join, and saves a screenshot of each screen:

```
python3 Frontend/Godot/tests/run_ui_tour.py build/Binaries/dolphin-emu-nogui <godot> [out_dir]
```

Linux only (`xvfb-run`). The tour covers:
- hosting, chat, buffer, start, the in-game menu and Stop Match;
- leaving the lobby;
- the browser and joining a lobby;
- matchmaking;
- offline play and live texture switching;
- the Gecko code list and the settings screens;
- controller presets;
- Terminology, with a fake doc server serving test GIFs;
- menu music (plays, switches per screen, mutes in game, resumes) and the splash.

`tests/gif_check.gd` decodes a folder of GIFs to PNGs, to compare the decoder against PIL.

## Notes

- Godot 4.3 on Linux/macOS closes the frontend's stdin when it frees a process pipe, and the
  next launch then dies with SIGPIPE. `scripts/dolphin.gd` keeps finished pipes open to avoid
  this. Windows is not affected.
- Exporting a standalone .exe: add `*.ini, *.json, *.txt` to the export preset's "Filters to export
  non-resource files" so the controller presets and terminology data are included.
- Fonts: drop `menu.ttf` (titles/menus) and `body.ttf` into `fonts/` to replace Godot's
  built-in font.
