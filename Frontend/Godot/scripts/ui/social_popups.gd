extends Control
## DRAGON NET pop-ups over the menus (scripts/social.gd):
##   - "<friend> is online": a green bar sliding in from the right, centre right of the screen,
##     with a character sprite at its end (picked at random from look/online/*.png); a quarter
##     of the screen at most; leaves by itself. One at a time, the rest queued (a few).
##   - Admin messages: the striped teal box (look/popup_box.png, as for "Receiving Ranking
##     Data...") in the middle of the screen, until the player closes it with a button. Once per
##     message: closing it tells the server.
## Nothing shows while a game runs, over the in-game menu or the splash: it waits until then.

const Style := preload("res://scripts/ui/style.gd")
const SPRITES_DIR := "res://look/online"
const SPRITES := ["krillin", "goku", "piccolo"]

const TOAST_W := 320.0     # a quarter of the 1280 x 720 screen
const TOAST_H := 150.0
const BAR_H := 58.0
const SPRITE_SIZE := 150.0
const HOLD := 3.6
const MAX_QUEUE := 4

var app: Node
var _toasts: Array = []          # names waiting
var _toast: Control = null       # the one on screen
var _messages: Array = []        # [{id, text}] waiting
var _box: Control = null         # the message on screen
var _box_id := -1
var _sprites: Array = []
var _toast_layer: Control        # the online bars
var _message_layer: Control      # messages, above the bars


func _ready() -> void:
	# (The overlay it sits in has no size of its own: the whole 1280 x 720 menu space.)
	position = Vector2.ZERO
	size = Vector2(1280, 720)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	for layer in ["_toast_layer", "_message_layer"]:
		var c := Control.new()
		c.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		c.mouse_filter = Control.MOUSE_FILTER_IGNORE
		add_child(c)
		set(layer, c)
	for n in SPRITES:
		var path := SPRITES_DIR.path_join(n + ".png")
		if ResourceLoader.exists(path):
			_sprites.append(load(path))
	Social.friend_online.connect(_on_friend_online)
	Social.message.connect(func(id: int, text: String): _messages.append({"id": id, "text": text}))


func _on_friend_online(friend: String) -> void:
	if _toasts.size() < MAX_QUEUE:
		_toasts.append(friend)


## Menus on screen: not in a game, not the in-game menu, not the splash.
func _can_show() -> bool:
	if app == null:
		return false
	return not Dolphin.in_game and not app.is_splash_showing() and not app.is_ingame_menu_open() \
			and get_window().mode != Window.MODE_MINIMIZED


func _process(_delta: float) -> void:
	if not _can_show():
		return
	if _box == null and not _messages.is_empty():
		_show_message(_messages.pop_front())
	if _toast == null and not _toasts.is_empty():
		_show_toast(_toasts.pop_front())


# --- "X is online" -----------------------------------------------------------------------------

