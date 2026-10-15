extends RefCounted
## The look of the whole frontend, read from res://look/menu_look.tres (edit it in the Godot
## editor's Inspector; see look/menu_look.gd). F9 in the running menus reloads it.
## (No class_name, so the project runs without the editor's class cache: `preload` this.)

# --- Current look (filled from menu_look.tres by load_skin) ---------------------------------
static var INK := Color("#0f3a48")
static var INK_LINE := Color("#cfe9ee")
static var DESC_TEXT := Color.WHITE
static var DARK := Color("#1b1b24")
static var TITLE := Color("#fcb630")
static var TITLE_BOTTOM := Color("#fd2a24")
static var TITLE_EDGE := Color("#631c12")
static var TITLE_RIM := Color("#fdecd6")
static var TITLE_RIM_SIZE := 10
static var TITLE_SIZE := 64
static var TITLE_OUTLINE := 12
static var TITLE_SHADOW := 6
static var SEL_TEXT := Color("#fff4d6")
static var SEL_EDGE := Color("#4a1a08")
static var IDLE_TEXT := Color("#5b3a8c")
static var IDLE_EDGE := Color.WHITE
static var ITEM_SIZE := 46
static var BADGES := true
static var ARROW := Color("#f7a531")
static var ARROW_HOVER := Color("#ffd27a")
static var PANEL := Color("#2b6478", 0.94)
static var PANEL_BORDER := Color(1, 1, 1, 0.45)
static var PANEL_RADIUS := 18
static var ROW := Color("#0f3a48", 0.72)
static var ROW_SEL := Color("#f2b531", 0.85)
static var ROW_SEL_BORDER := Color(1, 1, 1, 0.85)
static var ROW_TEXT := Color.WHITE
static var ROW_SEL_TEXT := Color("#fff4d6")
static var ROW_RADIUS := 10
static var GOLD := Color("#f2b531")
static var GOOD := Color("#3fbf6b")
static var MID := Color("#f2b531")
static var POOR := Color("#e8663d")
static var MUTED := Color("#8a9bb0")
static var TOAST_BG := Color("#1b1b24")
static var TOAST_TEXT := Color.WHITE
static var ITEM_COLORS := {}

static var FADE_COLOR := Color.BLACK
static var FADE_TIME := 0.35
static var LOBBY_FADE_COLOR := Color.WHITE
static var LOBBY_FADE_TIME := 0.6
static var SEL_BAR: Texture2D             # selected_bar
static var SEL_BAR_SIZE := Vector2(860, 72)
static var ROW_BAR: Texture2D              # row_bar
static var ROW_BAR_SIZE := Vector2(500, 44)
static var DESC_IMAGE: Texture2D
static var PANEL_IMAGE: Texture2D
static var PANEL_IMAGE_MARGIN := 24

const LOOK_PATH := "res://look/menu_look.tres"
const TitleLabel := preload("res://scripts/ui/title_label.gd")

static var look: Resource = null
static var _title_font: Font
static var _look_files := {}   # res://look/*.png loaded by look_texture()
static var _menu_font: Font
static var _body_font: Font
static var _button_font: Font


static func _ensure() -> void:
	if look == null:
		load_skin()


