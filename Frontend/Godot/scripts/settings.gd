extends Node
## Saved settings (user://sparking.cfg) and the Dolphin command lines built from them.
## This test build supports one game: BT3 PAL (RDSPAF).

const CONFIG_PATH := "user://sparking.cfg"

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

## Defaults match the test PC's layout (E:\SparkDol); the Setup screen changes them.
var defaults := {
	"paths": {
		"dolphin": "E:/SparkDol/dolphin-sparking/build/release/x64/Binaries/DolphinNoGUI.exe",
		"game": "",
		"data": "E:/SparkDol/SparkingData",
		"profile": "user",          # folder inside data: user (or user2 for a 2nd local instance)
		"extra_args": "",           # advanced/testing, e.g. "-p headless -v Null"
	},
	"player": {"nickname": "Player", "region": "NA"},
	"video": {"renderer": "Vulkan", "resolution": 3, "window": "1280x720", "borderless": false},
	"options": {"buttons": "Vanilla", "graphics": "Enhanced", "aspect": "16:9", "hud": true,
		"show_fps": false, "minimize_while_playing": true},
	"netplay": {"mode": "single", "find_mode": "any", "public": true, "traversal": true,
		"buffer": 4, "public_address": ""},
	"gecko": {"custom": false, "enabled": []},
}


var _path := CONFIG_PATH


func _ready() -> void:
	_cfg.load(_path)  # missing file = defaults


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
	return get_value("paths", "data").path_join(sub)


## Everything needed to launch is in place.
func is_configured() -> bool:
	return FileAccess.file_exists(get_value("paths", "dolphin")) \
		and FileAccess.file_exists(get_value("paths", "game")) \
		and DirAccess.dir_exists_absolute(get_value("paths", "data"))


func missing_paths() -> PackedStringArray:
	var out := PackedStringArray()
	if not FileAccess.file_exists(get_value("paths", "dolphin")):
		out.append("DolphinNoGUI.exe")
	if not FileAccess.file_exists(get_value("paths", "game")):
		out.append("game file")
	if not DirAccess.dir_exists_absolute(get_value("paths", "data")):
		out.append("data folder")
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
	a.append_array(["--hud", "on" if get_value("options", "hud") else "off"])
	a.append_array(["--textures-dir", data_path("textures")])
	a.append_array(["--textures", "Graphics=" + get_value("options", "graphics")])
	a.append_array(["--textures", "Buttons=" + get_value("options", "buttons")])
	if get_value("options", "show_fps"):
		a.append_array(["-C", "Graphics.Settings.ShowFPS=True"])
	a.append_array(_extra_args())
	return a


func solo_args() -> PackedStringArray:
	var a := common_args()
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


func list_gecko_args() -> PackedStringArray:
	return PackedStringArray(["-u", data_path(get_value("paths", "profile")), "--list-gecko",
		GAME["id"]])


## Dolphin's `textures` event reports the selection in lowercase; store the proper names.
func remember_textures(selection: Dictionary) -> void:
	for pair in [["graphics", GRAPHICS], ["buttons", BUTTONS]]:
		var picked := String(selection.get(pair[0], ""))
		for option in pair[1]:
			if option.to_lower() == picked:
				set_value("options", pair[0], option)
