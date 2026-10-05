extends "res://scripts/screens/form_screen.gd"
## Controller presets: scroll through them with Left/Right. The choice is written into the
## profile's GCPadNew.ini ([GCPad1], the mapping the game uses, in netplay too) right away and
## again before every game. "Auto" picks the preset matching the first connected controller.

const Controllers := preload("res://scripts/controllers.gd")

var _presets: Array = []


func screen_music() -> String:
	return "game_menu"


func screen_title() -> String:
	return "Controller Setup"


func screen_desc() -> String:
	return "Pick a controller preset with Left / Right.\nIt's used offline and in netplay."


func on_enter() -> void:
	super()
	Input.joy_connection_changed.connect(_on_joy_changed)


func _exit_tree() -> void:
	if Input.joy_connection_changed.is_connected(_on_joy_changed):
		Input.joy_connection_changed.disconnect(_on_joy_changed)


func _pads() -> String:
	var pads := Controllers.connected_pads()
	return ", ".join(pads) if not pads.is_empty() else "None found"


func _resolved() -> Dictionary:
	return Controllers.selected()


func build_rows() -> Array:
	_presets = Controllers.list()
	var values: Array = [Controllers.AUTO, Controllers.KEEP]
	var auto := Controllers.auto_pick()
	var names: Array = ["Auto" + (" (%s)" % auto["name"] if not auto.is_empty() else " (no match: keep)"),
		"Keep current mapping"]
	for p in _presets:
		values.append(p["name"])
		names.append(p["name"])
	var choice: String = Settings.get_value("controller", "preset")
	if not choice in values:
		choice = Controllers.AUTO
	var sel := _resolved()
	return [
		{"type": "info", "key": "pads", "label": "Connected", "value": _pads()},
		{"type": "choice", "key": "preset", "label": "Preset", "values": values, "names": names,
			"value": choice, "desc": _preset_desc(sel)},
		{"type": "info", "key": "device", "label": "Controller",
			"value": sel.get("device", "from GCPadNew.ini: " + _current_device())},
		{"type": "text", "key": "save_as", "label": "Save current mapping as", "value": "",
			"placeholder": "preset name", "max_length": 40,
			"desc": "Saves the mapping in GCPadNew.ini as a new preset\nin SparkingData\\controllers (e.g. after mapping it in Dolphin)."},
		{"type": "action", "key": "folder", "label": "Open presets folder",
			"desc": "SparkingData\\controllers: drop Dolphin GameCube pad profiles (.ini) here\nto add them to the list."},
		{"type": "action", "key": "back", "label": "Back", "desc": "Back to the game menu."},
	]


func _current_device() -> String:
	for kv in Controllers.current_keys():
		if kv[0] == "Device":
			return kv[1]
	return "none"


func _preset_desc(p: Dictionary) -> String:
	if p.is_empty():
		return "Uses the mapping already in GCPadNew.ini (%s)." % _current_device()
	var first := String(p.get("notes", ""))
	if first == "":
		first = "Controller: " + String(p["device"])
	return first + "\n" + Controllers.summary(p)


func _on_joy_changed(_id: int, _connected: bool) -> void:
	list.set_rows(build_rows())


func on_value(key: String, value: Variant) -> void:
	match key:
		"preset":
			Settings.set_value("controller", "preset", value)
			var p := _resolved()
			if Controllers.apply(p):
				app.toast("Controller: " + p["name"], 1.5)
			list.update_row("device", {"value": p.get("device", "from GCPadNew.ini: " + _current_device())})
			list.update_row("preset", {"desc": _preset_desc(p)})
		"save_as":
			if String(value) == "":
				return
			var saved := Controllers.save_current_as(value)
			list.update_row("save_as", {"value": ""})
			if saved == "":
				app.toast("Nothing to save: no mapping in GCPadNew.ini yet.")
				return
			Settings.set_value("controller", "preset", saved)
			list.set_rows(build_rows(), "preset")
			app.toast("Saved preset: " + saved)


func on_press(key: String) -> void:
	if key == "folder":
		DirAccess.make_dir_recursive_absolute(Controllers.user_dir())
		OS.shell_open(Controllers.user_dir())
	else:
		super(key)
