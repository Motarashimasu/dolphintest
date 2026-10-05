extends Control
## A list of option rows driven by Up/Down (pick a row), Left/Right (change it), Accept (press /
## edit). Works with a controller, keyboard or mouse.
##
## Row dictionaries (`key` is required, everything else optional):
##   {type:"choice", key, label, values:[...], names:[...], value, desc}
##   {type:"toggle", key, label, value: bool, on_text, off_text, desc}
##   {type:"number", key, label, value, min, max, step, desc}
##   {type:"text",   key, label, value, placeholder, max_length, desc}
##   {type:"action", key, label, value (right-hand text), desc}
##   {type:"info",   key, label, value}           (not selectable)
## Every row may also carry `disabled: true` (shown dimmed, can't change) and `color`.

signal value_changed(key: String, value: Variant)
signal pressed(key: String)
signal focused(row: Dictionary)

const Style := preload("res://scripts/ui/style.gd")
const LinkIcon := preload("res://scripts/ui/link_icon.gd")

var row_height := 52.0
var row_gap := 6.0
var label_width := 0.42     # share of the width for the row name
var font_size := 24
var accent := Style.GOLD

var rows: Array = []
var index := -1
var _nodes: Array = []      # per row: {root, name, value, edit}
var _scroll := 0.0          # rows scroll when they don't fit


func _init() -> void:
	mouse_filter = Control.MOUSE_FILTER_PASS
	clip_contents = true


func set_rows(new_rows: Array, keep_key := "") -> void:
	var keep := keep_key if keep_key != "" else current_key()
	rows = new_rows
	_rebuild()
	index = -1
	for i in rows.size():
		if rows[i].get("key", "") == keep and _selectable(i):
			index = i
	if index < 0:
		index = _next_selectable(-1, 1)
	_refresh_all()
	_ensure_visible()
	if index >= 0:
		focused.emit(rows[index])


func current_key() -> String:
	return rows[index].get("key", "") if index >= 0 and index < rows.size() else ""


func row(key: String) -> Dictionary:
	for r in rows:
		if r.get("key", "") == key:
			return r
	return {}


func get_value(key: String) -> Variant:
	return row(key).get("value")


## Changes a row from code (no value_changed signal). Any other row field can be updated too.
func update_row(key: String, fields: Dictionary) -> void:
	for i in rows.size():
		if rows[i].get("key", "") == key:
			rows[i].merge(fields, true)
			if fields.has("value") and _nodes[i].edit and not _nodes[i].edit.has_focus():
				_nodes[i].edit.text = String(fields["value"])
			_refresh(i)
			if i == index:
				focused.emit(rows[i])
			if index == i and not _selectable(i):
				index = _next_selectable(i, 1)
				_refresh_all()


func focus_key(key: String) -> void:
	for i in rows.size():
		if rows[i].get("key", "") == key and _selectable(i):
			_set_index(i)


func is_editing() -> bool:
	for n in _nodes:
		if n.edit and n.edit.has_focus():
			return true
	return false


## Called with each unhandled input event; true = used.
func handle_input(event: InputEvent) -> bool:
	if index < 0:
		return false
	if event.is_action_pressed("ui_up", true):
		_set_index(_next_selectable(index, -1))
	elif event.is_action_pressed("ui_down", true):
		_set_index(_next_selectable(index, 1))
	elif event.is_action_pressed("ui_left", true):
		_step(index, -1)
	elif event.is_action_pressed("ui_right", true):
		_step(index, 1)
	elif event.is_action_pressed("ui_accept"):
		_press(index)
	else:
		return false
	return true


# --- internals ---------------------------------------------------------------------------

func _selectable(i: int) -> bool:
	return i >= 0 and i < rows.size() and rows[i].get("type", "action") != "info"


func _next_selectable(from: int, dir: int) -> int:
	var n := rows.size()
	for k in range(1, n + 1):
		var i := posmod(from + dir * k, n)
		if _selectable(i):
			return i
	return -1


