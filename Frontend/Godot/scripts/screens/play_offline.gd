extends "res://scripts/screens/form_screen.gd"
## Offline play: launches the game with the solo save and the player's options, shows its state,
## and offers the quick in-game switches (also in the held-Select in-game menu).

const InGamePanel := preload("res://scripts/ui/ingame_panel.gd")

var _state := "starting"   # starting, running, stopping
var _aspect := ""
var _panel: Control
var _capturing := ""      # state file being saved (its old copy is .bak until it succeeds)
var capture := false      # Capture Battle States: netplay save + default codes (Settings.capture_args)


func setup(p_capture := false) -> Node:
	capture = p_capture
	return self


func screen_music() -> String:
	return "game_menu"


func screen_title() -> String:
	return "Capture Battle States" if capture else "Play Offline"


func screen_desc() -> String:
	if capture:
		return "Go to the character select screen of Single or Team Battle,\nthen hold Select and pick Save as ... Battle state."
	return "Hold Select (Back / Share) in game for the in-game menu.\nF3 graphics, F4 buttons, F5 aspect ratio."


func on_enter() -> void:
	_aspect = Settings.get_value("options", "aspect")
	super()
	Dolphin.event.connect(_on_event)
	if not Dolphin.launch(Settings.capture_args() if capture else Settings.solo_args()):
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
	rows.append_array([
		{"type": "action", "key": "graphics", "label": "Graphics", "value": Settings.get_value("options", "graphics"),
			"disabled": not running, "desc": "Switch between Enhanced (HD) and Legacy textures (F3)."},
		{"type": "action", "key": "buttons", "label": "Button prompts", "value": Settings.option_name("buttons", Settings.get_value("options", "buttons")),
			"disabled": not running, "desc": "Switch the button prompts: GameCube, PlayStation, Xbox (F4)."},
		{"type": "action", "key": "aspect", "label": "Aspect ratio", "value": _aspect,
			"disabled": not running, "desc": "Switch between 16:9 and 4:3 (F5)."},
		{"type": "action", "key": "stop", "label": "Stop Game", "color": "#e8663d",
			"desc": "Close the game and go back to the menu."},
	])
	if capture:
		# Capture the DRAGON NET battle states (everyone boots into these), on the character
		# select screen. This session runs like a netplay match: netplay save, default codes.
		var at := rows.size() - 1
		rows.insert(at, {"type": "action", "key": "capture:Single", "label": "Save as Single Battle state",
			"disabled": not running, "color": "#9b6be6",
			"desc": tr("Saves this moment as the DRAGON NET Single Battle state\n(%s). The old file is kept as .bak.") % Settings.battle_state_file("Single")})
		rows.insert(at + 1, {"type": "action", "key": "capture:Team", "label": "Save as Team Battle state",
			"disabled": not running, "color": "#9b6be6",
			"desc": tr("Saves this moment as the DRAGON NET Team Battle state\n(%s). The old file is kept as .bak.") % Settings.battle_state_file("Team")})
	return rows


## The state file each lobby mode boots into ([Sparking.Modes] in the game's ini).
static func battle_state_file(mode: String) -> String:
	return Settings.battle_state_file(mode)


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
		"stop":
			_state = "stopping"
			_refresh()
			app.close_ingame_menu(false)
			Dolphin.quit_session()
		"resume":
			app.close_ingame_menu()
		"capture:Single", "capture:Team":
			var file := battle_state_file(key.substr(8))
			var path := Settings.data_path("states").path_join(file)
			if FileAccess.file_exists(path):
				DirAccess.remove_absolute(path + ".bak")
				DirAccess.rename_absolute(path, path + ".bak")
			_capturing = path
			Dolphin.send("save_state_file " + file)
			app.toast(tr("Saving %s...") % file)


func on_back() -> void:
	# Leaving this screen means stopping the game: B moves to "Stop Game" first.
	if list.current_key() == "stop":
		on_press("stop")
	else:
		list.focus_key("stop")


func make_ingame_panel() -> Control:
	_panel = InGamePanel.new().setup(Settings.GAME["title"], _rows(true), 0,
			Vector2(560, 520) if capture else Vector2(520, 420))
	_panel.pressed.connect(on_press)
	return _panel


func _on_event(name: String, data: Dictionary) -> void:
	match name:
		"game_started":
			_state = "running"
			_refresh()
		"textures":
			Settings.remember_textures(data.get("selection", {}))
			_refresh()
		"aspect":
			_aspect = String(data.get("mode", _aspect))
			_refresh()
		"state_file_saved":
			_capturing = ""
			app.toast(tr("Saved %s. Everyone on DRAGON NET needs this new file.") % String(data.get("name", "")), 6.0)
		"error":
			if _capturing != "" and String(data.get("code", "")).begins_with("state"):
				if not FileAccess.file_exists(_capturing) and FileAccess.file_exists(_capturing + ".bak"):
					DirAccess.rename_absolute(_capturing + ".bak", _capturing)   # put the old one back
				_capturing = ""
			app.toast(tr("Dolphin: %s") % String(data.get("code", "error")).replace("_", " "))
		"process_exited":
			app.pop_to(func(s): return s != self)
