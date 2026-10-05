extends RefCounted
## Colors, fonts and small node factories shared by every screen.
## (No class_name, so the project runs without the editor's class cache: `preload` this.)

const SKY := Color("#6cc4ee")
const CLOUD := Color("#f4fbff")
const GROUND := Color("#7cc576")
const INK := Color("#0f3a48")          # description bar / panels
const INK_LINE := Color("#cfe9ee")
const DARK := Color("#1b1b24")
const TITLE := Color("#ff8a1f")
const TITLE_EDGE := Color("#6b1d0b")
const SEL_TEXT := Color("#fff4d6")
const SEL_EDGE := Color("#4a1a08")
const IDLE_TEXT := Color("#5b3a8c")
const GOLD := Color("#f2b531")
const GOOD := Color("#3fbf6b")
const MID := Color("#f2b531")
const POOR := Color("#e8663d")
const MUTED := Color("#8a9bb0")

static var _menu_font: Font
static var _body_font: Font


## Optional fonts: res://fonts/menu.ttf (titles, carousel) and res://fonts/body.ttf (text).
## Without them Godot's built-in font is used, emboldened for the menu.
static func menu_font() -> Font:
	if _menu_font == null:
		_menu_font = _load_font("menu", 0.9)
	return _menu_font


static func body_font() -> Font:
	if _body_font == null:
		_body_font = _load_font("body", 0.4)
	return _body_font


static func _load_font(base: String, fallback_bold: float) -> Font:
	for ext in ["ttf", "otf", "woff2", "woff"]:
		var path := "res://fonts/%s.%s" % [base, ext]
		if FileAccess.file_exists(path):
			var f := FontFile.new()
			if f.load_dynamic_font(path) == OK:
				return f
	var v := FontVariation.new()
	v.base_font = ThemeDB.fallback_font
	v.variation_embolden = fallback_bold
	return v


## Label with an outline (and optional drop shadow), like the game's menu text.
static func label(text: String, size: int, color: Color, outline := 0, edge := Color.BLACK,
		menu := false, shadow := 0) -> Label:
	var l := Label.new()
	l.text = text
	var s := LabelSettings.new()
	s.font = menu_font() if menu else body_font()
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


static func place(c: Control, x: float, y: float, w: float, h: float) -> Control:
	c.position = Vector2(x, y)
	c.size = Vector2(w, h)
	return c


## Text field styled for the dark panels.
static func line_edit(placeholder := "", max_len := 0) -> LineEdit:
	var e := LineEdit.new()
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
			return "Wired"
		"wireless":
			return "Wi-Fi"
		"virtual":
			return "VPN"
	return "?"


static func mode_name(mode: String) -> String:
	match mode:
		"single":
			return "Single Battle"
		"team":
			return "Team Battle"
	return "Any Mode"
