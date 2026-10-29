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
const ALL_VERSIONS := ["NTSC-U", "PAL", "NTSC-J"]
## Not supported yet (both games): shown in Game Copies as locked, never played. Take a version
## out of here to unlock it.
const LOCKED_VERSIONS := ["NTSC-U"]
## The versions that can be played (ALL_VERSIONS minus the locked ones).
const VERSIONS := ["PAL", "NTSC-J"]
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

const RENDERERS := ["Vulkan", "OGL", "D3D12", "D3D"]       # Dolphin -v names (D3D: Windows only)
## Anti-aliasing: Dolphin's MSAA sample count, SSAA on top.
const ANTIALIASING := ["off", "msaa2", "msaa4", "msaa8", "ssaa2", "ssaa4", "ssaa8"]
const ANTIALIASING_NAMES := ["Off", "2x MSAA", "4x MSAA", "8x MSAA", "2x SSAA", "4x SSAA", "8x SSAA"]
const ANISOTROPY := [-1, 0, 1, 2, 3, 4]
const ANISOTROPY_NAMES := ["Default", "1x", "2x", "4x", "8x", "16x"]
const TEXTURE_FILTERING := [0, 1, 2]
const TEXTURE_FILTERING_NAMES := ["Default", "Nearest", "Linear"]
const OUTPUT_RESAMPLING := [0, 1, 2, 3, 4, 5, 6]
const OUTPUT_RESAMPLING_NAMES := ["Default", "Bilinear", "B-Spline", "Mitchell-Netravali",
	"Catmull-Rom", "Sharp Bilinear", "Area Sampling"]
