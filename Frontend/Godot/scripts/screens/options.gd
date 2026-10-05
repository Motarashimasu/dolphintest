extends "res://scripts/screens/form_screen.gd"
## Texture variants, aspect ratio, HUD and other preferences.


func screen_title() -> String:
	return "Options"


func build_rows() -> Array:
	return [
		{"type": "choice", "key": "aspect", "label": "Aspect ratio", "values": ["16:9", "4:3"],
			"names": ["16:9 widescreen", "4:3"], "value": Settings.get_value("options", "aspect"),
			"desc": "The picture's shape when the game starts.\nF5 switches it during a game."},
		{"type": "number", "key": "music_volume", "label": "Music volume", "min": 0, "max": 10, "step": 1,
			"value": Settings.get_value("options", "music_volume"),
			"desc": "Menu music (0 = off). It fades out while you play\nand comes back when the game closes."},
		{"type": "toggle", "key": "hud", "label": "Match HUD", "value": Settings.get_value("options", "hud"),
			"desc": "Round score with player names, health % and\nconnection info on top of the game."},
		{"type": "toggle", "key": "show_fps", "label": "FPS counter", "value": Settings.get_value("options", "show_fps"),
			"desc": "Show frames per second in the top-left corner."},
		{"type": "toggle", "key": "minimize_while_playing", "label": "Hide menu while playing",
			"value": Settings.get_value("options", "minimize_while_playing"),
			"desc": "Minimise this window while a game runs.\nHold Select in game for the in-game menu."},
		{"type": "action", "key": "files", "label": "Files & Folders...",
			"desc": "Dolphin-Sparking, your game file, the SparkingData folder,\nyour netplay name and region."},
		{"type": "action", "key": "back", "label": "Back", "desc": "Back to the main menu."},
	]


func on_value(key: String, value: Variant) -> void:
	Settings.set_value("options", key, value)
	if key == "music_volume":
		Music.apply_volume()


func on_press(key: String) -> void:
	if key == "files":
		app.open("setup")
	else:
		super(key)
