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
4. The first time only, **Welcome** asks for your BT3 game file, netplay name and region.

Dolphin-Sparking and SparkingData are found automatically: next to the launcher, or up to 4
folders above it. In the development layout that's
`dolphin-sparking\build\release\x64\Binaries\DolphinNoGUI.exe` and `E:\SparkDol\SparkingData`.
Settings are saved in `SparkingData\frontend.cfg`, so moving the folder keeps them. Older
settings from Godot's user folder are copied over once.

## Packaging (one folder for players)

```
DRAGON BALL Sparking! Collection\
  DRAGON BALL Sparking! Collection.exe   the exported frontend
  Dolphin\                               everything from build\release\x64\Binaries
                                         (DolphinNoGUI.exe, Sys\, DLLs)
  SparkingData\                          user, saves, states, textures, music, controllers
```

1. In Godot, choose **Project > Export > Windows Desktop > Export Project**. The preset is
   included and writes `E:\SparkDol\SparkingRelease\DRAGON BALL Sparking! Collection.exe`.
   - The first time, Godot asks you to download its export templates; one click.
2. Copy the `Binaries` folder into `SparkingRelease` and rename it to `Dolphin`.
3. Copy `SparkingData` into `SparkingRelease`. Leave out `frontend.cfg` and anything else
   personal.

Players then only pick their game file once. Dolphin can't run from inside the Godot `.exe`
itself (it's a separate program with its own files), so it ships beside it in the same folder.

## Menus

```
Main Menu   Budokai Tenkaichi 3 > Play Offline
                                  Netplay > Lobby Browser
                                            Player Match > Host  (lobby options > Lobby)
                                                           Find  (Single / Team / Any > Lobby)
                                            Ranked Match (work in progress)
                                  Controller Setup (presets)
                                  Modifications > Graphics (Enhanced / Legacy)
                                                  Button Prompts (GameCube / PlayStation / Xbox)
                                                  Codes (offline)
                                  Tenkaichi Terminology > Movement / Offense / ... / Tech
            Video Settings  (renderer, resolution, window size / borderless)
            Options         (aspect, music volume, health %, match HUD, FPS, profile)
            Exit
```

Controls: Up/Down move, Left/Right change a value, A / Enter / Space select, B / Escape back.

**Controllers in the menus.** Xbox One / Series, DualShock 4 and DualSense work as soon as
they're plugged in.
- D-pad or left stick moves; holding a direction repeats it.
- A / Cross (or Start) selects; B / Circle goes back.
- The button prompts follow the controller you used last: A/B, ×/O, or Enter/Esc.

**In-game HUD.** Two separate options:
- **Health %** (Options, on by default): both fighters' health in the top corners.
- **Match HUD** (score bar, plus ping and buffer): always on in netplay matches. Offline it's
  off unless Options > Match HUD offline is turned on.

**Lobby.** Shows the room code or address, the players (slot, ping ± jitter, wired/Wi-Fi,
quality dot) and messages. You can also send a message, change the pad buffer (host), Start
Match (host), copy the room code, and Leave Lobby. Press B once to jump to Leave Lobby, and
press B again to leave.

**In game.** Hold **Select / Back / Share** for about 1 s. This window shrinks to a small menu
on top of the game:
- Netplay: messages, pad buffer, and **Stop Match** (ends the match for everyone and goes back
  to the lobby).
- Offline: graphics, button prompts, aspect ratio, and Stop Game.

While that menu is open it has the controller and the game ignores it. Dolphin also lets the
menu take the focus from the game window. "Back to the game" (or B) hands the focus back to
the game window (Dolphin raises it itself, since Windows won't let it happen on its own) and
the menu window minimises.

**Window.** The menus open in borderless fullscreen; Video Settings > Menu display switches to
a 1280 x 720 window. While a game runs they stay minimised.

**Modifications.** Graphics and Button Prompts each list their options; the current one is
marked "Selected". A choice is saved for the next game, and switched live if a game is running.
The GameCube prompts are the `@Buttons/Vanilla` texture folder; the folder keeps that name, only
the menus call it GameCube.

**Controller Setup.** Scroll through presets with Left/Right. The one you pick is written into
`SparkingData\user\Config\GCPadNew.ini` as `[GCPad1]` right away, and again before every
game. It's used offline and in netplay.
- **Auto** (the default) picks the preset that matches the first connected controller. If none
  matches, it leaves the mapping alone.
- Built-in presets: Xbox (your current mapping) and PlayStation 4/5 (the same layout through
  SDL; their device names aren't confirmed yet).
- **Create New Config / Edit This Config:** pick a GameCube button, press A, then press the
  button you want for it. The selection then moves to the next one.
  - The strip at the top shows live what the menus see and what Dolphin sees from your
    controller. If Dolphin sees nothing, the game won't either.
  - Bindings use Dolphin's own names (from `DolphinNoGUI --input-test`). Configs are saved to
    `SparkingData\controllers` and selected right away.
- You can also drop Dolphin GameCube pad profiles (`.ini`) into `SparkingData\controllers`.
- F12 shows the controllers Godot sees and each press it received (and whether it was ignored).
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

**Changing the look (in the Godot editor).**
- **Colors, fonts, pictures:** open `look/menu_look.tres` and change it in the Inspector. That
  covers the title, the menu wheel (highlight band color or picture, text colors and size,
  letter icons, arrows), per-item colors, the description bar, panels and rows, toasts,
  fonts, and a background picture per menu (main_menu, game_menu, netplay, lobby,
  terminology, or one default).
- **Background:** `scenes/Backdrop.tscn` is the scene behind every menu: the sky, the clouds
  and the ground. Open it in the 2D editor to recolor, move, delete or replace anything, or add
  your own art and animations. A menu picture from the look covers it (its `Scenery` node
  hides).
- Save, then run (F5). In the running menus, **F9** reloads both without restarting.

The menus take controller and keyboard only: the mouse is hidden and ignored, so it can't
steal the selection.

**Splash.** `splash/splash.png` is shown in two places: as Godot's boot splash while the
engine starts, then for 2 s over the menu before fading out. Any button skips it. It's blank
(black) for now: replace that file, keeping the name, with your own image. 1920×1080 works
best; it's scaled to cover the window.

**Music.** Each menu has a track:

| Track | Plays on |
|---|---|
| `main_menu` | Main Menu, Video Settings, Options, Welcome. Also used for any track that has no file. |
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
- Fonts: titles use the title font (Godot's own, bold), button text (menu wheel, settings rows,
  button hints) uses **Impact**, and descriptions and everything else use **Tahoma**. Impact and
  Tahoma come with Windows and are loaded from the PC, so they aren't shipped with the launcher;
  on a PC without them Godot's own font is used. To change any of them, set them in
  `look/menu_look.tres` (Menu font / Button font / Body font), or drop `menu.ttf`, `button.ttf`
  or `body.ttf` into `fonts/`.
