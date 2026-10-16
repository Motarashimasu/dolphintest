extends "res://scripts/screens/form_screen.gd"
## DRAGON NET > Rollback Test: the first step toward rollback netplay. Plays the game offline
## while Dolphin keeps saving the state, rewinding a few frames and re-running them with the same
## inputs (--rollback-test). It reports anything that comes out different (with its memory
## addresses) and how fast this PC saves, loads and re-runs: whether rollback can work here.
## Every result also goes to <SparkingData>/rollback_test/<date>.jsonl, to send to the developers.

const InGamePanel := preload("res://scripts/ui/ingame_panel.gd")
const DEPTHS := [2, 4, 6, 8]   # video fields (BT3 runs its game logic every 2)

var _depth := 4
var _gpu_state := false   # also save / load the graphics card's textures (Dolphin's default: on)
var _draw := false        # draw the re-runs too (real rollback won't)
var _diagnose := false    # detailed log of both runs, for the developers
var _state := "ready"   # ready, starting, running, stopping
var _stats := {}
var _mismatches := 0
var _last_mismatch := ""
var _log := ""
var _panel: Control


func _init() -> void:
	super()
	notices = false


func screen_title() -> String:
	return "Rollback Test"


func screen_music() -> String:
	return "netplay"


func screen_desc() -> String:
	return "Play offline while Dolphin keeps rewinding and replaying a few frames,\nto test if rollback netplay can work for this game on this PC."


func on_enter() -> void:
	super()
	Dolphin.event.connect(_on_event)


func _exit_tree() -> void:
	if Dolphin.event.is_connected(_on_event):
		Dolphin.event.disconnect(_on_event)


func _ms(key: String) -> String:
	return tr("%s ms (max %s)") % ["%.1f" % float(_stats.get(key, 0)), "%.1f" % float(_stats.get(key + "_max", 0))]


func _rows(in_game_menu: bool) -> Array:
	var rows: Array = []
	var running := _state in ["starting", "running"]
	if in_game_menu:
		rows.append({"type": "action", "key": "resume", "label": "Back to the game"})
	else:
		rows.append({"type": "choice", "key": "depth", "label": "Rewind", "values": DEPTHS,
			"names": DEPTHS.map(func(d): return tr("%d frames") % (d / 2)), "value": _depth,
			"disabled": running,
			"desc": "How far back each test rewinds (game frames, 1 = 2 video fields).\nStart small; real rollback rarely goes past 3."})
		rows.append({"type": "toggle", "key": "gpu_state", "label": "Rewind graphics too",
			"value": _gpu_state, "on_text": "On", "off_text": "Off", "disabled": running,
			"desc": "On: each rewind also saves and reloads the graphics card's textures (slow,\nbig). Off: only the game itself, like real rollback would."})
		rows.append({"type": "toggle", "key": "draw", "label": "Draw re-runs",
			"value": _draw, "on_text": "On", "off_text": "Off", "disabled": running,
			"desc": "Off: re-run frames aren't drawn (nobody sees them), like real rollback.\nOn: draw them anyway, to compare how much time drawing takes."})
		rows.append({"type": "toggle", "key": "diagnose", "label": "Detailed log",
			"value": _diagnose, "on_text": "On", "off_text": "Off", "disabled": running,
			"desc": "On: log everything the emulator does in both runs, so a mismatch shows\nexactly where they parted. Makes re-runs slower: leave Off to measure speed."})
	if not _stats.is_empty():
		var fit := int(_stats.get("max_rollback_fields", -1))
		rows.append_array([
			{"type": "info", "key": "tests", "label": "Tests done", "value": str(int(_stats.get("cycles", 0)))},
			{"type": "info", "key": "mismatches", "label": "Didn't match", "value": str(_mismatches),
				"desc": _last_mismatch if _last_mismatch != "" else "Every rewind came out exactly the same so far."},
			{"type": "info", "key": "save", "label": "Save state", "value": _ms("save_ms"),
				"desc": "Rollback saves the state every frame: this has to be small."},
			{"type": "info", "key": "load", "label": "Load state", "value": _ms("load_ms")},
			{"type": "info", "key": "rerun", "label": "Re-run one field", "value": tr("%s ms (max %s)") % [
				"%.1f" % float(_stats.get("rerun_ms_recent", _stats.get("rerun_ms_per_field", 0))),
				"%.1f" % float(_stats.get("rerun_ms_per_field_max", 0))],
				"desc": "The last 20 re-runs. Playing normally takes up to 16.7 ms per field."},
			{"type": "info", "key": "size", "label": "State size", "value": tr("%d MB") % (int(_stats.get("state_kb", 0)) / 1024)},
			{"type": "info", "key": "fit", "label": "This PC could rewind",
				"value": tr("%d frames") % (fit / 2) if fit >= 0 else "-",
				"desc": "Game frames this PC could re-run within one frame, with today's full saves.\nThe next step (saving only what the game needs) makes this much faster."},
		])
	if in_game_menu or running:
		rows.append({"type": "action", "key": "stop", "label": "Stop Test", "color": "#e8663d",
			"desc": "Close the game. The results stay in the results file."})
	else:
		rows.append({"type": "action", "key": "start", "label": "Start Test",
			"desc": "Starts the game offline. Play normally (any mode, any characters):\nthe more different things happen, the more the test covers."})
	if _log != "" and not in_game_menu:
		rows.append({"type": "action", "key": "folder", "label": "Open results folder",
			"desc": "Send the newest .jsonl file to the developers."})
	if not in_game_menu:
		rows.append({"type": "action", "key": "back", "label": "Back", "desc": "Back to the DRAGON NET menu."})
	return rows


