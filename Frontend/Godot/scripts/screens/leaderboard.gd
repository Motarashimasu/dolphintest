extends "res://scripts/screens/screen.gd"
## Ranked Match > Leaderboard, in the style of the game's "View Ranking" screen: a teal selector
## pill for the board (Single Battle FT2 / Team Battle / All-time record) and one for the region
## (Global or where the ranked lobby was hosted), three big purple ranking cards over a radar
## ring, orange scroll chevrons, your own entry pinned at the bottom, and the blue "Receiving
## Ranking Data..." popup (the striped teal box) while it loads.
##
## Controls: ▲▼ move between the board pill, the region pill and the list (and scroll it);
## ◀▶ change the focused pill (on the list: the board); A on the list opens the website.

const MODES := ["single", "team", "all"]
const MODE_NAMES := ["Single Battle FT2", "Team Battle", "All-time record"]

const CARD_X := 110.0
const CARD_W := 1060.0
const CARD_H := 86.0
const CARD_GAP := 8.0
const LIST_Y := 178.0
const VISIBLE := 3

const PURPLE := Color("#4b2f86")
const PURPLE_EDGE := Color("#b9a6ff")
const GOLD_EDGE := Color("#ffd24a")
const TEAL := Color("#1aa3a8")
const TEAL_EDGE := Color("#bff7f0")
const ORANGE := Color("#ff8a1f")
const NUMBER_TOP := Color("#fff27a")
const NUMBER_BOTTOM := Color("#f5a11f")

## Discord avatars already downloaded (url -> Texture2D), shared by every visit.
static var _avatars := {}

var _rows: Array = []
var _season := ""
var _loading := false
var _error := ""
var _focus := "list"     # board, region, list
var _cursor := 0
var _top := 0

var _board_pill: Dictionary
var _region_pill: Dictionary
var _cards: Array = []
var _up: Control
var _down: Control
var _you: Dictionary
var _overlay: Control
var _overlay_text: Label


func screen_music() -> String:
	return "netplay"


func screen_title() -> String:
	return "Leaderboard"


func screen_desc() -> String:
	return "Ranked standings. Global counts every region; a region counts\nranked lobbies hosted there."


func screen_hints() -> Array:
	return [["◀▶", Style.INK_LINE, "Change"], ["▲▼", Style.INK_LINE, "Move"],
			["A", Style.GOOD, "Website"], ["B", Style.POOR, "Back"]]


func on_enter() -> void:
	var radar := Radar.new()
	Style.place(radar, 0, 96, 1280, 434)
	add_child(radar)
	_board_pill = _make_pill(150, 108, 600)
	_region_pill = _make_pill(780, 108, 350)
	for i in VISIBLE:
		_cards.append(_make_card(LIST_Y + i * (CARD_H + CARD_GAP)))
	_up = _chevron(true, 152)
	_down = _chevron(false, LIST_Y + VISIBLE * (CARD_H + CARD_GAP) - 8)
	_you = _make_you_bar()
	_make_overlay()
	_refresh()
	_load()


# --- data ----------------------------------------------------------------------------------

func _mode() -> String:
	return String(Settings.get_value("ranked", "board_mode"))


func _region() -> String:
	return String(Settings.get_value("ranked", "board_region"))


func _regions() -> Array:
	var r: Array = ["global"]
	r.append_array(Settings.REGIONS)
	return r


func _region_name(code: String) -> String:
	var i := Settings.REGIONS.find(code)
	return tr("Global") if i < 0 else tr(Settings.REGION_NAMES[i])


func _load() -> void:
	_loading = true
	_error = ""
	_refresh()
	var res := await Ranked.api("leaderboard.php", {"mode": _mode(), "region": _region(), "limit": 50})
	if not is_inside_tree():
		return
	_loading = false
	var ok: bool = res.get("ok", false)
	_rows = res.get("rows", []) if ok else []
	_season = String(res.get("season", {}).get("name", "")) if ok else ""
	_error = "" if ok else Ranked.error_text(String(res.get("error", "")))
	_cursor = 0
	_top = 0
	var me := _my_index()
	if me >= 0:   # start on your own card
		_cursor = me
		_top = clampi(me - 1, 0, maxi(_rows.size() - VISIBLE, 0))
	_refresh()


