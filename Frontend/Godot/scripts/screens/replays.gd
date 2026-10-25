extends "res://scripts/screens/form_screen.gd"
## Ranked > Replays: the ranked matches this PC played, newest first. Each one is recorded by
## Dolphin from the start of the first round to the end of the match (<SparkingData>/replays:
## .dtm inputs + .dtm.sav start state + .json info). Every ranked replay is shared on DRAGON NET
## (Replay Search) after the match, by rule; one that couldn't be sent then is sent later
## (ReplayShare.upload_pending) or by hand here. Pick one to watch it, share it or delete it.
## Player Match and Battle Lounge games are recorded too when "Record matches" is on in their
## lobby: those stay on this PC (<SparkingData>/replays/local), never shared or uploaded.

const ReplayShare := preload("res://scripts/replay_share.gd")

const KEEP := 50   # the oldest replays beyond this are deleted (each is a few MB)

var _replays: Array = []   # the .json infos (+ "path": the .dtm), newest first
var _local: Array = []     # the same for this PC's Player Match / Battle Lounge recordings
var _status := ""
var _busy := false


func _init() -> void:
	super()
	notices = false   # no notification bars here


func screen_title() -> String:
	return "Replays"


func screen_music() -> String:
	return "netplay"


func screen_desc() -> String:
	return "Your recorded matches, newest first. Pick one to watch it,\nshare it (ranked) or delete it."


static func folder() -> String:
	return Settings.data_path("replays")


## Player Match / Battle Lounge recordings: this PC only, never uploaded.
static func local_folder() -> String:
	return Settings.data_path("replays").path_join("local")


## The saved replays (infos with "path" = the .dtm), newest first. Keeps only the newest KEEP.
## `local`: the Player Match / Battle Lounge ones (marked "local": true) instead of ranked.
static func load_all(local := false) -> Array:
	var out: Array = []
	var where := local_folder() if local else folder()
	var dir := DirAccess.open(where)
	if dir == null:
		return out
	for f in dir.get_files():
		if not f.ends_with(".json"):
			continue
		var info = JSON.parse_string(FileAccess.get_file_as_string(where.path_join(f)))
		if typeof(info) != TYPE_DICTIONARY:
			continue
		var dtm := where.path_join(String(info.get("dtm", f.get_basename() + ".dtm")))
		if not FileAccess.file_exists(dtm) or not FileAccess.file_exists(dtm + ".sav"):
			continue
		info["path"] = dtm
		info["json_path"] = where.path_join(f)
		if local:
			info["local"] = true
		out.append(info)
	out.sort_custom(func(a, b): return String(a.get("date", "")) > String(b.get("date", "")))
	while out.size() > KEEP:
		var old: Dictionary = out.pop_back()
		for p in [old["path"], String(old["path"]) + ".sav", old["json_path"]]:
			DirAccess.remove_absolute(p)
	return out


static func title_of(info: Dictionary) -> String:
	var players: Array = info.get("players", ["?", "?"])
	if info.get("local", false) and String(info.get("winner", "")) == "":
		return TranslationServer.translate("%s  vs  %s") % [players[0], players[1]]   # (Player Match: no set score)
	var wins: Array = info.get("wins", [0, 0])
	return "%s  %d - %d  %s" % [players[0], int(wins[0]), int(wins[1]), players[1]]


func build_rows() -> Array:
	_replays = load_all()
	var rows: Array = []
	if _status != "":
		rows.append({"type": "info", "key": "status", "label": _status, "value": ""})
	rows.append({"type": "action", "key": "search", "label": "Replay Search",
		"desc": "Everyone's shared replays: search by player name,\ndownload one and watch it."})
	for i in _replays.size():
		var r: Dictionary = _replays[i]
		var mode := String(r.get("mode", ""))
		var seconds := int(r.get("seconds", int(r.get("frames", 0)) / 60))
		var shared := int(r.get("shared_id", 0)) > 0
		rows.append({"type": "action", "key": "replay:%d" % i, "label": title_of(r),
			"value": String(r.get("date", "")).left(16), "color": "#3fbf6b" if shared else "",
			"desc": tr("%s, %s. Winner: %s. Shared on DRAGON NET.\nPress to watch or delete it." if shared
				else "%s, %s. Winner: %s.\nPress to watch, share or delete it.") % [
				Ranked.mode_title(mode) if mode in ["single", "team"] else tr("Ranked match"),
				"%d:%02d" % [seconds / 60, seconds % 60], String(r.get("winner", "?"))]})
	_local = load_all(true)
	if not _local.is_empty():
		rows.append({"type": "info", "key": "local_head", "label": "On this PC only (Player Match, Battle Lounge)", "value": "",
			"desc": "Recorded with Record matches on in their lobby. Never uploaded."})
	for i in _local.size():
		var r: Dictionary = _local[i]
		var seconds := int(r.get("seconds", int(r.get("frames", 0)) / 60))
		var kind := tr("Battle Lounge") if String(r.get("kind", "")) == "battle_lounge" else tr("Player Match")
		rows.append({"type": "action", "key": "local:%d" % i, "label": title_of(r),
			"value": String(r.get("date", "")).left(16),
			"desc": tr("%s, %s. Kept on this PC only (never uploaded).\nPress to watch or delete it.") % [
				kind, "%d:%02d" % [seconds / 60, seconds % 60]]})
	if _replays.is_empty() and _local.is_empty():
		rows.append({"type": "info", "key": "none", "label": "No replays yet",
			"desc": "Every ranked match you finish is saved here automatically;\nPlayer Match and Battle Lounge too, with Record matches on in the lobby."})
	rows.append({"type": "action", "key": "folder", "label": "Open replays folder",
		"desc": "The replay files: .dtm (inputs), .dtm.sav (start of the match), .json (info)."})
	rows.append({"type": "action", "key": "back", "label": "Back", "desc": "Back to the menu."})
	return rows


