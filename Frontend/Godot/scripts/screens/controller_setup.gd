extends "res://scripts/screens/form_screen.gd"
## Controller presets of the game whose menu this is (each game has its own presets and its own
## choice): scroll through them with Left/Right. The choice is written into the profile's
## GCPadNew.ini ([GCPad1], the mapping the game uses, in netplay too) right away and again
## before every game of it. "Auto" picks the preset matching the first connected controller.
## Player 2 (offline only): a second controller in port 2 ([GCPad2]): its own preset (or Player 1's)
## and which controller, from the list Dolphin sees (a helper Dolphin, --input-test, while on).

const Controllers := preload("res://scripts/controllers.gd")

var _presets: Array = []
var _helper: Object = null
var _devices: Array = []   # Dolphin's controllers: [{name, title, source}] (the helper's list)


func screen_music() -> String:
	return "game_menu"


func screen_title() -> String:
	return "Controller Setup"


func screen_desc() -> String:
	return tr("Pick a %s controller preset with Left / Right.\nIt's used offline and on DRAGON NET.") % Settings.GAMES[Settings.game]["short"]


func on_enter() -> void:
	super()
	Input.joy_connection_changed.connect(_on_joy_changed)
	_watch_devices(Controllers.p2_on())


func _exit_tree() -> void:
	if Input.joy_connection_changed.is_connected(_on_joy_changed):
		Input.joy_connection_changed.disconnect(_on_joy_changed)
	_watch_devices(false)


## The controller list Dolphin sees, for Player 2's controller choice (only while Player 2 is on).
func _watch_devices(on: bool) -> void:
	if on and _helper == null:
		_helper = Dolphin.start_helper(Settings.input_test_args(), _on_helper)
	elif not on and _helper:
		Dolphin.stop_helper(_helper)
		_helper = null


func _on_helper(e: Dictionary) -> void:
	if String(e.get("event", "")) == "devices" and is_inside_tree():
		_devices = e.get("devices", [])
		list.set_rows(build_rows(), list.current_key())


func _pads() -> String:
	var pads := Controllers.connected_pads()
	return ", ".join(pads) if not pads.is_empty() else "None found"


func _resolved() -> Dictionary:
	return Controllers.selected()


func build_rows() -> Array:
	_presets = Controllers.list()
	var values: Array = [Controllers.AUTO, Controllers.KEEP]
	var auto := Controllers.auto_pick()
	var names: Array = [tr("Auto (%s)") % auto["name"] if not auto.is_empty() else tr("Auto (no match: keep)"),
		"Keep current mapping"]
	for p in _presets:
		values.append(p["name"])
		names.append(p["name"])
	var choice := Controllers.choice()
	if not choice in values:
		choice = Controllers.AUTO
	var sel := _resolved()
	return [
		{"type": "info", "key": "pads", "label": "Connected", "value": _pads()},
		{"type": "choice", "key": "preset", "label": "Preset", "values": values, "names": names,
			"value": choice, "desc": _preset_desc(sel)},
		{"type": "info", "key": "device", "label": "Controller",
			"value": sel.get("device", tr("from GCPadNew.ini: %s") % _current_device())},
		{"type": "action", "key": "edit", "label": "Edit This Config",
			"desc": "Change the buttons of the config above by pressing them\n(saved as your own copy if it's a built-in one)."},
		{"type": "action", "key": "new", "label": "Create New Config",
			"desc": "Map every GameCube button yourself by pressing it on your controller.\nAlso shows live what the menus and Dolphin see from your controller."},
	] + _p2_rows() + [
		{"type": "action", "key": "folder", "label": "Open presets folder",
			"desc": tr("SparkingData\\controllers\\%s: drop Dolphin GameCube pad profiles (.ini) here\nto add them to this game's list.") % Settings.game},
		{"type": "action", "key": "back", "label": "Back", "desc": "Back to the game menu."},
	]