## Board / region change (also used by the UI tour).
func on_value(key: String, value: Variant) -> void:
	Settings.set_value("ranked", key, value)
	_load()


func _my_index() -> int:
	var me := Ranked.display_name()
	if me == "":
		return -1
	for i in _rows.size():
		if String(_rows[i].get("name", "")) == me:
			return i
	return -1


# --- input ---------------------------------------------------------------------------------

func on_input(event: InputEvent) -> bool:
	if event.is_action_pressed("ui_left", true) or event.is_action_pressed("ui_right", true):
		var step := -1 if event.is_action_pressed("ui_left", true) else 1
		_cycle("board_region" if _focus == "region" else "board_mode", step)
		return true
	if event.is_action_pressed("ui_up", true):
		_move(-1)
		return true
	if event.is_action_pressed("ui_down", true):
		_move(1)
		return true
	if event is InputEventMouseButton and event.pressed and event.button_index in [MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN]:
		_focus = "list"
		_move(-1 if event.button_index == MOUSE_BUTTON_WHEEL_UP else 1)
		return true
	if event.is_action_pressed("ui_accept"):
		if _focus == "list":
			Sfx.play("select")
			_open_website()
		else:
			_cycle("board_region" if _focus == "region" else "board_mode", 1)
		return true
	return false


func _cycle(key: String, step: int) -> void:
	var values: Array = MODES if key == "board_mode" else _regions()
	var i := values.find(Settings.get_value("ranked", key))
	Sfx.play("move")
	on_value(key, values[posmod(i + step, values.size())])


func _move(dir: int) -> void:
	var before := [_focus, _cursor]
	match _focus:
		"board":
			if dir > 0:
				_focus = "region"
		"region":
			_focus = "board" if dir < 0 else "list"
		"list":
			if dir < 0 and _cursor == 0:
				_focus = "region"
			elif dir > 0 and _cursor < _rows.size() - 1:
				_cursor += 1
			elif dir < 0:
				_cursor -= 1
	_top = clampi(_top, _cursor - VISIBLE + 1, _cursor)
	if [_focus, _cursor] != before:
		Sfx.play("move")
	_refresh()


func _open_website() -> void:
	Ranked.open_url.call("%sindex.php?mode=%s&region=%s" % [Ranked.server(), _mode(), _region()])


# --- drawing ---------------------------------------------------------------------------------

func _refresh() -> void:
	if _cards.is_empty():
		return
	var mode := _mode()
	var mi := MODES.find(mode)
	_set_pill(_board_pill, tr(MODE_NAMES[maxi(mi, 0)]), _focus == "board")
	var region_text := _region_name(_region())
	if _season != "" and mode != "all":
		region_text += "  ·  " + _season
	_set_pill(_region_pill, region_text, _focus == "region")

	for i in VISIBLE:
		var idx := _top + i
		_fill_card(_cards[i], _rows[idx] if idx < _rows.size() else {}, idx == _cursor and _focus == "list")
	_up.visible = _top > 0
	_down.visible = _top + VISIBLE < _rows.size()
	_fill_you()

	var msg := ""
	if _loading:
		msg = tr("Receiving Ranking Data...")
	elif _error != "":
		msg = _error
	elif _rows.is_empty():
		msg = tr("No ranked matches here yet")
	_overlay.visible = msg != ""
	_overlay_text.text = msg
	if app:
		app.set_desc(_focus_desc())


func _focus_desc() -> String:
	match _focus:
		"board":
			return tr("Single Battle FT2 / Team Battle: by rating.\nAll-time record: wins and losses across every mode.")
		"region":
			return tr("Global: every region. A region: ranked lobbies hosted there.")
	return screen_desc()


