extends Node
## Saved settings and the Dolphin command lines built from them.
## Games: Budokai Tenkaichi 3 and Budokai Tenkaichi 2 (Wii), each in up to three versions
## (NTSC-U, PAL, NTSC-J), every version its own disc image ("game copies", Options). The menus
## work on one game at a time (use_game): Play Offline runs that game's offline copy, DRAGON NET
## the version picked on the way in.
##
## Dolphin-Sparking and the SparkingData folder are found automatically, next to the launcher:
##   <folder>/DRAGON BALL Sparking! Collection.exe   (this frontend, exported)
##   <folder>/Dolphin/DolphinNoGUI.exe               (+ its Sys folder and DLLs)
##   <folder>/SparkingData/                          (user, saves, states, textures, music, ...)
## The search also walks up a few folders, so the development layout works too
## (Frontend/Godot inside the dolphin-sparking checkout, SparkingData next to the checkout).
## Settings live in SparkingData/frontend.cfg, so the whole folder can be moved or copied.

const CONFIG_FILE := "frontend.cfg"
const OLD_CONFIG := "user://sparking.cfg"   # before settings moved into SparkingData
const DOLPHIN_NAMES := ["DolphinNoGUI.exe", "dolphin-emu-nogui"]

## The games, and per game what the launcher needs. Versions: disc IDs.
const VERSIONS := ["NTSC-U", "PAL", "NTSC-J"]
const GAMES := {
	"bt3": {
		"title": "Budokai Tenkaichi 3",
		"short": "Tenkaichi 3",
		"jp": "Sparking! METEOR",
		"full_title": "Dragon Ball Z: Budokai Tenkaichi 3",
		"glyph": "3", "color": "#f2b531",
		"versions": {"NTSC-U": "RDSE70", "PAL": "RDSPAF", "NTSC-J": "RDSJAF"},
		# Netplay: each player runs only their own port's splitscreen remover (+ the ini defaults).
		"port_codes": {1: "Player 1 Splitscreen Remover", 2: "Player 2 Splitscreen Remover"},
		"neocode": true,        # the hidden NEOcode netcode (BT3 only for now)
		"terminology": true,    # Tenkaichi Terminology (data/terminology.json is BT3's)
		"ranked_prefix": "",    # ranked server modes: single / team
		"tracks": "",           # music / pictures: game_menu, netplay, lobby, ...
	},
	"bt2": {
		"title": "Budokai Tenkaichi 2",
		"short": "Tenkaichi 2",
		"jp": "Sparking! NEO",
		"full_title": "Dragon Ball Z: Budokai Tenkaichi 2",
		"glyph": "2", "color": "#3fa9f5",
		"versions": {"NTSC-U": "RDBE70", "PAL": "RDBPAF", "NTSC-J": "RDBJAF"},
		"port_codes": {1: "Player 1 Splitscreen Remover", 2: "Player 2 Splitscreen Remover"},
		"neocode": false,
		"terminology": false,
		"ranked_prefix": "b2",  # its own ranked ladder: b2single / b2team
		"tracks": "bt2_",       # its own music / pictures: bt2_game_menu, bt2_netplay, ...
	},
}
const GAME_ORDER := ["bt3", "bt2"]

## The game the menus are on and the version in use ("" = its offline copy). See use_game().
var game := "bt3"
var version := ""

## The current game and version, as one dictionary (the game's entry + id, version, path).
var GAME: Dictionary:
	get:
		var g: Dictionary = GAMES[game].duplicate()
		var v := current_version()
		g["key"] = game
		g["version"] = v
		g["id"] = g["versions"].get(v, "")
		g["path"] = copy_path(game, v)
		return g

const RENDERERS := ["Vulkan", "OGL"]                        # Dolphin -v names
const RENDERER_NAMES := ["Vulkan", "OpenGL"]
const RESOLUTIONS := [2, 3, 4, 6]                            # internal resolution multiplier
const RESOLUTION_NAMES := ["720p (2x)", "1080p (3x)", "1440p (4x)", "4K (6x)"]
const WINDOW_SIZES := ["1280x720", "1600x900", "1920x1080", "2560x1440",
	"2560x1080", "3440x1440"]   # (the last two: 21:9)