const CC_COLOR_SPACES := ["off", "0", "1", "2"]   # off, or the region's color space (Dolphin's ColorCorrectionRegion)
const CC_COLOR_SPACE_NAMES := ["Off", "NTSC-M (SMPTE 170M)", "NTSC-J (ARIB TR-B9)", "PAL (EBU)"]
const CC_GAMMAS := ["off", "2.2", "2.35", "2.5"]
const CC_GAMMA_NAMES := ["Off", "2.2", "2.35 (CRT TV)", "2.5"]
const CC_DISPLAY_GAMMAS := ["srgb", "2.2", "2.4"]
const CC_DISPLAY_GAMMA_NAMES := ["sRGB", "2.2", "2.4"]
const HDR_PAPER_WHITES := [80, 120, 203, 300, 400, 500]
const SHADER_MODES := [0, 1, 2, 3]
const SHADER_MODE_NAMES := ["Specialized", "Exclusive Ubershaders", "Hybrid Ubershaders", "Skip Drawing"]
const RENDERER_NAMES := ["Vulkan", "OpenGL", "Direct3D 12", "Direct3D 11"]
const RESOLUTIONS := [1, 2, 3, 4, 6]                            # internal resolution multiplier
const RESOLUTION_NAMES := ["480p (1x, native)", "720p (2x)", "1080p (3x)", "1440p (4x)", "4K (6x)"]
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
		"machine": "",              # the PC these settings belong to (Settings._check_machine)
	},
	"player": {"nickname": "Player", "region": "NA"},
	"video": {"renderer": "Vulkan", "resolution": 3, "window": "1280x720", "borderless": false,
		"smooth_motion": false,   # frame interpolation (Dolphin's --smooth-motion)
		"menu_display": "fullscreen",    # these menus: fullscreen (borderless) or window
		# Dolphin's other picture settings (only those that can't desync a netplay match; Dolphin
		# only syncs these in its "strict" mode, which DRAGON NET doesn't use). Dolphin's defaults.
		"vsync": false,
		"antialiasing": "off",           # ANTIALIASING
		"anisotropy": -1,                # -1 = the game's own, 0..4 = 1x..16x
		"texture_filtering": 0,          # 0 default, 1 nearest, 2 linear
		"output_resampling": 0,          # OUTPUT_RESAMPLING
		"shader_compilation": 0,         # SHADER_MODES
		"disable_fog": false,
		"crop": false,                   # crop the picture's edges to the aspect ratio
		"true_color": true,              # force 24-bit color
		"copy_filter_off": true,         # disable the copy filter (sharper)
		"arbitrary_mipmaps": false,      # arbitrary mipmap detection
		"backend_multithreading": true,
		# Dolphin's Color Correction (Graphics > Enhancements > Color Correction).
		"cc_color_space": "off",         # CC_COLOR_SPACES
		"cc_game_gamma": "off",          # CC_GAMMAS: correct the game's gamma to this
		"cc_display_gamma": "srgb",      # CC_DISPLAY_GAMMAS
		"hdr": false,                    # HDR output (an HDR monitor, Vulkan / Direct3D)
		"hdr_paper_white": 203},         # HDR_PAPER_WHITES (nits)
	"options": {"buttons": "Vanilla", "graphics": "Enhanced", "aspect": "16:9",
		"training_display": false,   # Modifications > Training Display: hitboxes + frame data offline
		"hud": false,             # score bar offline (netplay always shows it)
		"hud_health": true,       # health % in the corners
		"input_display": false,   # your input history (fighting-game style column) in every game
		"input_display_other": false,     # P2's too (offline only: never in online matches)
		"training_input_display": true,   # yours in Buffer Training (its own switch)
		"training_input_display_other": false,   # the other port's in Buffer Training
		"show_fps": false, "minimize_while_playing": true, "music_volume": 7,
		"discord": true, "sfx_volume": 7,
		"language": "",           # en / es / it / ja ("" = ask at first launch)
		"boot_timeout": 10},      # seconds a starting game may show nothing before it's closed (0 = off)
	"netplay": {"quick_direct": false,   # tests: Quick Match by IP (127.0.0.1), no room code server
		"mode": "single", "find_mode": "any", "public": true, "traversal": true,
		"record_matches": false,   # record Player Match / Battle Lounge games (kept on this PC only)
		"buffer": 4, "public_address": "",
		"buffer_auto": false,    # host: pad buffer picked from the pings (match start + after each KO)
		"neocode": false},       # host: NEOcode (hidden: PgUp + PgDn together in the lobby)
	# Offline codes per disc ID (every version has its own codes): "<ID>_custom" = only the ticked
	# ones, "<ID>_enabled" = those. (Before versions: "custom" / "enabled", now RDSPAF's.)
	"gecko": {},
	# DRAGON NET Ranked: the ranked server (Server/ranked) and this install's Discord session.
	# mirror: the same server through Cloudflare (Server/cloudflare-worker), for players whose
	# antivirus / router / ISP blocks the server's own address. Tried when the server can't be
	# reached; "" = none.
	"ranked": {"server": "https://tecshideout.ct.ws/sparking/", "mirror": "", "token": "", "name": "",
		"mode": "single", "board_mode": "single", "board_region": "global",
		"last_single": 0, "last_team": 0,     # last known ratings, for the menu's rating plate
		"b2last_single": 0, "b2last_team": 0},   # (Budokai Tenkaichi 2's)
	# Automatic updates (scripts/updater.gd). root / key / platform: tests only (the install
	# folder to update, the public key to trust, "windows" / "linux").
	"update": {"root": "", "key": "", "platform": "", "packs": {}},
	# Per game: "<game>_preset" = auto, keep, or a preset name (scripts/controllers.gd); "" = not
	# chosen yet. ("preset": the one choice before per-game ones, now Tenkaichi 3's.)
	# "gcpad_game": whose mapping GCPadNew.ini's [GCPad1] holds now (scripts/controllers.gd).
	"controller": {"preset": "auto", "bt3_preset": "", "bt2_preset": "", "gcpad_game": ""},
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
	_check_machine()
	_migrate_game_path()
	prepare_netplay_saves()