func _set_index(i: int) -> void:
	if i < 0 or i == index:
		return
	var old := index
	index = i
	_refresh(old)
	_refresh(i)
	_ensure_visible()
	focused.emit(rows[i])


func _enabled(i: int) -> bool:
	return not rows[i].get("disabled", false)


func _step(i: int, dir: int) -> void:
	var r: Dictionary = rows[i]
	if not _enabled(i):
		return
	match r.get("type", "action"):
		"choice":
			var values: Array = r.get("values", [])
			if values.is_empty():
				return
			var at := values.find(r.get("value"))
			r["value"] = values[posmod(at + dir, values.size())]
		"toggle":
			r["value"] = not r.get("value", false)
		"number":
			var v: float = r.get("value", 0) + dir * r.get("step", 1)
			v = clampf(v, r.get("min", -INF), r.get("max", INF))
			if v == r.get("value"):
				return
			r["value"] = int(v) if typeof(r.get("step", 1)) == TYPE_INT else v
		_:
			return
	_refresh(i)
	value_changed.emit(r["key"], r["value"])


func _press(i: int) -> void:
	var r: Dictionary = rows[i]
	if not _enabled(i):
		return
	match r.get("type", "action"):
		"toggle", "choice":
			_step(i, 1)
		"text":
			var e: LineEdit = _nodes[i].edit
			e.grab_focus()
			e.caret_column = e.text.length()
		"action":
			pressed.emit(r["key"])


func _rebuild() -> void:
	for n in _nodes:
		n.root.queue_free()
	_nodes.clear()
	_scroll = 0.0
	for i in rows.size():
		var r: Dictionary = rows[i]
		var root := Panel.new()
		root.mouse_filter = Control.MOUSE_FILTER_STOP
		root.gui_input.connect(_on_row_input.bind(i))
		add_child(root)

		var name_l := Style.label(String(r.get("label", "")), font_size, Color.WHITE, 3, Style.DARK)
		name_l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		name_l.clip_text = true
		name_l.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		root.add_child(name_l)

		var value_l := Style.label("", font_size, Color.WHITE, 3, Style.DARK)
		value_l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		value_l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		value_l.clip_text = true
		value_l.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		root.add_child(value_l)

		var edit: LineEdit = null
		if r.get("type", "") == "text":
			edit = Style.line_edit(String(r.get("placeholder", "")), int(r.get("max_length", 0)))
			edit.text = String(r.get("value", ""))
			edit.text_submitted.connect(func(_t): edit.release_focus())
			edit.focus_exited.connect(_on_edit_done.bind(i))
			edit.focus_entered.connect(_set_index.bind(i))
			root.add_child(edit)
		# Optional connection icon at the right end ("icon": "wired" / "wireless" / ...).
		var icon: Control = null
		if r.has("icon"):
			icon = LinkIcon.new()
			icon.link = String(r["icon"])
			root.add_child(icon)
		_nodes.append({"root": root, "name": name_l, "value": value_l, "edit": edit, "icon": icon})
	_layout_rows()


func _notification(what: int) -> void:
	if what == NOTIFICATION_RESIZED:
		_layout_rows()


func _layout_rows() -> void:
	var w := size.x
	var lw := w * label_width
	var y := -_scroll
	for n in _nodes:
		Style.place(n.root, 0, y, w, row_height)
		y += row_height + row_gap
		Style.place(n.name, 18, 0, lw - 24, row_height)
		Style.place(n.value, lw, 0, w - lw - (56 if n.icon else 12), row_height)
		if n.icon:
			var s := row_height * 0.6
			Style.place(n.icon, w - 18 - s, (row_height - s) / 2, s, s)
		if n.edit:
			Style.place(n.edit, lw, 6, w - lw - 14, row_height - 12)


func _ensure_visible() -> void:
	if index < 0:
		return
	var step := row_height + row_gap
	var total := rows.size() * step - row_gap
	var top := index * step
	var old := _scroll
	if top < _scroll + step * 0.5:
		_scroll = top - step * 0.5
	elif top + row_height > _scroll + size.y - step * 0.5:
		_scroll = top + row_height - size.y + step * 0.5
	_scroll = clampf(_scroll, 0.0, maxf(total - size.y, 0.0))
	if _scroll != old:
		_layout_rows()


