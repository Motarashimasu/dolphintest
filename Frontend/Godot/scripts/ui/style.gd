extends RefCounted
## The look of the whole frontend, read from res://look/menu_look.tres (edit it in the Godot
## editor's Inspector; see look/menu_look.gd). F9 in the running menus reloads it.
## (No class_name, so the project runs without the editor's class cache: `preload` this.)

# --- Current look (filled from menu_look.tres by load_skin) ---------------------------------
static var INK := Color("#0f3a48")
static var INK_LINE := Color("#cfe9ee")
static var DESC_TEXT := Color.WHITE
static var DARK := Color("#1b1b24")
static var TITLE := Color("#ff8a1f")
static var TITLE_EDGE := Color("#6b1d0b")
static var TITLE_SIZE := 64
static var TITLE_OUTLINE := 8
static var TITLE_SHADOW := 6
static var SEL_TEXT := Color("#fff4d6")
static var SEL_EDGE := Color("#4a1a08")
static var IDLE_TEXT := Color("#5b3a8c")
static var IDLE_EDGE := Color.WHITE
static var ITEM_SIZE := 46
static var BAND := "item"
static var BAND_ALPHA := 0.82
static var BAND_BORDER := Color(1, 1, 1, 0.8)
static var BAND_BORDER_WIDTH := 3
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

static var BAND_IMAGE: Texture2D            # band_image
static var BAND_IMAGE_TINT := true
static var BAND_FADE := true
static var FADE_COLOR := Color.BLACK
static var FADE_TIME := 0.35
static var LOBBY_FADE_COLOR := Color.WHITE
static var LOBBY_FADE_TIME := 0.6
static var BAND_FADE_START := 0.45
static var BAND_WIDTH := 860
static var DESC_IMAGE: Texture2D
static var PANEL_IMAGE: Texture2D
static var PANEL_IMAGE_MARGIN := 24

const LOOK_PATH := "res://look/menu_look.tres"

static var look: Resource = null
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
	TITLE_EDGE = L.title_outline_color
	TITLE_SIZE = L.title_size
	TITLE_OUTLINE = L.title_outline
	TITLE_SHADOW = L.title_shadow
	BAND = "item" if L.band_uses_item_color else "#" + L.band_color.to_html(false)
	BAND_ALPHA = L.band_opacity
	BAND_BORDER = L.band_border_color
	BAND_BORDER_WIDTH = L.band_border
	BAND_IMAGE = L.band_image
	BAND_IMAGE_TINT = L.band_image_tint
	BAND_FADE = L.band_fade
	FADE_COLOR = L.fade_color
	FADE_TIME = L.fade_time
	LOBBY_FADE_COLOR = L.lobby_fade_color
	LOBBY_FADE_TIME = L.lobby_fade_time
	BAND_FADE_START = L.band_fade_start
	BAND_WIDTH = L.band_width
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