## Settings made on another PC (a SparkingData folder copied over, or shipped inside an installer)
## hold that PC's disc image paths and its DRAGON NET login: those are forgotten here (setup runs
## again), the rest (options, video, controls) is kept. The settings remember the PC they're
## from ([paths] machine).
func _check_machine() -> void:
	var here := machine_id()
	if here == "":
		return
	var saved := String(_cfg.get_value("paths", "machine", ""))
	if saved == here:
		return
	if saved != "":
		forget_this_pc_only()
	_cfg.set_value("paths", "machine", here)
	_cfg.save(_path)


## This PC (a hash of the OS's machine id; "" if there's none).
static func machine_id() -> String:
	var raw := OS.get_unique_id()
	return raw.sha256_text().left(16) if raw != "" else ""


## What belongs to one PC only: the disc image paths, the DRAGON NET session, located folders.
func forget_this_pc_only() -> void:
	if _cfg.has_section("games"):
		_cfg.erase_section("games")
	for k in ["token", "name"]:
		if _cfg.has_section_key("ranked", k):
			_cfg.erase_section_key("ranked", k)
	for k in ["dolphin", "data", "game"]:
		if _cfg.has_section_key("paths", k):
			_cfg.erase_section_key("paths", k)
	_cfg.set_value("paths", "setup_done", false)


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
	if section == "paths" and key == "data":
		prepare_netplay_saves()


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


## The disc image a version runs. A version with a disc recipe (scripts/discs.gd) runs the
## launcher's own copy built from the player's disc, never a picked file.
func copy_path(key: String, ver: String) -> String:
	if ver == "":
		return ""
	var id := String(GAMES.get(key, {}).get("versions", {}).get(ver, ""))
	if Discs.has_recipe(id):
		return Discs.built_path(id)
	return String(get_value("games", "%s_%s" % [key, ver]))


func has_copy(key: String, ver: String) -> bool:
	if not ver in VERSIONS:
		return false   # a locked version (NTSC-U for now) is never played, even if it's set
	var id := String(GAMES.get(key, {}).get("versions", {}).get(ver, ""))
	if Discs.has_recipe(id):
		return Discs.ready(id)
	var p := copy_path(key, ver)
	return p != "" and FileAccess.file_exists(p)


## What players see for a version: "4.0" for one with a recipe named so, else "PAL", "NTSC-J".
func version_name(key: String, ver: String) -> String:
	return Discs.version_name(key, ver) if GAMES.has(key) and ver != "" else ver


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
	return owned[0] if not owned.is_empty() else (v if v in VERSIONS else "PAL")


func set_offline_version(key: String, ver: String) -> void:
	set_value("games", key + "_offline", ver)


## The game and version of a disc ID ("bt3", "PAL"), or [] if it's none of these games'.
func game_of_id(id: String) -> Array:
	for key in GAME_ORDER:
		for v in ALL_VERSIONS:
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


## DRAGON NET's own save folders, one per version (a Wii NAND each): the unlocked save every
## player of that version must have, never written back. saves/netplay/<disc ID>.
func netplay_save_dir(id := "") -> String:
	return data_path("saves/netplay").path_join(id if id != "" else String(GAME["id"]))


