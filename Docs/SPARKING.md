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
| `--textures <Group>=<Option>` (repeatable) | none | Texture variant to load, i.e. folder `@<Group>/<Option>` in the game's texture pack. Turns custom textures on. See *Texture variants*. |
| `--textures-dir <dir>` | `<user>/Load/Textures` | Texture library folder (holds `<GAMEID>/` folders), shared by every profile. |
| `--list-textures <GAMEID>` | | Print the game's variant groups and options (`texture_groups` event), then exit. |
| `--hud on\|off` | `on` | Temporary in-game HUD drawn by Dolphin: round score in the centre of BT3's top HUD, player names under each health bar (P1 left, P2 right; long names shrink, then get cut with "..."), health % in the window's top corners, and in netplay the ping + pad buffer at the bottom centre. Needs the game's `p1/p2_health_pct` watches. **For the Godot overlay this whole HUD is netplay-only.** |
| `--osd-messages on\|off` | `off` | Draw Dolphin's own on-screen messages. Off: they are sent as `osd` events for the frontend's overlay instead. (The FPS counter, `Graphics.Settings.ShowFPS`, is separate.) |
| `--background-input on\|off` | `on` | Controllers keep working while another window, e.g. the overlay, has focus. |
| `--stats-interval <ms>` | `0` | Emit a `stats` event every `<ms>` in game (0 = off). Same as the `stats` command. |
| `--aspect 16:9\|4:3` | `16:9` | Starting aspect ratio. **F5** in the game window (or the `aspect` command) flips it. See *Display*. |
| `--resolution <n>` | `3` | Internal resolution as a multiple of native: `3` = 1080p, `2` = 720p, `4` = 1440p, `6` = 4K. |
| `--window <W>x<H>` | `1280x720` | Size of the game window. Rendering stays at `--resolution` regardless. |
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
| `aspect` | `mode` (`16:9`/`4:3`) | At every boot and after every toggle |
| `peek` | `address`, `value` (hex) | Answer to `peek` |
| `window` | `open`, `x`, `y`, `width`, `height`, `focused`, `minimized`, `handle` | Game window changed (Windows). `x/y/width/height` = the picture area in screen pixels; `open:false` when the window closes. See *Overlay*. |
| `osd` | `kind` (`message`, `netplay_ping`, `netplay_buffer`), `text`, `ms`, `color` (`#RRGGBB`) | A Dolphin on-screen message, for the overlay to show its own way |
| `stats` | `fps`, `vps`, `speed` (% of full speed) | Every `stats` interval while the game runs |
| `watches_loaded` | `watches[]`, `triggers[]` | Game started; the memory watches/triggers from its game ini |
| `watch` | `name`, `value` (number, or `null` if unreadable); for `p1_`..`p4_` names also `port`, `player`, `label` | A watched memory value changed (every watch is sent once at game start) |
| `watch_values` | `values` (`{name: value}`) | Answer to `watch_values` |
| `game_event` | `name`; for `p1_`..`p4_` names also `port`, `player`, `label` | A trigger's condition just became true (e.g. `p1_defeated` → `player: "Goku"`, `label: "Goku_defeated"`) |
| `round_started` | `round`, `p1`, `p2` | Both sides are back at 100% health: a new round is live |
| `round_result` | `round`, `winner_port`, `winner`, `loser_port`, `loser`, `wins` (`{name: rounds won}`), `local_result` (`win`/`lose`, absent for spectators) | A side hit 0% in a live round and the other side was still alive ~0.75 s later: the other side scores. Nothing more counts until both are at 100% again. |
| `round_void` | `round`, `reason` (`both_health_zero`) | Both sides hit 0% within ~0.75 s (leaving a match, loading the next one): nobody scores |
| `score` | `wins`, `rounds` | After `score reset` |
| `hud` | `enabled` | After a `hud` command |
| `poked` | `address`, `value` | Answer to `poke` |
| `texture_groups` | `game_id`, `groups[]` of `{name, options[]}` | `--list-textures` result |
| `textures` | `selection` (`{group: option}`, lowercase) | After a `textures` command |
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
`state_file_missing`, `state_save_failed`, `state_load_failed`, `not_allowed_in_game`, `not_allowed_in_netplay`, `bad_argument`, `no_such_group`, `bad_watch`, `bad_trigger`, `unknown_command`.

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
| `aspect 16:9\|4:3\|toggle` | any, in game (netplay too) | Same as F5. Each player chooses their own. |
| `watch_values` | any | Send every memory-watch value now |
| `stats <ms>` | any | Start (`stats 500`) or stop (`stats 0`) the periodic `stats` event |
| `textures <Group>=<Option>` | any, in game (netplay too) | Switch a texture variant live; `<Group>=` clears it (no option loaded) |
| `textures_cycle <Group>` | any, in game | Next option of a group (alphabetical, wraps) — what F3/F4 do |
| `texture_path <tex1_name>` | any | Debug: which file a texture name is loaded from right now (`texture_path` event) |
| `hud on\|off` | any | Show/hide the temporary in-game HUD |
| `score reset` | any | Set the round score back to 0-0 |
| `poke <hex address> <hex value>` | solo | Debug: write a 32-bit word of game memory |
| `peek <hex address>` | solo | Debug: read a 32-bit word of game memory |
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

