extends "res://scripts/screens/form_screen.gd"
## First-run setup, shown once (and again only if the game file goes missing): your game file,
## netplay name and region. Dolphin-Sparking and SparkingData are found automatically next to
## the launcher; rows to locate them by hand only appear if that failed.

const GAME_FILTERS := ["*.iso, *.rvz, *.wbfs, *.gcz, *.ciso, *.wia ; Wii disc images", "* ; All files"]


func screen_music() -> String:
	return "main_menu"


func screen_title() -> String:
	return "Welcome"


func screen_desc() -> String:
	return tr("One-time setup: pick your %s game file,\nyour DRAGON NET name and your region.") % Settings.GAME["title"]


func _file_text(path: String) -> String:
	if path == "":
		return "Not set"
	return path.get_file() if FileAccess.file_exists(path) else tr("(missing) %s") % path.get_file()


func build_rows() -> Array:
	var rows: Array = [
		{"type": "action", "key": "game", "label": "Game file",
			"value": _file_text(Settings.get_value("paths", "game")),
			"desc": tr("Your %s disc image (%s).") % [Settings.GAME["full_title"], Settings.GAME["id"]]},
		{"type": "text", "key": "nickname", "label": "DRAGON NET name",
			"value": Settings.get_value("player", "nickname"), "max_length": 24,
			"desc": "The name other players see in lobbies and on the score bar."},
		{"type": "choice", "key": "region", "label": "Region", "values": Settings.REGIONS,
			"names": Settings.REGION_NAMES, "value": Settings.get_value("player", "region"),
			"desc": "Your region: public lobbies show it, and matchmaking\nprefers lobbies in the same region."},
	]
	# Normally found next to the launcher; only ask when they weren't.
	var missing := Settings.missing_paths()
	if "Dolphin-Sparking" in missing:
		rows.append({"type": "action", "key": "dolphin", "label": "Locate Dolphin-Sparking", "value": "Not found",
			"desc": "DolphinNoGUI.exe wasn't found next to the launcher.\nIt belongs in the Dolphin folder beside it."})
	if "SparkingData folder" in missing:
		rows.append({"type": "action", "key": "data", "label": "Locate SparkingData", "value": "Not found",
			"desc": "The SparkingData folder wasn't found next to the launcher."})
	rows.append({"type": "action", "key": "done", "label": "Done", "color": "#3fbf6b",
		"desc": "Save and go to the menu. You won't see this again."})
	return rows


func on_value(key: String, value: Variant) -> void:
	match key:
		"nickname":
			var name := String(value).strip_edges()
			Settings.set_value("player", "nickname", name if name != "" else "Player")
		"region":
			Settings.set_value("player", "region", value)


func on_press(key: String) -> void:
	match key:
		"game":
			pick_path(false, GAME_FILTERS, Settings.get_value("paths", "game"),
					"Select your %s game file" % Settings.GAME["title"], _set_path.bind("game"))
		"dolphin":
			pick_path(false, ["*.exe ; Programs", "* ; All files"], "", "Select DolphinNoGUI.exe",
					_set_path.bind("dolphin"))
		"data":
			pick_path(true, [], "", "Select the SparkingData folder", _set_path.bind("data"))
		"done":
			_finish()


func _set_path(path: String, key: String) -> void:
	Settings.set_value("paths", key, path.replace("\\", "/"))
	if key == "data":
		Music.rescan()   # your music lives in the data folder
	list.set_rows(build_rows(), key)


func _finish() -> void:
	var missing := Settings.missing_paths()
	if not missing.is_empty():
		app.toast(tr("Still missing: %s") % ", ".join(missing))
		list.focus_key("game" if "game file" in missing else list.rows[list.rows.size() - 2]["key"])
		return
	Settings.set_value("paths", "setup_done", true)
	app.pop()


func on_back() -> void:
	# Leaving early is fine; setup comes back next time until it's finished.
	if not Settings.missing_paths().is_empty():
		app.toast(tr("Setup isn't finished: %s") % ", ".join(Settings.missing_paths()))
	else:
		Settings.set_value("paths", "setup_done", true)
	app.pop()
