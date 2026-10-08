extends "res://scripts/screens/form_screen.gd"
## Ranked Match > Lobby Browser: ranked lobbies from the ranked server (never the regular or
## Battle Lounge ones), with the host's rating. Pick one to take the seat and join.

var _lobbies: Array = []
var _loading := false
var _error := ""


func screen_music() -> String:
	return "netplay"


func screen_title() -> String:
	return "Ranked Lobbies"


func screen_desc() -> String:
	return "Ranked lobbies: 2 players, no spectators.\nSingle Battle is first to 2 wins (FT2); Team Battle is one match."


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
	var res := await Ranked.api("lobby.php", {"action": "list"})
	if not is_inside_tree():
		return
	_loading = false
	if res.get("ok", false):
		_lobbies = res.get("lobbies", [])
	else:
		_lobbies = []
		_error = Ranked.error_text(String(res.get("error", "")))
	list.set_rows(build_rows(), list.current_key())


func _shown() -> Array:
	var filter := String(Settings.get_value("ranked", "mode"))
	return _lobbies.filter(func(l): return filter == "any" or l.get("mode") == filter)


func build_rows() -> Array:
	var rows: Array = [
		{"type": "choice", "key": "filter", "label": "Show", "values": ["any", "single", "team"],
			"names": ["All modes", "Single Battle FT2", "Team Battle"],
			"value": Settings.get_value("ranked", "mode"), "desc": "Which ranked lobbies to list."},
	]
	var shown := _shown()
	if _loading:
		rows.append({"type": "info", "key": "status", "label": "Looking for ranked lobbies...", "value": ""})
	elif _error != "":
		rows.append({"type": "info", "key": "status", "label": _error, "value": ""})
	elif shown.is_empty():
		rows.append({"type": "info", "key": "status", "label": "No ranked lobbies right now", "value": "Try Find or Host"})
	for l in shown:
		var host: Dictionary = l.get("host", {})
		var state := ""
		if l.get("yours", false):
			state = tr("Your lobby")
		elif l.get("full", false):
			state = tr("Full")
		var value := "%s   ·   %s   ·   %d   ·   %s" % [Ranked.mode_title(String(l.get("mode", "single"))),
			l.get("region", "?"), int(host.get("rating", 1000)),
			state if state != "" else tr("%d/2 players") % int(l.get("players", 1))]
		rows.append({"type": "action", "key": "lobby:%d" % int(l["id"]), "label": String(host.get("name", "?")),
			"value": value, "icon": String(l.get("link", "")),
			"disabled": state != "",
			"desc": tr("Host: %s   Rating: %d   Record: %d-%d\nMode: %s   Region: %s   %s") % [host.get("name", "?"),
				int(host.get("rating", 1000)), int(host.get("wins", 0)), int(host.get("losses", 0)),
				Ranked.mode_title(String(l.get("mode", "single"))), l.get("region", "?"),
				tr("Press %s to join.") % Pad.prompt("accept")["key"] if state == "" else state + "."]})
	rows.append_array([
		{"type": "action", "key": "refresh", "label": "Refresh", "desc": "Check the list again."},
		{"type": "action", "key": "back", "label": "Back", "desc": "Back to Ranked Match."},
	])
	return rows


func on_value(key: String, value: Variant) -> void:
	if key == "filter":
		Settings.set_value("ranked", "mode", value)
		list.set_rows(build_rows(), "filter")


func on_press(key: String) -> void:
	if key == "refresh":
		_refresh()
	elif key.begins_with("lobby:"):
		join_lobby(int(key.substr(6)))
	else:
		super(key)


## Takes the seat on the server, then opens the lobby (joins the host's room in Dolphin).
func join_lobby(id: int) -> void:
	var res := await Ranked.api("lobby.php", {"action": "join", "lobby": id})
	if not is_inside_tree():
		return
	if not res.get("ok", false):
		app.toast(Ranked.error_text(String(res.get("error", ""))))
		_refresh()
		return
	var l: Dictionary = res["lobby"]
	var lobby: Control = load("res://scripts/screens/lobby.gd").new()
	lobby.ranked = true
	lobby.ranked_lobby = id
	app.push(lobby.setup("join", Settings.ranked_join_args(String(l["join"])), String(l["mode"])))