## A teal selector pill with orange arrows, like the game's "My Area" bar.
func _make_pill(x: float, y: float, w: float) -> Dictionary:
	var p := Panel.new()
	p.mouse_filter = Control.MOUSE_FILTER_IGNORE
	Style.place(p, x, y, w, 50)
	add_child(p)
	var sheen := _gradient_rect(Color("#3fd9d0"), Color("#0b6f7e"))
	sheen.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	p.clip_children = CanvasItem.CLIP_CHILDREN_AND_DRAW
	p.add_child(sheen)
	var rim := Panel.new()
	rim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	rim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	p.add_child(rim)
	var text := Style.title_label("", 28, 0.42)
	text.auto_translate_mode = Node.AUTO_TRANSLATE_MODE_DISABLED   # (set from translated pieces)
	text.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	text.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	text.clip_text = true
	Style.place(text, 50, 0, w - 100, 50)
	(text.material as ShaderMaterial).set_shader_parameter("top_color", NUMBER_TOP)
	(text.material as ShaderMaterial).set_shader_parameter("bottom_color", ORANGE)
	p.add_child(text)
	for left in [true, false]:
		var a := Style.arrow("left" if left else "right")
		Style.place(a, 8 if left else w - 44, 7, 36, 36)
		a.mouse_filter = Control.MOUSE_FILTER_STOP
		a.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
		var key := "board_mode" if x < 640 else "board_region"
		a.gui_input.connect(func(e: InputEvent):
			if e is InputEventMouseButton and e.pressed and e.button_index == MOUSE_BUTTON_LEFT:
				_focus = "board" if key == "board_mode" else "region"
				_cycle(key, -1 if left else 1))
		p.add_child(a)
	return {"panel": p, "rim": rim, "text": text}


func _set_pill(pill: Dictionary, text: String, focused: bool) -> void:
	var box := Style.box(Color(0, 0, 0, 0), 25, 4 if focused else 3, GOLD_EDGE if focused else TEAL_EDGE)
	(pill["panel"] as Panel).add_theme_stylebox_override("panel", Style.box(TEAL, 25))
	(pill["rim"] as Panel).add_theme_stylebox_override("panel", box)
	(pill["text"] as Label).text = text


## One ranking card: rounded purple plate, rank, avatar, name banner, "Rating" and the number.
func _make_card(y: float) -> Dictionary:
	var c := Panel.new()
	c.mouse_filter = Control.MOUSE_FILTER_IGNORE
	Style.place(c, CARD_X, y, CARD_W, CARD_H)
	c.clip_children = CanvasItem.CLIP_CHILDREN_AND_DRAW
	add_child(c)
	var sheen := _gradient_rect(Color("#7a5cc4"), Color("#2a1a57"))
	sheen.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	sheen.modulate.a = 0.9
	c.add_child(sheen)
	# The name banner across the top middle.
	var banner := Style.panel(Color(0.06, 0.04, 0.12, 0.82), 0)
	Style.place(banner, 300, 6, 600, 30)
	c.add_child(banner)
	var nm := Style.label("", 24, Color.WHITE, 3, Color("#120a24"), "button")
	nm.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	nm.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	nm.auto_translate_mode = Node.AUTO_TRANSLATE_MODE_DISABLED
	nm.clip_text = true
	var spaced := FontVariation.new()
	spaced.base_font = nm.label_settings.font
	spaced.spacing_glyph = 5
	nm.label_settings.font = spaced
	Style.place(nm, 0, 0, 600, 30)
	banner.add_child(nm)
	# Rank, slanted like the game's numbers.
	var rank := Style.label("", 46, Color("#f4ecff"), 6, Color("#1a0f33"), "button", 3)
	rank.label_settings.font = _italic(rank.label_settings.font)
	rank.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	rank.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	rank.auto_translate_mode = Node.AUTO_TRANSLATE_MODE_DISABLED
	Style.place(rank, 16, 12, 124, 70)
	c.add_child(rank)
	# Avatar in a framed square (Discord picture, or the name's first letter).
	var frame := Style.panel(Color("#1a0f33"), 6, 3, PURPLE_EDGE)
	Style.place(frame, 156, 30, 76, 50)
	c.add_child(frame)
	var initial := Style.label("", 30, Color.WHITE, 4, Color("#1a0f33"), true)
	initial.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	initial.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	initial.auto_translate_mode = Node.AUTO_TRANSLATE_MODE_DISABLED
	initial.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	frame.add_child(initial)
	var pic := TextureRect.new()
	pic.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	pic.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	pic.mouse_filter = Control.MOUSE_FILTER_IGNORE
	pic.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	pic.offset_left = 3
	pic.offset_top = 3
	pic.offset_right = -3
	pic.offset_bottom = -3
	frame.add_child(pic)
	# "Rating" in gold italics, the win-loss record under it.
	var what := Style.label("", 30, Color("#ffd84a"), 6, Color("#3a1600"), "button", 2)
	what.label_settings.font = _italic(what.label_settings.font)
	what.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	what.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	Style.place(what, 300, 38, 440, 40)
	c.add_child(what)
	var record := Style.label("", 22, Color("#e9e1ff"), 4, Color("#120a24"), "button")
	record.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	record.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	record.auto_translate_mode = Node.AUTO_TRANSLATE_MODE_DISABLED
	Style.place(record, 680, 38, 150, 40)
	c.add_child(record)
	# The big number on the right, in yellow-orange.
	var value := Style.title_label("", 46, 0.6)
	value.label_settings.font = _italic(value.label_settings.font)
	value.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	value.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	value.auto_translate_mode = Node.AUTO_TRANSLATE_MODE_DISABLED
	(value.material as ShaderMaterial).set_shader_parameter("top_color", NUMBER_TOP)
	(value.material as ShaderMaterial).set_shader_parameter("bottom_color", NUMBER_BOTTOM)
	Style.place(value, 820, 14, 210, 70)
	c.add_child(value)
	var rim := Panel.new()
	rim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	rim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	c.add_child(rim)
	return {"panel": c, "rim": rim, "name": nm, "rank": rank, "initial": initial, "pic": pic,
			"what": what, "record": record, "value": value}


