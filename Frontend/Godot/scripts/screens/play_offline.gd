extends "res://scripts/screens/form_screen.gd"
## Offline play: launches the game with the solo save and the player's options, shows its state,
## and offers the quick in-game switches (also in the held-Select in-game menu).

const InGamePanel := preload("res://scripts/ui/ingame_panel.gd")

var _state := "starting"   # starting, running, stopping
var _aspect := ""
var _panel: Control
## Training Display (Modifications): which of its codes Dolphin loaded, and what the game's memory
## says a while into the game: each stage of the overlay, in order (see _td_check).
var _td_codes: Array = []
var _td_missing: Array = []
var _td_peeks := {}
var _td_status := ""
var _td_detail := ""
const TD_PEEKS := {
	"mem2": "80003118",        # Wii MEM2 size (the overlay needs 128 MB: 08000000)
	"arena": "80003128",       # MEM2 arena end (128 MB layout: 97FE0000)
	"framework": "817C0FF0",   # "BT3N": the Phantom Mods framework started
	"menu": "817C132C",        # "MCFG": its settings menu started
	"overlay": "817C1548",     # "DBG1": the overlay was put in place
	"defaults": "97AA2FA0",    # 1: our defaults (master switch on) applied
	# What the framework's installer checks before it starts (Phantom Mods: its code at 80003300,
	# called from the game function it hooks at 80012608), and how far it got (80003BC0).
	"stage": "80003BC0",       # 0: refused / not called yet, 1: copying, 2: checking, 3: started
	"hook": "80012608",        # 4BFF13F8 once hooked (9421FFE0: not hooked)
	"mem1": "80000028",        # must be 01800000
	"mem2sim": "8000311C",     # must be 08000000
	"mem2end": "80003120",     # 98000000 (the game picks its 128 MB BAT from it)
	"ipc": "80003130",         # must be 97FE0000
	"iosend": "8000314C",      # must be 98000000
	"top": "817F7FF0",         # must be 00000000
	"heap": "8062A44C",        # must be 933E0000 (the game's MEM2 heap end)
}
## The installer's requirements (TD_PEEKS key -> value it needs).
const TD_NEEDS := {"mem1": "01800000", "mem2": "08000000", "mem2sim": "08000000", "arena": "97FE0000",
	"ipc": "97FE0000", "iosend": "98000000", "top": "00000000", "heap": "933E0000"}


func screen_music() -> String:
	return "game_menu"


func screen_title() -> String:
	return "Play Offline"


func screen_desc() -> String:
	return "Hold Select (Back / Share) in game for the in-game menu.\nF1 graphics, F2 buttons, F3 aspect ratio."


func on_enter() -> void:
	_aspect = Settings.get_value("options", "aspect")
	super()
	Dolphin.event.connect(_on_event)
	if not Dolphin.launch(Settings.solo_args()):
		app.toast("Couldn't start Dolphin-Sparking (is the Dolphin folder next to the launcher?).")
		app.pop.call_deferred()


func _exit_tree() -> void:
	if Dolphin.event.is_connected(_on_event):
		Dolphin.event.disconnect(_on_event)


func _status() -> String:
	match _state:
		"running":
			return "Playing"
		"stopping":
			return "Stopping..."
	return "Starting..."


func _rows(in_game_menu: bool) -> Array:
	var running := _state == "running"
	var rows: Array = []
	if in_game_menu:
		rows.append({"type": "action", "key": "resume", "label": "Back to the game"})
	else:
		rows.append({"type": "info", "key": "status", "label": Settings.GAME["title"], "value": _status()})
	if Settings.training_display_on():
		rows.append({"type": "info", "key": "training_display", "label": "Training Display",
			"value": tr(_td_status) if _td_status != "" else tr("Checking..."),
			"desc": _td_detail if _td_detail != "" else tr("Hitboxes and frame data: checked a few seconds into the game.")})
	rows.append_array([
		{"type": "action", "key": "graphics", "label": "Graphics", "value": Settings.get_value("options", "graphics"),
			"disabled": not running, "desc": "Switch between Enhanced (HD) and Legacy textures (F1)."},
		{"type": "action", "key": "buttons", "label": "Button prompts", "value": Settings.option_name("buttons", Settings.get_value("options", "buttons")),
			"disabled": not running, "desc": "Switch the button prompts: GameCube, PlayStation, Xbox (F2)."},
		{"type": "action", "key": "aspect", "label": "Aspect ratio", "value": _aspect,
			"disabled": not running, "desc": "Switch between widescreen and 4:3 (F3)."},
		{"type": "action", "key": "input_display", "label": "P1 input history",
			"value": "On" if Settings.get_value("options", "input_display") else "Off", "disabled": not running,
			"desc": "Player 1's inputs down the left side: frames held, direction (dot = neutral), buttons."},
		{"type": "action", "key": "input_display_other", "label": "P2 input history",
			"value": "On" if Settings.get_value("options", "input_display_other") else "Off", "disabled": not running,
			"desc": "Player 2's inputs down the right side."},
		{"type": "action", "key": "stop", "label": "Stop Game", "color": "#e8663d",
			"desc": "Close the game and go back to the menu."},
	])
	return rows


func build_rows() -> Array:
	return _rows(false)


func _refresh() -> void:
	list.set_rows(build_rows())
	if _panel and is_instance_valid(_panel):
		_panel.list.set_rows(_rows(true))


