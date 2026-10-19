extends "res://scripts/screens/screen.gd"
## Profile picture cropper: the picked image with a square frame over it. Move the frame where
## you want it and make it bigger / smaller; the preview shows what you'll get (Pictures.SIZE
## square, what the server takes). A / Enter tears it off and hands it to `done`.
##   Move: stick, D-pad, arrow keys / WASD, or drag with the mouse
##   Size: LB / RB, Q / E, - / +, or the mouse wheel

const Pictures := preload("res://scripts/pictures.gd")
const AREA := Rect2(70, 130, 640, 380)    # where the image is shown (fitted)
const PREVIEW := Rect2(830, 150, 256, 256)
const MIN_CROP := 24.0                      # source pixels: the smallest frame

var _src: Image
var _done: Callable
var _shown := Rect2()        # where the image is drawn on screen
var _scale := 1.0            # screen pixels per source pixel
var _crop := Rect2()         # the frame, in source pixels (square)
var _overlay: Control
var _preview: TextureRect
var _dirty := true
var _dragging := false
var _tearing := false


## `img`: the picked image. `done.call(result: Image)` gets the Pictures.SIZE square.
func setup(img: Image, done: Callable) -> Node:
	_src = img
	if _src.is_compressed():
		_src.decompress()
	_src.convert(Image.FORMAT_RGBA8)
	_done = done
	return self


func screen_title() -> String:
	return "Profile Picture"


func screen_music() -> String:
	return "netplay"


func screen_desc() -> String:
	return tr("Move the frame and size it to what you want in your picture.\nThe preview shows it as everyone will see it (%d x %d).") % [Pictures.SIZE, Pictures.SIZE]


func screen_hints() -> Array:
	return [["◀▲▼▶", Style.INK_LINE, "Move"], ["LB RB", Style.INK_LINE, "Size"],
			["A", Style.GOOD, "Tear off"], ["B", Style.POOR, "Cancel"]]


func on_enter() -> void:
	var w := float(_src.get_width())
	var h := float(_src.get_height())
	_scale = minf(AREA.size.x / w, AREA.size.y / h)
	var sz := Vector2(w, h) * _scale
	_shown = Rect2(AREA.position + (AREA.size - sz) / 2.0, sz)
	var side := minf(w, h)
	_crop = Rect2((w - side) / 2.0, (h - side) / 2.0, side, side)

	add_form_panel(AREA.position.x - 20, AREA.position.y - 20, AREA.size.x + 40, AREA.size.y + 40)
	var tex := TextureRect.new()
	tex.texture = ImageTexture.create_from_image(_src)
	tex.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	tex.stretch_mode = TextureRect.STRETCH_SCALE
	tex.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
	tex.mouse_filter = Control.MOUSE_FILTER_IGNORE
	Style.place(tex, _shown.position.x, _shown.position.y, _shown.size.x, _shown.size.y)
	add_child(tex)
	_overlay = Control.new()
	_overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_overlay.draw.connect(_draw_frame)
	Style.place(_overlay, 0, 0, 1280, 720)
	add_child(_overlay)

	add_form_panel(PREVIEW.position.x - 20, PREVIEW.position.y - 20, PREVIEW.size.x + 40, PREVIEW.size.y + 40)
	_preview = TextureRect.new()
	_preview.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_preview.stretch_mode = TextureRect.STRETCH_SCALE
	_preview.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_preview.pivot_offset = PREVIEW.size / 2.0
	Style.place(_preview, PREVIEW.position.x, PREVIEW.position.y, PREVIEW.size.x, PREVIEW.size.y)
	add_child(_preview)
	var cap := Style.label(tr("Preview"), 22, Color.WHITE, 3, Style.DARK, "button")
	cap.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	Style.place(cap, PREVIEW.position.x, PREVIEW.end.y + 24, PREVIEW.size.x, 30)
	add_child(cap)
	var size_l := Style.label(tr("Picture: %d x %d") % [_src.get_width(), _src.get_height()], 18, Style.INK_LINE, 0, Color.BLACK)
	size_l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	Style.place(size_l, PREVIEW.position.x - 20, PREVIEW.end.y + 58, PREVIEW.size.x + 40, 26)
	add_child(size_l)
	_refresh()


## The finished picture: the frame's part of the image, at Pictures.SIZE square.
func result() -> Image:
	var r := Rect2i(_crop.position.round(), Vector2i(roundi(_crop.size.x), roundi(_crop.size.x)))
	r.position.x = clampi(r.position.x, 0, _src.get_width() - r.size.x)
	r.position.y = clampi(r.position.y, 0, _src.get_height() - r.size.y)
	var out := _src.get_region(r)
	out.resize(Pictures.SIZE, Pictures.SIZE, Image.INTERPOLATE_LANCZOS)
	return out


## Moves the frame by `d` source pixels and resizes it by `grow` (keeps its centre), inside the image.
func nudge(d: Vector2, grow := 0.0) -> void:
	var w := float(_src.get_width())
	var h := float(_src.get_height())
	var side := clampf(_crop.size.x + grow, minf(MIN_CROP, minf(w, h)), minf(w, h))
	var centre := _crop.get_center() + d
	var pos := centre - Vector2(side, side) / 2.0
	pos.x = clampf(pos.x, 0.0, w - side)
	pos.y = clampf(pos.y, 0.0, h - side)
	var new_crop := Rect2(pos, Vector2(side, side))
	if new_crop != _crop:
		_crop = new_crop
		_dirty = true