func _fill_card(card: Dictionary, r: Dictionary, selected: bool) -> void:
	var panel: Panel = card["panel"]
	panel.visible = not r.is_empty()
	if r.is_empty():
		return
	var mine := String(r.get("name", "")) == Ranked.display_name() and Ranked.display_name() != ""
	var radius := int(CARD_H / 2)
	panel.add_theme_stylebox_override("panel", Style.box(PURPLE, radius))
	var edge := GOLD_EDGE if selected else (Color("#9ff0ff") if mine else PURPLE_EDGE)
	(card["rim"] as Panel).add_theme_stylebox_override("panel",
			Style.box(Color(0, 0, 0, 0), radius, 4 if selected else 3, edge))
	var who := String(r.get("name", "?"))
	(card["name"] as Label).text = who.to_upper()
	(card["rank"] as Label).text = str(int(r.get("rank", 0)))
	var wins := int(r.get("wins", 0))
	var losses := int(r.get("losses", 0))
	if r.has("rating"):
		(card["what"] as Label).text = tr("Rating")
		(card["value"] as Label).text = str(int(r.get("rating", 1000)))
	else:
		(card["what"] as Label).text = tr("Wins")
		(card["value"] as Label).text = str(wins)
	(card["record"] as Label).text = "%d-%d" % [wins, losses]
	(card["initial"] as Label).text = who.left(1).to_upper()
	_set_avatar(card["pic"], String(r.get("avatar", "") if r.get("avatar") != null else ""))


## Your own entry, pinned under the list (dark bar, like the game's).
func _make_you_bar() -> Dictionary:
	var bar := Style.panel(Color("#0d1630", 0.92), 26, 3, Color("#9ff0ff"))
	Style.place(bar, CARD_X, 474, CARD_W, 52)
	add_child(bar)
	var rank := Style.label("", 30, Color("#f4ecff"), 5, Color("#1a0f33"), "button")
	rank.label_settings.font = _italic(rank.label_settings.font)
	rank.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	rank.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	rank.auto_translate_mode = Node.AUTO_TRANSLATE_MODE_DISABLED
	Style.place(rank, 20, 0, 120, 52)
	bar.add_child(rank)
	var text := Style.label("", 24, Color("#ffd84a"), 5, Color("#3a1600"), "button")
	text.label_settings.font = _italic(text.label_settings.font)
	text.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	text.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	Style.place(text, 160, 0, 640, 52)
	bar.add_child(text)
	var value := Style.title_label("", 34, 0.5)
	value.label_settings.font = _italic(value.label_settings.font)
	value.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	value.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	value.auto_translate_mode = Node.AUTO_TRANSLATE_MODE_DISABLED
	(value.material as ShaderMaterial).set_shader_parameter("top_color", NUMBER_TOP)
	(value.material as ShaderMaterial).set_shader_parameter("bottom_color", NUMBER_BOTTOM)
	Style.place(value, 820, 0, 210, 52)
	bar.add_child(value)
	return {"bar": bar, "rank": rank, "text": text, "value": value}