## Texture variant groups of the texture pack (folders @Graphics/<option>, @Buttons/<option>).
const GRAPHICS := ["Enhanced", "Legacy"]
const BUTTONS := ["Vanilla", "PlayStation", "Xbox"]
const REGIONS := ["NA", "SA", "EU", "AF", "EA", "CN", "OC"]
const REGION_NAMES := ["North America", "South America", "Europe", "Africa", "East Asia", "China", "Oceania"]

var _cfg := ConfigFile.new()

var defaults := {
	"paths": {
		"dolphin": "",              # "" = found automatically (see above); tests can force one
		"game": "",                 # (before game copies: the one BT3 PAL file; moved to [games])
		"data": "",                 # "" = found automatically
		"profile": "user",          # folder inside data: user (or user2 for LAN tests on one PC)
		"extra_args": "",           # advanced/testing, e.g. "-p headless -v Null"
		"setup_done": false,        # first-run setup finished
	},
	"player": {"nickname": "Player", "region": "NA"},
	"video": {"renderer": "Vulkan", "resolution": 3, "window": "1280x720", "borderless": false,
		"smooth_motion": false,   # frame interpolation (Dolphin's --smooth-motion)
		"menu_display": "fullscreen"},   # these menus: fullscreen (borderless) or window
	"options": {"buttons": "Vanilla", "graphics": "Enhanced", "aspect": "16:9",
		"hud": false,             # score bar offline (netplay always shows it)
		"hud_health": true,       # health % in the corners
		"show_fps": false, "minimize_while_playing": true, "music_volume": 7,
		"discord": true, "sfx_volume": 7,
		"language": ""},          # en / es / it ("" = ask at first launch)         # Discord Rich Presence (scripts/presence.gd)
	"netplay": {"mode": "single", "find_mode": "any", "public": true, "traversal": true,
		"buffer": 4, "public_address": "",
		"buffer_auto": false,    # host: pad buffer picked from the pings (match start + after each KO)
		"neocode": false},       # host: NEOcode (hidden: PgUp + PgDn together in the lobby)
	# Offline codes per disc ID (every version has its own codes): "<ID>_custom" = only the ticked
	# ones, "<ID>_enabled" = those. (Before versions: "custom" / "enabled", now RDSPAF's.)
	"gecko": {},
	# DRAGON NET Ranked: the ranked server (Server/ranked) and this install's Discord session.
	"ranked": {"server": "https://tecshideout.ct.ws/sparking/", "token": "", "name": "",
		"mode": "single", "board_mode": "single", "board_region": "global",
		"last_single": 0, "last_team": 0,     # last known ratings, for the menu's rating plate
		"b2last_single": 0, "b2last_team": 0},   # (Budokai Tenkaichi 2's)
	"controller": {"preset": "auto"},    # auto, keep, or a preset name (scripts/controllers.gd)
	# Game copies: "<game>_<version>" = disc image path, "<game>_offline" = the version Play
	# Offline uses, "<game>_netplay" = the version last picked for DRAGON NET.
	"games": {},
	"terminology": {"source": "https://docs.google.com/document/d/1QYI1z6ukEn-8PBvgysOUYB4-6EpmVy0HhpQmGjAmarU/mobilebasic"},
}


var _path := OLD_CONFIG
var _found_dolphin := ""
var _found_data := ""


func _ready() -> void:
	_found_dolphin = _search(func(dir: String) -> String:
		for sub in ["Dolphin", "", "build/release/x64/Binaries", "dolphin-sparking/build/release/x64/Binaries",
				"build/Binaries"]:
			for n in DOLPHIN_NAMES:
				var p := dir.path_join(sub).path_join(n)
				if FileAccess.file_exists(p):
					return p
		return "")
	_found_data = _search(func(dir: String) -> String:
		var p := dir.path_join("SparkingData")
		return p if DirAccess.dir_exists_absolute(p) else "")
	if _found_data != "":
		_path = _found_data.path_join(CONFIG_FILE)
		# Settings used to live in Godot's user folder: bring them along once.
		if not FileAccess.file_exists(_path) and FileAccess.file_exists(OLD_CONFIG):
			DirAccess.copy_absolute(ProjectSettings.globalize_path(OLD_CONFIG), _path)
	_cfg.load(_path)  # missing file = defaults
	_migrate_game_path()