## Before per-version folders, saves/netplay was one NAND holding the BT3 PAL save: it becomes
## saves/netplay/RDSPAF. Every version's folder is made (empty) so it's clear where saves go.
func prepare_netplay_saves() -> void:
	if data_dir() == "" or not DirAccess.dir_exists_absolute(data_dir()):
		return
	var root := data_path("saves/netplay")
	if DirAccess.dir_exists_absolute(root.path_join("title")) and \
			not DirAccess.dir_exists_absolute(root.path_join("RDSPAF")):
		var tmp := data_path("saves/netplay_old_layout")
		if DirAccess.rename_absolute(root, tmp) == OK:
			DirAccess.make_dir_recursive_absolute(root)
			DirAccess.rename_absolute(tmp, root.path_join("RDSPAF"))
	for key in GAME_ORDER:
		for v in VERSIONS:
			DirAccess.make_dir_recursive_absolute(root.path_join(String(GAMES[key]["versions"][v])))
	var readme := root.path_join("README.txt")
	if not FileAccess.file_exists(readme):
		var f := FileAccess.open(readme, FileAccess.WRITE)
		if f:
			f.store_string("DRAGON NET save folders: one per game version (disc ID), each a Wii NAND.\r\n"
				+ "Every player of a version needs the exact same unlocked save in its folder,\r\n"
				+ "or the lobby blocks the match. Online play never writes to these.\r\n\r\n"
				+ "  RDSPAF  Budokai Tenkaichi 3 PAL      RDBPAF  Budokai Tenkaichi 2 PAL\r\n"
				+ "  RDSE70  Budokai Tenkaichi 3 NTSC-U   RDBE70  Budokai Tenkaichi 2 NTSC-U\r\n"
				+ "  RDSJAF  Budokai Tenkaichi 3 NTSC-J   RDBJAF  Budokai Tenkaichi 2 NTSC-J\r\n\r\n"
				+ "The save goes in <ID>\\title\\00010000\\<hex of the first 4 letters>\\data\r\n"
				+ "(2_install_netplay_save.bat does it for you).\r\n")
			f.close()


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
	a.append_array(["-v", renderer()])
	a.append_array(["--resolution", str(get_value("video", "resolution"))])
	a.append_array(["--smooth-motion", "on" if get_value("video", "smooth_motion") else "off"])
	a.append_array(["--window", get_value("video", "window")])
	a.append_array(["--aspect", get_value("options", "aspect")])
	a.append_array(["--hud-health", "on" if get_value("options", "hud_health") else "off"])
	a.append_array(["--input-display", "on" if get_value("options", "input_display") else "off"])
	a.append_array(["--input-display-other", "on" if get_value("options", "input_display_other") else "off"])
	a.append_array(["--textures-dir", data_path("textures")])
	a.append_array(["--textures", "Graphics=" + get_value("options", "graphics")])
	a.append_array(["--textures", "Buttons=" + get_value("options", "buttons")])
	if get_value("options", "show_fps"):
		a.append_array(["-C", "Graphics.Settings.ShowFPS=True"])
	a.append_array(video_args())
	a.append_array(_extra_args())
	return a


## The renderers this system has: Direct3D only on Windows.
func renderers() -> Array:
	return RENDERERS if OS.get_name() == "Windows" else RENDERERS.filter(func(r): return not String(r).begins_with("D3D"))


func renderer_names() -> Array:
	return renderers().map(func(r): return RENDERER_NAMES[RENDERERS.find(r)])


## The renderer to use: the chosen one if this system has it (settings copied from Windows to
## Linux), else Vulkan.
func renderer() -> String:
	var r := String(get_value("video", "renderer"))
	return r if r in renderers() else "Vulkan"


