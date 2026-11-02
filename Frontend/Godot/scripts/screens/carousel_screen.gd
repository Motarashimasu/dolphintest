extends "res://scripts/screens/screen.gd"
## A menu screen made of one carousel. `items` entries are the carousel's items plus
## `action: Callable` (called on Accept) or `back: true`.

const Carousel := preload("res://scripts/ui/carousel.gd")
const RatingBumper := preload("res://scripts/ui/rating_bumper.gd")
const PlayerCard := preload("res://scripts/ui/player_card.gd")

var title := ""
var music := ""
var items: Array = []
var carousel: Control
var bumper: Control      # the ranked rating plate, for menus with a `bumper: true` item
var card: Control        # your DRAGON NET profile card (menus with the "player_card" meta)
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
	if not carousel:
		return ""
	var d = carousel.current().get("desc", "")
	return String(d.call()) if d is Callable else String(d)   # a Callable = text that can change


func on_enter() -> void:
	carousel = Carousel.new()
	carousel.position = Vector2(0, 112)
	add_child(carousel)
	carousel.set_items(items, _start)
	carousel.changed.connect(func(_i):
		app.set_desc(screen_desc())
		_update_bumper())
	carousel.activated.connect(_on_activated)
	if items.any(func(it): return it.get("bumper", false)):
		bumper = RatingBumper.new()
		add_child(bumper)
	if get_meta("player_card", false):
		card = PlayerCard.new()
		add_child(card)
	_update_bumper()


func on_resume() -> void:
	super()
	if bumper:
		bumper.refresh()
	if card:
		card.refresh()
	_update_bumper()


## The rating plate slides in while a `bumper: true` item (Ranked Match) is selected.
func _update_bumper() -> void:
	var plates := bool(carousel.current().get("bumper", false))
	if bumper:
		bumper.set_shown(plates)
	if card:   # (steps aside while the plates are out)
		card.set_room(not (plates and bumper and bumper.is_shown()))


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