## The folder the launcher runs from (the project folder when run from the editor).
func app_dir() -> String:
	if OS.has_feature("editor") or not OS.has_feature("template"):
		return ProjectSettings.globalize_path("res://").trim_suffix("/")
	return OS.get_executable_path().get_base_dir()


## Looks in the launcher's folder and up to 4 folders above it.
func _search(check: Callable) -> String:
	var dir := app_dir()
	for i in 5:
		var hit: String = check.call(dir)
		if hit != "":
			return hit
		var up := dir.get_base_dir()
		if up == dir or up == "":
			break
		dir = up
	return ""


func dolphin_path() -> String:
	var forced: String = get_value("paths", "dolphin")
	return forced if forced != "" else _found_dolphin


func data_dir() -> String:
	var forced: String = get_value("paths", "data")
	return forced if forced != "" else _found_data


## Tests: use another settings file, starting from defaults.
func use_file(path: String) -> void:
	_path = path
	_cfg = ConfigFile.new()
	_cfg.load(_path)
	_migrate_game_path()


func get_value(section: String, key: String) -> Variant:
	if section == "games":
		return _cfg.get_value(section, key, "")
	if section == "gecko":
		return _cfg.get_value(section, key, [] if key.ends_with("_enabled") else false)
	return _cfg.get_value(section, key, defaults[section][key])


func set_value(section: String, key: String, value: Variant) -> void:
	_cfg.set_value(section, key, value)
	_cfg.save(_path)
	if section == "paths" and key == "game":
		_migrate_game_path()   # (old settings / tests: the one game path)


func data_path(sub: String) -> String:
	return data_dir().path_join(sub)


# --- Games and their copies ----------------------------------------------------------------

## The menus are now on `key` (and `ver`; "" = the game's offline copy).
func use_game(key: String, ver := "") -> void:
	game = key if GAMES.has(key) else "bt3"
	version = ver


## The version in use: the one picked, else the offline one, else any the player has.
func current_version() -> String:
	if version != "":
		return version
	return offline_version(game)


func copy_path(key: String, ver: String) -> String:
	return String(get_value("games", "%s_%s" % [key, ver])) if ver != "" else ""


func has_copy(key: String, ver: String) -> bool:
	var p := copy_path(key, ver)
	return p != "" and FileAccess.file_exists(p)


## Versions of `key` with a copy on this PC, in VERSIONS order.
func owned_versions(key: String) -> Array:
	return VERSIONS.filter(func(v): return has_copy(key, v))


func set_copy(key: String, ver: String, path: String) -> void:
	set_value("games", "%s_%s" % [key, ver], path.replace("\\", "/"))
	# The first copy of a game is what Play Offline uses.
	if not has_copy(key, String(get_value("games", key + "_offline"))):
		set_value("games", key + "_offline", ver)


## The version Play Offline runs (Options > Game Copies): the one chosen, else the first owned.
func offline_version(key: String) -> String:
	var v := String(get_value("games", key + "_offline"))
	if has_copy(key, v):
		return v
	var owned := owned_versions(key)
	return owned[0] if not owned.is_empty() else (v if v != "" else "PAL")


func set_offline_version(key: String, ver: String) -> void:
	set_value("games", key + "_offline", ver)


## The game and version of a disc ID ("bt3", "PAL"), or [] if it's none of these games'.
func game_of_id(id: String) -> Array:
	for key in GAME_ORDER:
		for v in VERSIONS:
			if String(GAMES[key]["versions"][v]) == id.left(6):
				return [key, v]
	return []


