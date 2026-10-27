extends "res://scripts/screens/form_screen.gd"
## Modifications > Graphics / Button Prompts: pick one texture variant. Saved for the next game
## and, if a game is running, switched live.

var group := "graphics"   # graphics | buttons



func _init() -> void:
	super()
	notices = false   # no notification bars here


func setup(p_group: String) -> Node:
	group = p_group
	return self


func screen_music() -> String:
	return "game_menu"


func screen_title() -> String:
	return "Graphics" if group == "graphics" else "Button Prompts"


func screen_desc() -> String:
	if group == "graphics":
		return "HD or original textures. Your button prompts aren't affected.\nF1 switches it during a game."
	return "Which buttons the game shows. Graphics aren't affected.\nF2 switches it during a game."


func _options() -> Array:
	if group == "graphics":
		return [
			["Enhanced", "Enhanced", "The HD texture pack: sharper characters, stages and menus."],
			["Legacy", "Legacy", "The game's original textures, as on the console."],
		]
	return [
		["Vanilla", "GameCube", "The original GameCube button prompts."],
		["PlayStation", "PlayStation", "PlayStation button prompts: Cross, Circle, Square, Triangle."],
		["Xbox", "Xbox", "Xbox button prompts: A, B, X, Y."],
	]


func build_rows() -> Array:
	var current: String = Settings.get_value("options", group)
	var rows: Array = []
	for o in _options():
		var desc: String = o[2]
		if o[0] == "Enhanced" and not _pack_here():
			desc = "The HD texture pack: sharper characters, stages and menus.\nNot downloaded yet: Options > Enhanced textures."
		rows.append({"type": "action", "key": o[0], "label": o[1],
			"value": "✓  Selected" if o[0] == current else "", "desc": desc})
	rows.append({"type": "action", "key": "back", "label": "Back", "desc": "Back to Modifications."})
	return rows


func on_press(key: String) -> void:
	if key == "back":
		on_back()
		return
	Settings.set_value("options", group, key)
	# Live switch when a game is running (ignored by Dolphin otherwise).
	if Dolphin.is_running():
		Dolphin.send("textures %s=%s" % ["Graphics" if group == "graphics" else "Buttons", key])
	list.set_rows(build_rows(), key)
	if group == "graphics" and key == "Enhanced" and not _pack_here():
		app.toast(tr("The Enhanced textures aren't downloaded yet: Options > Enhanced textures."), 4.0)
		return
	app.toast(tr(screen_title() + ": %s") % tr(Settings.option_name(group, key)), 1.5)


## The HD pack is in the folder (or the launcher can't tell yet: no list from the server).
func _pack_here() -> bool:
	var info := Updater.pack_info(Updater.TEXTURES_PACK)
	return not info["known"] or info["wanted"]
