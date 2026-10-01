# Dolphin-Sparking: frontend protocol

Dolphin-Sparking adds a machine-readable control channel to `dolphin-emu-nogui` (Windows:
`DolphinNoGUI.exe`) so an external frontend — the Sparking Godot app — can be the entire UI.
Dolphin never shows its own interface: in a netplay lobby it has no window at all, and when a
game starts it opens a bare render window that closes again when the game ends.

All fork code lives in `Source/Core/DolphinNoGUI/Sparking*.{h,cpp}`. The only upstream files
touched are `DolphinNoGUI/MainNoGUI.cpp` (hook calls, null-checks for the lobby's missing
window), `DolphinNoGUI/CMakeLists.txt`, and `Core/State.{h,cpp}` (a single-use permission for the
netplay boot-state load, plus reporting whether a load succeeded).

## Launching

| Mode | Command line |
|---|---|
| Solo game, frontend-controlled | `dolphin-emu-nogui --sparking -e <game> [-u <userdir>] [-s <state.sav>]` |
| Host netplay | `dolphin-emu-nogui --netplay-host <game> [--nickname N] [--automap wii\|gc\|none]` |
| Join netplay (room code) | `dolphin-emu-nogui --netplay-join <ROOMCODE> [--netplay-game <path>]...` |
| Join netplay (direct) | `dolphin-emu-nogui --netplay-join 1.2.3.4:2626 [--netplay-game <path>]...` |

Add `--state-dir <dir>` to any of these to enable battle states (see below).

Sparking-mode options (apply only with `--sparking` / `--netplay-*`; never written to Dolphin.ini):

| Option | Default | Effect |
|---|---|---|
| `--nand <dir>` | Dolphin's NAND | Wii NAND folder = where Wii game saves live. Use one folder for solo, another for netplay. |
| `--pads gc\|keep` | `gc` | GameCube controllers in the first ports, all Wii Remotes off. `keep` uses Dolphin.ini as-is. |
| `--local-players <1-4>` | `1` | Solo: how many GameCube ports are plugged in. |
| `--netplay-direct` | off | Host by IP:port instead of a room code. By default hosting uses Dolphin's traversal server (`stun.dolphin-emu.org`, ports 6262/6226) and gets a room code, whatever `Dolphin.ini` says. |
| `--automap gc\|wii\|none` | `gc` | Netplay host: joiners get the next free GameCube port. |
| `--gecko <name>` (repeatable) / `--no-gecko` | ini selection | Solo: exactly these Gecko codes on, everything else off, for this run. |
| `--netplay-gecko <port>=<name>` (repeatable) | none | Netplay: the player on GameCube port `<port>` runs only these codes. Everything else is off for everyone, and Dolphin's "Sync Codes" is forced off. |
| `--list-gecko <GAMEID>[:<rev>]` | | Print every Gecko code Dolphin knows for the game (`gecko_codes` event), then exit. Starts no game. |
| `--netplay-saves host-readonly\|keep` | `host-readonly` | Netplay: every player plays on the **host's** save, which is never written back. |

Dolphin's own Discord Rich Presence ("Playing on Dolphin") is always switched off in Sparking
mode so it can't overwrite the frontend's presence.

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
| `game_booting` | `path`, `battle_state` (file name or empty) | Boot parameters ready, window about to open |
| `game_info` | `game_id`, `title`, `revision`, `netplay`, `session` (effective `pads`, `wiimotes`, `nand`, `dolphin_discord`, `netplay_save_load/write`) | Just before `game_started`; feed it to Discord presence |
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
| `gecko_codes` | `game_id`, `codes[]` | `--list-gecko` result |
| `gecko_active` | `port` (0 = solo), `codes[]`, `missing[]` | Codes activated for this boot |
| `state_file_saved` | `name`, `sha1` | Solo: a `save_state_file` capture is fully on disk |
| `state_applied` | | A save state really loaded (solo load, or the netplay battle state at boot) |
| `save_data` | `host_hash`, host also `ready`, clients `local_status` | Netplay save fingerprint check updated |
| `battle_state` | `active`, `name`, `sha1`, `local_ok`, host also `ready` | Battle-state selection changed or a player verified it |
| `alert` | `severity`, `caption`, `text`, `auto_answer` | A Dolphin panic/assert alert. In Sparking mode these never open a Dolphin dialog; they are reported here and answered "yes/ok" so emulation continues. |
| `error` | `code`, plus context | See below |
| `exit` | `code` | Last line before the process exits |

