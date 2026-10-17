extends "res://scripts/screens/form_screen.gd"
## Watching a ranked replay: Dolphin plays the recorded inputs back from the start state and
## closes the game at the end (replay_ended). Shows the progress; Stop ends it early.

const InGamePanel := preload("res://scripts/ui/ingame_panel.gd")

var info := {}
var _state := "starting"   # starting, playing, ended, stopping
var _frame := 0
var _frames := 0
var _panel: Control


func setup(p_info: Dictionary) -> Node:
	info = p_info
	_frames = int(info.get("frames", 0))
	return self


func _init() -> void:
	super()
	notices = false


func screen_title() -> String:
	return "Replay"


func screen_music() -> String:
	return "netplay"


func screen_desc() -> String:
	return "Hold Select (Back / Share) in game for the in-game menu."


func on_enter() -> void:
	super()
	Dolphin.event.connect(_on_event)
	var disc_id := String(info.get("game_id", ""))
	var where := Settings.game_of_id(disc_id)
	if not where.is_empty() and not Settings.has_copy(where[0], where[1]):
		app.toast(tr("This replay is on %s %s: add that copy in Options > Game Copies.") % [
			Settings.GAMES[where[0]]["title"], where[1]], 5.0)
		app.pop.call_deferred()
		return
	if not Dolphin.launch(Settings.replay_args(String(info.get("path", "")), info.get("gecko", []), disc_id)):
		app.toast("Couldn't start Dolphin-Sparking (is the Dolphin folder next to the launcher?).")
		app.pop.call_deferred()


func _exit_tree() -> void:
	if Dolphin.event.is_connected(_on_event):
		Dolphin.event.disconnect(_on_event)


func _status() -> String:
	match _state:
		"playing":
			return "%d%%" % (100 * _frame / max(_frames, 1))
		"ended":
			return "Finished"
		"stopping":
			return "Stopping..."
	return "Starting..."


func _rows(in_game_menu: bool) -> Array:
	var rows: Array = []
	if in_game_menu:
		rows.append({"type": "action", "key": "resume", "label": "Back to the replay"})
	rows.append({"type": "info", "key": "status", "label": load("res://scripts/screens/replays.gd").title_of(info),
		"value": _status()})
	rows.append({"type": "action", "key": "stop", "label": "Stop Replay", "color": "#e8663d",
		"desc": "Close the replay and go back to the list."})
	return rows


func build_rows() -> Array:
	return _rows(false)


func _refresh() -> void:
	list.set_rows(build_rows())
	if _panel and is_instance_valid(_panel):
		_panel.list.set_rows(_rows(true))


func on_press(key: String) -> void:
	match key:
		"stop":
			_state = "stopping"
			_refresh()
			app.close_ingame_menu(false)
			Dolphin.quit_session()
		"resume":
			app.close_ingame_menu()


func on_back() -> void:
	if list.current_key() == "stop":
		on_press("stop")
	else:
		list.focus_key("stop")


func make_ingame_panel() -> Control:
	_panel = InGamePanel.new().setup(tr("Replay"), _rows(true), 0, Vector2(520, 300))
	_panel.pressed.connect(on_press)
	return _panel


func _on_event(name: String, data: Dictionary) -> void:
	match name:
		"replay_started":
			_frames = int(data.get("frames", _frames))
			_state = "playing"
			_refresh()
		"replay_progress":
			_frame = int(data.get("frame", _frame))
			_frames = int(data.get("frames", _frames))
			_state = "playing"
			_refresh()
		"replay_ended":
			_state = "ended"
			_frame = _frames
			_refresh()
		"error":
			app.toast(tr("Dolphin: %s") % String(data.get("code", "error")).replace("_", " "))
		"process_exited":
			app.pop_to(func(s): return s != self)