## (Re)reads res://look/menu_look.tres (edited in the Godot editor's Inspector).
static func load_skin() -> void:
	look = ResourceLoader.load(LOOK_PATH, "", ResourceLoader.CACHE_MODE_REPLACE)
	if look == null:
		push_warning("Menu look not found: " + LOOK_PATH)
		look = load("res://look/menu_look.gd").new()
	var L := look
	TITLE = L.title_color
	TITLE_BOTTOM = L.title_color_bottom
	TITLE_EDGE = L.title_outline_color
	TITLE_RIM = L.title_rim_color
	TITLE_RIM_SIZE = L.title_rim
	TITLE_SIZE = L.title_size
	TITLE_OUTLINE = L.title_outline
	TITLE_SHADOW = L.title_shadow
	FADE_COLOR = L.fade_color
	FADE_TIME = L.fade_time
	LOBBY_FADE_COLOR = L.lobby_fade_color
	LOBBY_FADE_TIME = L.lobby_fade_time
	SEL_BAR = L.selected_bar
	SEL_BAR_SIZE = Vector2(L.selected_bar_size)
	ROW_BAR = L.row_bar
	ROW_BAR_SIZE = Vector2(L.row_bar_size)
	SEL_TEXT = L.selected_text
	SEL_EDGE = L.selected_outline
	IDLE_TEXT = L.text
	IDLE_EDGE = L.text_outline
	ITEM_SIZE = L.text_size
	BADGES = L.badges
	ARROW = L.arrow_color
	ARROW_HOVER = L.arrow_hover_color
	ITEM_COLORS = {}
	for k in L.item_colors:
		var v = L.item_colors[k]
		ITEM_COLORS[String(k)] = v if v is Color else Color(String(v))
	INK = L.description_color
	INK_LINE = L.description_border
	DESC_TEXT = L.description_text
	DESC_IMAGE = L.description_image
	PANEL = L.panel_color
	PANEL_BORDER = L.panel_border
	PANEL_RADIUS = L.panel_radius
	PANEL_IMAGE = L.panel_image
	PANEL_IMAGE_MARGIN = L.panel_image_margin
	ROW = L.row_color
	ROW_SEL = L.row_selected_color
	ROW_SEL_BORDER = L.row_selected_border
	ROW_TEXT = L.row_text
	ROW_SEL_TEXT = L.row_selected_text
	ROW_RADIUS = L.row_radius
	GOLD = L.accent
	GOOD = L.good
	MID = L.ok
	POOR = L.poor
	MUTED = L.muted
	TOAST_BG = L.toast_color
	TOAST_TEXT = L.toast_text
	_title_font = null
	_menu_font = null
	_body_font = null
	_button_font = null


## The color for a menu item: Item colors in the look, else the menu's own.
static func item_color(label: String, fallback: Color) -> Color:
	_ensure()
	return ITEM_COLORS.get(label, fallback)


## Picture for a menu (by its music track name: main_menu, game_menu, ...), or null.
const BACKGROUND_PARENT := {"battle_lounge": "lobby", "ranked": "lobby"}   # same as Music.TRACK_PARENT


static func background(track: String) -> Texture2D:
	_ensure()
	var t = look.get("background_" + track) if track != "" else null
	# A screen variant without its own picture uses its parent's (Battle Lounge -> lobby).
	if t == null and BACKGROUND_PARENT.has(track):
		t = look.get("background_" + String(BACKGROUND_PARENT[track]))
	return t if t else look.background_default


## Fonts: the look's fonts, else res://fonts/menu.* / button.* / body.*, else the system font
## (Impact for buttons, Tahoma for the rest; both come with Windows), else Godot's own.
## Screen titles: the look's title font, else the menu font (as before).
static func title_font() -> Font:
	_ensure()
	if _title_font == null:
		_title_font = look.title_font if look.title_font else menu_font()
	return _title_font


static func menu_font() -> Font:
	_ensure()
	if _menu_font == null:
		_menu_font = look.menu_font if look.menu_font else _load_font("menu", 0.9)
	return _menu_font


static func body_font() -> Font:
	_ensure()
	if _body_font == null:
		_body_font = look.body_font if look.body_font else _load_font("body", 0.4, ["Tahoma", "Verdana"])
	return _body_font


static func button_font() -> Font:
	_ensure()
	if _button_font == null:
		_button_font = look.button_font if look.button_font \
				else _load_font("button", 0.6, ["Impact", "Haettenschweiler"])
	return _button_font