func build_rows() -> Array:
	return _rows(false)


func _refresh() -> void:
	var key: String = list.current_key()
	list.set_rows(build_rows())
	if list.row(key).is_empty() == false:
		list.focus_key(key)
	if _panel and is_instance_valid(_panel):
		_panel.list.set_rows(_rows(true))


func on_value(key: String, value: Variant) -> void:
	if key == "depth":
		_depth = int(value)
	elif key == "gpu_state":
		_gpu_state = bool(value)
	elif key == "draw":
		_draw = bool(value)
	elif key == "diagnose":
		_diagnose = bool(value)


func on_press(key: String) -> void:
	match key:
		"start":
			if not app.require_setup():
				return
			_stats = {}
			_mismatches = 0
			_last_mismatch = ""
			_log = Settings.data_path("rollback_test").path_join(
				Time.get_datetime_string_from_system().replace(":", "-") + ".jsonl")
			if Dolphin.launch(Settings.rollback_test_args(_depth, _log, _gpu_state, _draw, _diagnose)):
				_state = "starting"
			else:
				app.toast("Couldn't start Dolphin-Sparking (is the Dolphin folder next to the launcher?).")
			_refresh()
		"stop":
			_state = "stopping"
			app.close_ingame_menu(false)
			Dolphin.quit_session()
			_refresh()
		"resume":
			app.close_ingame_menu()
		"folder":
			DirAccess.make_dir_recursive_absolute(Settings.data_path("rollback_test"))
			OS.shell_open(Settings.data_path("rollback_test"))
		_:
			super(key)


func on_back() -> void:
	if _state in ["starting", "running"]:
		list.focus_key("stop")
	else:
		super()


func make_ingame_panel() -> Control:
	if not _state in ["starting", "running"]:
		return null
	_panel = InGamePanel.new().setup(tr("Rollback Test"), _rows(true), 0, Vector2(560, 520))
	_panel.pressed.connect(on_press)
	return _panel


func _on_event(name: String, data: Dictionary) -> void:
	match name:
		"game_started", "rollback_test":
			_state = "running"
			_refresh()
		"rollback_test_stats":
			_stats = data
			_refresh()
		"rollback_mismatch":
			_mismatches += 1
			var where: Array = []
			for r in data.get("mem1", []):
				where.append(String(r.get("address", "")))
			_last_mismatch = tr("Last at video field %d: %d bytes differ (%s).") % [
				int(data.get("field", 0)), int(data.get("mem1_bytes", 0)),
				", ".join(where.slice(0, 4)) if not where.is_empty() else tr("audio memory or inputs")]
			_refresh()
		"process_exited":
			_state = "ready"
			_refresh()
