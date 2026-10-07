extends "res://scripts/screens/form_screen.gd"
## Player Match > Host: lobby options, then the lobby.


func screen_music() -> String:
	return "netplay"


func screen_title() -> String:
	return "Host a Lobby"


func screen_desc() -> String:
	return "Set up your lobby, then Start."


func build_rows() -> Array:
	return [
		{"type": "choice", "key": "traversal", "label": "Connection", "values": [true, false],
			"names": ["Room code", "Direct IP"], "value": Settings.get_value("netplay", "traversal"),
			"desc": "Room code: players join with a code, no router setup needed.\nDirect IP: they join your IP address (port 2626 must be open)."},
		{"type": "choice", "key": "mode", "label": "Mode", "values": ["single", "team"],
			"names": ["Single Battle", "Team Battle"], "value": Settings.get_value("netplay", "mode"),
			"desc": "Everyone boots straight into this mode when the match starts.\nShown in the Lobby Browser."},
		{"type": "text", "key": "nickname", "label": "DRAGON NET name", "max_length": 24,
			"value": Settings.get_value("player", "nickname"),
			"desc": "The name other players see."},
		{"type": "toggle", "key": "public", "label": "Appear in Lobby Browser",
			"value": Settings.get_value("netplay", "public"), "on_text": "Public", "off_text": "Private",
			"desc": "Public: listed in the Lobby Browser and used by matchmaking.\nPrivate: only people you give the code (or IP) to can join."},
		{"type": "text", "key": "public_address", "label": "Your public IP", "max_length": 64,
			"value": Settings.get_value("netplay", "public_address"), "placeholder": "needed for a public IP lobby",
			"disabled": Settings.get_value("netplay", "traversal") or not Settings.get_value("netplay", "public"),
			"desc": "Only for a public Direct IP lobby: the address players connect to\n(your internet IP, e.g. from whatismyip.com). Room code lobbies don't need it."},
		{"type": "choice", "key": "region", "label": "Region", "values": Settings.REGIONS,
			"names": Settings.REGION_NAMES, "value": Settings.get_value("player", "region"),
			"desc": "Shown with public lobbies; matchmaking prefers the same region."},
		{"type": "choice", "key": "buffer_auto", "label": "Pad buffer mode", "values": [false, true],
			"names": ["Manual", "Automatic"], "value": Settings.get_value("netplay", "buffer_auto"),
			"desc": "Automatic: picked from the ping when the match starts, and again right\nafter each KO (never during a fight). Manual: the number below."},
		{"type": "number", "key": "buffer", "label": "Pad buffer", "min": 1, "max": 20, "step": 1,
			"value": Settings.get_value("netplay", "buffer"), "disabled": Settings.get_value("netplay", "buffer_auto"),
			"desc": "Input delay in frames. Higher hides more lag but feels slower.\nRule of thumb: ping / 8 (can be changed in the lobby)."},
		{"type": "action", "key": "start", "label": "Start Lobby", "color": "#3fbf6b",
			"desc": "Open the lobby and wait for players."},
		{"type": "action", "key": "back", "label": "Back", "desc": "Back to Player Match."},
	]


func on_value(key: String, value: Variant) -> void:
	match key:
		"nickname":
			Settings.set_value("player", "nickname", value if String(value) != "" else "Player")
		"region":
			Settings.set_value("player", "region", value)
		_:
			Settings.set_value("netplay", key, value)
			if key == "buffer_auto":
				list.update_row("buffer", {"disabled": value})
			if key == "traversal" or key == "public":
				list.update_row("public_address", {"disabled": Settings.get_value("netplay", "traversal")
						or not Settings.get_value("netplay", "public")})


func on_press(key: String) -> void:
	if key == "start":
		if Settings.get_value("netplay", "public") and not Settings.get_value("netplay", "traversal") \
				and String(Settings.get_value("netplay", "public_address")) == "":
			app.toast("A public Direct IP lobby needs your public IP.")
			list.focus_key("public_address")
			return
		var args := Settings.host_args(Settings.get_value("netplay", "mode"),
				Settings.get_value("netplay", "public"), Settings.get_value("netplay", "traversal"))
		var lobby: Control = load("res://scripts/screens/lobby.gd").new()
		app.push(lobby.setup("host", args, Settings.get_value("netplay", "mode")))
	else:
		super(key)
