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
                                  Controller Setup (placeholder)
                                  Modifications (Gecko codes, offline)
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
- the Gecko code list and the settings screens.

## Notes

- Godot 4.3 on Linux/macOS closes the frontend's stdin when it frees a process pipe, and the
  next launch then dies with SIGPIPE. `scripts/dolphin.gd` keeps finished pipes open to avoid
  this. Windows is not affected.
- Fonts: drop `menu.ttf` (titles/menus) and `body.ttf` into `fonts/` to replace Godot's
  built-in font.