## Dolphin's picture settings (Options > Video Settings), always given, so the launcher's
## choice wins over whatever the profile's Dolphin settings say.
func video_args() -> PackedStringArray:
	var b := func(key: String) -> String: return "True" if get_value("video", key) else "False"
	var aa := String(get_value("video", "antialiasing"))
	var samples := 1 if aa == "off" else int(aa.right(1))
	var c := PackedStringArray([
		"Graphics.Hardware.VSync=" + b.call("vsync"),
		"Graphics.Settings.MSAA=%d" % samples,
		"Graphics.Settings.SSAA=" + ("True" if aa.begins_with("ssaa") else "False"),
		"Graphics.Enhancements.MaxAnisotropy=%d" % int(get_value("video", "anisotropy")),
		"Graphics.Enhancements.ForceTextureFiltering=%d" % int(get_value("video", "texture_filtering")),
		"Graphics.Enhancements.OutputResampling=%d" % int(get_value("video", "output_resampling")),
		"Graphics.Settings.ShaderCompilationMode=%d" % int(get_value("video", "shader_compilation")),
		"Graphics.Settings.DisableFog=" + b.call("disable_fog"),
		"Graphics.Settings.Crop=" + b.call("crop"),
		"Graphics.Enhancements.ForceTrueColor=" + b.call("true_color"),
		"Graphics.Enhancements.DisableCopyFilter=" + b.call("copy_filter_off"),
		"Graphics.Enhancements.ArbitraryMipmapDetection=" + b.call("arbitrary_mipmaps"),
		"Graphics.Settings.BackendMultithreading=" + b.call("backend_multithreading"),
		"Graphics.ColorCorrection.CorrectColorSpace=" + ("False" if String(get_value("video", "cc_color_space")) == "off" else "True"),
		"Graphics.ColorCorrection.GameColorSpace=" + (String(get_value("video", "cc_color_space")) if String(get_value("video", "cc_color_space")) != "off" else "0"),
		"Graphics.ColorCorrection.CorrectGamma=" + ("False" if String(get_value("video", "cc_game_gamma")) == "off" else "True"),
		"Graphics.ColorCorrection.GameGamma=" + (String(get_value("video", "cc_game_gamma")) if String(get_value("video", "cc_game_gamma")) != "off" else "2.35"),
		"Graphics.ColorCorrection.SDRDisplayGammaSRGB=" + ("True" if String(get_value("video", "cc_display_gamma")) == "srgb" else "False"),
		"Graphics.ColorCorrection.SDRDisplayCustomGamma=" + (String(get_value("video", "cc_display_gamma")) if String(get_value("video", "cc_display_gamma")) != "srgb" else "2.2"),
		"Graphics.Enhancements.HDROutput=" + b.call("hdr"),
		"Graphics.ColorCorrection.HDRPaperWhiteNits=%d" % int(get_value("video", "hdr_paper_white")),
	])
	var a := PackedStringArray()
	for x in c:
		a.append_array(["-C", x])
	return a


## Modifications > Training Display: the Stats & Frame Data Overlay from BT3 Phantom Mods (with the
## creator's permission), as Action Replay codes in Dolphin's Sys game ini. Per disc ID: the codes
## it needs (framework, its settings menu, the overlay) and ours that makes it show hitboxes and
## frame data from the start (its own defaults show nothing). Offline only: never in netplay (Dolphin
## runs no Action Replay code there) nor in replays.
const TRAINING_DISPLAY := {
	"RDSPAF": ["BT3 Phantom Mods Framework V0.6.17", "Mod Settings Menu V0.20.17",
		"Stats & Frame Data Overlay - Menu V0.36.1", "Training Display Defaults [Sparking]"],
}

## The overlay is made for this version of the game.
func training_display_available() -> bool:
	return TRAINING_DISPLAY.has(String(GAME["id"]))


## Training Display on for the next offline game (on, and made for this version).
func training_display_on() -> bool:
	return bool(get_value("options", "training_display")) and training_display_available()


## Its codes, plus the setup the creator runs them with (CPU overclock 3x, 128 MB MEM2).
func training_display_args() -> PackedStringArray:
	var a := PackedStringArray()
	if not training_display_on():
		return a
	for code in TRAINING_DISPLAY[String(GAME["id"])]:
		a.append_array(["--action-replay", code])
	a.append_array(["-C", "Dolphin.Core.OverclockEnable=True", "-C", "Dolphin.Core.Overclock=3",
		"-C", "Dolphin.Core.RAMOverrideEnable=True", "-C", "Dolphin.Core.MEM2Size=134217728"])
	return a


func solo_args(training_display := true) -> PackedStringArray:
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
	if training_display:
		a.append_array(training_display_args())
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
	var a := solo_args(false)   # (never the Training Display: it measures the game alone)
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
	a.append_array(["--input-display-other", "off"])   # never the opponent's inputs online
	a.append_array(["--nand", netplay_save_dir(), "--state-dir", data_path("states")])
	a.append_array(["--nickname", nickname if nickname != "" else String(get_value("player", "nickname"))])
	# The DRAGON NET account (if logged in): friends in the same lobby get told.
	if Ranked.logged_in() and not Ranked.needs_account and Ranked.display_name() != "":
		a.append_array(["--account", Ranked.display_name()])
	var codes: Dictionary = GAMES[game]["port_codes"]
	for port in codes:
		a.append_array(["--netplay-gecko", "%d=%s" % [port, codes[port]]])
	return a


