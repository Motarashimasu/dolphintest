# Dolphin-Sparking: frontend protocol

Dolphin-Sparking adds a machine-readable control channel to `dolphin-emu-nogui` (Windows:
`DolphinNoGUI.exe`) so an external frontend — the Sparking Godot app — can be the entire UI.
Dolphin never shows its own interface: in a netplay lobby it has no window at all, and when a
game starts it opens a bare render window that closes again when the game ends.

All fork code lives in `Source/Core/DolphinNoGUI/Sparking*.{h,cpp}`. The only upstream files
touched are `DolphinNoGUI/MainNoGUI.cpp` (hook calls, null-checks for the lobby's missing
window) and `DolphinNoGUI/CMakeLists.txt`.

## Launching

| Mode | Command line |
|---|---|
| Solo game, frontend-controlled | `dolphin-emu-nogui --sparking -e <game> [-u <userdir>] [-s <state.sav>]` |
| Host netplay | `dolphin-emu-nogui --netplay-host <game> [--nickname N] [--automap wii\|gc\|none]` |
| Join netplay (room code) | `dolphin-emu-nogui --netplay-join <ROOMCODE> [--netplay-game <path>]...` |
| Join netplay (direct) | `dolphin-emu-nogui --netplay-join 1.2.3.4:2626 [--netplay-game <path>]...` |

`-p win32` (Windows), `-p x11` (Linux) or `-p macos` pick the render window type; the default
is the best one available. `-p headless` renders nothing and is only useful for testing.

Netplay settings not on the command line (traversal vs direct, ports, buffer, save-data sync,
Gecko code sync, host input authority) are read from `Dolphin.ini [NetPlay]`, which the Godot
`ConfigWriter` writes before launch. Joining players find the host's game among the
`--netplay-game`/`-e` paths plus Dolphin's configured game folders.

## Events (stdout)

One JSON object per line, prefixed with `[SPARKING] `. Every object has an `"event"` key first.
Ignore any stdout line without the prefix (Dolphin's own logging).

```
[SPARKING] {"event":"ready","protocol":1,"mode":"netplay"}
[SPARKING] {"event":"lobby_opening","role":"host","traversal":true,"nickname":"Goku","known_games":3}
[SPARKING] {"event":"lobby_ready","role":"host"}
[SPARKING] {"event":"room","type":"traversal","state":"ready","code":"a1B2c3D4"}
[SPARKING] {"event":"players","players":[{"pid":1,"name":"Goku","ping":0,"status":"ok","is_host":true,"gc_slot":-1,"wii_slot":1,"mapping":"1","revision":"..."}],"all_have_game":true,"in_game":false}
```

| Event | Fields | When |
|---|---|---|
| `ready` | `protocol`, `mode` (`solo`/`netplay`) | Process started, options parsed |
| `hello` | `protocol` | Reply to the `hello` command |
| `lobby_opening` | `role`, `traversal`, `nickname`, `known_games` | About to connect |
| `lobby_ready` | `role` | Connected; lobby is live |
| `room` | `type` (`traversal`/`direct`), `state` (`connecting`/`ready`/`failed`), `code` or `port`+`addresses` | Host only; re-sent whenever it changes |
| `players` | `players[]`, `all_have_game`, `in_game` | On any change, and every 1 s (pings) |
| `player_joined` / `player_left` | `name` | |
| `game_changed` | `name`, `game_id`, `local_status` | Host picked a game |
| `chat` | `text`, `self`, (`from` when self) | |
| `game_starting` | | Host pressed start; save/code sync may follow |
| `sync_begin` / `sync_progress` / `sync_end` | `title`, `bytes` / `pid`, `bytes` | Netplay save-data transfer |
| `game_booting` | `path` | Boot parameters ready, window about to open |
| `game_started` | | Emulation actually running (first transition to Running) — hide the Godot window, commands are safe now |
| `emulation_state` | `state` (`starting`/`running`/`paused`/`stopping`/`uninitialized`) | Every core state change |
| `game_stopping` | | Server ordered a stop |
| `game_stopped` | | Window closed, back in the lobby — show the Godot window |
| `game_start_aborted` | | |
| `buffer_changed` | `buffer` | |
| `host_input_authority` | `enabled` | |
| `golfer_changed` | `is_golfer`, `name` | |
| `desync` | `frame`, `player` | |
| `connection_lost` | | |
| `state_saved` / `state_loaded` | `slot` | Solo only |
| `alert` | `severity`, `caption`, `text`, `auto_answer` | A Dolphin panic/assert alert. In Sparking mode these never open a Dolphin dialog; they are reported here and answered "yes/ok" so emulation continues. |
| `error` | `code`, plus context | See below |
| `exit` | `code` | Last line before the process exits |

`players[].status` is one of `ok`, `wrong_hash`, `wrong_disc`, `wrong_revision`,
`wrong_region`, `not_found`, `unknown`. Slots are 1–4, or -1 if unassigned.

Error codes: `invalid_game`, `listen_failed`, `no_session_target`, `bad_address`,
`connect_failed`, `connection_error`, `traversal_error` (+`reason`), `host_only`,
`not_all_players_have_game`, `game_not_found`, `start_rejected`, `platform_init_failed`,
`boot_failed`, `not_running`, `not_allowed_in_netplay`, `bad_argument`, `unknown_command`.

## Commands (stdin)

Plain text, one per line: a command name, optionally a space and an argument.

| Command | Who | Effect |
|---|---|---|
| `hello` | any | Handshake. After this, stdin closing (frontend exited) makes Dolphin quit. |
| `start` / `start force` | host | Start the game (`force` skips the "everyone has the game" check) |
| `chat <text>` | any | Send a chat message |
| `stop` | any | Stop the running game for everyone (solo: stop and exit) |
| `buffer <n>` | host | Set pad buffer |
| `kick <pid>` | host | Kick a player |
| `automap wii\|gc\|none` | host | Auto-assign joiners to Wii Remote / GC slots in join order |
| `players` | any | Re-send the `players` event now |
| `pause` / `resume` | solo | |
| `save_state <1-10>` / `load_state <1-10>` | solo | Slot save states |
| `quit` | any | Stop any game and exit |

Always send `hello` first. If Dolphin is launched without a stdin pipe it keeps running on EOF.

## Godot side (sketch)

```gdscript
var proc := OS.execute_with_pipe(dolphin_path, ["--netplay-host", game_path, "--nickname", nick])
var io: FileAccess = proc["stdio"]
io.store_line("hello")

# Pipe reads block, so read on a thread and hand events to the main thread.
var reader := Thread.new()
reader.start(func():
    while io.is_open() and io.get_error() == OK:
        var line := io.get_line()
        if line.begins_with("[SPARKING] "):
            _on_event.call_deferred(JSON.parse_string(line.substr(11)))
)

func send(cmd: String) -> void:
    io.store_line(cmd)   # e.g. send("start"), send("chat gg")
```
