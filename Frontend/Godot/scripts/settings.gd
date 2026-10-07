extends Node
## Saved settings and the Dolphin command lines built from them.
## This test build supports one game: BT3 PAL (RDSPAF).
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

## The one game of this build. Per-game data the launcher needs.
const GAME := {
	"id": "RDSPAF",
	"title": "Budokai Tenkaichi 3",
	"full_title": "Dragon Ball Z: Budokai Tenkaichi 3 (PAL)",
	# Netplay: each player runs only their own port's splitscreen remover (+ the ini defaults).
	"port_codes": {1: "Player 1 Splitscreen Remover", 2: "Player 2 Splitscreen Remover"},
}

const RENDERERS := ["Vulkan", "OGL"]                        # Dolphin -v names
const RENDERER_NAMES := ["Vulkan", "OpenGL"]
const RESOLUTIONS := [2, 3, 4, 6]                            # internal resolution multiplier
const RESOLUTION_NAMES := ["720p (2x)", "1080p (3x)", "1440p (4x)", "4K (6x)"]
const WINDOW_SIZES := ["1280x720", "1600x900", "1920x1080", "2560x1440"]
## Texture variant groups of the texture pack (folders @Graphics/<option>, @Buttons/<option>).
const GRAPHICS := ["Enhanced", "Legacy"]
const BUTTONS := ["Vanilla", "PlayStation", "Xbox"]
const REGIONS := ["NA", "SA", "EU", "AF", "EA", "CN", "OC"]
const REGION_NAMES := ["North America", "South America", "Europe", "Africa", "East Asia", "China", "Oceania"]

var _cfg := ConfigFile.new()

var defaults := {
	"paths": {
		"dolphin": "",              # "" = found automatically (see above); tests can force one
		"game": "",
		"data": "",                 # "" = found automatically
		"profile": "user",          # folder inside data: user (or user2 for LAN tests on one PC)
		"extra_args": "",           # advanced/testing, e.g. "-p headless -v Null"
		"setup_done": false,        # first-run setup finished
	},
	"player": {"nickname": "Player", "region": "NA"},
	"video": {"renderer": "Vulkan", "resolution": 3, "window": "1280x720", "borderless": false,
		"menu_display": "fullscreen"},   # these menus: fullscreen (borderless) or window
	"options": {"buttons": "Vanilla", "graphics": "Enhanced", "aspect": "16:9",
		"hud": false,             # score bar offline (netplay always shows it)
		"hud_health": true,       # health % in the corners
		"show_fps": false, "minimize_while_playing": true, "music_volume": 7,
		"discord": true, "sfx_volume": 7,
		"language": ""},          # en / es / it ("" = ask at first launch)         # Discord Rich Presence (scripts/presence.gd)
	"netplay": {"mode": "single", "find_mode": "any", "public": true, "traversal": true,
		"buffer": 4, "public_address": "",
		"buffer_auto": false},   # host: pad buffer picked from the pings (match start + after each KO)
	"gecko": {"custom": false, "enabled": []},
	"controller": {"preset": "auto"},    # auto, keep, or a preset name (scripts/controllers.gd)
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


func get_value(section: String, key: String) -> Variant:
	return _cfg.get_value(section, key, defaults[section][key])


func set_value(section: String, key: String, value: Variant) -> void:
	_cfg.set_value(section, key, value)
	_cfg.save(_path)


func data_path(sub: String) -> String:
	return data_dir().path_join(sub)


## Everything needed to launch is in place.
func is_configured() -> bool:
	return missing_paths().is_empty()


## The first-run setup is needed: never done, or the game file has gone.
func needs_setup() -> bool:
	return not get_value("paths", "setup_done") or not FileAccess.file_exists(get_value("paths", "game"))


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
	if not FileAccess.file_exists(get_value("paths", "game")):
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
	if get_value("gecko", "custom"):
		var codes: Array = get_value("gecko", "enabled")
		if codes.is_empty():
			a.append("--no-gecko")
		for code in codes:
			a.append_array(["--gecko", code])
	a.append_array(["-e", get_value("paths", "game")])
	return a


func _netplay_base() -> PackedStringArray:
	var a := common_args()
	a.append_array(["--hud", "on"])   # score bar + ping always on in netplay matches
	a.append_array(["--nand", data_path("saves/netplay"), "--state-dir", data_path("states")])
	a.append_array(["--nickname", get_value("player", "nickname")])
	for port in GAME["port_codes"]:
		a.append_array(["--netplay-gecko", "%d=%s" % [port, GAME["port_codes"][port]]])
	return a


func host_args(mode: String, public: bool, traversal: bool) -> PackedStringArray:
	var a := _netplay_base()
	a.append_array(["--mode", mode])
	if not traversal:
		a.append("--netplay-direct")
	if public:
		a.append_array(["--public", "--region", get_value("player", "region")])
		# A direct (IP) lobby is listed with the address others should connect to.
		if not traversal and String(get_value("netplay", "public_address")) != "":
			a.append_array(["--public-address", get_value("netplay", "public_address")])
	a.append_array(["--netplay-host", get_value("paths", "game")])
	return a


func join_args(target: String) -> PackedStringArray:
	var a := _netplay_base()
	a.append_array(["--netplay-game", get_value("paths", "game"), "--netplay-join", target])
	return a


func find_args(mode: String) -> PackedStringArray:
	var a := _netplay_base()
	a.append_array(["--netplay-find", mode, "--region", get_value("player", "region")])
	a.append_array(["--netplay-game", get_value("paths", "game")])
	return a


func list_lobbies_args() -> PackedStringArray:
	var a := PackedStringArray(["-u", data_path(get_value("paths", "profile")), "--list-lobbies"])
	a.append_array(_extra_args())
	return a


## Controller tester / binding helper (Dolphin's own device and input names).
func input_test_args() -> PackedStringArray:
	var a := PackedStringArray(["-u", data_path(get_value("paths", "profile")), "--input-test"])
	a.append_array(_extra_args())
	return a


func list_gecko_args() -> PackedStringArray:
	return PackedStringArray(["-u", data_path(get_value("paths", "profile")), "--list-gecko",
		GAME["id"]])


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
