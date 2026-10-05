extends "res://scripts/screens/form_screen.gd"
## Gecko codes for offline play. "Game defaults" = whatever the game ini enables; "Custom" =
## exactly the codes ticked here. Netplay always uses the lobby's fixed code set.

var _codes: Array = []   # from the gecko_codes event
var _loading := true


func screen_music() -> String:
	return "game_menu"


func screen_title() -> String:
	return "Gecko Codes"


func screen_desc() -> String:
	return "Gecko codes for offline play.\nNetplay always uses the same fixed set for everyone."


func on_enter() -> void:
	super()
	if not Dolphin.query(Settings.list_gecko_args(), _on_codes):
		_loading = false
		list.set_rows(build_rows())
		app.toast("Couldn't start Dolphin-Sparking")


func _on_codes(events: Array) -> void:
	_loading = false
	for e in events:
		if e.get("event") == "gecko_codes":
			_codes = e.get("codes", [])
	if is_inside_tree():
		list.set_rows(build_rows())


func build_rows() -> Array:
	var custom: bool = Settings.get_value("gecko", "custom")
	var enabled: Array = Settings.get_value("gecko", "enabled")
	var rows: Array = [
		{"type": "toggle", "key": "custom", "label": "Code selection", "value": custom,
			"on_text": "Custom", "off_text": "Game defaults",
			"desc": "Game defaults: the codes this build turns on (16:9, controls\nfixes...). Custom: exactly the codes ticked below."},
	]
	if _loading:
		rows.append({"type": "info", "key": "loading", "label": "Loading codes...", "value": ""})
	elif _codes.is_empty():
		rows.append({"type": "info", "key": "none", "label": "No codes found", "value": ""})
	for i in _codes.size():
		var c: Dictionary = _codes[i]
		var name := String(c.get("name", ""))
		var notes := _text(c.get("notes", "")).strip_edges()
		var by := _text(c.get("creator", "")).strip_edges()
		var desc := name
		if by != "":
			desc += "  (by %s)" % by
		if notes != "":
			desc += "\n" + notes.replace("\n", " ").left(110)
		rows.append({"type": "toggle", "key": "code:%d" % i, "label": name,
			"value": (name in enabled) if custom else bool(c.get("default_enabled", false)),
			"disabled": not custom, "desc": desc})
	rows.append({"type": "action", "key": "back", "label": "Back", "desc": "Back to Modifications."})
	return rows


## Notes come as a list of lines.
func _text(v: Variant) -> String:
	if v is Array:
		return " ".join(v)
	return "" if v == null else str(v)


func on_value(key: String, value: Variant) -> void:
	if key == "custom":
		if value and Settings.get_value("gecko", "enabled").is_empty():
			# Start the custom set from the current defaults.
			var defaults: Array = []
			for c in _codes:
				if c.get("default_enabled", false):
					defaults.append(c["name"])
			Settings.set_value("gecko", "enabled", defaults)
		Settings.set_value("gecko", "custom", value)
		list.set_rows(build_rows(), "custom")
	elif key.begins_with("code:"):
		var name: String = _codes[int(key.substr(5))]["name"]
		var enabled: Array = Settings.get_value("gecko", "enabled").duplicate()
		enabled.erase(name)
		if value:
			enabled.append(name)
		Settings.set_value("gecko", "enabled", enabled)
