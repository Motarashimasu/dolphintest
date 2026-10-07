extends "res://scripts/screens/form_screen.gd"
## Player Match > Find: pick a mode, then matchmaking puts you in the nearest open lobby (or
## hosts a public one others will find).


func screen_music() -> String:
	return "netplay"


var koth := false   # Battle Lounge: only KOTH lobbies (or host one)


func with_koth(value: bool) -> Node:
	koth = value
	return self


func screen_title() -> String:
	return "Find a Battle Lounge" if koth else "Find a Match"


func screen_desc() -> String:
	return "Pick what you want to play, then Search."


func build_rows() -> Array:
	return [
		{"type": "choice", "key": "find_mode", "label": "Mode", "values": ["single", "team", "any"],
			"names": ["Single Battle", "Team Battle", "Any"], "value": Settings.get_value("netplay", "find_mode"),
			"desc": "Single or Team Battle only joins lobbies of that mode.\nAny takes the first open lobby."},
		{"type": "choice", "key": "region", "label": "Region", "values": Settings.REGIONS,
			"names": Settings.REGION_NAMES, "value": Settings.get_value("player", "region"),
			"desc": "Lobbies in your region are tried first."},
		{"type": "text", "key": "nickname", "label": "DRAGON NET name", "max_length": 24,
			"value": Settings.get_value("player", "nickname"), "desc": "The name other players see."},
		{"type": "action", "key": "search", "label": "Search", "color": "#3fbf6b",
			"desc": ("Get in line in a Battle Lounge lobby with room. If there's none, one\nis opened for you and others can join it." if koth
				else "Look for an open lobby. If none is free, a public lobby\nof this mode is opened for you and others can join it.")},
		{"type": "action", "key": "back", "label": "Back",
			"desc": "Back to Battle Lounge." if koth else "Back to Player Match."},
	]


func on_value(key: String, value: Variant) -> void:
	match key:
		"nickname":
			Settings.set_value("player", "nickname", value if String(value) != "" else "Player")
		"region":
			Settings.set_value("player", "region", value)
		"find_mode":
			Settings.set_value("netplay", "find_mode", value)


func on_press(key: String) -> void:
	if key == "search":
		var mode: String = Settings.get_value("netplay", "find_mode")
		var lobby: Control = load("res://scripts/screens/lobby.gd").new()
		lobby.koth = koth
		app.push(lobby.setup("find", Settings.find_args(mode, koth), mode))
	else:
		super(key)
