extends "res://scripts/screens/form_screen.gd"
## Files & folders: DolphinNoGUI.exe, the BT3 game file, the SparkingData folder, plus the
## player's name and region.

const GAME_FILTERS := ["*.iso, *.rvz, *.wbfs, *.gcz, *.ciso, *.wia ; Wii disc images", "* ; All files"]


func screen_title() -> String:
	return "Files & Folders"


func screen_desc() -> String:
	return "Where Dolphin-Sparking, your %s game file\nand the SparkingData folder are." % Settings.GAME["title"]


func _path_text(path: String, is_dir: bool) -> String:
	if path == "":
		return "Not set"
	var ok := DirAccess.dir_exists_absolute(path) if is_dir else FileAccess.file_exists(path)
	var shown := path if is_dir else path.get_file()
	return shown if ok else "(missing) " + shown


func build_rows() -> Array:
	var regions: Array = Settings.REGIONS
	return [
		{"type": "action", "key": "dolphin", "label": "Dolphin-Sparking",
			"value": _path_text(Settings.get_value("paths", "dolphin"), false),
			"desc": "DolphinNoGUI.exe from your Dolphin-Sparking build\n(build\\release\\x64\\Binaries)."},
		{"type": "action", "key": "game", "label": "Game file",
			"value": _path_text(Settings.get_value("paths", "game"), false),
			"desc": "Your %s disc image (%s)." % [Settings.GAME["full_title"], Settings.GAME["id"]]},
		{"type": "action", "key": "data", "label": "SparkingData folder",
			"value": _path_text(Settings.get_value("paths", "data"), true),
			"desc": "The folder with user, saves, states and textures\n(next to settings.bat)."},
		{"type": "text", "key": "nickname", "label": "Netplay name",
			"value": Settings.get_value("player", "nickname"), "max_length": 24,
			"desc": "The name other players see in lobbies and on the score bar."},
		{"type": "choice", "key": "region", "label": "Region", "values": regions,
			"names": Settings.REGION_NAMES, "value": Settings.get_value("player", "region"),
			"desc": "Your region: public lobbies show it, and matchmaking\nprefers lobbies in the same region."},
		{"type": "choice", "key": "profile", "label": "Dolphin profile",
			"values": ["user", "user2"], "value": Settings.get_value("paths", "profile"),
			"desc": "The Dolphin user folder inside SparkingData. Use user2 for a\nsecond copy on the same PC (local netplay tests)."},
		{"type": "text", "key": "extra_args", "label": "Extra Dolphin options",
			"value": Settings.get_value("paths", "extra_args"), "placeholder": "(none)",
			"desc": "Advanced: added to every Dolphin command line."},
		{"type": "action", "key": "back", "label": "Done", "desc": "Save and go back."},
	]


func on_value(key: String, value: Variant) -> void:
	match key:
		"nickname":
			var name := String(value).strip_edges()
			if name == "":
				name = "Player"
			Settings.set_value("player", "nickname", name)
		"region":
			Settings.set_value("player", "region", value)
		"profile", "extra_args":
			Settings.set_value("paths", key, value)


func on_press(key: String) -> void:
	match key:
		"dolphin":
			pick_path(false, ["*.exe ; Programs", "* ; All files"], Settings.get_value("paths", "dolphin"),
					"Select DolphinNoGUI.exe", _set_path.bind("dolphin"))
		"game":
			pick_path(false, GAME_FILTERS, Settings.get_value("paths", "game"),
					"Select your %s game file" % Settings.GAME["title"], _set_path.bind("game"))
		"data":
			pick_path(true, [], Settings.get_value("paths", "data"), "Select the SparkingData folder",
					_set_path.bind("data"))
		"back":
			on_back()


func _set_path(path: String, key: String) -> void:
	Settings.set_value("paths", key, path.replace("\\", "/"))
	list.set_rows(build_rows(), key)


func on_back() -> void:
	var missing := Settings.missing_paths()
	if not missing.is_empty():
		app.toast("Still missing: " + ", ".join(missing))
	app.pop()
