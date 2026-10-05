extends "res://scripts/screens/screen.gd"
## A menu screen made of one carousel. `items` entries are the carousel's items plus
## `action: Callable` (called on Accept) or `back: true`.

const Carousel := preload("res://scripts/ui/carousel.gd")

var title := ""
var music := ""
var items: Array = []
var carousel: Control
var _start := 0


func setup(p_title: String, p_items: Array, start := 0, p_music := "") -> Node:
	title = p_title
	music = p_music
	items = p_items
	_start = start
	return self


func screen_title() -> String:
	return title


func screen_music() -> String:
	return music


func screen_desc() -> String:
	return String(carousel.current().get("desc", "")) if carousel else ""


func on_enter() -> void:
	carousel = Carousel.new()
	carousel.position = Vector2(0, 112)
	add_child(carousel)
	carousel.set_items(items, _start)
	carousel.changed.connect(func(_i): app.set_desc(screen_desc()))
	carousel.activated.connect(_on_activated)


func on_input(event: InputEvent) -> bool:
	return carousel.handle_input(event)


func _on_activated(i: int) -> void:
	var item: Dictionary = items[i]
	if item.get("back", false):
		on_back()
	elif item.get("disabled", false):
		app.toast(String(item.get("disabled_text", "Not available yet")))
	elif item.has("action"):
		item["action"].call()
