extends Control
## The ranked rating "bumper" (like the game's Fighting Points plate): slides in from the right
## while the Ranked Match item is selected and the player is logged in, and back out otherwise.
## A big plate for Single Battle FT2 and a smaller one for Team Battle, staggered.

const Style := preload("res://scripts/ui/style.gd")

const SCREEN_W := 1280.0
const OVERHANG := 40.0      # the square end runs this far past the right edge of the screen
const OFF_X := 1300.0       # fully off the right edge
const SLIDE := 0.28

var _plates: Array[Control] = []
var _values: Array[Label] = []
var _shown := false
var _tween: Tween


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	# Width includes the overhang: the visible part is OVERHANG narrower.
	_plates.append(_plate(Vector2(480, 104), 136, "Single Battle", 30, 58))
	_plates.append(_plate(Vector2(370, 74), 252, "Team Battle", 22, 40))
	for p in _plates:
		p.position.x = OFF_X
		p.modulate.a = 0.0
	Ranked.changed.connect(refresh)
	refresh()


## Builds one plate: dark-teal body with a light-green rim, a lighter header band with the title,
## and the number in gold with a dark outline, right-aligned.
func _plate(size: Vector2, y: float, title: String, title_size: int, value_size: int) -> Control:
	var plate := Panel.new()
	plate.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var body := Style.box(Color("#0e4a66"), 0, 4, Color("#8ff0b4"))
	# Rounded end on the left; the square end sits past the right edge of the screen.
	body.corner_radius_top_left = int(size.y / 2)
	body.corner_radius_bottom_left = int(size.y / 2)
	body.corner_radius_top_right = 0
	body.corner_radius_bottom_right = 0
	body.shadow_color = Color(0, 0, 0, 0.45)
	body.shadow_size = 10
	body.shadow_offset = Vector2(0, 5)
	plate.add_theme_stylebox_override("panel", body)
	plate.clip_children = CanvasItem.CLIP_CHILDREN_AND_DRAW
	plate.position = Vector2(OFF_X, y)
	plate.size = size
	add_child(plate)

	# Vertical sheen: lighter teal at the top, deep blue at the bottom.
	var grad := Gradient.new()
	grad.set_color(0, Color("#2fa6c4"))
	grad.set_color(1, Color("#0a2f4f"))
	var tex := GradientTexture2D.new()
	tex.gradient = grad
	tex.fill_from = Vector2(0, 0)
	tex.fill_to = Vector2(0, 1)
	var sheen := TextureRect.new()
	sheen.texture = tex
	sheen.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	sheen.stretch_mode = TextureRect.STRETCH_SCALE
	sheen.mouse_filter = Control.MOUSE_FILTER_IGNORE
	sheen.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	plate.add_child(sheen)

	# Header band across the top, like the "Fighting Points" strip.
	var band := Style.panel(Color(0.55, 0.95, 1.0, 0.22), 0)
	Style.place(band, 0, 0, size.x, size.y * 0.42)
	plate.add_child(band)
	var head := Style.label(title, title_size, Color("#fff1c4"), 6, Color("#8a3b06"), true)
	head.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	Style.place(head, size.y * 0.42, 0, size.x - size.y * 0.42 - OVERHANG - 20, size.y * 0.44)
	plate.add_child(head)

	var value := Style.label("", value_size, Color("#ffb52e"), 9, Color("#4a1a00"), true, 3)
	value.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	value.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	Style.place(value, size.y * 0.42, size.y * 0.30, size.x - size.y * 0.42 - OVERHANG - 24, size.y * 0.72)
	plate.add_child(value)
	_values.append(value)

	# The light-green rim on top of everything (the sheen would cover the body's border).
	var rim := Panel.new()
	rim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var rb := body.duplicate() as StyleBoxFlat
	rb.bg_color = Color(0, 0, 0, 0)
	rb.shadow_size = 0
	rim.add_theme_stylebox_override("panel", rb)
	rim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	plate.add_child(rim)
	return plate


## Selected item changed (or the profile did): in or out.
func set_shown(on: bool) -> void:
	on = on and Ranked.logged_in()
	if on == _shown:
		return
	_shown = on
	if on:
		refresh()
		if Ranked.profile.is_empty():
			Ranked.refresh()   # fills the numbers in when it answers (Ranked.changed)
	if _tween and _tween.is_valid():
		_tween.kill()
	_tween = create_tween().set_parallel(true).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	for i in _plates.size():
		var p := _plates[i]
		var delay := 0.07 * i if on else 0.0
		_tween.tween_property(p, "position:x", SCREEN_W + OVERHANG - p.size.x if on else OFF_X, SLIDE).set_delay(delay)
		_tween.tween_property(p, "modulate:a", 1.0 if on else 0.0, SLIDE * 0.8).set_delay(delay)


func is_shown() -> bool:
	return _shown


## Numbers from the profile; the last known ones until the server answers.
func refresh() -> void:
	if not is_inside_tree():
		return
	for i in 2:
		var mode := "single" if i == 0 else "team"
		var r := Ranked.rating(mode) if not Ranked.profile.is_empty() \
				else int(Settings.get_value("ranked", "last_" + mode))
		_values[i].text = str(r) if r > 0 else "----"
	if _shown and not Ranked.logged_in():
		set_shown(false)
