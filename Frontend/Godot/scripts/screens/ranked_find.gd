extends "res://scripts/screens/form_screen.gd"
## Ranked Match > Find: joins the open ranked lobby of your mode that suits you best (your
## region first, then the closest rating), or opens one for you that others will find.

var _searching := false
var _status := ""


func screen_music() -> String:
	return "netplay"


func screen_title() -> String:
	return "Find a Ranked Match"


func screen_desc() -> String:
	return "Single Battle FT2: first to 2 wins. Team Battle: one match.\nLeaving a match counts as a loss."


func build_rows() -> Array:
	var rows: Array = [
		{"type": "choice", "key": "mode", "label": "Mode", "values": ["single", "team"],
			"names": ["Single Battle FT2", "Team Battle"], "value": _mode(),
			"desc": "Single Battle FT2: first to 2 wins. Team Battle: one match."},
		{"type": "choice", "key": "region", "label": "Region", "values": Settings.REGIONS,
			"names": Settings.REGION_NAMES, "value": Settings.get_value("player", "region"),
			"desc": "Lobbies in your region are tried first; a lobby you open is listed there."},
	]
	if _status != "":
		rows.append({"type": "info", "key": "status", "label": _status, "value": ""})
	rows.append({"type": "action", "key": "search", "label": "Search", "color": "#3fbf6b",
		"disabled": _searching,
		"desc": "Join the best open ranked lobby, or open one for you if there's none."})
	rows.append({"type": "action", "key": "back", "label": "Back", "desc": "Back to Ranked Match."})
	return rows


func _mode() -> String:
	var m := String(Settings.get_value("netplay", "mode"))
	return m if m in ["single", "team"] else "single"


func on_value(key: String, value: Variant) -> void:
	if key == "region":
		Settings.set_value("player", "region", value)
	elif key == "mode":
		Settings.set_value("netplay", "mode", value)


func on_press(key: String) -> void:
	if key != "search":
		super(key)
		return
	_searching = true
	_status = tr("Looking for a ranked lobby...")
	list.set_rows(build_rows(), "search")
	var mode := _mode()
	var res := await Ranked.api("lobby.php", {"action": "list", "mode": mode})
	if not is_inside_tree():
		return
	_searching = false
	if not res.get("ok", false):
		_status = Ranked.error_text(String(res.get("error", "")))
		list.set_rows(build_rows(), "search")
		return
	var region := String(Settings.get_value("player", "region"))
	var mine := Ranked.rating(mode)
	var open: Array = (res.get("lobbies", []) as Array).filter(func(l):
		return not l.get("full", false) and not l.get("yours", false))
	open.sort_custom(func(a, b):
		var ra := (0 if a.get("region") == region else 100000) + absi(int(a["host"]["rating"]) - mine)
		var rb := (0 if b.get("region") == region else 100000) + absi(int(b["host"]["rating"]) - mine)
		return ra < rb)
	for l in open:
		var j := await Ranked.api("lobby.php", {"action": "join", "lobby": int(l["id"])})
		if not is_inside_tree():
			return
		if j.get("ok", false):
			_status = ""
			var lobby: Control = load("res://scripts/screens/lobby.gd").new()
			lobby.ranked = true
			lobby.ranked_lobby = int(l["id"])
			app.push(lobby.setup("join", Settings.ranked_join_args(String(j["lobby"]["join"])), mode))
			return
	# Nobody to join: open one in this mode; it shows in everyone's Ranked Lobby Browser.
	_status = ""
	app.toast("No open ranked lobby: opened one for you.")
	var host: Control = load("res://scripts/screens/lobby.gd").new()
	host.ranked = true
	app.push(host.setup("host", Settings.ranked_host_args(mode, Settings.get_value("netplay", "traversal")), mode))