## Display

Sparking mode renders at 1080p (`--resolution 3`) with Dolphin's output forced to 16:9.
**F5** in the game window (Windows), or the `aspect` command, switches the output between
16:9 and 4:3. Only Dolphin's output stretch changes: the game's own widescreen Gecko code (e.g.
BT3's "16:9 aspect ratio") stays on whichever is chosen. The choice carries over to the next
match in the same netplay session, and each netplay player has their own.

## Texture variants (graphics pack, button layouts, ...)

Normal Dolphin loads every texture under `Load/Textures/<GAMEID>/`, and when two files have the
same name an arbitrary one wins, so alternative versions of the same texture can't live side by
side. Sparking adds switchable **variant groups**: any folder whose name starts with `@` is a
group, and each subfolder of it is one option.

```
<textures-dir>/RDSPAF/
  @Graphics/
    Enhanced/     the HD texture pack (everything)        --textures Graphics=Enhanced
    Legacy/       empty: the game's original textures      --textures Graphics=Legacy
  @Buttons/
    Vanilla/      GameCube buttons (HD ones, or empty = the game's own)
    PlayStation/  PlayStation button textures              --textures Buttons=PlayStation
    Xbox/         Xbox button textures                     --textures Buttons=Xbox
  (anything outside @ folders is always loaded)
```

Rules:
- Only the selected option of each group is loaded; the other options are ignored completely.
  A group with no selection, or an option with no folder, loads nothing from that group.
- **Ownership:** a texture name that appears anywhere in a group's options belongs to that
  group, and is only ever loaded from that group's selected option. If that option doesn't have
  it, the game's original is shown, never a copy from the base pack or from another group.
- A name that two groups both have belongs to the **smaller** group (fewer textures; ties by
  name), i.e. the more specific one. So if the HD pack also contains button textures, `@Buttons`
  still decides every button, and Enhanced/Legacy never changes the button prompts.
- Folders inside an option are fine (`@Graphics/Enhanced/menus/...`). Files placed directly in
  an `@Group/` folder are never loaded. Group and option names are case-insensitive.
- In game, `textures Graphics=Legacy` / `textures Buttons=Xbox` switch live; the new textures
  appear within a frame or two.
- Hotkeys in the game window (Windows): **F3** cycles `@Graphics`, **F4** cycles `@Buttons`
  (options in alphabetical order, wrapping), **F5** toggles 16:9 / 4:3. Every switch emits a
  `textures` event with the new selection so the frontend can remember it.
- Purely visual, so each netplay player can use their own.
- Godot settings: `--list-textures RDSPAF` gives the groups and choices; launch with one
  `--textures Group=Choice` per group.

## Overlay

**Plan (decided):** Godot draws all in-game UI on its **own transparent, borderless,
click-through, always-on-top window** placed exactly over the game window ("Option 1").
Dolphin draws no UI of its own and feeds the overlay:

- `window` events: where the picture is (client area, screen pixels), focus, minimized. Move and
  resize the overlay window to match; hide it when `minimized` or `open:false`.
- `osd` events: Dolphin's on-screen messages (netplay ping/buffer changes, "custom textures
  loaded", ...), since Dolphin no longer draws them (`--osd-messages on` brings them back).
- `stats` events: FPS / VPS / speed for a HUD. Netplay pings are in the `players` event.
- Controllers keep working while the overlay has focus (`--background-input`, default on).

Notes for the Godot side:
- Make the overlay window non-activating/click-through except when it shows something
  interactive (pause menu). While the overlay has focus, the F3/F4/F5 hotkeys (which only fire
  when the game window is focused) don't trigger, so the overlay should offer the same actions
  via the `textures_cycle`, `textures` and `aspect` commands.
- Use the game in a borderless/maximized window, not exclusive fullscreen (nothing can be drawn
  over exclusive fullscreen; this build has none anyway).

**Kept in mind for later:**
- *Option 3*: overlay drawn inside Dolphin (its ImGui layer) with custom fonts/images, content
  sent by Godot over stdin. Frame-exact and works in any window mode; good for a few simple
  elements (toasts, round timer) if the Godot window ever proves unsuitable.
- *Option 2* (rejected for now): Dolphin rendering into Godot's window/scene. Embedding the game
  as a child window still can't be drawn over; sharing frames as a GPU texture is a large,
  backend-specific job; copying frames through RAM adds input lag.

## Memory watcher (match results, HUD data)

Each game can name values in its memory; Dolphin reads them every frame (without slowing the
game) and reports changes. Defined in the game ini (bundled `Sys/GameSettings/<ID>.ini`, or the
user's `GameSettings/<ID>.ini`, which overrides entries with the same name):

```ini
[Sparking.Watch]
# name = type address [> offset > offset ...]     types: u8 u16 u32 s8 s16 s32 f32
p1_health_pct = f32 0x803D1024
p1_hp         = u32 0x80400000 > 0x1C       # pointer: read the u32 at 0x80400000, add 0x1C,
                                            # read the value there (chain as many as needed)
[Sparking.Trigger]
# name = watch op number [&& watch op number ...]  ops: == != < <= > >=
p1_ko = p1_health_pct <= 0
```

- Addresses are game addresses as Dolphin's memory tools show them: `0x80000000`– (MEM1) and
  `0x90000000`– (Wii MEM2). Anything else, or a broken pointer, reads as `null`.
- `watch` is sent for every watch at game start and then on every change (floats rounded to 3
  decimals). `game_event` fires when a trigger goes from false to true; a condition that is
  already true when the game starts doesn't fire.
- Names starting with `p1_`..`p4_` belong to the player on that GameCube port. Their events also
  carry `port`, `player` (in netplay: that player's username; in solo: `--nickname` for port 1,
  else `P1`..`P4`) and `label` (the name with `p1` replaced by the username, e.g.
  `Goku_defeated`). Ports are read from the netplay pad mapping at every match start.
- Netplay keeps both games identical, so every player sees the same values and events — the
  basis for ranked results (both clients report, the server accepts matching reports).

**BT3 PAL (RDSPAF)**:
- `p1_health_pct` (`0x803D1024`) and `p2_health_pct` (`0x803D1028`): each side's health in percent
  (current HP / max HP × 100). In Team Battle it is the whole team's combined health. Verified:
  P1 94.125 with 37650/40000 HP; P2 0 when dead; team totals in Team Battle.
- Triggers `p1_defeated` / `p2_defeated`: that side's health reached 0 = that side lost the
  match (Single and Team Battle alike). Winner = the other side.

- Round counting (temporary HUD score bar + `round_result`): a round is live once both sides are
  at 100%. When a side reaches 0%, the result waits ~0.75 s: if the other side is still alive
  it's a KO and the other side scores; if both are at 0% by then (BT3 clears both values when
  leaving a match or loading the next one from character select) the round is void
  (`round_void`). Nothing more counts until both are at 100% again. Scores are per player name,
  last for the whole boot (all rematches) and reset when the game is rebooted or closed. The
  `*_defeated` triggers stay available as raw events.

Still to check:
- that both addresses are the same in every new battle (MEM1, so likely);
- time-out wins (no one reaches 0): compare the two percentages when the timer ends.

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
