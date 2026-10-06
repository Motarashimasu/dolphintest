extends "res://scripts/screens/form_screen.gd"
## Aspect ratio, music, in-game HUD and other preferences.


func screen_title() -> String:
	return "Options"


func build_rows() -> Array:
	return [
		{"type": "choice", "key": "aspect", "label": "Aspect ratio", "values": ["16:9", "4:3"],
			"value": Settings.get_value("options", "aspect"),
			"desc": "The picture's shape when the game starts.\nF5 switches it during a game."},
		{"type": "number", "key": "music_volume", "label": "Music volume", "min": 0, "max": 10, "step": 1,
			"value": Settings.get_value("options", "music_volume"),
			"desc": "Menu music (0 = off). It fades out while you play\nand comes back when the game closes."},
		{"type": "toggle", "key": "hud_health", "label": "Health %", "value": Settings.get_value("options", "hud_health"),
			"desc": "Both fighters' health as a percentage, in the top corners."},
		{"type": "toggle", "key": "hud", "label": "Match HUD offline", "value": Settings.get_value("options", "hud"),
			"desc": "Round score with player names on top of the game in offline play.\nNetplay matches always show it, with the connection info."},
		{"type": "toggle", "key": "show_fps", "label": "FPS counter", "value": Settings.get_value("options", "show_fps"),
			"desc": "Show frames per second in the top-left corner."},
		{"type": "toggle", "key": "minimize_while_playing", "label": "Hide menu while playing",
			"value": Settings.get_value("options", "minimize_while_playing"),
			"desc": "Minimise this window while a game runs.\nHold Select in game for the in-game menu."},
		{"type": "toggle", "key": "discord", "label": "Discord status", "value": Settings.get_value("options", "discord"),
			"desc": "Show what you're doing on your Discord profile (menus, lobby, match).\nFriends can join a public lobby you host from there."},
		{"type": "choice", "key": "profile", "label": "Profile", "values": ["user", "user2"],
			"names": ["user (primary)", "user2 (secondary)"], "value": Settings.get_value("paths", "profile"),
			"desc": "Primary and secondary user profiles for online play.\nOnly change to user2 for LAN testing."},
		{"type": "action", "key": "back", "label": "Back", "desc": "Back to the main menu."},
	]


func on_value(key: String, value: Variant) -> void:
	if key == "profile":
		Settings.set_value("paths", "profile", value)
		return
	Settings.set_value("options", key, value)
	if key == "music_volume":
		Music.apply_volume()
