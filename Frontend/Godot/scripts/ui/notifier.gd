extends Control
## The notification bars: thin red / blue / yellow bars just above the description bar.
##   red    emergencies, updates, notices (always the first one shown)
##   blue   general announcements
##   yellow player news (e.g. a player reaching the global Top 5): Tenkaichi 3 ranked, so only in
##          Tenkaichi 3's menus (see main.gd's notice_color_allowed)
## Their text comes from the ranked server (notices.php, in the menu language). A bar slides in
## from the left with its picture, stops, runs its text through twice, then slides off to the
## right. One bar at a time, taking turns every 30 seconds, never in the first 5 seconds.
## Not shown on screens with `notices = false` (options, modifications, lobbies, leaderboards),
## while a game runs, or while `app.notices_allowed()` says no.

const Style := preload("res://scripts/ui/style.gd")

const ORDER := ["red", "blue", "yellow"]
const BAR_Y := 490.0          # top of the bar (the description bar starts at 530)
const BAR_H := 34.0
const FIRST_DELAY_S := 5.0    # nothing right after the launcher starts
const INTERVAL_S := 30.0      # from one bar's start to the next one's
const GAP_S := 2.0            # at least this long between two bars (long texts)
const POLL_S := 120.0         # asks the server again this often
const SLIDE_IN_S := 0.55
const SLIDE_OUT_S := 0.45
const PASSES := 2             # the whole text runs through the bar this many times

var app: Node                 # main.gd
var texts := {"red": "", "blue": "", "yellow": ""}
var shown: Array = []         # colors shown so far, in order (tests)
var current := ""             # the color on screen, "" = none ("leaving" = sliding off)
var paused := false           # tests: no more bars
var _next := 0                # index into ORDER for the next turn
var _due_ms := 0              # when the next bar may start
var _poll_ms := 0
var _polling := false
var _tween: Tween
var _bar: Control
var _strip: Panel
var _clip: Control
var _text: Label
var _sprite: TextureRect


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	Style.place(self, 0, 0, 1280, 720)
	_due_ms = Time.get_ticks_msec() + int(FIRST_DELAY_S * 1000)
	_bar = Control.new()
	_bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	Style.place(_bar, 0, BAR_Y, 1280, BAR_H)
	add_child(_bar)
	_strip = Panel.new()
	_strip.mouse_filter = Control.MOUSE_FILTER_IGNORE
	Style.place(_strip, 0, 0, 1280, BAR_H)
	_bar.add_child(_strip)
	_clip = Control.new()
	_clip.clip_contents = true
	_clip.mouse_filter = Control.MOUSE_FILTER_IGNORE
	Style.place(_clip, 0, 0, 1280, BAR_H)
	_bar.add_child(_clip)
	_text = Style.label("", 22, Style.look_value("notice_text", Color.WHITE), 0, Color.BLACK, true)
	_text.auto_translate_mode = Node.AUTO_TRANSLATE_MODE_DISABLED   # the server sends it translated
	_text.label_settings.outline_size = 6
	_text.label_settings.outline_color = Style.look_value("notice_text_outline", Color("#1a1030"))
	_text.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_text.autowrap_mode = TextServer.AUTOWRAP_OFF
	_clip.add_child(_text)
	_sprite = TextureRect.new()
	_sprite.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_sprite.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_sprite.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_sprite.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	add_child(_sprite)   # after the bar: in front of the bar and its text
	_hide_now()


func _process(_delta: float) -> void:
	var now := Time.get_ticks_msec()
	if now >= _poll_ms and not _polling:
		_poll()
	var allowed: bool = not paused and (app == null or app.notices_allowed())
	if current != "":
		if current != "leaving" and not (allowed and _color_ok(current)):
			_leave(true)
		return
	if not allowed or now < _due_ms:
		return
	var color := _pick()
	if color != "":
		_show(color)
		_due_ms = now + int(INTERVAL_S * 1000)


