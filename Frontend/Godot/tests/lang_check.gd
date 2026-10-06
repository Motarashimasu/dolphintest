extends Node
## Picks Español on the first-launch language screen with a real "accept" press, the way a
## player does (the menus rebuild), and checks the result. Lives on the root so it survives the
## rebuild. Run: godot --path Frontend/Godot -- --lang-check <settings.cfg>

func _ready() -> void:
	_run.call_deferred()


func _run() -> void:
	for i in 20:
		await get_tree().process_frame
	var main := get_tree().current_scene
	print("LANG_CHECK picker shown: ", main.top().screen_title() == "Language / Idioma / Lingua")
	for d in ["ui_down"]:   # English -> Español
		_press(d)
		await get_tree().process_frame
	_press("ui_accept")
	for i in 30:
		await get_tree().process_frame
	main = get_tree().current_scene
	print("LANG_CHECK language: ", Lang.current(), " title: ", tr(main.top().screen_title()))
	get_tree().quit()


func _press(action: String) -> void:
	for pressed in [true, false]:
		var e := InputEventAction.new()
		e.action = action
		e.pressed = pressed
		Input.parse_input_event(e)
