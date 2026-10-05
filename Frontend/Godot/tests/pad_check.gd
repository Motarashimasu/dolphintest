extends Node
## godot --headless --path Frontend/Godot -- --pad-check
## Feeds controller events (as a real pad would produce them) into the menus and reports.

var app: Control


func _ready() -> void:
	app = get_parent()
	app.ignore_focus = true
	Pad.ignore_focus = true
	_run.call_deferred()


func _btn(b: int, pressed: bool) -> void:
	var e := InputEventJoypadButton.new()
	e.device = 0
	e.button_index = b
	e.pressed = pressed
	e.pressure = 1.0 if pressed else 0.0
	Input.parse_input_event(e)
	for i in 3:
		await get_tree().process_frame


func _run() -> void:
	for i in 10:
		await get_tree().process_frame
	print("ui_down events: ", InputMap.action_get_events("ui_down"))
	print("ui_accept events: ", InputMap.action_get_events("ui_accept"))
	var c: Control = app.top().carousel
	var before: int = c.index
	await _btn(JOY_BUTTON_DPAD_DOWN, true)
	await _btn(JOY_BUTTON_DPAD_DOWN, false)
	print("PAD_CHECK dpad moved: ", c.index != before, " kind=", Pad.kind)
	var title: String = app._title.text
	await _btn(JOY_BUTTON_A, true)
	await _btn(JOY_BUTTON_A, false)
	print("PAD_CHECK A opened a screen: ", app._title.text != title, " (", app._title.text, ")")
	await _btn(JOY_BUTTON_B, true)
	await _btn(JOY_BUTTON_B, false)
	print("PAD_CHECK B went back: ", app._title.text == title)
	get_tree().quit()