func _gui_input(event: InputEvent) -> void:
	# Mouse wheel over the gaps scrolls the selection.
	if event is InputEventMouseButton and event.pressed:
		if event.button_index == MOUSE_BUTTON_WHEEL_UP:
			_set_index(_next_selectable(index, -1))
			accept_event()
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			_set_index(_next_selectable(index, 1))
			accept_event()


func _on_edit_done(i: int) -> void:
	if i >= rows.size():
		return
	var r: Dictionary = rows[i]
	var text: String = _nodes[i].edit.text.strip_edges()
	_nodes[i].edit.text = text
	if text != String(r.get("value", "")):
		r["value"] = text
		value_changed.emit(r["key"], text)


func _on_row_input(event: InputEvent, i: int) -> void:
	if not (event is InputEventMouseButton and event.pressed):
		return
	if not _selectable(i):
		return
	var was := index == i
	_set_index(i)
	var r: Dictionary = rows[i]
	var t: String = r.get("type", "action")
	if event.button_index == MOUSE_BUTTON_LEFT:
		if t in ["choice", "number"]:
			# Left half of the value area = previous, right half = next.
			var mid: float = size.x * label_width + (size.x - size.x * label_width) / 2.0
			if event.position.x >= size.x * label_width:
				_step(i, -1 if event.position.x < mid else 1)
		elif t == "toggle" or t == "action" or (t == "text" and was):
			_press(i)
		elif t == "text":
			_press(i)
	elif event.button_index == MOUSE_BUTTON_WHEEL_UP and t in ["choice", "number"]:
		_step(i, 1)
	elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN and t in ["choice", "number"]:
		_step(i, -1)
	accept_event()


func _refresh_all() -> void:
	for i in rows.size():
		_refresh(i)


func _value_text(r: Dictionary) -> String:
	var v = r.get("value")
	match r.get("type", "action"):
		"choice":
			var values: Array = r.get("values", [])
			var names: Array = r.get("names", values)
			var at := values.find(v)
			return "◀   %s   ▶" % (String(names[at]) if at >= 0 and at < names.size() else str(v))
		"toggle":
			return "◀   %s   ▶" % (r.get("on_text", "On") if v else r.get("off_text", "Off"))
		"number":
			return "◀   %s   ▶" % str(v)
		"text":
			return ""
	return "" if v == null else String(str(v))


func _refresh(i: int) -> void:
	if i < 0 or i >= rows.size() or i >= _nodes.size():
		return
	var r: Dictionary = rows[i]
	var n: Dictionary = _nodes[i]
	var sel := i == index
	var enabled := _enabled(i)
	var info: bool = r.get("type", "action") == "info"
	var c = r.get("color", null)
	var sel_bg: Color = Style.ROW_SEL if c == null else Color(c if c is Color else Color(String(c)), Style.ROW_SEL.a)
	var bg := sel_bg if sel else (Color(0, 0, 0, 0.12) if info else Style.ROW)
	var sb := Style.box(bg, Style.ROW_RADIUS, 3 if sel else 0, Style.ROW_SEL_BORDER)
	n.root.add_theme_stylebox_override("panel", sb)
	n.name.text = String(r.get("label", ""))
	n.value.text = _value_text(r)
	var dim := 1.0 if enabled else 0.5
	n.root.modulate = Color(1, 1, 1, dim)
	if r.get("type", "") == "action" and r.get("value", null) == null:
		n.name.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	n.name.label_settings.font_color = Style.ROW_SEL_TEXT if sel else Style.ROW_TEXT
	n.name.label_settings.outline_color = Style.SEL_EDGE if sel else Style.DARK
	n.value.label_settings.outline_color = Style.SEL_EDGE if sel else Style.DARK
	n.value.label_settings.font_color = Style.ROW_SEL_TEXT if sel else Style.ROW_TEXT
	if n.edit:
		n.edit.editable = enabled