static func _load_font(base: String, fallback_bold: float, system: Array = []) -> Font:
	for ext in ["ttf", "otf", "woff2", "woff"]:
		var path := "res://fonts/%s.%s" % [base, ext]
		if ResourceLoader.exists(path):
			return load(path)
	if not system.is_empty() and _system_has(system):
		var f := SystemFont.new()
		f.font_names = PackedStringArray(system)
		return f
	var v := FontVariation.new()
	v.base_font = ThemeDB.fallback_font
	v.variation_embolden = fallback_bold
	return v


static func _system_has(names: Array) -> bool:
	var installed := OS.get_system_fonts()
	for n in names:
		if installed.has(n):
			return true
	return false


## Label with an outline (and optional drop shadow), like the game's menu text.
static func label(text: String, size: int, color: Color, outline := 0, edge := Color.BLACK,
		menu: Variant = false, shadow := 0) -> Label:
	var l := Label.new()
	l.text = text
	var s := LabelSettings.new()
	# menu: false = body (descriptions), true = title font, "button" = button font.
	s.font = button_font() if menu is String else (menu_font() if menu else body_font())
	s.font_size = size
	s.font_color = color
	s.outline_size = outline
	s.outline_color = edge
	if shadow > 0:
		s.shadow_size = outline
		s.shadow_color = edge
		s.shadow_offset = Vector2(0, shadow)
	l.label_settings = s
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return l


## A screen title in the title style: rounded heavy letters with an orange-to-red gradient,
## a dark edge and a light rim (res://look/title_gradient.gdshader colors the letters).
## `scale` sizes the edges with the text (1 = the big title at the top).
static func title_label(text: String, size: int, scale := 1.0) -> Label:
	_ensure()
	var l: Label = TitleLabel.new()
	l.text = text
	var s := LabelSettings.new()
	s.font = title_font()
	s.font_size = size
	s.font_color = Color(1, 0, 1)   # the shader's marker for the letters
	s.outline_size = maxi(1, roundi(TITLE_OUTLINE * scale))
	s.outline_color = TITLE_EDGE
	if TITLE_RIM_SIZE > 0:
		s.stacked_outline_count = 1
		s.set_stacked_outline_size(0, maxi(1, roundi(TITLE_RIM_SIZE * scale)))
		s.set_stacked_outline_color(0, TITLE_RIM)
	if TITLE_SHADOW > 0:
		s.shadow_size = 0
		s.shadow_color = Color(0, 0, 0, 0.35)
		s.shadow_offset = Vector2(0, roundi(TITLE_SHADOW * scale * 0.6))
	l.label_settings = s
	var m := ShaderMaterial.new()
	m.shader = preload("res://look/title_gradient.gdshader")
	m.set_shader_parameter("top_color", TITLE)
	m.set_shader_parameter("bottom_color", TITLE_BOTTOM)
	l.material = m
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	l.place_gradient()
	return l


## A picture from the look (or, if Godot hasn't imported it yet, straight from the PNG file).
static func look_texture(prop: String, file: String) -> Texture2D:
	_ensure()
	var t = look.get(prop)
	if t is Texture2D:
		return t
	var path := "res://look/%s" % file
	if _look_files.has(path):
		return _look_files[path]
	var tex: Texture2D = null
	if ResourceLoader.exists(path):
		tex = load(path)
	if tex == null:
		# Not imported by Godot yet (e.g. just pulled, editor not opened): read the PNG itself.
		var img := Image.load_from_file(ProjectSettings.globalize_path(path))
		if img != null and not img.is_empty():
			img.generate_mipmaps()
			tex = ImageTexture.create_from_image(img)
		else:
			push_warning("Menu picture missing: " + path)
	_look_files[path] = tex
	return tex


## A value from the look (menu_look.tres), or `fallback` when the look has no such slot.
static func look_value(prop: String, fallback: Variant) -> Variant:
	_ensure()
	if look and prop in look:
		var v = look.get(prop)
		return fallback if v == null else v
	return fallback


