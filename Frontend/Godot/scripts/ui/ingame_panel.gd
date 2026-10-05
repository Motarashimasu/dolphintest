extends Control
## The small in-game menu (held Select): Main shrinks its window to this panel and keeps it on
## top of the game. A title, an optional body (players, chat...) and an OptionList.

signal pressed(key: String)
signal value_changed(key: String, value: Variant)

const Style := preload("res://scripts/ui/style.gd")
const OptionList := preload("res://scripts/ui/option_list.gd")

var list: Control
var body: Control


## `body_height` = room reserved for the body (0 = none); the list gets the rest.
func setup(title: String, rows: Array, body_height := 0.0, panel_size := Vector2(560, 600)) -> Control:
	size = panel_size
	var bg := Style.panel(Style.INK, 0, 4, Style.INK_LINE)
	Style.place(bg, 0, 0, size.x, size.y)
	add_child(bg)
	var t := Style.label(title, 34, Style.TITLE, 6, Style.TITLE_EDGE, true, 4)
	Style.place(t, 22, 10, size.x - 44, 52)
	t.clip_text = true
	add_child(t)
	var y := 70.0
	if body_height > 0:
		body = Control.new()
		Style.place(body, 20, y, size.x - 40, body_height)
		add_child(body)
		y += body_height + 12
	list = OptionList.new()
	list.row_height = 46
	list.font_size = 21
	list.label_width = 0.5
	Style.place(list, 20, y, size.x - 40, size.y - y - 46)
	add_child(list)
	list.set_rows(rows)
	list.pressed.connect(func(k): pressed.emit(k))
	list.value_changed.connect(func(k, v): value_changed.emit(k, v))
	var hint := Style.label("%s  Select      %s  Back to the game" % [Pad.prompt("accept")["key"],
			Pad.prompt("back")["key"]], 16, Style.INK_LINE, 0, Color.BLACK, "button")
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	Style.place(hint, 0, size.y - 36, size.x, 24)
	add_child(hint)
	return self


func handle_input(event: InputEvent) -> bool:
	return list.handle_input(event)
