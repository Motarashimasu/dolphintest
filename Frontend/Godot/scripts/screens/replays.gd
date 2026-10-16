extends "res://scripts/screens/form_screen.gd"
## Ranked > Replays: the ranked matches this PC played, newest first. Each one is recorded by
## Dolphin from the start of the first round to the end of the match (<SparkingData>/replays:
## .dtm inputs + .dtm.sav start state + .json info). Pick one to watch it like a demo.

const KEEP := 50   # the oldest replays beyond this are deleted (each is a few MB)

var _replays: Array = []   # the .json infos (+ "path": the .dtm), newest first


func _init() -> void:
	super()
	notices = false   # no notification bars here


func screen_title() -> String:
	return "Replays"


func screen_music() -> String:
	return "netplay"


func screen_desc() -> String:
	return "Your ranked matches, newest first. Pick one to watch it\nfrom the first round to the last KO."


static func folder() -> String:
	return Settings.data_path("replays")


## The saved replays (infos with "path" = the .dtm), newest first. Keeps only the newest KEEP.
static func load_all() -> Array:
	var out: Array = []
	var dir := DirAccess.open(folder())
	if dir == null:
		return out
	for f in dir.get_files():
		if not f.ends_with(".json"):
			continue
		var info = JSON.parse_string(FileAccess.get_file_as_string(folder().path_join(f)))
		if typeof(info) != TYPE_DICTIONARY:
			continue
		var dtm := folder().path_join(String(info.get("dtm", f.get_basename() + ".dtm")))
		if not FileAccess.file_exists(dtm) or not FileAccess.file_exists(dtm + ".sav"):
			continue
		info["path"] = dtm
		info["json_path"] = folder().path_join(f)
		out.append(info)
	out.sort_custom(func(a, b): return String(a.get("date", "")) > String(b.get("date", "")))
	while out.size() > KEEP:
		var old: Dictionary = out.pop_back()
		for p in [old["path"], String(old["path"]) + ".sav", old["json_path"]]:
			DirAccess.remove_absolute(p)
	return out


static func title_of(info: Dictionary) -> String:
	var players: Array = info.get("players", ["?", "?"])
	var wins: Array = info.get("wins", [0, 0])
	return "%s  %d - %d  %s" % [players[0], int(wins[0]), int(wins[1]), players[1]]


func build_rows() -> Array:
	_replays = load_all()
	var rows: Array = []
	for i in _replays.size():
		var r: Dictionary = _replays[i]
		var mode := String(r.get("mode", ""))
		var seconds := int(r.get("seconds", int(r.get("frames", 0)) / 60))
		rows.append({"type": "action", "key": "replay:%d" % i, "label": title_of(r),
			"value": String(r.get("date", "")).left(16),
			"desc": tr("%s, %s. Winner: %s.\nPress to watch it.") % [
				Ranked.mode_title(mode) if mode in ["single", "team"] else tr("Ranked match"),
				"%d:%02d" % [seconds / 60, seconds % 60], String(r.get("winner", "?"))]})
	if _replays.is_empty():
		rows.append({"type": "info", "key": "none", "label": "No replays yet",
			"desc": "Every ranked match you finish is saved here automatically."})
	rows.append({"type": "action", "key": "folder", "label": "Open replays folder",
		"desc": "The replay files: .dtm (inputs), .dtm.sav (start of the match), .json (info)."})
	rows.append({"type": "action", "key": "back", "label": "Back", "desc": "Back to the Ranked Match menu."})
	return rows


func on_press(key: String) -> void:
	if key.begins_with("replay:"):
		var info: Dictionary = _replays[int(key.get_slice(":", 1))]
		if not app.require_setup():
			return
		app.push(load("res://scripts/screens/replay_player.gd").new().setup(info))
	elif key == "folder":
		DirAccess.make_dir_recursive_absolute(folder())
		OS.shell_open(folder())
	else:
		super(key)
