extends "res://scripts/screens/form_screen.gd"
## Ranked > Replay Search: everyone's shared replays of this game (Server/ranked/replays.php),
## newest first. Search by part of a player's name and the mode; pick one to watch it (it's
## downloaded first, once) or just download it. Downloads: <SparkingData>/replays/online.

const ReplayShare := preload("res://scripts/replay_share.gd")
const Replays := preload("res://scripts/screens/replays.gd")

var _q := ""
var _mode := ""            # "" = any, single, team
var _results: Array = []   # search results (the server's entries)
var _page := 0
var _more := false
var _searched := false
var _status := ""
var _busy := false


func _init() -> void:
	super()
	notices = false


func screen_title() -> String:
	return "Replay Search"


func screen_music() -> String:
	return "netplay"


func screen_desc() -> String:
	return "Everyone's shared ranked replays, newest first.\nPick one to watch it."


func on_enter() -> void:
	super()
	_search(0)


func build_rows() -> Array:
	var rows: Array = []
	if _status != "":
		rows.append({"type": "info", "key": "status", "label": _status, "value": ""})
	rows.append({"type": "text", "key": "q", "label": "Player name", "value": _q, "max_length": 24,
		"placeholder": tr("Anyone"), "desc": "Part of a player's name (either side of the match)."})
	rows.append({"type": "choice", "key": "mode", "label": "Mode", "values": ["", "single", "team"],
		"names": [tr("Any"), Ranked.mode_title("single"), Ranked.mode_title("team")], "value": _mode,
		"desc": "Only this mode's matches."})
	for i in _results.size():
		var r: Dictionary = _results[i]
		var seconds := int(r.get("seconds", 0))
		var here := not ReplayShare.downloaded(int(r["id"])).is_empty()
		rows.append({"type": "action", "key": "r:%d" % i, "label": Replays.title_of(r),
			"value": String(r.get("date", "")).left(10), "color": "#3fbf6b" if here else "",
			"desc": tr("%s, %s. Winner: %s. Shared by %s, watched %d times (%s MB).\nDownloaded: press to watch it."
				if here else "%s, %s. Winner: %s. Shared by %s, watched %d times (%s MB).\nPress to download and watch it.") % [
				Ranked.mode_title(String(r.get("mode", ""))) if String(r.get("mode", "")) in ["single", "team"] else tr("Ranked match"),
				"%d:%02d" % [seconds / 60, seconds % 60], String(r.get("winner", "?")),
				String(r.get("uploader", "?")), int(r.get("downloads", 0)), "%.1f" % (float(r.get("size", 0)) / 1048576.0)]})
	if _searched and _results.is_empty():
		rows.append({"type": "info", "key": "none", "label": "No replays found", "value": ""})
	if _more:
		rows.append({"type": "action", "key": "more", "label": "More results", "desc": "The next, older replays."})
	rows.append({"type": "action", "key": "back", "label": "Back", "desc": "Back to the replays."})
	return rows


func on_value(key: String, value: Variant) -> void:
	match key:
		"q":
			_q = String(value).strip_edges()
			_search(0)
		"mode":
			_mode = String(value)
			_search(0)


func on_press(key: String) -> void:
	if key.begins_with("r:"):
		_result_menu(_results[int(key.substr(2))])
	elif key == "more":
		_search(_page + 1)
	else:
		super(key)


func _search(page: int) -> void:
	if _busy:
		return
	_busy = true
	_set_status("Searching...")
	var res: Dictionary = await ReplayShare.search(_q, _mode, page)
	_busy = false
	if not is_inside_tree():
		return
	_searched = true
	if not res.get("ok", false):
		_set_status(Ranked.error_text(String(res.get("error", ""))))
		return
	_results = (_results if page > 0 else []) + Array(res.get("replays", []))
	_page = page
	_more = res.get("more", false)
	_set_status("")


func _result_menu(entry: Dictionary) -> void:
	var id := int(entry["id"])
	var here := not ReplayShare.downloaded(id).is_empty()
	var items: Array = [
		{"label": "Watch", "glyph": "W", "color": "#3fbf6b",
			"desc": "Watch it (downloaded first)." if not here else "Watch it.",
			"action": func():
				app.pop()
				_fetch_replay(id, true)},
	]
	if not here:
		items.append({"label": "Download", "glyph": "D", "color": "#3fa9f5",
			"desc": "Keep it on this PC to watch later.",
			"action": func():
				app.pop()
				_fetch_replay(id, false)})
	items.append({"label": "Back", "glyph": "B", "color": "#8a9bb0", "back": true, "desc": "Back to the results."})
	var m: Control = app.menu(Replays.title_of(entry), items, "netplay")
	m.notices = false
	app.push(m)


func _fetch_replay(id: int, then_watch: bool) -> void:
	if _busy:
		return
	_busy = true
	_set_status(tr("Downloading... %s") % "0%")
	var res: Dictionary = await ReplayShare.download(id, func(p: float): _set_status(tr("Downloading... %s") % ("%d%%" % int(p * 100))))
	_busy = false
	if not is_inside_tree():
		return
	if not res.get("ok", false):
		_set_status(tr("Couldn't download it: %s") % Ranked.error_text(String(res.get("error", ""))))
		return
	_set_status("Downloaded.")
	if then_watch:
		Replays.watch(app, res["info"])


## `text`: already translated, or an English text to translate.
func _set_status(text: String) -> void:
	_status = tr(text) if text != "" else ""
	if is_inside_tree() and list:
		list.set_rows(build_rows())