func _show_toast(friend: String) -> void:
	var t := Control.new()
	t.mouse_filter = Control.MOUSE_FILTER_IGNORE
	t.size = Vector2(TOAST_W, TOAST_H)
	var y := 360.0 - TOAST_H / 2.0 - 40.0   # centre right, a bit above the middle
	t.position = Vector2(1280.0, y)
	_toast_layer.add_child(t)
	_toast = t
	# The green bar along the bottom, the sprite standing on its right end.
	var bar := Panel.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color("#2fae5a")
	sb.border_color = Color("#bff5c9")
	sb.set_border_width_all(3)
	sb.corner_radius_top_left = 14
	sb.corner_radius_bottom_left = 14
	sb.shadow_color = Color(0, 0, 0, 0.35)
	sb.shadow_size = 6
	bar.add_theme_stylebox_override("panel", sb)
	bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	Style.place(bar, 0, TOAST_H - BAR_H, TOAST_W + 20, BAR_H)   # (runs off the right edge)
	t.add_child(bar)
	var shine := ColorRect.new()
	shine.color = Color(1, 1, 1, 0.18)
	shine.mouse_filter = Control.MOUSE_FILTER_IGNORE
	Style.place(shine, 6, 5, TOAST_W - 6, BAR_H * 0.38)
	bar.add_child(shine)
	var name_l := Style.label(friend, 24, Color.WHITE, 5, Color("#0b4a22"), "button")
	name_l.clip_text = true
	name_l.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	Style.place(name_l, 16, 2, TOAST_W - SPRITE_SIZE * 0.62 - 16, 30)
	bar.add_child(name_l)
	var sub := Style.label(tr("is online!"), 17, Color("#eaffef"), 3, Color("#0b4a22"))
	Style.place(sub, 16, 30, TOAST_W - SPRITE_SIZE * 0.62 - 16, 24)
	bar.add_child(sub)
	if not _sprites.is_empty():
		var pic := TextureRect.new()
		pic.texture = _sprites[randi() % _sprites.size()]
		pic.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		pic.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		pic.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
		pic.mouse_filter = Control.MOUSE_FILTER_IGNORE
		Style.place(pic, TOAST_W - SPRITE_SIZE + 6, 0, SPRITE_SIZE, SPRITE_SIZE)
		t.add_child(pic)
	Sfx.play("player_join")
	var tw := create_tween()
	tw.tween_property(t, "position:x", 1280.0 - TOAST_W, 0.42).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	tw.tween_interval(HOLD)
	tw.tween_property(t, "position:x", 1300.0, 0.3).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN)
	tw.tween_callback(func():
		t.queue_free()
		if _toast == t:
			_toast = null)


# --- Admin messages ----------------------------------------------------------------------------

func has_message_open() -> bool:
	return _box != null


func _show_message(m: Dictionary) -> void:
	_box_id = int(m["id"])
	var root := Control.new()
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_STOP
	_message_layer.add_child(root)
	_box = root
	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.45)
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.add_child(dim)
	var frame := Control.new()
	Style.place(frame, 230, 170, 820, 330)
	root.add_child(frame)
	var box := Style.popup_box()
	box.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	frame.add_child(box)
	var title := Style.label(tr("Message from DRAGON NET"), 22, Color("#fff27a"), 5, Color("#06302f"), "button")
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	Style.place(title, 60, 34, 700, 30)
	frame.add_child(title)
	var text := Style.label(String(m["text"]), 26, Color.WHITE, 6, Color("#06302f"), "button")
	text.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	text.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	text.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	text.auto_translate_mode = Node.AUTO_TRANSLATE_MODE_DISABLED   # (the admin's own words)
	Style.place(text, 70, 72, 680, 190)
	frame.add_child(text)
	# Shrink long messages until they fit.
	var size := 26
	while size > 16 and text.label_settings.font.get_multiline_string_size(text.text,
			HORIZONTAL_ALIGNMENT_CENTER, 680, size).y > 190:
		size -= 1
	text.label_settings.font_size = size
	var p: Dictionary = Pad.prompt("accept")
	var ok := HBoxContainer.new()
	ok.alignment = BoxContainer.ALIGNMENT_CENTER
	ok.add_theme_constant_override("separation", 10)
	Style.place(ok, 60, 268, 700, 36)
	frame.add_child(ok)
	var badge := Style.panel(p["color"], 16)
	badge.custom_minimum_size = Vector2(maxf(34, 16 + 10 * String(p["key"]).length()), 32)
	var k := Style.label(String(p["key"]), 15, Style.INK, 0, Color.BLACK, "button")
	k.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	k.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	k.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	badge.add_child(k)
	ok.add_child(badge)
	ok.add_child(Style.label(tr("OK"), 22, Color.WHITE, 4, Color("#06302f"), "button"))
	root.modulate.a = 0.0
	create_tween().tween_property(root, "modulate:a", 1.0, 0.18)
	Sfx.play("message")


## Main sends every input here while a message is open: A / B / Enter / Esc close it.
func handle_input(event: InputEvent) -> void:
	if _box == null:
		return
	if event.is_action_pressed("ui_accept") or event.is_action_pressed("ui_cancel"):
		Sfx.play("select")
		var id := _box_id
		_box.queue_free()
		_box = null
		_box_id = -1
		Social.close_message(id)