## The disc ID inside a disc image (ISO / GCM, WBFS, RVZ / WIA, CISO), else one written in the
## file name like "(RDSPAF)", else "" (GCZ and the like: the player says which version it is).
static func read_disc_id(path: String) -> String:
	var f := FileAccess.open(path, FileAccess.READ)
	var id := ""
	if f != null:
		var magic := f.get_buffer(4)
		var at := 0
		if magic == "WBFS".to_ascii_buffer():
			f.seek(8)
			at = 1 << f.get_8()                 # the disc's header copy: one "HD sector" in
		elif magic == "WIA\u0001".to_ascii_buffer() or magic == "RVZ\u0001".to_ascii_buffer():
			at = 0x58                           # header 2's copy of the disc header
		elif magic == "CISO".to_ascii_buffer():
			at = 0x8000                         # the first block (always present)
		f.seek(at)
		var raw := f.get_buffer(6)
		f.close()
		if raw.size() == 6:
			var text := raw.get_string_from_ascii()
			if text.length() == 6 and RegEx.create_from_string("^[A-Z0-9]{6}$").search(text):
				id = text
	if id == "":
		var m := RegEx.create_from_string("[\\[(]([A-Z0-9]{6})[\\])]").search(path.get_file())
		if m:
			id = m.get_string(1)
	return id


## Offline codes of a version (disc ID): "custom" = exactly `enabled`, else the game's defaults.
func gecko_custom(id: String) -> bool:
	return bool(get_value("gecko", id + "_custom"))


func gecko_enabled(id: String) -> Array:
	return Array(get_value("gecko", id + "_enabled"))


func set_gecko(id: String, custom: bool, enabled: Array) -> void:
	_cfg.set_value("gecko", id + "_custom", custom)
	_cfg.set_value("gecko", id + "_enabled", enabled)
	_cfg.save(_path)


## Before game copies there was one path (BT3 PAL): file it under its version. The one code
## selection of that time was BT3 PAL's too.
func _migrate_game_path() -> void:
	if _cfg.has_section_key("gecko", "custom") or _cfg.has_section_key("gecko", "enabled"):
		if not _cfg.has_section_key("gecko", "RDSPAF_custom"):
			_cfg.set_value("gecko", "RDSPAF_custom", _cfg.get_value("gecko", "custom", false))
			_cfg.set_value("gecko", "RDSPAF_enabled", _cfg.get_value("gecko", "enabled", []))
		for k in ["custom", "enabled"]:
			if _cfg.has_section_key("gecko", k):
				_cfg.erase_section_key("gecko", k)
		_cfg.save(_path)
	var old := String(_cfg.get_value("paths", "game", ""))
	if old == "":
		return
	var where := game_of_id(read_disc_id(old))
	if where.is_empty() or where[0] != "bt3":
		where = ["bt3", "PAL"]
	if String(_cfg.get_value("games", "%s_%s" % where, "")) == "":
		_cfg.set_value("games", "%s_%s" % where, old)
	if String(_cfg.get_value("games", "bt3_offline", "")) == "":
		_cfg.set_value("games", "bt3_offline", where[1])
	_cfg.set_value("paths", "game", "")
	_cfg.save(_path)


## The disc image the current game / version runs.
func game_path() -> String:
	return GAME["path"]


## Everything needed to launch is in place.
func is_configured() -> bool:
	return missing_paths().is_empty()


## The first-run setup is needed: never done, or no copy of any game is left.
func needs_setup() -> bool:
	return not get_value("paths", "setup_done") or GAME_ORDER.all(func(k): return owned_versions(k).is_empty())


## Can the launcher and Dolphin write into SparkingData? Not when it's under C:\Program Files (or
## another protected folder) without admin rights: Dolphin then can't create its Wii system
## files, saves or settings, and the boot hangs. Checked by writing a small test file.
func data_writable() -> bool:
	if data_dir() == "" or not DirAccess.dir_exists_absolute(data_dir()):
		return true   # reported as missing instead
	for sub in ["", get_value("paths", "profile")]:
		var dir := data_dir().path_join(sub)
		if not DirAccess.dir_exists_absolute(dir) and DirAccess.make_dir_recursive_absolute(dir) != OK:
			return false
		var probe := dir.path_join(".write_test")
		var f := FileAccess.open(probe, FileAccess.WRITE)
		if f == null:
			return false
		f.store_string("ok")
		f.close()
		DirAccess.remove_absolute(probe)
	return true


func missing_paths() -> PackedStringArray:
	var out := PackedStringArray()
	if dolphin_path() == "" or not FileAccess.file_exists(dolphin_path()):
		out.append("Dolphin-Sparking")
	if not FileAccess.file_exists(game_path()):
		out.append("game file")
	if data_dir() == "" or not DirAccess.dir_exists_absolute(data_dir()):
		out.append("SparkingData folder")
	return out


