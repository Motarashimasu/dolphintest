extends Control
## BT3-style menu wheel: the selected row sits on a colored band; neighbours shrink, slide left
## and fade; rows past `visible_range` are hidden. Wraps around. Up/Down move, Accept picks.
## Items: [{label, glyph, color (Color or "#hex"), desc, disabled?}]

signal changed(index: int)
signal activated(index: int)

const Style := preload("res://scripts/ui/style.gd")

const ROW_H := 60.0
const CENTER_Y := 152.0   # selected row's top inside the 860x400 box
const TWEEN_S := 0.22

var visible_range := 2
var fit_width := 0.0      # > 0: shrink labels wider than this (px at full size)
var row_gap := 64.0
var items: Array = []
var index := 0

var _band: Panel
var _band_box: StyleBox   # StyleBoxFlat, or StyleBoxTexture with the skin's band_image
var _band_prop := "bg_color" # what the color animates: bg_color, or modulate_color (image)
var _rows: Array[Control] = []
var _wheel_lock := 0
var _band_tween: Tween


func _init() -> void:
	size = Vector2(860, 400)
	mouse_filter = Control.MOUSE_FILTER_STOP
	clip_contents = false


func _ready() -> void:
	var band_tex := Style.BAND_IMAGE
	if band_tex:
		var sbt := StyleBoxTexture.new()
		sbt.texture = band_tex
		_band_box = sbt
		_band_prop = "modulate_color"
	else:
		var flat := Style.box(Color.WHITE)
		flat.border_width_top = Style.BAND_BORDER_WIDTH
		flat.border_width_bottom = Style.BAND_BORDER_WIDTH
		flat.border_color = Style.BAND_BORDER
		_band_box = flat
	_band = Panel.new()
	_band.add_theme_stylebox_override("panel", _band_box)
	_band.mouse_filter = Control.MOUSE_FILTER_IGNORE
	Style.place(_band, 0, CENTER_Y - 6, 860, 72)
	add_child(_band)
	_add_arrow(true)
	_add_arrow(false)
	if not items.is_empty():
		_build()


func set_items(new_items: Array, start := 0) -> void:
	items = new_items
	index = clampi(start, 0, max(items.size() - 1, 0))
	if is_inside_tree():
		_build()


func current() -> Dictionary:
	return items[index] if index < items.size() else {}


func move(step: int) -> void:
	if items.is_empty():
		return
	index = posmod(index + step, items.size())
	_layout(true)
	changed.emit(index)


func select(i: int) -> void:
	if i == index:
		return
	index = i
	_layout(true)
	changed.emit(index)


func activate() -> void:
	if not items.is_empty():
		activated.emit(index)


## Called by the screen with every unhandled input event; true = used.
func handle_input(event: InputEvent) -> bool:
	if event.is_action_pressed("ui_up", true):
		move(-1)
	elif event.is_action_pressed("ui_down", true):
		move(1)
	elif event.is_action_pressed("ui_accept"):
		activate()
	else:
		return false
	return true


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed:
		if event.button_index == MOUSE_BUTTON_WHEEL_UP or event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			var now := Time.get_ticks_msec()
			if now - _wheel_lock >= 160:
				_wheel_lock = now
				move(1 if event.button_index == MOUSE_BUTTON_WHEEL_DOWN else -1)
			accept_event()


func _color(item: Dictionary) -> Color:
	var c = item.get("color", Style.MUTED)
	return Style.item_color(String(item.get("label", "")), c if c is Color else Color(String(c)))


## The highlight band's color for the selected item (skin: band_color "item" or a color).
func _band_color(item: Dictionary) -> Color:
	var base := _color(item) if Style.BAND == "item" else Color(Style.BAND)
	if _band_prop == "modulate_color" and not Style.BAND_IMAGE_TINT:
		base = Color.WHITE
	return Color(base, Style.BAND_ALPHA)


func _build() -> void:
	for r in _rows:
		r.queue_free()
	_rows.clear()
	for i in items.size():
		var row := _make_row(items[i], i)
		add_child(row)
		_rows.append(row)
	_layout(false)