func _fill_you() -> void:
	var i := _my_index()
	var rank: Label = _you["rank"]
	var text: Label = _you["text"]
	var value: Label = _you["value"]
	if i >= 0:
		var r: Dictionary = _rows[i]
		rank.text = str(int(r.get("rank", 0)))
		text.text = tr("Your rank")
		value.text = str(int(r.get("rating", r.get("wins", 0))))
	else:
		rank.text = ""
		value.text = ""
		text.text = tr("Log in with Discord to get ranked") if not Ranked.logged_in() \
				else tr("You're not on this board yet")


func _chevron(up: bool, y: float) -> Control:
	var a := Style.arrow("up" if up else "down")
	Style.place(a, 618, y, 44, 30)
	add_child(a)
	return a


## The striped teal popup box (look/popup_box.png) for "Receiving Ranking Data..." and messages.
func _make_overlay() -> void:
	_overlay = Control.new()
	_overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	Style.place(_overlay, 250, 196, 780, 236)
	add_child(_overlay)
	var box := Style.popup_box()
	box.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_overlay.add_child(box)
	_overlay_text = Style.label("", 30, Color.WHITE, 6, Color("#06302f"), "button")
	_overlay_text.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_overlay_text.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_overlay_text.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_overlay_text.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_overlay_text.offset_left = 60
	_overlay_text.offset_right = -60
	_overlay.add_child(_overlay_text)


# --- helpers ---------------------------------------------------------------------------------

func _gradient_rect(top: Color, bottom: Color) -> TextureRect:
	var g := Gradient.new()
	g.set_color(0, top)
	g.set_color(1, bottom)
	var t := GradientTexture2D.new()
	t.gradient = g
	t.fill_from = Vector2(0, 0)
	t.fill_to = Vector2(0, 1)
	var r := TextureRect.new()
	r.texture = t
	r.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	r.stretch_mode = TextureRect.STRETCH_SCALE
	r.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return r


static func _italic(font: Font) -> Font:
	var v := FontVariation.new()
	v.base_font = font
	v.variation_transform = Transform2D(Vector2(1, 0), Vector2(0.22, 1), Vector2.ZERO)
	return v


## Shows a Discord avatar (downloaded once, then cached); the first letter until then / if none.
func _set_avatar(pic: TextureRect, url: String) -> void:
	pic.set_meta("url", url)
	pic.texture = _avatars.get(url) if url != "" and _avatars.get(url) is Texture2D else null
	if url == "" or _avatars.has(url):
		return
	_avatars[url] = null   # downloading
	var req := HTTPRequest.new()
	add_child(req)
	req.request_completed.connect(func(result: int, code: int, _h: PackedStringArray, body: PackedByteArray):
		req.queue_free()
		if result != HTTPRequest.RESULT_SUCCESS or code != 200:
			return
		var img := Image.new()
		if img.load_png_from_buffer(body) != OK and img.load_jpg_from_buffer(body) != OK \
				and img.load_webp_from_buffer(body) != OK:
			return
		_avatars[url] = ImageTexture.create_from_image(img)
		if is_inside_tree():
			_refresh())
	if req.request(url) != OK:
		req.queue_free()


## The radar ring behind the cards (the game's ranking screen has a big dial there).
class Radar extends Control:
	func _init() -> void:
		mouse_filter = Control.MOUSE_FILTER_IGNORE

	func _draw() -> void:
		var c := Vector2(size.x / 2, size.y / 2 + 10)
		var ink := Color(1.0, 0.95, 0.8, 0.22)
		var faint := Color(1.0, 0.95, 0.8, 0.10)
		draw_circle(c, 250, Color(0.2, 0.1, 0.45, 0.25))
		for r in [250.0, 200.0, 120.0]:
			draw_arc(c, r, 0, TAU, 96, ink if r == 250.0 else faint, 3.0 if r == 250.0 else 2.0, true)
		for i in 48:
			var a := TAU * i / 48.0
			var inner := 236.0 if i % 4 == 0 else 244.0
			draw_line(c + Vector2.from_angle(a) * inner, c + Vector2.from_angle(a) * 250, ink, 2.0, true)
		draw_line(c + Vector2(-270, 0), c + Vector2(270, 0), faint, 2.0, true)
		draw_line(c + Vector2(0, -270), c + Vector2(0, 270), faint, 2.0, true)