Host `players[]` entries also carry `state_status`: `ok`, `missing`, `mismatch`, `pending`, or
empty when no battle state is selected.

`players[].status` is one of `ok`, `wrong_hash`, `wrong_disc`, `wrong_revision`,
`wrong_region`, `not_found`, `unknown`. Slots are 1–4, or -1 if unassigned.

Error codes: `invalid_game`, `listen_failed`, `no_session_target`, `bad_address`,
`connect_failed`, `connection_error`, `traversal_error` (+`reason`), `host_only`,
`not_all_players_have_game`, `game_not_found`, `start_rejected`, `platform_init_failed`,
`boot_failed`, `not_running`, `gecko_needs_exec`, `save_data_mismatch`, `battle_state_not_ready`, `no_state_dir`, `bad_state_name`,
`state_file_missing`, `state_save_failed`, `state_load_failed`, `not_allowed_in_game`, `not_allowed_in_netplay`, `bad_argument`, `unknown_command`.

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
| `battle_state <file.sst>` / `battle_state none` | host | Select the state everyone boots into |
| `save_check` | host | Re-verify that every player's netplay save matches the host's |
| `players` | any | Re-send the `players` event now |
| `pause` / `resume` | solo | |
| `save_state <1-10>` / `load_state <1-10>` | solo | Slot save states |
| `save_state_file <file.sst>` / `load_state_file <file.sst>` | solo | Capture / test a battle state in `--state-dir` |
| `quit` | any | Stop any game and exit |

Always send `hello` first. If Dolphin is launched without a stdin pipe it keeps running on EOF.

## Battle states (Single Battle / Team Battle)

The host picks a save state and every player boots straight into it, e.g. the BT3 character
select screen of Single Battle or Team Battle, so nobody navigates menus online.

1. **Capture once** (solo): launch the game with `--sparking --state-dir <dir>`, navigate to the
   screen, send `save_state_file BT3-SingleBattle.sst`. Wait for `state_file_saved`. Capture with
   the same per-game settings profile Godot uses for netplay.
2. **Ship** the `.sst` files with the app so every player has identical bytes in `--state-dir`.
3. **In the lobby** the host sends `battle_state BT3-SingleBattle.sst`. Dolphin hashes it (SHA-1)
   and tells every peer the name + hash; each peer checks its own copy and replies `ok`,
   `missing` or `mismatch` (visible in `players[].state_status` and `battle_state.ready`).
   Joiners who arrive later are asked automatically.
4. **`start`** is refused with `battle_state_not_ready` until every player is `ok`
   (`start force` overrides; a peer without the file would then desync).
5. At boot each peer injects the state and loads it before the first frame, emitting
   `state_applied`. Upstream Dolphin blocks all state loads during netplay; the fork allows
   exactly this one, because identical bytes loaded before any input keep everyone in sync.