func on_press(key: String) -> void:
	if key.begins_with("replay:"):
		_replay_menu(int(key.get_slice(":", 1)))
	elif key.begins_with("local:"):
		_local_menu(int(key.get_slice(":", 1)))
	elif key == "search":
		app.open("replay_search")
	elif key == "folder":
		DirAccess.make_dir_recursive_absolute(folder())
		OS.shell_open(folder())
	else:
		super(key)


func _replay_menu(i: int) -> void:
	var info: Dictionary = _replays[i]
	var shared := int(info.get("shared_id", 0)) > 0
	var items: Array = [
		{"label": "Watch", "glyph": "W", "color": "#3fbf6b", "desc": "Watch it from the first round to the last KO.",
			"action": func():
				app.pop()
				watch(app, info)},
		{"label": "Shared" if shared else "Share", "glyph": "S", "color": "#3fa9f5",
			"desc": "Already on DRAGON NET: anyone can find it in Replay Search." if shared
				else "Put it on DRAGON NET: anyone can find it in Replay Search.\nNeeds a DRAGON NET account.",
			"action": func():
				app.pop()
				if not shared:
					_share(info)},
		{"label": "Delete", "glyph": "D", "color": "#e8663d", "desc": "Delete it from this PC (not from DRAGON NET).",
			"action": func():
				app.pop()
				for p in [info["path"], String(info["path"]) + ".sav", info["json_path"]]:
					DirAccess.remove_absolute(p)
				list.set_rows(build_rows())},
		{"label": "Back", "glyph": "B", "color": "#8a9bb0", "back": true, "desc": "Back to the replays."},
	]
	var m: Control = app.menu(title_of(info), items, "netplay")
	m.notices = false
	app.push(m)


## A recording kept on this PC: watch or delete (never shared).
func _local_menu(i: int) -> void:
	var info: Dictionary = _local[i]
	var items: Array = [
		{"label": "Watch", "glyph": "W", "color": "#3fbf6b", "desc": "Watch it from the first round to the end.",
			"action": func():
				app.pop()
				watch(app, info)},
		{"label": "Delete", "glyph": "D", "color": "#e8663d", "desc": "Delete it from this PC.",
			"action": func():
				app.pop()
				for p in [info["path"], String(info["path"]) + ".sav", info["json_path"]]:
					DirAccess.remove_absolute(p)
				list.set_rows(build_rows())},
		{"label": "Back", "glyph": "B", "color": "#8a9bb0", "back": true, "desc": "Back to the replays."},
	]
	var m: Control = app.menu(title_of(info), items, "netplay")
	m.notices = false
	app.push(m)


## Watches a replay (an info with "path"): the Replay screen.
static func watch(p_app: Node, info: Dictionary) -> void:
	if not p_app.require_setup():
		return
	p_app.push(load("res://scripts/screens/replay_player.gd").new().setup(info))


func _share(info: Dictionary) -> void:
	if _busy:
		return
	if not Ranked.logged_in() or Ranked.needs_account:
		app.toast("Sharing replays needs a DRAGON NET account (Ranked Match > Profile).", 4.0)
		return
	_busy = true
	_set_status(tr("Sharing... %s") % "0%")
	var res: Dictionary = await ReplayShare.upload(info, func(p: float): _set_status(tr("Sharing... %s") % ("%d%%" % int(p * 100))))
	_busy = false
	if not is_inside_tree():
		return
	if res.get("ok", false):
		_set_status(tr("Shared: anyone can find it in Replay Search.") if not res.get("exists", false)
				else tr("Already shared: anyone can find it in Replay Search."))
	else:
		_set_status(tr("Couldn't share it: %s") % Ranked.error_text(String(res.get("error", ""))))


func _set_status(text: String) -> void:
	_status = text
	if is_inside_tree():
		list.set_rows(build_rows())