## The next color with text, taking turns red -> blue -> yellow (red starts).
func _pick() -> String:
	for i in ORDER.size():
		var c: String = ORDER[(_next + i) % ORDER.size()]
		if texts[c] != "" and _color_ok(c):
			_next = (ORDER.find(c) + 1) % ORDER.size()
			return c
	return ""


func _color_ok(color: String) -> bool:
	return app == null or app.notice_color_allowed(color)


func _poll() -> void:
	_polling = true
	_poll_ms = Time.get_ticks_msec() + int(POLL_S * 1000)
	var r: Dictionary = await Ranked.api("notices.php", {"lang": Lang.current()})
	_polling = false
	if r.get("ok", false) and r.get("notices") is Dictionary:
		for c in ORDER:
			texts[c] = String(r["notices"].get(c, "")).strip_edges()


## Asks the server again soon (e.g. the language changed).
func refresh() -> void:
	_poll_ms = 0


func _show(color: String) -> void:
	current = color
	shown.append(color)
	var col: Color = Style.look_value("notice_%s_color" % color, Color.WHITE)
	var sb := StyleBoxFlat.new()
	sb.bg_color = col
	sb.border_color = col.lightened(0.45)
	sb.border_width_top = 3
	sb.border_width_bottom = 3
	sb.shadow_color = Color(0, 0, 0, 0.35)
	sb.shadow_size = 4
	_strip.add_theme_stylebox_override("panel", sb)
	_text.text = texts[color]
	_text.size = Vector2(_text.get_minimum_size().x + 8, BAR_H)
	_text.position = Vector2(1280, 0)
	var tex := _sprite_for(color)
	_sprite.texture = tex
	var w := 0.0
	if tex:
		var h := float(Style.look_value("notice_sprite_height", 150))
		w = h * tex.get_width() / max(1.0, float(tex.get_height()))
		_sprite.size = Vector2(w, h)
		_sprite.position = Vector2(-w, BAR_Y + BAR_H - h + 6)
	_bar.position.x = -1280
	_bar.visible = true
	_sprite.visible = tex != null
	Sfx.play("notice_" + color)

	var speed := float(Style.look_value("notice_text_speed", 170.0))
	var pass_s := (1280.0 + _text.size.x) / speed
	_tween = create_tween()
	_tween.tween_property(_bar, "position:x", 0.0, SLIDE_IN_S).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	if tex:
		_tween.parallel().tween_property(_sprite, "position:x", 1280.0 - w, SLIDE_IN_S + 0.15) \
			.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	for i in PASSES:
		_tween.tween_property(_text, "position:x", -_text.size.x, pass_s).from(1280.0)
	_tween.tween_callback(_leave.bind(false))


## Slides the bar (and its picture) off to the right. `quick` = the screen doesn't allow bars.
func _leave(quick: bool) -> void:
	if _tween:
		_tween.kill()
	var t := 0.18 if quick else SLIDE_OUT_S
	_tween = create_tween()
	_tween.tween_property(_bar, "position:x", 1280.0, t).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN)
	if _sprite.visible:
		_tween.parallel().tween_property(_sprite, "position:x", 1280.0, t).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN)
	_tween.tween_callback(_hide_now)
	current = "leaving"
	_due_ms = max(_due_ms, Time.get_ticks_msec() + int((t + GAP_S) * 1000))


func _hide_now() -> void:
	current = ""
	_bar.visible = false
	_sprite.visible = false


## The color's picture: the look's slot, else look/notice_<color>.png if it's there.
func _sprite_for(color: String) -> Texture2D:
	var prop := "notice_sprite_" + color
	var file := "notice_%s.png" % color
	if Style.look_value(prop, null) is Texture2D:
		return Style.look_value(prop, null)
	var path := "res://look/" + file
	if ResourceLoader.exists(path) or FileAccess.file_exists(path):
		return Style.look_texture(prop, file)
	return null