## The menu arrows (look: arrow_left / right / up / down) as a picture, sized by its rect.
static func arrow(dir: String) -> TextureRect:
	var t := TextureRect.new()
	t.texture = look_texture("arrow_" + dir, "arrow_%s.png" % dir)
	t.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	t.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	t.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	t.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return t


## The striped teal popup box (look/popup_box.png): its notched corners keep their size, the
## middle stretches.
static func popup_box() -> NinePatchRect:
	_ensure()
	var b := NinePatchRect.new()
	b.texture = look_texture("popup_box", "popup_box.png")
	var m: Vector4i = look.get("popup_box_margins") if look.get("popup_box_margins") != null else Vector4i(100, 64, 100, 64)
	b.patch_margin_left = m.x
	b.patch_margin_top = m.y
	b.patch_margin_right = m.z
	b.patch_margin_bottom = m.w
	b.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	b.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return b


static func box(bg: Color, radius := 0, border := 0, border_color := Color.WHITE) -> StyleBoxFlat:
	var b := StyleBoxFlat.new()
	b.bg_color = bg
	b.set_corner_radius_all(radius)
	b.set_border_width_all(border)
	b.border_color = border_color
	b.anti_aliasing = true
	return b


static func panel(bg: Color, radius := 0, border := 0, border_color := Color.WHITE) -> Panel:
	var p := Panel.new()
	p.add_theme_stylebox_override("panel", box(bg, radius, border, border_color))
	p.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return p


## A panel in the skin's [panels] colors (forms, lobby).
static func skin_panel(radius := -1) -> Panel:
	var p := panel(PANEL, PANEL_RADIUS if radius < 0 else radius, 3, PANEL_BORDER)
	if PANEL_IMAGE:
		var sbt := StyleBoxTexture.new()
		sbt.texture = PANEL_IMAGE
		var m := float(PANEL_IMAGE_MARGIN)
		sbt.texture_margin_left = m
		sbt.texture_margin_right = m
		sbt.texture_margin_top = m
		sbt.texture_margin_bottom = m
		p.add_theme_stylebox_override("panel", sbt)
	return p


static func place(c: Control, x: float, y: float, w: float, h: float) -> Control:
	c.position = Vector2(x, y)
	c.size = Vector2(w, h)
	return c


## Text field styled for the dark panels.
static func line_edit(placeholder := "", max_len := 0) -> LineEdit:
	var e := LineEdit.new()
	# Only a click or the menu (OptionList) opens a text field: Godot 4.5+ would otherwise jump
	# to it on any D-pad / arrow press when nothing has focus, hijacking the menu's own selection.
	e.focus_mode = Control.FOCUS_CLICK
	e.placeholder_text = placeholder
	if max_len > 0:
		e.max_length = max_len
	e.add_theme_font_override("font", body_font())
	e.add_theme_font_size_override("font_size", 22)
	e.add_theme_color_override("font_color", Color.WHITE)
	e.add_theme_color_override("font_placeholder_color", Color(1, 1, 1, 0.45))
	e.add_theme_stylebox_override("normal", box(Color(0, 0, 0, 0.35), 8, 2, Color(1, 1, 1, 0.25)))
	e.add_theme_stylebox_override("focus", box(Color(0, 0, 0, 0.5), 8, 2, GOLD))
	return e


static func quality_color(q: String) -> Color:
	match q:
		"good":
			return GOOD
		"ok":
			return MID
		"poor":
			return POOR
	return MUTED


static func link_name(link: String) -> String:
	match link:
		"wired":
			return TranslationServer.translate("Wired")
		"wireless":
			return "Wi-Fi"
		"virtual":
			return "VPN"
	return "?"


static func mode_name(mode: String) -> String:
	match mode:
		"single":
			return TranslationServer.translate("Single Battle")
		"team":
			return TranslationServer.translate("Team Battle")
		"training":
			return TranslationServer.translate("Buffer Training")
	return TranslationServer.translate("Any Mode")
