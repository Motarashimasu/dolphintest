extends "res://scripts/screens/form_screen.gd"
## Netplay > Lobby Browser: public lobbies of this exact build (Dolphin filters by version and
## never reports it). Mode, host, region and the host's connection type; pick one to join.

var koth := false             # King of the Hill browser: only KOTH lobbies
var _lobbies: Array = []
var _loading := false
var _error := ""


func screen_music() -> String:
	return "netplay"


func with_koth(value: bool) -> Node:
	koth = value
	return self


func screen_title() -> String:
	return "King of the Hill Lobbies" if koth else "Lobby Browser"


func screen_desc() -> String:
	if koth:
		return "King of the Hill lobbies on your version. You can get in line\nany time there's room: if a set is on, you join when it ends."
	return "Public lobbies of players on your version.\nPing shows once you're in a lobby."


func list_rect() -> Rect2:
	return Rect2(70, 136, 1140, 352)


func on_enter() -> void:
	super()
	_refresh()


func on_resume() -> void:
	super()
	_refresh()


func _refresh() -> void:
	if _loading:
		return
	_loading = true
	_error = ""
	list.set_rows(build_rows())
	if not Dolphin.query(Settings.list_lobbies_args(koth), _on_lobbies):
		_loading = false
		_error = "Couldn't start Dolphin-Sparking"
		list.set_rows(build_rows())


func _on_lobbies(events: Array) -> void:
	_loading = false
	_lobbies = []
	for e in events:
		match e.get("event"):
			"lobbies":
				_lobbies = e.get("lobbies", [])
			"error":
				_error = tr("Lobby server unreachable (%s)") % e.get("reason", e.get("code", "error"))
	if is_inside_tree():
		list.set_rows(build_rows())


func _shown() -> Array:
	var filter: String = Settings.get_value("netplay", "find_mode")
	var out: Array = []
	for l in _lobbies:
		if filter == "any" or l.get("mode", "any") == filter or l.get("mode", "any") == "any":
			out.append(l)
	return out


func build_rows() -> Array:
	var rows: Array = [
		{"type": "choice", "key": "filter", "label": "Show", "values": ["any", "single", "team"],
			"names": ["All modes", "Single Battle", "Team Battle"],
			"value": Settings.get_value("netplay", "find_mode"),
			"desc": "Which lobbies to list."},
	]
	var shown := _shown()
	if _loading:
		rows.append({"type": "info", "key": "status", "label": "Looking for lobbies...", "value": ""})
	elif _error != "":
		rows.append({"type": "info", "key": "status", "label": _error, "value": ""})
	elif shown.is_empty():
		rows.append({"type": "info", "key": "status", "label": "No open lobbies right now", "value": "Try Find or Host"})
	for i in shown.size():
		var l: Dictionary = shown[i]
		var right_game: bool = String(l.get("game_id", "")).begins_with(Settings.GAME["id"])
		var full: bool = not l.get("joinable", true)
		var state := ""
		# King of the Hill: a set being played only means waiting for it to end.
		var blocked_by_match: bool = l.get("in_game", false) and not koth
		if koth:
			var people := int(l.get("players", 0)) + int(l.get("spectators", 0))
			if full:
				state = tr("Full")
			elif not right_game:
				state = tr("Other game")
			else:
				state = (tr("Set on · %d/8 in line") if l.get("in_game", false) else tr("%d/8 in line")) % people
		elif l.get("in_game", false):
			state = tr("In match")
		elif full:
			state = tr("Full")
		elif not right_game:
			state = tr("Other game")
		rows.append({"type": "action", "key": "lobby:%d" % _lobbies.find(l),
			"label": String(l.get("host", "?")),
			"value": "%s   ·   %s   ·   %s" % [Style.mode_name(l.get("mode", "any")),
				l.get("region", "?"), state if state != "" else tr("%d/2 players") % int(l.get("players", 1))],
			"icon": String(l.get("link", "")),
			"disabled": full or not right_game or blocked_by_match,
			"desc": tr("Host: %s   Mode: %s   Region: %s\nConnection: %s   Players: %d   %s") % [l.get("host", "?"),
				Style.mode_name(l.get("mode", "any")), l.get("region", "?"), Style.link_name(l.get("link", "")),
				int(l.get("players", 1)), tr("Press %s to join.") % Pad.prompt("accept")["key"] if state == "" or (koth and not full and right_game) else state + "."]})
		# Watching: up to 2 spectators, before the match starts (Dolphin can't let anyone in mid-match).
		var watchers := int(l.get("spectators", 0))
		var can_watch: bool = l.get("watchable", watchers < 2) and right_game and not blocked_by_match
		rows.append({"type": "action", "key": "watch:%d" % _lobbies.find(l),
			"label": tr("   Watch %s") % String(l.get("host", "?")),
			"value": "" if koth else tr("%d/2 watching") % watchers,
			"disabled": not can_watch,
			"desc": tr("Watch this lobby's matches without playing (2 spectators at most).\nSpectators never get a controller; they can chat and leave any time.")})
	rows.append_array([
		{"type": "action", "key": "refresh", "label": "Refresh", "desc": "Check the list again."},
		{"type": "text", "key": "direct", "label": "Join by code or IP", "value": "",
			"placeholder": "room code or 1.2.3.4:2626",
			"desc": "Join a private lobby: type the room code (or IP:port) the host gave you."},
		{"type": "text", "key": "watch_direct", "label": "Watch by code or IP", "value": "",
			"placeholder": "room code or 1.2.3.4:2626",
			"desc": "Watch a private lobby as a spectator: type its room code (or IP:port)."},
		{"type": "action", "key": "back", "label": "Back",
			"desc": "Back to the King of the Hill menu." if koth else "Back to the DRAGON NET menu."},
	])
	return rows


func on_value(key: String, value: Variant) -> void:
	if key == "filter":
		Settings.set_value("netplay", "find_mode", value)
		list.set_rows(build_rows(), "filter")
	elif key == "direct" and String(value) != "":
		list.update_row("direct", {"value": ""})
		_join(String(value).strip_edges(), "any")
	elif key == "watch_direct" and String(value) != "":
		list.update_row("watch_direct", {"value": ""})
		_join(String(value).strip_edges(), "any", true)


func on_press(key: String) -> void:
	if key == "refresh":
		_refresh()
	elif key.begins_with("lobby:"):
		var l: Dictionary = _lobbies[int(key.substr(6))]
		_join(String(l.get("join", "")), String(l.get("mode", "any")))
	elif key.begins_with("watch:"):
		var l: Dictionary = _lobbies[int(key.substr(6))]
		_join(String(l.get("join", "")), String(l.get("mode", "any")), true)
	else:
		super(key)


func _join(target: String, mode: String, watch := false) -> void:
	if target == "":
		return
	var lobby: Control = load("res://scripts/screens/lobby.gd").new()
	lobby.koth = koth
	if watch:
		app.push(lobby.setup("watch", Settings.watch_args(target, koth), mode))
	else:
		app.push(lobby.setup("join", Settings.join_args(target, koth), mode))