func _make_row(item: Dictionary, i: int) -> Control:
	var row := Control.new()
	row.size = Vector2(720, ROW_H)
	row.pivot_offset = Vector2(0, ROW_H / 2)
	row.mouse_filter = Control.MOUSE_FILTER_STOP
	row.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	row.gui_input.connect(_on_row_input.bind(i))

	var badge := Panel.new()
	badge.name = "Badge"
	badge.mouse_filter = Control.MOUSE_FILTER_IGNORE
	Style.place(badge, 12, 5, 50, 50)
	badge.visible = Style.BADGES
	row.add_child(badge)
	var glyph := Style.label(String(item.get("glyph", "")), 26, Color.BLACK, 0, Color.BLACK, "button")
	glyph.name = "Glyph"
	glyph.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	glyph.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	Style.place(glyph, 0, 0, 50, 50)
	badge.add_child(glyph)

	var text := Style.label(String(item.get("label", "")), Style.ITEM_SIZE, Style.IDLE_TEXT, 4, Style.IDLE_EDGE, "button")
	text.name = "Text"
	text.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	if fit_width > 0:
		var ls := text.label_settings
		var w := ls.font.get_string_size(text.text, HORIZONTAL_ALIGNMENT_LEFT, -1, ls.font_size).x
		if w > fit_width:
			ls.font_size = maxi(22, int(ls.font_size * fit_width / w))
	Style.place(text, 78 if Style.BADGES else 12, 0, 640, ROW_H)
	row.add_child(text)
	return row


func _on_row_input(event: InputEvent, i: int) -> void:
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		if i == index:
			activate()
		else:
			select(i)
		accept_event()


func _layout(animate: bool) -> void:
	var n := items.size()
	if n == 0:
		return
	var band_color := _band_color(items[index])
	if _band_tween and _band_tween.is_valid():
		_band_tween.kill()
	if animate:
		_band_tween = create_tween()
		_band_tween.tween_property(_band_box, _band_prop, band_color, TWEEN_S)
	else:
		_band_box.set(_band_prop, band_color)

	for i in n:
		var row := _rows[i]
		var item: Dictionary = items[i]
		# Signed distance from the selection, wrapped around the wheel.
		var d := posmod(i - index, n)
		if d > n / 2.0:
			d -= n
		var a := absi(d)
		var visible_row := a <= visible_range
		var is_sel := d == 0
		var s := 1.0 if is_sel else (0.84 if a == 1 else 0.72)
		var x := 120.0 if is_sel else 100.0 - a * 26.0
		var y := CENTER_Y + d * row_gap + (0.0 if is_sel else signf(d) * 6.0)
		var alpha := 0.0 if not visible_row else (0.55 if a >= 2 else 1.0)
		var shade := 0.75 if a >= 2 else 1.0
		var target_mod := Color(shade, shade, shade, alpha)
		row.z_index = 10 - a
		row.mouse_filter = Control.MOUSE_FILTER_STOP if visible_row else Control.MOUSE_FILTER_IGNORE
		# Rows jumping across the wrap point would fly through the band: snap those.
		var jump := absf(row.position.y - y) > row_gap * 2.5
		# A row still moving from the last step must not keep going after we re-place it.
		var running: Tween = row.get_meta("tween") if row.has_meta("tween") else null
		if running and running.is_valid():
			running.kill()
		if animate and not jump:
			var t := create_tween().set_parallel().set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
			row.set_meta("tween", t)
			t.tween_property(row, "position", Vector2(x, y), TWEEN_S)
			t.tween_property(row, "scale", Vector2(s, s), TWEEN_S)
			t.tween_property(row, "modulate", target_mod, TWEEN_S)
		else:
			row.position = Vector2(x, y)
			row.scale = Vector2(s, s)
			row.modulate = target_mod

		var color := _color(item)
		var disabled: bool = item.get("disabled", false)
		var badge: Panel = row.get_node("Badge")
		var glyph: Label = badge.get_node("Glyph")
		var text: Label = row.get_node("Text")
		badge.add_theme_stylebox_override("panel", Style.box(Style.DARK if is_sel else color, 25, 3,
				color if is_sel else Color.WHITE))
		glyph.label_settings.font_color = color if is_sel else Style.DARK
		var ls := text.label_settings
		if is_sel:
			ls.font_color = Style.SEL_TEXT.darkened(0.25) if disabled else Style.SEL_TEXT
			ls.outline_size = 6
			ls.outline_color = Style.SEL_EDGE
			ls.shadow_size = 6
			ls.shadow_color = Style.SEL_EDGE
			ls.shadow_offset = Vector2(0, 5)
		else:
			ls.font_color = Style.MUTED if disabled else Style.IDLE_TEXT
			ls.outline_size = 4
			ls.outline_color = Style.IDLE_EDGE
			ls.shadow_size = 0
			ls.shadow_offset = Vector2.ZERO


func _add_arrow(up: bool) -> void:
	var b := Button.new()
	b.flat = true
	b.focus_mode = Control.FOCUS_NONE
	b.text = "▲" if up else "▼"
	b.add_theme_font_size_override("font_size", 30)
	b.add_theme_color_override("font_color", Style.ARROW)
	b.add_theme_color_override("font_hover_color", Style.ARROW_HOVER)
	b.add_theme_color_override("font_outline_color", Style.TITLE_EDGE)
	b.add_theme_constant_override("outline_size", 8)
	Style.place(b, 400, 0 if up else 356, 64, 40)
	b.pressed.connect(move.bind(-1 if up else 1))
	add_child(b)