Only the name and hash cross the network (sent as hidden control messages on the netplay chat
channel, so Core's packet protocol is unchanged). Names are restricted to `[A-Za-z0-9._-]`
ending in `.sst` or `.sav` (regular Dolphin's "Save State to File" format), so a host can't make peers read outside their state folder. States are tied
to this Dolphin build; recapture them after updating the fork.

## Save data: solo vs netplay

Wii games keep their saves in Dolphin's emulated Wii NAND, so separate saves = separate NAND
folders:

```
<app>/saves/solo/      ← --nand for solo play; normal progress, written as you play
<app>/saves/netplay/   ← --nand for netplay; ships with your 100%-unlocked save
```

**Every player must have a byte-identical netplay save, or the match desyncs** (confirmed in
testing, even with Dolphin's host-save sync on). So the fork verifies it:

- When the host picks a game, and whenever someone joins, the host fingerprints its save
  (SHA-1 over every file under `title/…/data` in its `--nand`) and sends the fingerprint.
- Each player fingerprints their own copy and answers `ok`, `mismatch` or `missing`
  (`players[].save_status` on the host, `save_data` events on everyone).
- `start` is refused with `save_data_mismatch` until every player is `ok` (`start force`
  overrides). After a player fixes their files, the host sends `save_check` to re-verify.

Ship the same unlocked save in every install's `saves/netplay/`. On top of that,
`--netplay-saves host-readonly` (default) keeps Dolphin's save sync on and write-back off, so the
netplay save is never modified by a match.

To install the unlocked save into `saves/netplay/`: in regular Dolphin set
Config → Paths → Wii NAND Root to that folder, then Tools → Import Wii Save (`data.bin`) — or copy
the save's `title/00010000/<id>/data/` folder into the same place inside it.

## Gecko codes

BT3 PAL (`RDSPAF`) ships with its codes built in: `Data/Sys/GameSettings/RDSPAF.ini` (PS2
control layout, PAL60, outlines, 16:9, soft reset, World Tournament stages = on by default;
`Player 1/2 Splitscreen Remover` = per-port netplay codes).

Game IDs: BT3 = `RDSE70` (US) / `RDSPAF` (EU) / `RDSJAF` (Sparking! Meteor); BT2 = `RDBE70` (US) /
`RDBPAF` (EU) / `RDBJAF` (Sparking! Neo). Dolphin ships no Gecko codes for these games; codes
come from the user's `GameSettings/<ID>.ini` (e.g. ones the frontend writes).

- **Per-game code tab in Godot:** run `dolphin-emu-nogui --list-gecko RDSE70` once per game. It
  prints a `gecko_codes` event with every code from Dolphin's bundled and user `GameSettings`
  (`name`, `creator`, `notes`, `default_enabled`, `user_defined`, `lines`). Godot stores the
  player's toggles itself.
- **Solo:** launch with one `--gecko "<name>"` per enabled code (or `--no-gecko`). Dolphin
  activates exactly those for that run; the game's ini is never edited.
- **Netplay:** everyone runs the game's default-on codes (`[Gecko_Enabled]` in the Sys + user
  game inis; `--netplay-gecko-defaults off` disables that), plus only the codes mapped to the
  port each player lands on. Every other code is off. Per-port codes are never part of the
  defaults, even if an ini enables them. The lobby's save check also fingerprints this code
  setup (code names + exact lines); a player whose codes differ shows
  `save_status: codes_mismatch` and `start` is refused. Port mapping example:
  `--netplay-gecko "1=Splitscreen Remover P1" --netplay-gecko "2=Splitscreen Remover P2"`.
  Pass the same list to host and guests; each Dolphin picks its own port at boot (the host is
  normally port 1, the first guest port 2). Each player's `gecko_active` event confirms which
  codes it actually loaded, and `game_info.session.gecko_active_count` confirms the emulator's
  count.
- Codes that differ per player must only change presentation (camera, viewport, HUD), never
  game logic, or the match desyncs. Keep each player's code the same length, so Dolphin's code
  handler costs the same emulated CPU time on every machine.

## Controllers

With `--pads gc` (default) the game sees GameCube controllers only; Wii Remotes are off. The
physical controller each player uses is Dolphin's GameCube pad profile for **port 1**
(`Config/GCPadNew.ini`, `[GCPad1]`) — in netplay too, since each player's local port 1 drives
their assigned slot. The frontend writes that profile from its controller settings.

## Discord Rich Presence

The frontend owns presence with its own Discord application ID (it runs across menus, the lobby
and matches; Dolphin only runs during the latter two). Useful inputs: `game_info.title`,
`room.code` (join secret for "Ask to Join"), `players` count/max, `battle_state.name`
(Single/Team Battle), `game_started`/`game_stopped` for timestamps.

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
