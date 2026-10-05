extends Control
## Base of every screen on Main's stack. Screens are 1280x720 and draw over Main's background.
## Override what you need:
##   screen_title()  - big title in the header
##   screen_desc()   - text for the description bar (or call app.set_desc any time)
##   on_enter()      - added to the stack (built, visible)
##   on_resume()     - top of the stack again after the screen above was popped
##   on_input(e)     - unhandled input while on top; return true if used
##   on_back()       - Back / Escape / B; default pops
##   make_ingame_panel() - optional: the small in-game menu (held Select) while a game runs

const Style := preload("res://scripts/ui/style.gd")

var app: Node   # main.gd
var show_desc_bar := true
var show_header := true


func _init() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	position = Vector2.ZERO
	size = Vector2(1280, 720)


func screen_title() -> String:
	return ""


func screen_desc() -> String:
	return ""


func on_enter() -> void:
	pass


func on_resume() -> void:
	app.set_desc(screen_desc())


func on_input(_event: InputEvent) -> bool:
	return false


func on_back() -> void:
	app.pop()


## The standard form panel (dark, rounded) used by settings-style screens.
func add_form_panel(x := 40.0, y := 112.0, w := 1200.0, h := 400.0) -> Panel:
	var p := Style.panel(Color("#2b6478", 0.94), 18, 3, Color(1, 1, 1, 0.45))
	Style.place(p, x, y, w, h)
	add_child(p)
	return p
