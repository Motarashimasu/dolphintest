extends Control
## BT3-style menu wheel: every row has its own bar (look: row_bar); the selected one lights up
## with the highlight (selected_bar), which sweeps in, gently pulses and travels with its row;
## neighbours shrink, slide left and fade; rows past `visible_range` are hidden. Wraps around. Up/Down move, Accept picks.
## Items: [{label, glyph, color (Color or "#hex"), desc, disabled?}]

signal changed(index: int)
signal activated(index: int)

const Style := preload("res://scripts/ui/style.gd")

const ROW_H := 60.0
const CENTER_Y := 152.0   # selected row's top inside the 860x400 box
const TWEEN_S := 0.22
const SEL_X := 120.0       # the selected row's x
const HI_IN_S := 0.2       # highlight sweeping in ...
const HI_OUT_S := 0.12     # ... and out (quick, so fast scrolling leaves no trail)
const PULSE_S := 0.9       # one half of the highlight's glow pulse
const SQUISH_S := 0.55     # one half of the selected text's soft squish
const SQUISH := Vector2(1.025, 0.93)   # at its softest: a touch wider, a little shorter

var visible_range := 2
var fit_width := 0.0      # > 0: shrink labels wider than this (px at full size)
var row_gap := 64.0
var items: Array = []
var index := 0

var _rows: Array[Control] = []
var _wheel_lock := 0


func _init() -> void:
	size = Vector2(860, 400)
	mouse_filter = Control.MOUSE_FILTER_STOP
	clip_contents = false


func _ready() -> void:
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
		Sfx.play("move")
	elif event.is_action_pressed("ui_down", true):
		move(1)
		Sfx.play("move")
	elif event.is_action_pressed("ui_accept"):
		if not items.is_empty() and not current().get("disabled", false):
			Sfx.play("back" if current().get("back", false) else "select")
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


static func _bar(tex: Texture2D) -> TextureRect:
	var r := TextureRect.new()
	r.texture = tex
	r.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	r.stretch_mode = TextureRect.STRETCH_SCALE
	r.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return r


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

	# The highlight: from the wheel's left edge (the row sits at SEL_X when selected), behind the
	# row's bar, badge and text. Hidden unless this row is the selected one.
	var hi := _bar(Style.SEL_BAR)
	hi.name = "Highlight"
	Style.place(hi, -SEL_X, (ROW_H - Style.SEL_BAR_SIZE.y) / 2, Style.SEL_BAR_SIZE.x, Style.SEL_BAR_SIZE.y)
	hi.pivot_offset = Vector2(0, Style.SEL_BAR_SIZE.y / 2)
	hi.modulate.a = 0.0
	row.add_child(hi)
	# The row's own bar (fades out while the row is highlighted).
	var bar := _bar(Style.ROW_BAR)
	bar.name = "Bar"
	Style.place(bar, 0, (ROW_H - Style.ROW_BAR_SIZE.y) / 2, Style.ROW_BAR_SIZE.x, Style.ROW_BAR_SIZE.y)
	row.add_child(bar)
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
		var x := SEL_X if is_sel else 100.0 - a * 26.0
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
			t.tween_property(row.get_node("Bar"), "modulate:a", 0.0 if is_sel else 1.0, TWEEN_S)
		else:
			row.position = Vector2(x, y)
			row.scale = Vector2(s, s)
			row.modulate = target_mod
			row.get_node("Bar").modulate.a = 0.0 if is_sel else 1.0
		_highlight(row, is_sel, animate)

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


## Lights a row up (sweeps in from the left, then pulses) or lets it go (quick fade).
func _highlight(row: Control, on: bool, animate: bool) -> void:
	var hi: TextureRect = row.get_node("Highlight")
	var was_on: bool = row.get_meta("lit", false)
	if was_on == on and animate:
		return
	row.set_meta("lit", on)
	for key in ["hi_tween", "hi_pulse"]:
		var running: Tween = row.get_meta(key) if row.has_meta(key) else null
		if running and running.is_valid():
			running.kill()
	hi.self_modulate = Color.WHITE
	_squish(row, on)
	if not on:
		if animate:
			var t := create_tween()
			row.set_meta("hi_tween", t)
			t.tween_property(hi, "modulate:a", 0.0, HI_OUT_S)
		else:
			hi.modulate.a = 0.0
		return
	if animate:
		hi.modulate.a = 0.0
		hi.scale = Vector2(0.55, 1.0)
		var t := create_tween().set_parallel()
		row.set_meta("hi_tween", t)
		t.tween_property(hi, "modulate:a", 1.0, HI_IN_S)
		t.tween_property(hi, "scale:x", 1.0, HI_IN_S).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
		t.finished.connect(_pulse.bind(row))
	else:
		hi.modulate.a = 1.0
		hi.scale = Vector2.ONE
		_pulse(row)


## The selected item's text gently squishes and springs back while it stays selected.
func _squish(row: Control, on: bool) -> void:
	var text: Label = row.get_node("Text")
	var running: Tween = row.get_meta("squish") if row.has_meta("squish") else null
	if running and running.is_valid():
		running.kill()
	text.pivot_offset = Vector2(0, ROW_H / 2)
	if not on:
		var back := create_tween()
		row.set_meta("squish", back)
		back.tween_property(text, "scale", Vector2.ONE, 0.12)
		return
	var t := create_tween().set_loops().set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	row.set_meta("squish", t)
	t.tween_property(text, "scale", SQUISH, SQUISH_S)
	t.tween_property(text, "scale", Vector2.ONE, SQUISH_S)


## A soft glow pulse while the row stays selected.
func _pulse(row: Control) -> void:
	if not is_instance_valid(row) or not row.get_meta("lit", false):
		return
	var hi: TextureRect = row.get_node("Highlight")
	var p := create_tween().set_loops().set_trans(Tween.TRANS_SINE)
	row.set_meta("hi_pulse", p)
	p.tween_property(hi, "self_modulate", Color(1.12, 1.12, 1.08), PULSE_S)
	p.tween_property(hi, "self_modulate", Color.WHITE, PULSE_S)


func _add_arrow(up: bool) -> void:
	var b := TextureButton.new()
	b.focus_mode = Control.FOCUS_NONE
	b.texture_normal = Style.look_texture("arrow_up" if up else "arrow_down", "arrow_up.png" if up else "arrow_down.png")
	b.ignore_texture_size = true
	b.stretch_mode = TextureButton.STRETCH_KEEP_ASPECT_CENTERED
	b.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	b.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	Style.place(b, 408, 0 if up else 358, 48, 40)
	b.mouse_entered.connect(func(): b.modulate = Color(1.15, 1.15, 1.15))
	b.mouse_exited.connect(func(): b.modulate = Color.WHITE)
	b.pressed.connect(move.bind(-1 if up else 1))
	add_child(b)