# --- Command lines -----------------------------------------------------------------------

func _extra_args() -> PackedStringArray:
	var out := PackedStringArray()
	for part in String(get_value("paths", "extra_args")).split(" ", false):
		out.append(part)
	return out


## Shared by every game launch: profile, textures, video, display options.
func common_args() -> PackedStringArray:
	var a := PackedStringArray()
	a.append_array(["-u", data_path(get_value("paths", "profile"))])
	a.append_array(["-v", get_value("video", "renderer")])
	a.append_array(["--resolution", str(get_value("video", "resolution"))])
	a.append_array(["--smooth-motion", "on" if get_value("video", "smooth_motion") else "off"])
	a.append_array(["--window", get_value("video", "window")])
	a.append_array(["--aspect", get_value("options", "aspect")])
	a.append_array(["--hud-health", "on" if get_value("options", "hud_health") else "off"])
	a.append_array(["--textures-dir", data_path("textures")])
	a.append_array(["--textures", "Graphics=" + get_value("options", "graphics")])
	a.append_array(["--textures", "Buttons=" + get_value("options", "buttons")])
	if get_value("options", "show_fps"):
		a.append_array(["-C", "Graphics.Settings.ShowFPS=True"])
	a.append_array(_extra_args())
	return a


func solo_args() -> PackedStringArray:
	var a := common_args()
	# Score bar offline only if the player wants it.
	a.append_array(["--hud", "on" if get_value("options", "hud") else "off"])
	a.append_array(["--sparking", "--nand", data_path("saves/solo"), "--state-dir", data_path("states")])
	if gecko_custom(GAME["id"]):
		var codes: Array = gecko_enabled(GAME["id"])
		if codes.is_empty():
			a.append("--no-gecko")
		for code in codes:
			a.append_array(["--gecko", code])
	a.append_array(["-e", game_path()])
	return a


## Watch a recorded ranked match (replays.gd): from the start of its first round to its end,
## with the Gecko codes the recording player had on.
func replay_args(dtm_path: String, codes: Array, disc_id := "") -> PackedStringArray:
	# The replay's own game and version (recorded in its info), else the current one.
	var where := game_of_id(disc_id)
	if not where.is_empty() and has_copy(where[0], where[1]):
		use_game(where[0], where[1])
	var a := common_args()
	a.append_array(["--hud", "off", "--sparking", "--local-players", "2"])
	a.append_array(["--nand", data_path("saves/replay"), "--state-dir", data_path("states")])
	if codes.is_empty():
		a.append("--no-gecko")
	for code in codes:
		a.append_array(["--gecko", String(code)])
	a.append_array(["--replay", dtm_path, "-e", game_path()])
	return a


## DRAGON NET > Rollback Test: offline, with Dolphin rewinding and re-running `fields` video
## fields again and again (--rollback-test), results to `log` (JSON lines).
func rollback_test_args(fields: int, log: String, gpu_state := false, draw := false,
		diagnose := false) -> PackedStringArray:
	var a := solo_args()
	var game := a.size() - 2   # (solo_args ends with -e <game>)
	var extra := PackedStringArray(["--rollback-test", str(fields), "--rollback-gap", "20",
		"--rollback-log", log])
	# Dolphin's states normally carry the graphics card's textures too; rollback won't.
	# (-C takes the system's name as Dolphin writes it: "Graphics", not "GFX".)
	extra.append_array(["-C", "Graphics.Settings.SaveTextureCacheToState=%s" % ("True" if gpu_state else "False")])
	if draw:
		extra.append("--rollback-draw")       # re-runs drawn too (normally skipped, as rollback will)
	if diagnose:
		extra.append("--rollback-diagnose")   # detailed log: where the runs parted (slower)
	for i in extra.size():
		a.insert(game + i, extra[i])
	return a


