extends "res://scripts/screens/form_screen.gd"
## Placeholder: the game reads Dolphin's GameCube pad profile for port 1. Mapping inside the
## frontend (and picking a profile from the first connected pad) comes later.


func screen_title() -> String:
	return "Controller Setup"


func screen_desc() -> String:
	return "Coming soon: map your controller here, with a layout picked\nautomatically from the first pad you connect."


func _pads() -> String:
	var names: Array = []
	for id in Input.get_connected_joypads():
		names.append(Input.get_joy_name(id))
	return ", ".join(names) if not names.is_empty() else "None found"


func build_rows() -> Array:
	return [
		{"type": "info", "key": "pads", "label": "Connected", "value": _pads()},
		{"type": "info", "key": "profile", "label": "Used by the game", "value": "GameCube port 1 profile"},
		{"type": "action", "key": "folder", "label": "Open Dolphin config folder",
			"desc": "Config/GCPadNew.ini, [GCPad1]: the mapping the game uses,\nin netplay too. Set it up with regular Dolphin for now."},
		{"type": "action", "key": "back", "label": "Back", "desc": "Back to the game menu."},
	]


func on_enter() -> void:
	super()
	Input.joy_connection_changed.connect(_on_joy_changed)


func _on_joy_changed(_id: int, _connected: bool) -> void:
	list.update_row("pads", {"value": _pads()})


func on_press(key: String) -> void:
	if key == "folder":
		var dir := Settings.data_path(Settings.get_value("paths", "profile")).path_join("Config")
		if DirAccess.dir_exists_absolute(dir):
			OS.shell_open(dir)
		else:
			app.toast("Not found yet: " + dir)
	else:
		super(key)
