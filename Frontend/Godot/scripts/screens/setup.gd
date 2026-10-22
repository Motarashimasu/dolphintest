extends "res://scripts/screens/form_screen.gd"
## First-run setup, shown once (and again only if every game copy goes missing): one copy of each
## game (any version; more in Options > Game Copies), netplay name and region. Dolphin-Sparking
## and SparkingData are found automatically next to the launcher; rows to locate them by hand only
## appear if that failed.

const GameCopies := preload("res://scripts/screens/game_copies.gd")


func screen_music() -> String:
	return "main_menu"


func screen_title() -> String:
	return "Welcome"


func screen_desc() -> String:
	return tr("One-time setup: pick your game files,\nyour DRAGON NET name and your region.")


func _copies_text(key: String) -> String:
	var owned := Settings.owned_versions(key)
	if owned.is_empty():
		var any := ""
		for v in Settings.VERSIONS:
			if Settings.copy_path(key, v) != "":
				any = Settings.copy_path(key, v)
		return GameCopies.file_text(any)
	var v: String = owned[0]
	return "%s · %s" % [v, Settings.copy_path(key, v).get_file()]


func build_rows() -> Array:
	var rows: Array = []
	for key in Settings.GAME_ORDER:
		var g: Dictionary = Settings.GAMES[key]
		rows.append({"type": "action", "key": "game_" + key, "label": g["title"],
			"value": _copies_text(key),
			"desc": tr("Your %s disc image (any version).\nMore versions later: Options > Game Copies.") % g["full_title"]})
	rows.append_array([
		{"type": "text", "key": "nickname", "label": "DRAGON NET name",
			"value": Settings.get_value("player", "nickname"), "max_length": 24,
			"desc": "The name other players see in lobbies and on the score bar."},
		{"type": "choice", "key": "region", "label": "Region", "values": Settings.REGIONS,
			"names": Settings.REGION_NAMES, "value": Settings.get_value("player", "region"),
			"desc": "Your region: public lobbies show it, and matchmaking\nprefers lobbies in the same region."},
	])
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
	if key.begins_with("game_"):
		var game_key := key.trim_prefix("game_")
		var owned := Settings.owned_versions(game_key)
		var current := Settings.copy_path(game_key, owned[0]) if not owned.is_empty() else ""
		pick_path(false, GameCopies.GAME_FILTERS, current,
				tr("Select your %s game file") % Settings.GAMES[game_key]["title"],
				func(path: String): GameCopies.store(self, path, game_key, "", func(): list.set_rows(build_rows(), key)))
		return
	match key:
		"dolphin":
			if OS.get_name() == "Windows":
				pick_path(false, ["*.exe ; Programs", "* ; All files"], "", "Select DolphinNoGUI.exe",
						_set_path.bind("dolphin"))
			else:   # Linux: dolphin-emu-nogui, no extension
				pick_path(false, ["* ; All files"], "", "Select dolphin-emu-nogui", _set_path.bind("dolphin"))
		"data":
			pick_path(true, [], "", "Select the SparkingData folder", _set_path.bind("data"))
		"done":
			_finish()


func _set_path(path: String, key: String) -> void:
	Settings.set_value("paths", key, path.replace("\\", "/"))
	if key == "data":
		Music.rescan()   # your music lives in the data folder
	list.set_rows(build_rows(), key)


## What still stops the launcher: Dolphin, SparkingData, or no game copy at all.
func _missing() -> PackedStringArray:
	var out := PackedStringArray()
	for m in Settings.missing_paths():
		if m != "game file":
			out.append(m)
	if Settings.GAME_ORDER.all(func(k): return Settings.owned_versions(k).is_empty()):
		out.append(tr("a game file"))
	return out


func _finish() -> void:
	var missing := _missing()
	if not missing.is_empty():
		app.toast(tr("Still missing: %s") % ", ".join(missing))
		list.focus_key("game_bt3" if tr("a game file") in missing else list.rows[list.rows.size() - 2]["key"])
		return
	Settings.set_value("paths", "setup_done", true)
	app.pop()


func on_back() -> void:
	# Leaving early is fine; setup comes back next time until it's finished.
	if not _missing().is_empty():
		app.toast(tr("Setup isn't finished: %s") % ", ".join(_missing()))
	else:
		Settings.set_value("paths", "setup_done", true)
	app.pop()