func on_press(key: String) -> void:
	match key:
		"graphics":
			Dolphin.send("textures_cycle Graphics")
		"buttons":
			Dolphin.send("textures_cycle Buttons")
		"aspect":
			Dolphin.send("aspect toggle")
		"input_display", "input_display_other":
			var on := not bool(Settings.get_value("options", key))
			Settings.set_value("options", key, on)
			Dolphin.send(key + " " + ("on" if on else "off"))
			_refresh()
		"stop":
			_state = "stopping"
			_refresh()
			app.close_ingame_menu(false)
			Dolphin.quit_session()
		"resume":
			app.close_ingame_menu()


func on_back() -> void:
	# Leaving this screen means stopping the game: B moves to "Stop Game" first.
	if list.current_key() == "stop":
		on_press("stop")
	else:
		list.focus_key("stop")


func make_ingame_panel() -> Control:
	_panel = InGamePanel.new().setup(Settings.GAME["title"], _rows(true), 0, Vector2(520, 420))
	_panel.pressed.connect(on_press)
	return _panel


func _on_event(name: String, data: Dictionary) -> void:
	match name:
		"game_started":
			_state = "running"
			_refresh()
			if Settings.training_display_on():
				_td_schedule()
		"gecko_active":
			if int(data.get("port", 0)) == 0:
				_td_codes = data.get("action_replay", [])
				_td_missing = data.get("missing", [])
		"peek":
			_td_peeks[String(data.get("address", ""))] = String(data.get("value", ""))
		"textures":
			Settings.remember_textures(data.get("selection", {}))
			_refresh()
		"aspect":
			_aspect = String(data.get("mode", _aspect))
			_refresh()
		"error":
			app.toast(tr("Dolphin: %s") % String(data.get("code", "error")).replace("_", " "))
		"process_exited":
			app.pop_to(func(s): return s != self)


# --- Training Display self-check -------------------------------------------------------------

func _td_schedule() -> void:
	for wait in [12.0, 30.0, 60.0]:
		await get_tree().create_timer(wait if wait == 12.0 else wait - 12.0).timeout
		if not is_inside_tree() or _state != "running":
			return
		await _td_check()
		if _td_status == "Loaded":
			return


## Reads each stage's marker and says where it stops: codes in Dolphin's game settings, the
## 128 MB memory layout, the framework, its settings menu, the overlay, our defaults.
func _td_check() -> void:
	_td_peeks.clear()
	for key in TD_PEEKS:
		Dolphin.send("peek " + String(TD_PEEKS[key]))
	var end := Time.get_ticks_msec() + 3000
	while _td_peeks.size() < TD_PEEKS.size() and Time.get_ticks_msec() < end:
		await get_tree().process_frame
	var v := func(key: String) -> String: return String(_td_peeks.get(TD_PEEKS[key], "?"))
	var parts := PackedStringArray()
	for key in TD_PEEKS:
		parts.append("%s %s" % [key, v.call(key)])
	var values := ", ".join(parts)
	var unmet := PackedStringArray()
	for key in TD_NEEDS:
		if v.call(key) != TD_NEEDS[key]:
			unmet.append("%s %s (needs %s)" % [key, v.call(key), TD_NEEDS[key]])
	var wanted: Array = Settings.TRAINING_DISPLAY.get(String(Settings.GAME["id"]), [])
	var missing := wanted.filter(func(n): return not n in _td_codes or n in _td_missing)
	if not missing.is_empty():
		_td_status = "Codes missing"
		_td_detail = tr("Dolphin doesn't have the Training Display codes: its Sys folder is out of date.\nReplace the whole Dolphin folder (Sys included) with the new build.")
	elif v.call("mem2") != "08000000":
		_td_status = "No 128 MB"
		_td_detail = tr("Dolphin didn't give the game 128 MB of memory, which the overlay needs.\n%s") % values
	elif v.call("framework") != "4254334E":
		_td_status = "Framework didn't start"
		var why := ""
		if v.call("hook") == "9421FFE0":
			why = "not hooked yet"
		elif v.call("hook") != "4BFF13F8":
			why = "this game copy's code differs at 80012608"
		elif not unmet.is_empty():
			why = "refused: " + ", ".join(unmet)
		else:
			why = "stage %s" % v.call("stage")
		_td_detail = tr("The Phantom Mods framework didn't start (%s).\nSend SparkingData/logs/training_display.txt to report it.") % why
	elif v.call("menu") != "4D434647":
		_td_status = "Menu didn't start"
		_td_detail = tr("The overlay's settings menu didn't start.\n%s") % values
	elif v.call("overlay") != "44424731":
		_td_status = "Overlay didn't start"
		_td_detail = tr("The overlay didn't load.\n%s") % values
	elif v.call("defaults") != "00000001":
		_td_status = "Switched off"
		_td_detail = tr("The overlay is loaded but switched off. In the game's Options, press Right:\nMod Settings > Stats And Frame Data Overlay.\n%s") % values
	else:
		_td_status = "Loaded"
		_td_detail = tr("Loaded, with hitboxes and frame data on. Nothing in a match? In the game's Options,\npress Right: Mod Settings > Stats And Frame Data Overlay.")
	_td_log(values)
	_refresh()


## SparkingData/logs/training_display.txt: the last check, to send when reporting a problem.
func _td_log(values: String) -> void:
	var dir := Settings.data_path("logs")
	DirAccess.make_dir_recursive_absolute(dir)
	var f := FileAccess.open(dir.path_join("training_display.txt"), FileAccess.WRITE)
	if f:
		f.store_string("%s\n%s %s\ncodes: %s\nmissing: %s\n%s\n" % [Time.get_datetime_string_from_system(),
			Settings.GAME["id"], Settings.GAME["version"], ", ".join(_td_codes), ", ".join(_td_missing),
			values])
		f.store_string("%s: %s\n" % [_td_status, _td_detail])