func _process(delta: float) -> void:
	if _tearing or app == null or app.top() != self:
		return
	var move := Input.get_vector("ui_left", "ui_right", "ui_up", "ui_down")
	for pad in Input.get_connected_joypads():
		var stick := Vector2(Input.get_joy_axis(pad, JOY_AXIS_LEFT_X), Input.get_joy_axis(pad, JOY_AXIS_LEFT_Y))
		if stick.length() > 0.25:
			move += stick
	if Input.is_physical_key_pressed(KEY_A):
		move.x -= 1
	if Input.is_physical_key_pressed(KEY_D):
		move.x += 1
	if Input.is_physical_key_pressed(KEY_W):
		move.y -= 1
	if Input.is_physical_key_pressed(KEY_S):
		move.y += 1
	var grow := 0.0
	for pad in Input.get_connected_joypads():
		if Input.is_joy_button_pressed(pad, JOY_BUTTON_LEFT_SHOULDER):
			grow -= 1
		if Input.is_joy_button_pressed(pad, JOY_BUTTON_RIGHT_SHOULDER):
			grow += 1
	if Input.is_physical_key_pressed(KEY_Q) or Input.is_physical_key_pressed(KEY_MINUS):
		grow -= 1
	if Input.is_physical_key_pressed(KEY_E) or Input.is_physical_key_pressed(KEY_EQUAL):
		grow += 1
	if move != Vector2.ZERO or grow != 0.0:
		# About a third of the image per second, whatever its size.
		var speed := minf(_src.get_width(), _src.get_height()) * 0.35 * delta
		nudge(move.limit_length(1.0) * speed, grow * speed)
	if _dirty:
		_refresh()


# Mouse: drag the frame, wheel to size it. (Before Main's _input, which drops mouse events.)
func _input(event: InputEvent) -> void:
	if _tearing or app == null or app.top() != self:
		return
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_LEFT:
			_dragging = event.pressed and _shown.has_point(event.position)
		elif event.pressed and event.button_index in [MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN]:
			var step := _crop.size.x * 0.08 * (-1.0 if event.button_index == MOUSE_BUTTON_WHEEL_UP else 1.0)
			nudge(Vector2.ZERO, step)
		get_viewport().set_input_as_handled()
	elif event is InputEventMouseMotion and _dragging:
		nudge(event.relative / _scale)
		get_viewport().set_input_as_handled()
	if _dirty:
		_refresh()


func on_input(event: InputEvent) -> bool:
	if _tearing:
		return true
	if event.is_action_pressed("ui_accept"):
		_tear_off()
		return true
	# Moving / sizing is read every frame (_process); eat the presses so nothing else moves.
	for a in ["ui_left", "ui_right", "ui_up", "ui_down"]:
		if event.is_action(a):
			return true
	return false


func _refresh() -> void:
	_dirty = false
	if _preview:
		_preview.texture = ImageTexture.create_from_image(result())
	if _overlay:
		_overlay.queue_redraw()


func _draw_frame() -> void:
	var f := Rect2(_shown.position + _crop.position * _scale, _crop.size * _scale)
	var dim := Color(0, 0, 0, 0.6)
	# Darken what's cut away.
	_overlay.draw_rect(Rect2(_shown.position, Vector2(_shown.size.x, f.position.y - _shown.position.y)), dim)
	_overlay.draw_rect(Rect2(Vector2(_shown.position.x, f.end.y), Vector2(_shown.size.x, _shown.end.y - f.end.y)), dim)
	_overlay.draw_rect(Rect2(Vector2(_shown.position.x, f.position.y), Vector2(f.position.x - _shown.position.x, f.size.y)), dim)
	_overlay.draw_rect(Rect2(Vector2(f.end.x, f.position.y), Vector2(_shown.end.x - f.end.x, f.size.y)), dim)
	# Dashed "tear here" border, thirds, and corner handles.
	var gold := Color("#f2b531")
	var corners := [f.position, Vector2(f.end.x, f.position.y), f.end, Vector2(f.position.x, f.end.y)]
	for i in 4:
		_overlay.draw_dashed_line(corners[i], corners[(i + 1) % 4], Color.WHITE, 2.0, 8.0)
	for t in [1.0 / 3.0, 2.0 / 3.0]:
		_overlay.draw_line(Vector2(f.position.x + f.size.x * t, f.position.y), Vector2(f.position.x + f.size.x * t, f.end.y), Color(1, 1, 1, 0.25), 1.0)
		_overlay.draw_line(Vector2(f.position.x, f.position.y + f.size.y * t), Vector2(f.end.x, f.position.y + f.size.y * t), Color(1, 1, 1, 0.25), 1.0)
	var k := minf(18.0, f.size.x * 0.25)
	for c in corners:
		var sx := 1.0 if c.x == f.position.x else -1.0
		var sy := 1.0 if c.y == f.position.y else -1.0
		_overlay.draw_line(c, c + Vector2(k * sx, 0), gold, 4.0)
		_overlay.draw_line(c, c + Vector2(0, k * sy), gold, 4.0)


## The cut: the preview lifts off like a torn sticker, then the picture goes to `done`.
func _tear_off() -> void:
	_tearing = true
	Sfx.play("select")
	var img := result()
	var tw := create_tween()
	tw.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	tw.tween_property(_preview, "rotation_degrees", -6.0, 0.18)
	tw.parallel().tween_property(_preview, "scale", Vector2(1.08, 1.08), 0.18)
	tw.tween_property(_preview, "rotation_degrees", 0.0, 0.14)
	tw.parallel().tween_property(_preview, "scale", Vector2(1.0, 1.0), 0.14)
	tw.tween_interval(0.12)
	await tw.finished
	if not is_inside_tree():
		return
	var done := _done
	app.pop()
	if done.is_valid():
		done.call(img)
