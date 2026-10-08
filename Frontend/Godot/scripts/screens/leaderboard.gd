extends "res://scripts/screens/form_screen.gd"
## Ranked Match > Leaderboard: Single Battle FT2 or Team Battle by rating, or the all-time record
## (wins across every mode); Global or one region (where the ranked lobby was hosted).

var _rows: Array = []
var _loading := false
var _error := ""


func screen_music() -> String:
	return "netplay"


func screen_title() -> String:
	return "Leaderboard"


func screen_desc() -> String:
	return "Ranked standings. Global counts every region; a region counts\nranked lobbies hosted there."


func on_enter() -> void:
	super()
	_load()


func _load() -> void:
	_loading = true
	_error = ""
	list.set_rows(build_rows(), list.current_key())
	var res := await Ranked.api("leaderboard.php", {"mode": Settings.get_value("ranked", "board_mode"),
		"region": Settings.get_value("ranked", "board_region"), "limit": 50})
	if not is_inside_tree():
		return
	_loading = false
	_rows = res.get("rows", []) if res.get("ok", false) else []
	_error = "" if res.get("ok", false) else Ranked.error_text(String(res.get("error", "")))
	list.set_rows(build_rows(), list.current_key())


func build_rows() -> Array:
	var mode := String(Settings.get_value("ranked", "board_mode"))
	var regions: Array = ["global"]
	regions.append_array(Settings.REGIONS)
	var region_names: Array = ["Global"]
	region_names.append_array(Settings.REGION_NAMES)
	var rows: Array = [
		{"type": "choice", "key": "board_mode", "label": "Board", "values": ["single", "team", "all"],
			"names": ["Single Battle FT2", "Team Battle", "All-time record"], "value": mode,
			"desc": "Single Battle FT2 / Team Battle: by rating.\nAll-time record: wins and losses across every mode."},
		{"type": "choice", "key": "board_region", "label": "Region", "values": regions, "names": region_names,
			"value": Settings.get_value("ranked", "board_region"),
			"desc": "Global: every region. A region: ranked lobbies hosted there."},
	]
	if _loading:
		rows.append({"type": "info", "key": "status", "label": "Loading the leaderboard...", "value": ""})
	elif _error != "":
		rows.append({"type": "info", "key": "status", "label": _error, "value": ""})
	elif _rows.is_empty():
		rows.append({"type": "info", "key": "status", "label": "No ranked matches here yet", "value": ""})
	var me := Ranked.display_name()
	for r in _rows:
		var record := "%d-%d" % [int(r.get("wins", 0)), int(r.get("losses", 0))]
		var value := record if mode == "all" else "%d   ·   %s" % [int(r.get("rating", 1000)), record]
		var label := "#%d   %s" % [int(r.get("rank", 0)), String(r.get("name", "?"))]
		if me != "" and String(r.get("name", "")) == me:
			label += "   " + tr("(you)")
		rows.append({"type": "info", "key": "row:%d" % int(r.get("rank", 0)), "label": label, "value": value})
	rows.append_array([
		{"type": "action", "key": "web", "label": "Open in browser",
			"desc": "The full leaderboard on the ranked website."},
		{"type": "action", "key": "back", "label": "Back", "desc": "Back to Ranked Match."},
	])
	return rows


func on_value(key: String, value: Variant) -> void:
	Settings.set_value("ranked", key, value)
	_load()


func on_press(key: String) -> void:
	if key == "web":
		Ranked.open_url.call("%sindex.php?mode=%s&region=%s" % [Ranked.server(),
			Settings.get_value("ranked", "board_mode"), Settings.get_value("ranked", "board_region")])
	else:
		super(key)