func _p2_rows() -> Array:
	var rows: Array = [{"type": "toggle", "key": "p2", "label": "Player 2", "value": Controllers.p2_on(),
		"on_text": "On", "off_text": "Off",
		"desc": "A second controller for a friend on the same PC (offline only:\nonline, each player uses their own PC)."}]
	if not Controllers.p2_on():
		return rows
	var values: Array = [Controllers.SAME]
	var names: Array = ["Same as Player 1"]
	for p in _presets:
		values.append(p["name"])
		names.append(p["name"])
	var choice := Controllers.p2_choice()
	if not choice in values:
		choice = Controllers.SAME
	rows.append({"type": "choice", "key": "p2_preset", "label": "Player 2 preset", "values": values,
		"names": names, "value": choice, "desc": "Player 2's buttons: one of the presets, or the same as Player 1's."})
	# Which controller: Auto (Player 1's kind, the next one), or one Dolphin sees.
	var auto := Controllers.next_device(_value_of(Controllers.p2_keys_base(), "Device"))
	var dev_values: Array = [""]
	var dev_names: Array = [tr("Auto (%s)") % auto if auto != "" else tr("Auto")]
	var current := Controllers.p2_device()
	for d in _devices:
		dev_values.append(String(d["name"]))
		dev_names.append(String(d["name"]))
	if current != "" and not current in dev_values:   # chosen before, not connected now
		dev_values.append(current)
		dev_names.append(tr("%s (not connected)") % current)
	rows.append({"type": "choice", "key": "p2_device", "label": "Player 2 controller", "values": dev_values,
		"names": dev_names, "value": current,
		"desc": "Auto: the same kind as Player 1's, the next one (2nd Xbox pad, 2nd PlayStation pad...).\nPick one if Player 2 uses a different controller."
			if not _devices.is_empty() else "Looking for controllers..."})
	return rows


func _value_of(keys: Array, key: String) -> String:
	for kv in keys:
		if kv[0] == key:
			return kv[1]
	return ""


func _current_device() -> String:
	for kv in Controllers.current_keys():
		if kv[0] == "Device":
			return kv[1]
	return "none"


func _preset_desc(p: Dictionary) -> String:
	if p.is_empty():
		return tr("Uses the mapping already in GCPadNew.ini (%s).") % _current_device()
	var first := String(p.get("notes", ""))
	if first == "":
		first = tr("Controller: %s") % String(p["device"])
	return first


func _on_joy_changed(_id: int, _connected: bool) -> void:
	list.set_rows(build_rows())


func on_value(key: String, value: Variant) -> void:
	match key:
		"preset":
			Controllers.set_choice(value)
			var p := _resolved()
			if Controllers.apply(p):
				app.toast(tr("Controller: %s") % p["name"], 1.5)
			list.update_row("device", {"value": p.get("device", tr("from GCPadNew.ini: %s") % _current_device())})
			list.update_row("preset", {"desc": _preset_desc(p)})
		"p2":
			Controllers.set_p2_on(bool(value))
			_watch_devices(bool(value))
			list.set_rows(build_rows(), "p2")
			app.toast(tr("Player 2: on (offline)") if value else tr("Player 2: off"), 1.5)
		"p2_preset":
			Controllers.set_p2_choice(String(value))
			list.set_rows(build_rows(), "p2_preset")
		"p2_device":
			Controllers.set_p2_device(String(value))
		"save_as":
			if String(value) == "":
				return
			var saved := Controllers.save_current_as(value)
			list.update_row("save_as", {"value": ""})
			if saved == "":
				app.toast("Nothing to save: no mapping in GCPadNew.ini yet.")
				return
			Controllers.set_choice(saved)
			list.set_rows(build_rows(), "preset")
			app.toast(tr("Saved preset: %s") % saved)


func on_press(key: String) -> void:
	if key == "new" or key == "edit":
		var base := {}
		if key == "edit":
			base = _resolved()
			if base.is_empty():
				base = {"name": "My Controller", "keys": Controllers.current_keys()}
		app.push(load("res://scripts/screens/controller_editor.gd").new().setup(base))
		return
	if key == "folder":
		DirAccess.make_dir_recursive_absolute(Controllers.user_dir())
		OS.shell_open(Controllers.user_dir())
	else:
		super(key)