## Record matches (a lobby's switch, remembered): Player Match / Battle Lounge games go to
## replays/local, on this PC only (never uploaded; ranked ones are recorded anyway).
func local_replay_args() -> PackedStringArray:
	if not get_value("netplay", "record_matches"):
		return PackedStringArray()
	return PackedStringArray(["--record-replays", local_replay_dir()])


func local_replay_dir() -> String:
	return data_path("replays").path_join("local")


func host_args(mode: String, public: bool, traversal: bool, koth := false) -> PackedStringArray:
	var a := _netplay_base()
	a.append_array(["--mode", mode])
	if mode != "training":
		a.append_array(local_replay_args())
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
	a.append("--ranked")   # (a guest: its recordings are the ranked kind)
	a.append_array(["--netplay-game", game_path(), "--netplay-join", target])
	return a


## Quick Match: the connection made once two players are paired, before either accepts (so both
## see the real ping): a second Dolphin next to Buffer Training, room code only, never listed,
## Single Battle. The host (picked by the server) gets pad 1. Its own port (2627), so it doesn't
## clash with Buffer Training's (2626). On both accepting it becomes the match (Dolphin.adopt).
const QUICK_PORT := 2627

func quick_host_args() -> PackedStringArray:
	var a := _netplay_base(ranked_nickname())
	a.append_array(["--mode", "single"])
	a.append_array(local_replay_args())
	if get_value("netplay", "quick_direct"):
		a.append_array(["--netplay-direct", "-C", "Dolphin.NetPlay.HostPort=%d" % QUICK_PORT])
	else:
		a.append_array(["-C", "Dolphin.NetPlay.TraversalChoice=traversal", "-C", "Dolphin.NetPlay.ListenPort=%d" % QUICK_PORT])
	a.append_array(["--stats-interval", "1000"])   # (the boot watchdog, once it's the match)
	a.append_array(["--netplay-host", game_path()])
	return a


func quick_join_args(target: String) -> PackedStringArray:
	var a := _netplay_base(ranked_nickname())
	a.append_array(local_replay_args())
	if not get_value("netplay", "quick_direct"):
		a.append_array(["-C", "Dolphin.NetPlay.TraversalChoice=traversal"])
	a.append_array(["--stats-interval", "1000"])
	a.append_array(["--netplay-game", game_path(), "--netplay-join", target])
	return a


func ranked_nickname() -> String:
	var n := String(get_value("ranked", "name")).strip_edges()
	return (n if n != "" else String(get_value("player", "nickname"))).left(24)


## Buffer Training: solo direct-IP host, never listed; Dolphin refuses anyone else who joins.
func training_args() -> PackedStringArray:
	var a := host_args("training", false, false)
	# Its own input history switch (on by default): the later --input-display wins.
	a.append_array(["--input-display", "on" if get_value("options", "training_input_display") else "off"])
	a.append_array(["--input-display-other",
		"on" if get_value("options", "training_input_display_other") else "off"])
	return a


## The settings key of an input history switch: yours or the other port's (`other`), in Buffer
## Training or any other game.
static func input_display_key(training: bool, other := false) -> String:
	return ("training_" if training else "") + ("input_display_other" if other else "input_display")


func join_args(target: String, koth := false) -> PackedStringArray:
	var a := _netplay_base()
	a.append_array(local_replay_args())
	a.append_array(["--netplay-game", game_path(), "--netplay-join", target])
	if koth:
		a.append("--koth")   # joining during a set waits for it to end
	return a


## Watch a lobby: joins it as a spectator (no controller port; runs pad 1's codes, so its game
## runs exactly like player 1's).
func watch_args(target: String, koth := false) -> PackedStringArray:
	var a := join_args(target, koth)
	a.append("--spectate")
	return a


func find_args(mode: String, koth := false) -> PackedStringArray:
	var a := _netplay_base()
	a.append_array(local_replay_args())
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
