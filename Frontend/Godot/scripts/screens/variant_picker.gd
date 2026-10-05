extends "res://scripts/screens/form_screen.gd"
## Modifications > Graphics / Button Prompts: pick one texture variant. Saved for the next game
## and, if a game is running, switched live.

var group := "graphics"   # graphics | buttons


func setup(p_group: String) -> Node:
	group = p_group
	return self


func screen_music() -> String:
	return "game_menu"


func screen_title() -> String:
	return "Graphics" if group == "graphics" else "Button Prompts"


func screen_desc() -> String:
	if group == "graphics":
		return "HD or original textures. Your button prompts aren't affected.\nF3 switches it during a game."
	return "Which buttons the game shows. Graphics aren't affected.\nF4 switches it during a game."


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
		rows.append({"type": "action", "key": o[0], "label": o[1],
			"value": "✓  Selected" if o[0] == current else "", "desc": o[2]})
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
	app.toast("%s: %s" % [screen_title(), Settings.option_name(group, key)], 1.5)
