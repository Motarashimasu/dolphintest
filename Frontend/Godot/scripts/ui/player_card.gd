extends Control
## Your DRAGON NET profile card on the right of the DRAGON NET menu: picture, name, the flag of the
## country you picked (Your Account > Country), and your ranked record in this game (all seasons):
## battles, wins, losses. Slides in from the right while you're logged in; steps aside while the
## Ranked Match rating plates are out.

const Style := preload("res://scripts/ui/style.gd")
const Pictures := preload("res://scripts/pictures.gd")
const Flags := preload("res://scripts/flags.gd")

const CARD := Vector2(460, 112)
const X := 1280.0 - 460.0 - 36.0
const Y := 146.0
const OFF_X := 1310.0
const SLIDE := 0.3

var _card: Panel
var _pic: Control
var _name: Label
var _flag: TextureRect
var _battles: Label
var _pill: Panel
var _record: Label
var _shown := false
var _want := true
var _tween: Tween


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_card = Panel.new()
	_card.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var body := Style.box(Color("#a8237f"), 18, 3, Color("#ffc4ec"))
	_card.add_theme_stylebox_override("panel", body)
	_card.clip_children = CanvasItem.CLIP_CHILDREN_AND_DRAW
	Style.place(_card, OFF_X, Y, CARD.x, CARD.y)
	_card.modulate.a = 0.0
	add_child(_card)

	# Sheen: lighter magenta at the top, deeper at the bottom.
	var grad := Gradient.new()
	grad.set_color(0, Color("#e54fb8"))
	grad.set_color(1, Color("#7c1159"))
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
	_card.add_child(sheen)

	_pic = Pictures.Box.new()
	_card.add_child(_pic)
	Style.place(_pic, 12, 12, 88, 88)   # (once in the tree: the box lays itself out on resize)

	_name = Style.label("", 28, Color("#4a0f52"), 8, Color.WHITE, "button")
	_name.auto_translate_mode = Node.AUTO_TRANSLATE_MODE_DISABLED
	_name.clip_text = true
	_name.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_name.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	Style.place(_name, 114, 6, 270, 44)
	_card.add_child(_name)

	_flag = TextureRect.new()
	_flag.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_flag.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_flag.mouse_filter = Control.MOUSE_FILTER_IGNORE
	Style.place(_flag, CARD.x - 56, 14, 40, 30)
	_card.add_child(_flag)

	# The battle count on a dark pill.
	_pill = Style.panel(Color(0.22, 0.02, 0.2, 0.85), 15, 2, Color(1, 0.8, 0.95, 0.6))
	Style.place(_pill, 112, 60, 172, 36)
	_card.add_child(_pill)
	_battles = Style.label("", 19, Color("#ffd75e"), 4, Color(0, 0, 0, 0.7))
	_battles.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_battles.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_pill.add_child(_battles)
	_battles.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

	_record = Style.label("", 19, Color.WHITE, 4, Color(0, 0, 0, 0.6))
	_record.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_record.auto_translate_mode = Node.AUTO_TRANSLATE_MODE_DISABLED   # (made of translated pieces)
	_record.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	Style.place(_record, 290, 60, CARD.x - 300, 36)
	_card.add_child(_record)

	Ranked.changed.connect(refresh)
	refresh()


## Out while the rating plates are (`room` false), in otherwise; only while logged in.
func set_room(room: bool) -> void:
	_want = room
	_slide()


func _slide() -> void:
	var on := _want and Ranked.logged_in() and not Ranked.needs_account
	if on == _shown:
		return
	_shown = on
	if on and not Ranked.has_profile():
		Ranked.refresh()   # fills it in when it answers (Ranked.changed)
	if _tween and _tween.is_valid():
		_tween.kill()
	_tween = create_tween().set_parallel(true).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	_tween.tween_property(_card, "position:x", X if on else OFF_X, SLIDE)
	_tween.tween_property(_card, "modulate:a", 1.0 if on else 0.0, SLIDE * 0.8)


func is_shown() -> bool:
	return _shown


func refresh() -> void:
	if not is_inside_tree():
		return
	var who := Ranked.display_name()
	_name.text = who
	_pic.show_player(Ranked.picture(), who)
	var country := Ranked.country()
	_flag.texture = Flags.texture(country) if country != "" else null
	# The name gets the flag's room when there's no flag.
	_name.size.x = CARD.x - 114 - (66.0 if _flag.texture else 16.0)
	if Ranked.has_profile():
		var life := Ranked.lifetime()
		var w := int(life["wins"])
		var l := int(life["losses"])
		_battles.text = tr("%d ranked battles") % (w + l) if w + l != 1 else tr("1 ranked battle")
		_record.text = (tr("1 win") if w == 1 else tr("%d wins") % w) + "   " \
				+ (tr("1 loss") if l == 1 else tr("%d losses") % l)
	else:
		_battles.text = "..."
		_record.text = ""
	_slide()
