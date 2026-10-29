# Dolphin-Sparking: frontend protocol

Dolphin-Sparking adds a machine-readable control channel to `dolphin-emu-nogui` (Windows:
`DolphinNoGUI.exe`) so an external frontend — the Sparking Godot app — can be the entire UI.
Dolphin never shows its own interface: in a netplay lobby it has no window at all, and when a
game starts it opens a bare render window that closes again when the game ends.

All fork code lives in `Source/Core/DolphinNoGUI/Sparking*.{h,cpp}`. The only upstream files
touched are `DolphinNoGUI/MainNoGUI.cpp` (hook calls, null-checks for the lobby's missing
window), `DolphinNoGUI/CMakeLists.txt`, and `Core/State.{h,cpp}` (a single-use permission for the
netplay boot-state load, plus reporting whether a load succeeded).

The Godot test frontend that speaks this protocol lives in `Frontend/Godot` (see its README).

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
| `--gecko-extra <name>` (repeatable) | | Solo: the game's default Gecko codes plus these, for this run. (Battle states are captured with the defaults only: never with a splitscreen remover, which is per player and netplay-only.) |
| `--action-replay <name>` (repeatable) | none | Solo: also run this Action Replay code from the game ini (with the Gecko codes chosen as above, or the ini's defaults). Never in netplay (no Action Replay code runs there) nor with `--replay`. `gecko_active` lists them under `action_replay`. The launcher's Training Display (Modifications) uses it for the Stats & Frame Data Overlay from BT3 Phantom Mods, in RDSPAF.ini's `[ActionReplay]` (included with its creator's permission). |
| `--netplay-gecko <port>=<name>` (repeatable) | none | Netplay: the player on GameCube port `<port>` runs only these codes. Everything else is off for everyone, and Dolphin's "Sync Codes" is forced off. |
| `--list-gecko <GAMEID>[:<rev>]` | | Print every Gecko code Dolphin knows for the game (`gecko_codes` event), then exit. Starts no game. |
| `--textures <Group>=<Option>` (repeatable) | none | Texture variant to load, i.e. folder `@<Group>/<Option>` in the game's texture pack. Turns custom textures on. See *Texture variants*. |
| `--textures-dir <dir>` | `<user>/Load/Textures` | Texture library folder (holds `<GAMEID>/` folders), shared by every profile. |
| `--input-test` | | Controller tester: prints the input devices Dolphin sees (`devices` event, again on every change) and every button/axis pressed or released (`input` events: `device`, `input`, `pressed`), with Dolphin's own names, until `quit` / stdin closes. The Godot controller config editor binds buttons with it. Starts no game. |
| `--list-textures <GAMEID>` | | Print the game's variant groups and options (`texture_groups` event), then exit. |
| `--public` | off | Host: list the lobby on Dolphin's lobby server (browser + matchmaking). Name on the server: `SPK1\|<mode>\|<link>\|<nickname>`. |
| `--spectate` | off | With `--netplay-join`: watch only. Lobbies hold 2 players (GameCube ports 1-2) and up to 2 spectators. A spectator never gets a port (not even when a player leaves), runs the game's default codes plus pad 1's per-port codes (so its game runs exactly like player 1's and shows their view; with no splitscreen remover at all the game's timing differs and it drifted from the players'), and `stop` only ends their own game. A 3rd player or 3rd spectator is turned away (`error` `lobby_full` / `spectators_full`). The public listing's player count is players + 10 × spectators. |
| `--ranked` | off | Host: a ranked lobby. Uses the King of the Hill set engine for exactly 2 players: Single Battle first to 2 wins, Team Battle 1 win; spectators are turned away (`ranked_no_spectators`), a 3rd player gets `lobby_full`; after each set the lobby waits for the host's `start` (no automatic next set). Never listed on Dolphin's lobby server: the ranked server (`Server/ranked`) lists ranked lobbies and rates the results the launchers report. |
| `--koth` | off | King of the Hill. Host: a KOTH lobby (see *King of the Hill*). `--netplay-find` / `--list-lobbies`: only KOTH lobbies (without it, only regular ones). `--netplay-join`: if a set is being played (Dolphin lets nobody in during a game), wait (`koth_waiting`) and retry every 3 s until it ends. |
| `--mode single\|team\|training\|any` | `any` | Host: lobby mode, shown in the browser; `single`/`team`/`training` also auto-select that battle state from the game ini's `[Sparking.Modes]`. `training` is Buffer Training: a solo lobby that is never listed (even with `--public`) and turns anyone who joins away (`error` `training_solo`); `start` works with just the host, and `buffer <n>` changes the pad buffer live. |
| `--region EA\|CN\|EU\|NA\|SA\|OC\|AF` | `NA` | Public lobby region; matchmaking prefers lobbies in the same region. |
| `--public-address <ip>` | | Direct (non-traversal) public lobby only: the address others join. |
| `--list-lobbies` [`--mode m`] | | Print the public Sparking lobbies for **this exact build** (`lobbies` event), then exit. Other builds, regular Dolphin rooms and passworded rooms are filtered out. |
| `--netplay-find single\|team\|any` | | Matchmaking (needs `--netplay-game`): join the best open public lobby of a compatible mode for the same game (same region first, exact mode before "any"); if it's taken or none exist, host a public lobby of that mode and wait. `matchmaking` events report progress. |
| `--menu-button <input>` (repeatable) / `--menu-hold-ms <ms>` | `Back`,`Select`,`Share` / `1000` | Holding that controller button sends `menu_request` (the frontend opens its in-game menu). `none` disables. |
| `--account <username>` | | Netplay: the DRAGON NET account logged in on this PC, told to the other players (`account` in each `players` entry; the launcher pops up "<friend> has entered the lobby!" for a friend's). |
| `--link auto\|wired\|wireless\|unknown` | `auto` | Netplay: this PC's connection type, shown to everyone. `auto` asks the OS which adapter reaches the internet (Ethernet = wired, Wi-Fi/mobile = wireless, VPN/tunnel/virtual adapter = `virtual`). Only this PC's own adapter is visible: a cable into a Wi-Fi extender/powerline/mesh node reads as wired. Self-reported, so not for anything ranked. |
| `--hud on\|off` | `on` | Temporary in-game HUD drawn by Dolphin: a score bar in the centre of BT3's top HUD (`Name1  W1 | W2  Name2`; long names shrink, then get cut with "..."), and in netplay the ping + pad buffer at the bottom centre. Needs the game's `p1/p2_health_pct` watches. The Godot frontend turns it on for netplay and leaves it to the player offline. |
| `--hud-health on\|off` | `on` | Health % in the window's top corners (separate from `--hud`). |
| `--input-display on\|off` | `off` | Your own input history, like a fighting game's training mode: a column down the side of the game picture (port 1 left, port 2 right). See *Input history*. The launcher turns it on for Buffer Training (its own switch) and leaves it to the player elsewhere (Options > Your input history). |
| `--input-display-other on\|off` | `off` | The other port's input history too (1 <-> 2). Offline and Buffer Training only: in an online match (another player on that port) it's never shown. |
| `--osd-messages on\|off` | `off` | Draw Dolphin's own on-screen messages. Off: they are sent as `osd` events for the frontend's overlay instead. (The FPS counter, `Graphics.Settings.ShowFPS`, is separate.) |
| `--background-input on\|off` | `on` | Controllers keep working while another window, e.g. the overlay, has focus. |
| `--stats-interval <ms>` | `0` | Emit a `stats` event every `<ms>` in game (0 = off). Same as the `stats` command. |
| `--aspect 16:9\|21:9\|4:3` | `16:9` | Starting aspect ratio. **F3** in the game window (or the `aspect` command) flips between 4:3 and the wide one. See *Display*. In netplay battles F1-F3 and the `aspect` / `textures` / `textures_cycle` commands are locked (a `locked` event / `not_allowed_in_netplay` error); Buffer Training (solo) isn't. |
| `--resolution <n>` | `3` | Internal resolution as a multiple of native: `3` = 1080p, `2` = 720p, `4` = 1440p, `6` = 4K. |
| `--window <W>x<H>\|borderless` | `1280x720` | Size of the game window, or `borderless`: a frameless window covering the whole monitor (Windows; X11 uses its fullscreen). Rendering stays at `--resolution` regardless. |
| `--netplay-saves host-readonly\|keep` | `host-readonly` | Netplay: every player plays on the **host's** save, which is never written back. |

Pre-alpha builds always draw a see-through "PRE-ALPHA" watermark in the game window's bottom-right corner (4.3% of the window height).

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
| `players` | `players[]` (each with `role`: `player`, `spectator` or `pending`), `all_have_game`, `in_game` | On any change, and every 1 s (pings) |
| `player_rejected` | `pid`, `reason` (`lobby_full` / `spectators_full` / `training_solo`) | Host: someone over the 2 + 2 limit is being turned away |
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
| `buffer_mode` | `auto` | Host: automatic pad buffer turned on / off |
| `buffer_auto` | `reason` (`match_start` / `live` / `between_rounds`), `from`, `to`, `ping`, `jitter` (or `skipped: "measuring"`) | Host: the automatic buffer made a choice (`live`: during a fight, once a new ping / 12 target has held 3 s; `between_rounds`: after a KO; both only when it changes) |
| `host_input_authority` | `enabled` | |
| `golfer_changed` | `is_golfer`, `name` | |
| `desync` | `frame`, `player` | |
| `connection_lost` | | |
| `state_saved` / `state_loaded` | `slot` | Solo only |
| `gecko_codes` | `game_id`, `codes[]` | `--list-gecko` result |
| `gecko_active` | `port` (0 = solo), `codes[]`, `missing[]` | Codes activated for this boot |
| `lobby_codes` | `available[]`, `on[]` | Netplay: the game's optional codes the host may switch on, and the ones on (on game change and every switch) |
| `aspect` | `mode` (`16:9`/`21:9`/`4:3`) | At every boot and after every toggle |
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
| `koth` | `state` (`waiting` for a 2nd person, `ready` for the host's Start, `next` set in `next_in` s, `playing`, `decided`), `cap` (wins that take a set), `streak`, `champion`, `wins` (`[pad 1, pad 2]` this set), `line[]` of `{pid, name, pos}` (pos 0 = pad 1), `local_pos` (-1 = watching), `max` | King of the Hill: whenever the line or set changes (everyone) |
| `koth_set` | `winner`, `loser`, `streak`, `wins` (`[winner, loser]`) | King of the Hill: the deciding KO of a set |
| `koth_waiting` | `retry_in` | King of the Hill joiner: a set is on, trying again in a few seconds |
| `lobbies` | `lobbies[]` of `{host, mode, format (classic/koth), link, region, game, game_id, players, spectators, in_game, joinable, watchable, method, join}` | `--list-lobbies` result. `join` is what `--netplay-join` takes. No version field: it only filters. |
| `public` | `listed`, `mode`, `region`, `name` / `error` | Host: the lobby is (or failed to be) on the public list |
| `mode` | `mode`, `battle_state` | Host: the lobby mode selected this battle state |
| `lobby_mode` | `mode` (`single`/`team`) | The lobby's mode (host: after a `mode` command; joiners: when the host's changes, and on joining) |
| `matchmaking` | `state` (`searching`, `candidates`+`count`, `joining`+`host`/`mode`/`region`/`link`, `retry`+`reason`, `hosting`, `matched`+`port`, `cancelled`, `lobby_server_unreachable`) | `--netplay-find` progress |
| `menu_request` | `button`, `netplay` | The menu button was held: open the in-game menu |
| `texture_groups` | `game_id`, `groups[]` of `{name, options[]}` | `--list-textures` result |
| `textures` | `selection` (`{group: option}`, lowercase) | After a `textures` command |
| `state_file_saved` | `name`, `sha1` | Solo: a `save_state_file` capture is fully on disk |
| `state_applied` | | A save state really loaded (solo load, or the netplay battle state at boot) |
| `replay_recording` | | Ranked replay (`--record-replays`): recording started with the first round |
| `replay_saved` | `dtm`, `json`, `frames`, `bytes` | The decided match was saved (see Ranked replays) |
| `replay_dropped` | `reason` (`no_result`) | The recorded match ended without a winner: nothing saved |
| `replay_error` | `code` | Recording couldn't start / the start state wasn't written |
| `replay_started` / `replay_progress` / `replay_ended` | `frames` (+ `frame`) | `--replay` playback |
| `save_data` | `host_hash`, host also `ready`, clients `local_status` | Netplay save fingerprint check updated |
| `battle_state` | `active`, `name`, `sha1`, `local_ok`, host also `ready` | Battle-state selection changed or a player verified it |
| `alert` | `severity`, `caption`, `text`, `auto_answer` | A Dolphin panic/assert alert. In Sparking mode these never open a Dolphin dialog; they are reported here and answered "yes/ok" so emulation continues. |
| `error` | `code`, plus context | See below |
| `exit` | `code` | Last line before the process exits |
| `crash` | `report`, `dump` (Windows minidump, else ""), `summary` | Dolphin crashed and wrote its report (see Crash reports); the process dies right after |

`players[]` entries also carry `link` (`wired`, `wireless`, `virtual`, `unknown`: each player's
own report), `jitter` (average ping change between 1-second samples over the last ~10 s, -1 until
measured) and `quality` (`good`: ping ≤ 80, jitter ≤ 8, peak ≤ 120 ms; `ok`: ≤ 150 / ≤ 20 / ≤ 250;
else `poor`; `measuring` for the first seconds). A `link` event at startup reports this PC's own
type.

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
| `buffer <n>` | host | Set pad buffer (and turn the automatic buffer off) |
| `buffer auto` | host | Automatic pad buffer: the worst player's typical ping (median of its last ~10 pings) ÷ 12, rounded up, between 1 and 20. Set when the host starts the match (before the game boots), re-chosen right after each KO, and during the fight too: checked once a second, changed once a new value has held for 3 s (so one spike never moves it). NEOcode keeps its own rule (90th percentile + jitter, ÷ 8, − 2) and only changes between rounds. |
| `kick <pid>` | host | Kick a player |
| `automap wii\|gc\|none` | host | Auto-assign joiners to Wii Remote / GC slots in join order |
| `battle_state <file.sst>` / `battle_state none` | host | Select the state everyone boots into |
| `mode single` / `mode team` | host, between matches | Switch a Player Match lobby's mode: its battle state (`[Sparking.Modes]`) and the public listing's mode follow; everyone gets `lobby_mode`. Refused: `game_running` during a game; `not_allowed` in Battle Lounge, ranked and Buffer Training lobbies (their mode is picked before) |
| `save_check` | host | Re-verify that every player's netplay save matches the host's |
| `codes <Name A>\|<Name B>` / `codes none` | host, not during a match | Switch on the game's optional lobby codes (`[Sparking.LobbyCodes]`) for everyone; the rest go off. Unknown names and a second code of an exclusive group are ignored. Everyone re-runs the save check (it fingerprints the choice), so `start` waits until every player has it |
| `players` | any | Re-send the `players` event now |
| `pause` / `resume` | solo | |
| `save_state <1-10>` / `load_state <1-10>` | solo | Slot save states |
| `save_state_file <file.sst>` / `load_state_file <file.sst>` | solo | Capture / test a battle state in `--state-dir` |
| `aspect 16:9\|21:9\|4:3\|toggle` | any, in game (netplay too) | `toggle` = F3 (4:3 <-> the wide one last chosen). Each player chooses their own. |
| `watch_values` | any | Send every memory-watch value now |
| `stats <ms>` | any | Start (`stats 500`) or stop (`stats 0`) the periodic `stats` event |
| `textures <Group>=<Option>` | any, in game (netplay too) | Switch a texture variant live; `<Group>=` clears it (no option loaded) |
| `textures_cycle <Group>` | any, in game | Next option of a group (alphabetical, wraps) — what F1/F2 do |
| `texture_path <tex1_name>` | any | Debug: which file a texture name is loaded from right now (`texture_path` event) |
| `hud on\|off` | any | Show/hide the score bar (+ netplay ping/buffer) |
| `hud_health on\|off` | any | Show/hide the health % in the corners |
| `input_display on\|off\|toggle\|clear\|dump` | any | Show/hide your own input history (`input_display` event: `enabled`, `other`, `other_allowed`); `clear` empties both; `dump` sends the recorded entries as an `input_history` event (`entries` = yours, `p1`, `p2`, `shown`, `local_port`; newest first: `dir`, `c`, `dpad` in numpad notation, `buttons`, `frames`) |
| `step_down` | Battle Lounge player | Go to the back of the line; one of the two fighting forfeits the set (the other wins it, then the line rotates as after any set). `koth_step_down` event to everyone (`name`, `forfeit`) |
| `ask_start` | ranked host | Ask the other player to approve the start: they get `start_asked` (`from`); their answer comes back as `start_answered` (`accepted`, `name`). The launcher starts the ranked match only on a yes (30 s to answer) |
| `answer_start yes\|no` | ranked guest | Answer `start_asked` |
| `input_display_other on\|off\|toggle` | any | The other port's input history; refused with `not_allowed_online` while another player plays that port |
| `score reset` | any | Set the round score back to 0-0 |
| `background_input on\|off` | any | Controllers work (`on`) or are ignored (`off`) while the game window isn't focused. The frontend turns it off while its in-game menu is open (`background_input` event confirms). |
| `focus_game` | any | Brings the game window to the front with the keyboard focus (Windows). The frontend sends it when its in-game menu closes; `focus_game` event confirms. |
| `poke <hex address> <hex value>` | solo | Debug: write a 32-bit word of game memory |
| `peek <hex address>` | solo | Debug: read a 32-bit word of game memory |
| `quit` | any | Stop any game and exit |

Always send `hello` first. If Dolphin is launched without a stdin pipe it keeps running on EOF.

## Crash reports

When a game ends unexpectedly the player gets a pop-up ("The game crashed" / "The game closed
unexpectedly", with "Open the logs folder") and a report in `SparkingData/logs`:

* `dolphin_crash_<date>_<time>.txt` — written by Dolphin itself as it crashes (access violation,
  `abort()`, `std::terminate`, pure virtual call, bad CRT argument; Linux/macOS: SIGSEGV, SIGBUS,
  SIGILL, SIGFPE, SIGABRT): what and where (module + offset, symbol and line when the .pdb is
  next to the exe), the crashing thread's stack, the session kind, the last game and stats
  lines and the last 40 events. Windows also writes `dolphin_crash_<date>_<time>.dmp` (a
  minidump: open it in Visual Studio / WinDbg with the build's .pdb). Then it prints the
  `crash` event and dies as it would have (no Windows "has stopped working" box). Folder:
  `$SPARKING_CRASH_DIR` (the launcher sets it), else `<user folder>/Logs`.
* `crash_<date>_<time>.txt` — written by the launcher (scripts/crash_log.gd) when the session or
  a helper Dolphin crashed, ended without its `exit` event and with a non-zero code (killed from
  outside, failed to start), or was closed by the boot watchdog: launcher version, OS, CPU,
  GPU, renderer, the command line, Dolphin's own report (above) copied in, the last events and
  commands, and Dolphin's last console lines. IP addresses are masked and chat text left out.
  Stopping a game, closing its window or the launcher closing Dolphin is never reported.
* `launcher_crash_<date>_<time>.txt` — at start, if Godot's log of the previous run
  (`user://logs`) says "Program crashed", it's copied here (once) and the player is told.

The newest 20 reports of each kind and 3 minidumps are kept. Tests: `test_crash [segv|abort|terminate]`
(`--test-hooks`).

## Battle states (Single Battle / Team Battle)

The host picks a save state and every player boots straight into it, e.g. the BT3 character
select screen of Single Battle or Team Battle, so nobody navigates menus online.

1. **Capture once** (solo): launch the game with `--sparking --state-dir <dir>`, navigate to the
   screen, send `save_state_file BT3-SingleBattle.sst`. Wait for `state_file_saved`. Capture with
   the same per-game settings profile Godot uses for netplay.
   - Capture with the game's **default codes on** (don't pass `--no-gecko`): netplay runs them,
     and some only take effect while the game sets itself up. BT3's PAL60 code (30 fps) is one:
     the video mode is chosen before the menus, so a state captured without it keeps every match
     at 25 fps.
   - `Tools/sparking_state_check.py <state>` shows the build that saved a state, whether the
     version's default codes were on (RDSPAF: PAL60; RDSJAF: the widescreen HUD; RDBJAF: the 16:9
     patch, the fog removal and the widescreen HUD) and that no splitscreen remover was (BT3:
     its hooks; BT2: its nop writes).
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

## Ranked replays

`--record-replays <dir>` (the launcher passes it for ranked lobbies): when the first round of a
netplay match starts (both health watches at 100%), Dolphin saves a state and records every
controller input from there (an input movie "from save state"). Netplay already sends everyone
every input, so this adds nothing on the network; the state is written in the background and the
game file isn't checksummed. When the set is decided (`koth_set`) and the game stops, it writes
`<date>_<P1>_vs_<P2>.dtm` (inputs), `.dtm.sav` (the state at the first round) and `.json`
(players, wins per port, winner, mode, this player's Gecko codes, date, frames, seconds). A
match nobody won is dropped. Both players save their own copy.

`--replay <file.dtm> -e <game> --local-players 2` plays one back with the same Gecko codes (the
launcher passes the `.json`'s `gecko` list) and stops the game when the inputs run out. A replay
needs the same game, Dolphin-Sparking version and per-port codes to play back exactly.

## Rollback test mode

`--rollback-test <fields> [--rollback-gap <fields>] [--rollback-log <file>]` (solo, `--sparking`):
the first step toward rollback netplay. Every `gap` video fields Dolphin saves the whole state to
memory, plays `fields` fields while recording the controller polls, copies MEM1 + ARAM, rewinds
and re-runs those fields as fast as it can with the recorded inputs, and compares. Emulation is
kept deterministic (as in netplay) while it runs. Events: `rollback_test`, `rollback_mismatch`
(`field`, `mem1` ranges, `mem1_bytes`, `aram_bytes`, `input_mismatch`) and `rollback_test_stats`
(`cycles`, `mismatches`, `save_ms`, `load_ms`, `rerun_ms_per_field` (+ `_max`), `state_kb`,
`max_rollback_fields`: fields this PC could re-run inside one 16.7 ms field after a save and a
load). The launcher's Rollback Test screen runs it and writes `<data>/rollback_test/*.jsonl` (hidden
from the DRAGON NET menu now; `scripts/screens/rollback_test.gd` is still there for testing
builds).

Re-runs aren't drawn, as real rollback won't draw them (nobody sees those frames): right after
the rewind's state load the GPU starts skipping vertex loading, draws and EFB copies that stay
on the GPU (state commands still run; copies into game memory are still made), and after the
re-run the GPU is synced before drawing resumes, so `rerun_ms_per_field` includes the GPU's
share. `--rollback-draw` draws them anyway (to compare). Stats carry `draws` / `draws_skipped`
(vertex batches).

Where re-run time goes: `first_run_cpu_ms_per_field` / `rerun_cpu_ms_per_field` are the
emulation thread's own CPU time per field (no throttle sleeps, no GPU waits) in the first run
and in the re-run, and `rerun_first_field_ms` / `rerun_later_fields_ms` split the re-run's wall
time into the field right after the load and the others (last 20 tests each).

Rewinds keep the compiled code (`--rollback-recompile` to throw it away like a normal load).
A state load used to throw it away anyway: `PowerPC::DoState` calls `IBATUpdated` /
`DBATUpdated`, which cleared the JIT (and remapped fastmem) even when the mappings came back
the same, so the first re-run field recompiled the game (~200 ms in a BT3 fight). With the keep
flag on (rollback loads only) they now do that only when the mappings changed. `jit_clears` in
the stats counts the clears.

Save / load cost: `save_parts_ms` / `load_parts_ms` time each part of the state (from the save
state markers, the costliest 8, last 20 tests). Nearly all of it is copying MEM1 and MEM2
(BT3: ~17 of ~19 ms). `pages_changed_per_frame` / `pages_changed_per_rewind` count the 4 KB
pages of MEM1 / MEM2 that changed after one game frame (2 fields) and over the rewind (plus
64 KB blocks): how much a save of only the changed memory would have to copy.

Saves copy only the memory the game changed (`Core/HW/SparkingDirtyPages`): after a save every
host view of MEM1 / MEM2 (the plain view, the fastmem physical view, the DBAT logical views) is
write-protected; the first write to a page from any thread faults, and the fault handler (EMM,
before the JIT's) makes it writable in that view and marks it. A save copies the marked pages
into a shadow copy and protects them again; a rewind copies them back (states are then saved
and loaded without MEM1 / MEM2, `State::SaveToMemory(..., skip_ram)`). Host code that writes
into emulated memory through the OS (the IOS file system's fread, SD card reads) unprotects its
target first, since the OS fails such a write instead of faulting. DBAT remaps / page table
mappings / shutdown stop the tracking (everything writable; the next save copies everything).
In BT3 a fight changes ~200 pages per frame, so save / load drop from ~16 / ~19 ms to ~2 / ~3 ms
on a Wii test program. Stats: `memory_tracking`, `pages_saved`, `pages_restored`,
`write_faults_per_field`, `restore_errors` (after every tracked restore MEM1 / MEM2 are compared
with a full copy taken at the save; must stay 0). `--rollback-full-copy` copies everything as
before. Each re-run is also compared on MEM2 now, not just MEM1.

Rollback states (`State::IsRollbackState()`: in memory, without MEM1 / MEM2) also skip work a
normal load does: the presenter doesn't re-display the last frame (the rewind's frames aren't
shown), and the IOS file system restores `/tmp` (deleting and rewriting it on disk) only if it
changed since that save: every change (create / delete / rename / write / metadata / format)
gives the file system a new, never reused id, saved with the state.
They also skip the bounding box read-back while the game has bounding box off: reading the
graphics card's values waits for it to finish everything queued (~4 ms per save in a busy BT3
fight), and they don't change while it's off.

Quitting stops the test: Dolphin taps the Wii's power button so the game can shut down, and that
tap isn't a recorded input (a rewind would take it back, and the runs would differ).

`--rollback-diagnose` (the launcher's "Detailed log") makes each mismatch also carry
`first_divergence`: the first entry where the two runs part ways in a log of everything the
emulator did (CoreTiming events, IOS IPC commands with their results, and what the CPU read from
the GPU: EFB peeks, bounding box, GPU counters), and `gpu_copies_divergence` for EFB copies the
GPU wrote into RAM (GPU thread, own list). It slows the re-runs down, so it's off by default.

Found and fixed with it: loading a state didn't close the IOS file descriptors opened after the
state was saved, so the next open after a load got another fd than the first time. BT3 hit it
every minute through the Wii SDK's play time recorder (`play_rec.dat`), at a fixed time after
boot. The smoke test's "IOS file descriptors" check guards it.

## NEOcode (rollback netplay, hidden)

A host-chosen switch in the netplay lobby, hidden for now: the host presses **PgUp + PgDn**
together (not during a match, not in buffer training). The UI never says "rollback": the mode is
called NEOcode, and the rewind length is shown as "R n" (lobby info line and HUD bar).

- Commands: `netcode neocode|delay` (host only; refused while a game runs). The host rebroadcasts
  it to everyone (and to players who connect later) as a control message.
- Events: `{"event":"netcode","mode":"neocode|delay"}`;
  `{"event":"neocode","state":"on|waiting|failed|off",...}`: "on" at the start, then every ~60
  fields with `r` (the biggest re-run since the last one, in game frames: what "R n" shows),
  `rollbacks`, `stalls`, `polls`, `guesses`, `wrong_guesses`, `saves_skipped`, `save_ms`, `load_ms`, `resim_ms` (the
  longest re-run since the last one, real time: how long the picture and sound stopped), ...;
  "failed" with `reason`;
  `{"event":"neocode_check","field":n,"match":true|false}`;
  `{"event":"neocode_diff","field":n,"player":pid,"block_size":65536,"blocks":["80xx0000",...]}`
  after the first mismatch of a match: which 64 KiB pieces of MEM1 differ (the checksum is taken
  per piece; both players send theirs once, `neoblk` control messages, ~8 KB).
- Engine (`Core/NeoCode`): the pad buffer stays as a minimum delay; past it a missing remote input
  is guessed (the last one received). The state is saved at every field end (dirty memory pages,
  rest of the state, the frontend's watch/HUD state); a wrong guess rewinds to the latest field
  before it and re-runs to the present unthrottled, without drawing and without sound (what the
  game plays then was already heard; queueing it again garbled the audio: pops, repeats). The
  re-run doesn't touch the emulation speed setting (that switched VSync off and on twice per
  rewind: a swap chain rebuild, a big hitch); the throttle's timeline is kept, so the game catches
  up to real time right after instead of slipping behind the other player. Guessing stops (the
  game waits, as in delay netplay) once the oldest unconfirmed input is `MAX_ROLLBACK_FIELDS`
  (12 fields, 6 BT3 frames, 200 ms) old.
- The per-field save and the rewind run as CPU-thread jobs at the end of the CPU's slice
  (`CPUManager::BreakForJob` / `ResumeAfterJob`). Unlike `Break` / `SetStepping` these don't
  pause the GPU thread and the sound stream: stopping and restarting the audio stream 60 times a
  second popped the sound and stalled the game.
- Local controllers are steadied before their input is sent (`NeoCode::Stabilize`): sticks within
  6 of the centre snap to it and otherwise keep their value until they move by more than 3;
  triggers / analog buttons within 12 of released / full snap to 0 / 255 and otherwise move in
  steps of more than 6. A real stick wobbles by a step or two all the time, and every wobble was
  a new input for the other side to guess wrong: a rewind every few frames while it was held.
- Events the game "does" (results, watches) are held until final (every input before them
  confirmed) and dropped when a rewind takes them back, so both players emit the same sequence.
- Every 120 fields the players exchange the MEM1 checksum (`neosum`); a mismatch shows
  "NEOcode: the players' games are out of sync." once per match. It's only a notice: the match
  goes on. BT3 PAL matches showed it every time (Oct 2026); the cameras aren't the cause (they
  live in MEM2, around `0x9233F000`, and the check covers MEM1 only), and neither the GPU command
  buffer nor a copy of the camera is in MEM1: `neocode_diff` is there to find what is. The Gecko code area (0x80001800-0x80003000) isn't in the checksum, nor the memory the
  per-port codes write (their 00 / 02 / 04 / 06 writes and C2 hooks, every port's): each player
  runs only their own port's splitscreen remover. Dolphin's own desync warning (from the
  timebase) is off with NEOcode.
- NEOcode's saves never include the graphics card's texture cache / EFB contents, whatever
  "Save Texture Cache to State" says: reading them back every field would cost more the higher
  the resolution and anti-aliasing. A rewind keeps the texture cache as it is (emptying it lost
  the frame / effect copies that only live there: purple flashes and big stutters); an effect
  copy may be a few frames old right after a rewind. The game itself isn't affected.
- BT3 reads the pads 120 times a second (2 polls per field per pad: `polls` grows by 240 per 60
  fields in a 2-player match), so one pad-buffer step is ~8 ms. Measured in matches (50 ms ping,
  clashes): at buffer 2 nearly every guess of the other side's mashing was wrong, 8-19 rewinds a
  second each freezing the picture 24-75 ms; at buffer 6, about one 16 ms rewind every few
  seconds. With NEOcode the automatic pad buffer is `(ping + jitter) / 8 - 2` (2-20), so only
  spikes are left to rewind.
- A re-run doesn't save the fields nothing could rewind to (all of its inputs and the next
  field's are real: the next field's save replaces it), about half of them: each save is ~2 ms of
  a ~10 ms re-run field. `saves_skipped` in the stats counts them.
- With NEOcode, ranked
  replays are off, spectators stay on delay netplay, and every player needs this build.
- If saving / rewinding fails, the match goes on as delay netplay ("NEOcode stopped ...").
- Test hooks (`--test-hooks`): `test_input <seed>` plays a pseudo-random pad pattern,
  `test_lag <ms>` holds remote inputs back. The smoke test's "neocode" check uses them.

## Save data: solo vs netplay

Wii games keep their saves in Dolphin's emulated Wii NAND, so separate saves = separate NAND
folders:

```
<app>/saves/solo/              ← --nand for solo play; normal progress, written as you play
<app>/saves/netplay/<disc ID>/  ← --nand for netplay, one per game version (RDSPAF, RDSE70,
                                  RDSJAF, RDBPAF, RDBE70, RDBJAF); each ships with that
                                  version's 100%-unlocked save
```

The launcher passes the folder of the version being played. A `saves/netplay/` from before
per-version folders (a NAND with `title/` right in it: the BT3 PAL save) is moved into
`saves/netplay/RDSPAF` on its own, and every version's folder is created.

**Every player must have a byte-identical netplay save, or the match desyncs** (confirmed in
testing, even with Dolphin's host-save sync on). So the fork verifies it:

- When the host picks a game, and whenever someone joins, the host fingerprints its save
  (SHA-1 over every file under `title/…/data` in its `--nand`) and sends the fingerprint.
- Each player fingerprints their own copy and answers `ok`, `mismatch` or `missing`
  (`players[].save_status` on the host, `save_data` events on everyone).
- `start` is refused with `save_data_mismatch` until every player is `ok` (`start force`
  overrides). After a player fixes their files, the host sends `save_check` to re-verify.

Ship the same unlocked save in every install's `saves/netplay/<disc ID>/`. On top of that,
`--netplay-saves host-readonly` (default) keeps Dolphin's save sync on and write-back off, so the
netplay save is never modified by a match.

To install an unlocked save into `saves/netplay/<disc ID>/`: in regular Dolphin set
Config → Paths → Wii NAND Root to that folder, then Tools → Import Wii Save (`data.bin`) — or copy
the save's `title/00010000/<id>/data/` folder into the same place inside it.

## Gecko codes

BT3 PAL (`RDSPAF`) ships with its codes built in: `Data/Sys/GameSettings/RDSPAF.ini` (PS2
control layout, PAL60, outlines, 16:9, soft reset, World Tournament stages = on by default;
`Player 1/2 Splitscreen Remover` = per-port netplay codes).

BT3 NTSC-J (`RDSJAF`, Sparking! METEOR) ships the user's Rev1 codes `In-Game Controls Fix To Match
Playstation 2 Layout`, `Menu Controls Fix To Match Playstation 2 Layout` (Confirm = B, Back = Y)
and `WFC Wiilink24`, and `Widescreen HUD (life bars at the screen edges)`, all on by default (the
HUD: RDSPAF's code ported with `Tools/gecko/find_hud_sites.py`: hooks
`0x8010771c` / `0x80107d20`, battle 2D callers `0x80100000-0x80110000`) and `Player 1/2
Splitscreen Remover` (`0x80090B6C`, `0x8001529C`, `0x800152AC`), plus `[Sparking.Modes]` pointing at
`RDSJAF-SingleBattle.sst` / `RDSJAF-TeamBattle.sst` / `RDSJAF-BufferTraining.sst` (to capture).
Its netplay save: `saves/netplay/RDSJAF/title/00010000/5244534a/data/` (`banner.bin`, `DBZSM`,
`nocopy/DBZSM_WIFI`). Its `[Sparking.Watch]` (`p1/p2_health_pct`, see Memory watcher) turns on the
HUD's score bar, ping / buffer line and KO detection.

BT2 NTSC-J (`RDBJAF`, Sparking! NEO) ships `Player 1/2 Splitscreen Remover` too, in
`Data/Sys/GameSettings/RDBJAF.ini`. BT2's engine doesn't share BT3's hook sites, so these were
found in its own main.dol: battle setup sets a "2 human players" bit (0x2 of the mode word at
`-0x74a8(r13)+0x4dc`), and the camera code splits the screen while it's set. Both codes nop its four
setters (`0x801530D4`, `0x80159064`, `0x8017B340`, `0x80204A98`, one per battle menu), so the game
draws one full-screen view (camera 0). Player 2's code also swaps the per-frame camera loop's
player index (`0x80067488` / `0x800674A0`), so camera 0 follows port 2's fighter (player 1's
writes those two unchanged, keeping both codes the same length). BT2 US / PAL have
no removers yet (their addresses differ; the launcher asks for the codes by name, and a missing
one is skipped).

RDBJAF's other codes: `16:9 Widescreen Patch`, `Remove Bugged Fog/Shadow` and `Widescreen HUD
(life bars at the screen edges)` (BT2's own HUD engine, `Tools/gecko/widescreen_hud_bt2.py`; see
`Tools/gecko/README.md`) are on by default (solo and netplay). `Ground & Pound Infinite Combo Fix` and `English Dub` are off; in a netplay
lobby the host may switch them on for both players (`[Sparking.LobbyCodes]`). `Japanese Dub` is
for solo only (it brings the Japanese voices back to a save that was played with `English Dub`);
the two dubs are an exclusive group. The NTSC-J netplay save goes in
`saves/netplay/RDBJAF/title/00010000/5244424a/data/` (`banner.bin` + `DBZSN`). Its `[Sparking.Modes]` boots
DRAGON NET lobbies into `RDBJAF-SingleBattle.sst` / `RDBJAF-TeamBattle.sst` (Tag Battle) /
`RDBJAF-BufferTraining.sst` (captured with `3_capture_battle_states.bat`, version RDBJAF); without
that section (before Oct 20 2026) BT2 lobbies booted to the game's menus.

Game IDs: BT3 = `RDSE70` (US) / `RDSPAF` (EU) / `RDSJAF` (Sparking! Meteor); BT2 = `RDBE70` (US) /
`RDBPAF` (EU) / `RDBJAF` (Sparking! Neo). Dolphin ships no Gecko codes for these games; codes
come from the user's `GameSettings/<ID>.ini` (e.g. ones the frontend writes).

- **Per-game code tab in Godot:** run `dolphin-emu-nogui --list-gecko RDSE70` once per game. It
  prints a `gecko_codes` event with every code from Dolphin's bundled and user `GameSettings`
  (`name`, `creator`, `notes`, `default_enabled`, `user_defined`, `lines`, `lobby_option`,
  `group`). Godot stores the player's toggles itself; turning on a code of an exclusive `group`
  turns the others of that group off.
- **Game ini sections:** `[Sparking.LobbyCodes]` (one code name per line): codes that stay off
  by default and that the netplay host may switch on for everyone (lobby rows "Host option";
  Dolphin's `codes` command). They're never default-on in netplay, and every player must have the
  same definitions (the save check covers them). `[Sparking.Exclusive]`: `group = Code A | Code B`,
  codes that can't be on together (Tenkaichi 2 JP's English / Japanese Dub).
- **Solo:** launch with one `--gecko "<name>"` per enabled code (or `--no-gecko`). Dolphin
  activates exactly those for that run; the game's ini is never edited.
- **Netplay:** everyone runs the game's default-on codes (`[Gecko_Enabled]` in the Sys + user
  game inis; `--netplay-gecko-defaults off` disables that), plus only the codes mapped to the
  port each player lands on. Every other code is off. Per-port codes are never part of the
  defaults, even if an ini enables them. The lobby's save check also fingerprints this code
  setup (code names + exact lines, every lobby option, and which ones the host switched on); a
  player whose codes differ shows
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

Sparking mode renders at 1080p (`--resolution 3`) with Dolphin's output stretched to the
window (16:9): the picture fills the window or monitor whatever its shape. 21:9 is the same plus
Dolphin's widescreen hack, so on a 21:9 screen the 3D view gets wider instead of only stretched
(2D parts like the HUD are stretched); in a 16:9 window it looks like 16:9. 4:3 is forced 4:3.
**F3** in the game window (Windows), or the `aspect` command, switches between 4:3 and the wide
one chosen. Only Dolphin's output / the GPU's projection change, nothing the emulated game sees:
the game's own widescreen Gecko code (e.g. BT3's "16:9 aspect ratio") stays on whichever is
chosen. The choice carries over to the next
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
- Hotkeys in the game window (Windows): **F1** cycles `@Graphics`, **F2** cycles `@Buttons`
  (options in alphabetical order, wrapping), **F3** toggles 16:9 / 4:3. Every switch emits a
  `textures` event with the new selection so the frontend can remember it.
- Purely visual, so each netplay player can use their own.
- Godot settings: `--list-textures RDSPAF` gives the groups and choices; launch with one
  `--textures Group=Choice` per group.

## Netplay menu flow (Godot) → Dolphin

```
Play Game > Netplay
  1. Lobby Browser   --list-lobbies [--mode m]  (refresh = run again)  -> lobbies[]
                     join one: --netplay-join <lobby.join> --netplay-game <iso> --nickname N
  2. Player Match
     Host            options screen -> --netplay-host <iso> [--netplay-direct] --mode single|team
                                       --nickname N [--public --region R] --state-dir <dir>
     Find            pick Single/Team/Any -> --netplay-find <mode> --netplay-game <iso>
                                              --nickname N --region R --state-dir <dir>
  3. Ranked Match    (WIP)

Lobby screen         events: room (code), players (name, ping, link, quality, slot), chat, buffer_changed
                     commands: chat <text>, buffer <n> (host), start (host), quit
In game (hold Select -> menu_request): same panel; chat, buffer, "stop match" = stop
                     (back to the lobby screen), quit = leave entirely.
```

Notes:
- The browser only lists lobbies of the same Sparking build: the lobby server's `version` field
  (Dolphin's build string) is used as a filter and never shown.
- Ping can't be known before connecting (the lobby server doesn't measure it); the browser shows
  region and the host's wired/Wi-Fi status, and the lobby shows live ping once joined.
- The lobby's mode picks the battle state (`[Sparking.Modes]` in the game ini, BT3: Single =
  `RDSPAF-SingleBattle.sav`, Team = `RDSPAF-TeamBattle.sst`, Training =
  `RDSPAF-BufferTraining.sst`), so a "Team Battle" lobby boots everyone straight into Team
  Battle, and Buffer Training boots straight into Training Mode.

- Gecko codes and battle states: Dolphin keeps the running code list in game RAM, so a state
  would bring back the codes that were on when it was captured. Dolphin-Sparking rewrites the
  list from the codes active now whenever a state loads, so each player's per-port codes apply.
  A code that was on at capture time can still leave its last written values in memory (turning
  it off doesn't undo them), so capture battle states with no per-port code on.

### Ranked match start

The host's Start Match first asks the other player (`ask_start`): a "<host> wants to start"
question pops up on their launcher (Accept / Decline, 30 s). Only on Accept does the host open the
match on the ranked server and start it.

### Ranked server

`Server/ranked` (PHP 8.1+, MySQL/MariaDB; see its README.txt) runs ranked play for the
launcher: DRAGON NET accounts (account.php: username + password, made in the launcher; profiles
from before accounts convert once through the Discord OAuth login), friends and the admin's
messages (social.php), the ranked lobby list
(host opens / heartbeats, guest joins a seat), matches (the host starts one; each player reports
win / loss; agreeing reports count, a lone report counts after 2 minutes, disagreeing reports void
it; a forfeit is a loss), Elo per mode (K=32, start 1000), per-region records and the
leaderboard (JSON + web page). `Tools/ranked_server_test.py` runs it on SQLite with a fake
Discord. Each game has its own ladder: Budokai Tenkaichi 3's modes are `single` / `team`,
Budokai Tenkaichi 2's `b2single` / `b2team` (the launcher maps them; requests carry
`game` = bt3 | bt2, older launchers = bt3). A lobby records the disc version it plays
(`version`, e.g. RDSE70; lobbies from before that count as RDSPAF) and the list only shows the
asking player's version; a game's versions share one rating.

### King of the Hill

(Shown as **Battle Lounge** in the frontend and on Discord; `koth` everywhere in the protocol.)

`--koth` lobbies are a ladder. Everyone who joins (not `--spectate` watchers) gets in line, up
to 8 people in all: line position 1 holds GameCube pad 1 (the champion), position 2 pad 2 (the
challenger), and the rest wait without a pad (they watch the set like spectators: default codes
+ pad 1's codes; per-port codes follow whoever holds the pad at each boot).

- A **set** is one boot of the battle state. The host counts KOs per pad from the health
  watches: Single Battle sets go to the first to 2 wins, Team Battle sets to 1 win (the team
  health bar covers the whole team).
- About 4 s after the deciding KO the host ends the game for everyone. The winner keeps / takes
  pad 1, the loser goes to the back of the line, and the next in line takes pad 2. The champion's
  streak counts sets won in a row.
- After a 10 s break (time for people to join: Dolphin lets nobody in while a game runs) the next
  set starts on its own, once everyone's game, save and battle state check out. Joining during a
  set (`--koth` on the joiner) waits for the break.
- The host starts the first set. A set stopped by hand (`stop`) pauses the ladder until the host
  starts again; if someone on a pad leaves, nobody wins and the next set starts on its own. The
  host referees: its `stop` works even while it waits in line without a pad.
- Public KOTH lobbies are listed as `SPK1|koth.<mode>|<link>|<host>` (`format: koth`): the
  listing's players are the 2 on pads, spectators everyone else. They're only shown with
  `--koth`, and regular lobbies only without it.

- **Who decides a set:** the two players' own games. Each player's Dolphin tells the host every
  KO it counts (`kothko <p1 wins> <p2 wins>`), and the host takes the highest of those (and of its
  own count, only when it's fighting itself). Before, the host counted from its own game even
  while it waited in line, and a game without a pad could drift from the players' (see below):
  a KO it never saw made the set endless.
- **Everyone without a pad runs pad 1's codes** (watchers and people waiting in line): with
  neither splitscreen remover the game draws both views, which changes how long its frames take,
  and that game drifted away from the players'. Now it runs exactly like player 1's (and shows
  player 1's view).
- **Step down** (lobby / in-game menu): to the back of the line. Between sets the line just
  moves (a champion stepping down loses the streak); one of the two fighting forfeits the set.

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
  interactive (pause menu). While the overlay has focus, the F1-F3 hotkeys (which only fire
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

## Input history

`--input-display on` (or the `input_display` command) draws your inputs like a fighting game's
training mode: a column down the side of the game picture, **port 1 on the left, port 2 on the
right**, newest on top (highlighted, its frame count in yellow), older ones fading downwards,
between the health bars and the ki gauges. `--input-display-other on` / `input_display_other`
adds the other port's column (offline, Buffer Training); in an online match (another player on
that port) it's off and can't be switched on, and spectators see neither.

- each row is one input held for some frames (video fields, 60/s): the **frame count** at the
  outer edge, then the **direction** of the main stick (an arrow, or a ring with a dot for
  **neutral**), then the **buttons** held (A B X Y Z L R Start), then the C-stick and the D-pad if
  used.
- ports 1 and 2 are recorded at the moment the game reads them, i.e. after the netplay pad
  buffer: it shows exactly what the game got and when. NEOcode re-runs aren't recorded twice.
- recorded whether shown or not; emptied at each game start.

Button pictures, first found wins:

1. the selected `@Buttons` pack option's replacement of the game's own button texture
   (PlayStation / Xbox ...);
2. the game's own button texture: the first time the game draws one (while no pack option
   replaces it, e.g. Vanilla), it is saved to `<User>/Sparking/ButtonIcons/<GameID>/<name>.png`
   (`button_icon_saved` event) and used from then on;
3. a drawn icon in the selected pack option's style (GameCube colours, PlayStation shapes, Xbox
   letters; shoulders as L2/R2/R1 or LT/RT/RB following the launcher's controller presets).

The texture names come from the game ini (Sys, overridable by the user's game ini):

```ini
[Sparking.ButtonIcons]
# GameCube button = texture name (keys A B X Y Z L R Start; several names: first found wins)
A = tex1_32x32_ce62786fc1170192_70b585e07941e91c_8
```

RDSPAF has A B X Y Z (the textures the button packs replace). Other versions/games: add theirs
(dump textures, find the button prompts, copy the names).

## Shared replays and friends (DRAGON NET server)

- `Server/ranked/replays.php`: ranked replays shared by players. **Every ranked replay is
  shared**, by rule (no switch): right after the match; one that couldn't be sent then (offline,
  server down) is sent later by itself (`ReplayShare.upload_pending`: at login, then every ~10
  minutes; never while a game runs, so it doesn't eat the netplay connection), or by hand
  (Replays > a replay > Share): `start` (info + sizes + SHA-1s; the same replay or the same
  ranked match already shared -> `exists`), the .dtm and .dtm.sav in 256 KB base64 pieces
  (`part`), `finish` (checks them). Replay Search (`search`: part of a player's name, mode, this
  game) lists them newest first; `file` downloads one (to `<SparkingData>/replays/online`), then
  it plays like the player's own. Files live in `replay_dir` (config.php; default
  `Server/ranked/replay_files`, closed to browsers); `replay_max_mb` (default 1500: the oldest go
  first) and `replay_daily` (uploads per player per day, default 30). admin.php > Replays lists
  and deletes them.
- Profile pictures: `account.php` `picture` takes a 128 x 128 PNG / JPEG / WebP (base64, 256 KB
  at most; redrawn as a PNG by GD when the host has it, so only pixels are kept), `picture_remove`
  drops it; `pic.php?id=&v=` serves it (a new picture gets a new `v`, so it's cached for long).
  The URL is in `me.php` (`player.picture`), `social.php` (each friend's `pic`) and the
  leaderboards (`avatar`, in place of the Discord one). In the launcher: Ranked Match > Profile >
  Profile picture: any picture on the PC; one that isn't exactly 128 x 128 opens the cropper
  (move a square frame with the stick / arrows / mouse, size it with LB RB / Q E / wheel, live
  preview; A tears it off). admin.php > a player > Remove picture.
- Friends "is online" pop-ups: the server keeps when each player came online (`online_since`: on
  their first request after being offline, or when their launcher starts: `poll` with
  `start`); `poll` returns each friend's `since`, and the launcher announces a friend whose `since`
  is newer than the last one it saw. A missed poll, a slow server or a quick restart no longer
  loses the pop-up.

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
# a ratio: <value> / <value> [* number]  (null when the divisor is unreadable or 0)
p1_health_pct = u32 0x805F3210 > 0x0 > 0x11D8 / u32 0x805F3210 > 0x0 > 0x11E0 * 100
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

**BT3 NTSC-J (RDSJAF)**: the same values in the same battle struct, at `0x803CF924` /
`0x803CF928` (PAL's struct is at `0x803CF6C0`, JP's at `0x803CDFC0`; both cleared `0x1a00` bytes
at battle setup, `0x8008eb4c` / `0x8008e360`; the percentages are at +0x1964 / +0x1968). Checked
in a JP battle dump (100.0 / 92.47). Same triggers.

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

## Memory notes for other games (not active yet)

**BT2 NTSC-J (RDBJAF)** keeps its health as whole HP numbers (max 30000 / 50000 / ... per
character), so its ini computes the percentages with ratios: each fighter is a 0x1560-byte struct
in MEM2 from the pointer at `0x805F3210` (`r13-0x72f0`; P1's struct first, P2's right after it),
with current HP at `+0x11D8`, the bar's lagging damage value at `+0x11DC` and max HP at `+0x11E0`.
Found by memory search (P1 `0x924D1378`, P2 `0x924D28D8` in one battle) and checked in a battle
dump: P1 50000 / 50000, P2 29170 / 30000 (97%). Not checked yet in Tag Battle, where each side has
two fighters (BT3's percentages are the whole team's).

## Controllers

With `--pads gc` (default) the game sees GameCube controllers only; Wii Remotes are off. The
physical controller each player uses is Dolphin's GameCube pad profile for **port 1**
(`Config/GCPadNew.ini`, `[GCPad1]`) — in netplay too, since each player's local port 1 drives
their assigned slot. The frontend writes that profile from its controller settings.

## Discord Rich Presence

The frontend owns presence with its own Discord application ID (it runs across menus, the lobby
and matches; a game session only exists during the latter two). It keeps one helper process
running for that:

```
DolphinNoGUI --discord-presence <application id>
```

The helper talks to the Discord app on the same PC through the bundled discord-rpc library
(local IPC only). After `hello` it takes:

| Command | |
|---|---|
| `presence {json}` | Show this. Keys (all optional): `details`, `state`, `large_image`, `large_text`, `small_image`, `small_text` (image = an Art Asset key or an https URL), `start` / `end` (unix seconds: elapsed / remaining timer), `party_id`, `party_size`, `party_max`, `join_secret` (adds "Ask to Join"), `match_secret` |
| `clear` | Show nothing |
| `respond <user id> yes\|no\|ignore` | Answer an "Ask to Join" request |
| `quit` | Clear and exit (closing stdin does the same) |

Events: `ready` (`mode: "discord"`, `enabled`: false when built without Discord support),
`connected` (`user_id`, `username`), `disconnected`, `presence`, `join` (`secret`: the joiner's
side, after their request was accepted), `join_request` (`user_id`, `username`: the host's side),
`error`.

## Launcher settings (frontend.cfg) and installers

The launcher keeps its settings in `SparkingData/frontend.cfg`. It remembers the PC it belongs
to (`[paths] machine`, a hash of the OS's machine id): settings that come from another PC (a
copied SparkingData, or one shipped inside an installer) lose that PC's disc image paths, its
DRAGON NET login and located folders on first launch, and setup runs again; options, video and
controls stay. **Don't ship your own frontend.cfg anyway** (it holds your DRAGON NET session):
leave it out of installers (Inno Setup: `Excludes: "frontend.cfg"` on the SparkingData files).

**Automatic updates** replace shipping a new installer for every build: `Docs/UPDATES.md`
(Cloudflare R2, `Server/ranked/update.php`, `Tools/sparking_release.py`, the launcher's
`scripts/updater.gd`). The installer is then only for new players.

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