func _netplay_base(nickname := "") -> PackedStringArray:
	var a := common_args()
	a.append_array(["--hud", "on"])   # score bar + ping always on in netplay matches
	a.append_array(["--nand", data_path("saves/netplay"), "--state-dir", data_path("states")])
	a.append_array(["--nickname", nickname if nickname != "" else String(get_value("player", "nickname"))])
	var codes: Dictionary = GAMES[game]["port_codes"]
	for port in codes:
		a.append_array(["--netplay-gecko", "%d=%s" % [port, codes[port]]])
	return a


func host_args(mode: String, public: bool, traversal: bool, koth := false) -> PackedStringArray:
	var a := _netplay_base()
	a.append_array(["--mode", mode])
	if koth:
		a.append("--koth")   # Battle Lounge lobby
	if not traversal:
		a.append("--netplay-direct")
	if public:
		a.append_array(["--public", "--region", get_value("player", "region")])
		# A direct (IP) lobby is listed with the address others should connect to.
		if not traversal and String(get_value("netplay", "public_address")) != "":
			a.append_array(["--public-address", get_value("netplay", "public_address")])
	a.append_array(["--netplay-host", game_path()])
	return a


## Ranked: never on Dolphin's lobby list (the ranked server lists it), 2 players, no spectators.
## Everyone plays under their Discord name.
func ranked_host_args(mode: String, traversal: bool) -> PackedStringArray:
	var a := _netplay_base(ranked_nickname())
	a.append_array(["--mode", mode, "--ranked"])
	a.append_array(["--record-replays", data_path("replays")])
	if not traversal:
		a.append("--netplay-direct")
	a.append_array(["--netplay-host", game_path()])
	return a


func ranked_join_args(target: String) -> PackedStringArray:
	var a := _netplay_base(ranked_nickname())
	a.append_array(["--record-replays", data_path("replays")])   # decided matches are saved
	a.append_array(["--netplay-game", game_path(), "--netplay-join", target])
	return a


func ranked_nickname() -> String:
	var n := String(get_value("ranked", "name")).strip_edges()
	return (n if n != "" else String(get_value("player", "nickname"))).left(24)


## Buffer Training: solo direct-IP host, never listed; Dolphin refuses anyone else who joins.
func training_args() -> PackedStringArray:
	return host_args("training", false, false)


func join_args(target: String, koth := false) -> PackedStringArray:
	var a := _netplay_base()
	a.append_array(["--netplay-game", game_path(), "--netplay-join", target])
	if koth:
		a.append("--koth")   # joining during a set waits for it to end
	return a


## Watch a lobby: joins it as a spectator (no controller port, default codes only).
func watch_args(target: String, koth := false) -> PackedStringArray:
	var a := join_args(target, koth)
	a.append("--spectate")
	return a


func find_args(mode: String, koth := false) -> PackedStringArray:
	var a := _netplay_base()
	a.append_array(["--netplay-find", mode, "--region", get_value("player", "region")])
	if koth:
		a.append("--koth")
	a.append_array(["--netplay-game", game_path()])
	return a


func list_lobbies_args(koth := false) -> PackedStringArray:
	var a := PackedStringArray(["-u", data_path(get_value("paths", "profile")), "--list-lobbies"])
	if koth:
		a.append("--koth")   # Battle Lounge lobbies only (without it: regular ones only)
	a.append_array(_extra_args())
	return a


## Controller tester / binding helper (Dolphin's own device and input names).
func input_test_args() -> PackedStringArray:
	var a := PackedStringArray(["-u", data_path(get_value("paths", "profile")), "--input-test"])
	a.append_array(_extra_args())
	return a


## The codes of a disc ID (default: the current version's).
func list_gecko_args(id := "") -> PackedStringArray:
	return PackedStringArray(["-u", data_path(get_value("paths", "profile")), "--list-gecko",
		id if id != "" else String(GAME["id"])])


## How a texture option is shown: the "Vanilla" button folder is the GameCube prompts.
func option_name(group: String, option: String) -> String:
	if group == "buttons" and option == "Vanilla":
		return "GameCube"
	return option


## Dolphin's `textures` event reports the selection in lowercase; store the proper names.
func remember_textures(selection: Dictionary) -> void:
	for pair in [["graphics", GRAPHICS], ["buttons", BUTTONS]]:
		var picked := String(selection.get(pair[0], ""))
		for option in pair[1]:
			if option.to_lower() == picked:
				set_value("options", pair[0], option)
