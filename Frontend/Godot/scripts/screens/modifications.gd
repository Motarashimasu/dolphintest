extends "res://scripts/screens/form_screen.gd"
## Codes for offline play, one tab per version of the game (NTSC-U / PAL / NTSC-J): every version
## has its own codes (memory addresses differ), and its own choice. "Game defaults" = whatever
## that version's game ini enables; "Custom" = exactly the codes ticked here. LB / RB (or Q / E)
## switch versions. Netplay always uses the lobby's fixed code set.

const TAB_Y := 112.0
const TAB_W := 250.0
const TAB_H := 50.0
const TAB_GAP := 14.0

var _version := ""          # the tab shown
var _codes := {}            # disc ID -> codes (from its gecko_codes event)
var _loading := {}          # disc ID -> true while Dolphin lists them
var _tabs: Array = []       # [{version, panel, name, id}]


func _init() -> void:
	super()
	notices = false   # no notification bars here


func screen_music() -> String:
	return "game_menu"


func screen_title() -> String:
	return "Codes"


func screen_desc() -> String:
	return "Codes for offline play, per version of the game.\nDRAGON NET always uses the same fixed set for everyone."


func screen_hints() -> Array:
	return [["LB RB", Style.INK_LINE, "Version"], ["▲▼", Style.INK_LINE, "Move"],
			["A", Style.GOOD, "Select"], ["B", Style.POOR, "Back"]]


func list_rect() -> Rect2:
	return Rect2(70, 204, 1140, 290)


func on_enter() -> void:
	_version = Settings.offline_version(Settings.game)
	super()
	_build_tabs()
	_show(_version)


## The disc ID of the tab shown.
func _id() -> String:
	return String(Settings.GAMES[Settings.game]["versions"][_version])


func _build_tabs() -> void:
	var x := 640.0 - (TAB_W * 3 + TAB_GAP * 2) / 2.0
	for v in Settings.VERSIONS:
		var p := Style.panel(Color.WHITE, 12, 3, Color.WHITE)
		Style.place(p, x, TAB_Y, TAB_W, TAB_H)
		add_child(p)
		var name := Style.label(v, 24, Color.WHITE, 4, Color.BLACK, "button")
		name.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		Style.place(name, 0, 2, TAB_W, 30)
		p.add_child(name)
		var id := Style.label(String(Settings.GAMES[Settings.game]["versions"][v]), 14, Color.WHITE, 3)
		id.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		id.auto_translate_mode = Node.AUTO_TRANSLATE_MODE_DISABLED   # (the ID + tr("no copy"))
		Style.place(id, 0, 29, TAB_W, 18)
		p.add_child(id)
		_tabs.append({"version": v, "panel": p, "name": name, "id": id})
		x += TAB_W + TAB_GAP


func _paint_tabs() -> void:
	for t in _tabs:
		var on: bool = t["version"] == _version
		var owned := Settings.has_copy(Settings.game, t["version"])
		var bg: Color = Style.GOOD if on else Style.INK
		var sb: StyleBoxFlat = (t["panel"] as Panel).get_theme_stylebox("panel")
		sb.bg_color = bg
		sb.border_color = Color("#fff27a") if on else Style.INK_LINE
		(t["panel"] as Panel).modulate.a = 1.0 if on or owned else 0.55
		(t["id"] as Label).text = String(Settings.GAMES[Settings.game]["versions"][t["version"]]) \
				+ ("" if owned else "  ·  " + tr("no copy"))


func _show(version: String) -> void:
	_version = version
	_paint_tabs()
	var id := _id()
	if not _codes.has(id) and not _loading.get(id, false):
		_loading[id] = true
		if not Dolphin.query(Settings.list_gecko_args(id), _on_codes.bind(id)):
			_loading[id] = false
			_codes[id] = []
			app.toast("Couldn't start Dolphin-Sparking")
	list.set_rows(build_rows(), "custom")
	app.set_desc(current_desc())


func _on_codes(events: Array, id: String) -> void:
	_loading[id] = false
	_codes[id] = []
	for e in events:
		if e.get("event") == "gecko_codes":
			_codes[id] = e.get("codes", [])
	if is_inside_tree() and id == _id():
		list.set_rows(build_rows(), list.current_key())


func on_input(event: InputEvent) -> bool:
	if _dialog_open:
		return true
	var step := 0
	if event is InputEventJoypadButton and event.pressed:
		if event.button_index == JOY_BUTTON_LEFT_SHOULDER:
			step = -1
		elif event.button_index == JOY_BUTTON_RIGHT_SHOULDER:
			step = 1
	elif event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_Q:
			step = -1
		elif event.keycode == KEY_E:
			step = 1
	if step != 0:
		var i := Settings.VERSIONS.find(_version)
		Sfx.play("move")
		_show(Settings.VERSIONS[wrapi(i + step, 0, Settings.VERSIONS.size())])
		return true
	return super(event)


func build_rows() -> Array:
	var id := _id()
	var codes: Array = _codes.get(id, [])
	var custom := Settings.gecko_custom(id)
	var enabled := Settings.gecko_enabled(id)
	var rows: Array = [
		{"type": "toggle", "key": "custom", "label": "Code selection", "value": custom,
			"on_text": "Custom", "off_text": "Game defaults",
			"desc": tr("%s %s (%s). Game defaults: the codes this build turns on\nfor this version. Custom: exactly the codes ticked below.") % [
				Settings.GAMES[Settings.game]["short"], _version, id]},
	]
	if _loading.get(id, false) or not _codes.has(id):
		rows.append({"type": "info", "key": "loading", "label": "Loading codes...", "value": ""})
	elif codes.is_empty():
		rows.append({"type": "info", "key": "none", "label": "No codes for this version yet", "value": ""})
	for i in codes.size():
		var c: Dictionary = codes[i]
		var name := String(c.get("name", ""))
		var notes := _text(c.get("notes", "")).strip_edges()
		var by := _text(c.get("creator", "")).strip_edges()
		var desc := name
		if by != "":
			desc += tr("  (by %s)") % by
		if notes != "":
			desc += "\n" + notes.replace("\n", " ").left(110)
		if c.get("lobby_option", false):
			desc += "\n" + tr("Online: off unless the lobby's host switches it on for everyone.")
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
	var id := _id()
	var codes: Array = _codes.get(id, [])
	if key == "custom":
		var enabled := Settings.gecko_enabled(id)
		if value and enabled.is_empty():
			# Start the custom set from this version's defaults.
			for c in codes:
				if c.get("default_enabled", false):
					enabled.append(c["name"])
		Settings.set_gecko(id, bool(value), enabled)
		list.set_rows(build_rows(), "custom")
	elif key.begins_with("code:"):
		var picked: Dictionary = codes[int(key.substr(5))]
		var name: String = picked["name"]
		var enabled := Settings.gecko_enabled(id).duplicate()
		enabled.erase(name)
		if value:
			enabled.append(name)
			# Codes of the same exclusive group ([Sparking.Exclusive], e.g. the two dubs) go off.
			var group := String(picked.get("group", ""))
			if group != "":
				for c in codes:
					if String(c.get("group", "")) == group and c["name"] != name and c["name"] in enabled:
						enabled.erase(c["name"])
						app.toast(tr("%s switched off (can't be on with %s).") % [c["name"], name])
		Settings.set_gecko(id, Settings.gecko_custom(id), enabled)
		list.set_rows(build_rows(), key)
