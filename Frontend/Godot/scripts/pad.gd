extends Node
## Controller support for the menus (Xbox One / Series, DualShock 4, DualSense; any pad in
## Godot's controller database works the same way):
##  - D-pad and left stick move, A / Cross selects (Start too), B / Circle goes back;
##  - holding a direction repeats it, like a keyboard key;
##  - remembers what was used last (keyboard, Xbox-style or PlayStation pad) so the menus can show
##    matching button prompts.
## Pads are picked up automatically when plugged in (Godot handles hot-plugging).

signal kind_changed(kind: String)   # "keyboard", "xbox", "playstation"

const STICK_ON := 0.55      # past this the stick counts as a direction
const STICK_OFF := 0.35     # back under this it's neutral again
const REPEAT_DELAY := 0.38
const REPEAT_EVERY := 0.085
const DPAD := {JOY_BUTTON_DPAD_UP: "up", JOY_BUTTON_DPAD_DOWN: "down",
	JOY_BUTTON_DPAD_LEFT: "left", JOY_BUTTON_DPAD_RIGHT: "right"}

var kind := "keyboard"
var last_press := ""        # "Xbox Controller: A" - shown by the controller tester
var press_log: PackedStringArray = []   # recent pad presses, for the F12 log
var ignore_focus := false   # tests: accept input without window focus

var _stick := ""            # direction the left stick is held in ("" = neutral)
var _held := ""             # direction being repeated (D-pad or stick)
var _held_device := -1
var _timer := 0.0


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_ensure_actions()
	Input.joy_connection_changed.connect(func(device: int, connected: bool):
		if connected:
			_set_kind(_kind_of(device)))
	# A pad already plugged in decides the prompts from the start.
	var pads := Input.get_connected_joypads()
	if not pads.is_empty():
		_set_kind(_kind_of(pads[0]))


## A / Cross and Start select, B / Circle goes back, D-pad moves (Godot's defaults cover most of
## it; this makes sure of it). The left stick is handled below, with its own repeat.
func _ensure_actions() -> void:
	var want := {
		"ui_accept": [JOY_BUTTON_A, JOY_BUTTON_START],
		"ui_cancel": [JOY_BUTTON_B],
		"ui_up": [JOY_BUTTON_DPAD_UP], "ui_down": [JOY_BUTTON_DPAD_DOWN],
		"ui_left": [JOY_BUTTON_DPAD_LEFT], "ui_right": [JOY_BUTTON_DPAD_RIGHT],
	}
	for action in want:
		# Stick motion in the ui_ actions would fire on every tiny movement: we do it ourselves.
		for e in InputMap.action_get_events(action):
			if e is InputEventJoypadMotion:
				InputMap.action_erase_event(action, e)
		for button in want[action]:
			var ev := InputEventJoypadButton.new()
			ev.button_index = button
			ev.device = -1   # any pad
			if not InputMap.action_has_event(action, ev):
				InputMap.action_add_event(action, ev)


func _kind_of(device: int) -> String:
	var name := Input.get_joy_name(device).to_lower()
	for w in ["ps4", "ps5", "dualsense", "dualshock", "playstation", "sony"]:
		if w in name:
			return "playstation"
	return "xbox"


func _set_kind(k: String) -> void:
	if k != kind:
		kind = k
		kind_changed.emit(k)


## Controllers also reach a background window: only ignore them while a game is running (so
## presses meant for the game don't move the menus).
func _focused() -> bool:
	return ignore_focus or get_window().has_focus() or not Dolphin.is_running()


func _input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed:
		_set_kind("keyboard")
	elif event is InputEventJoypadButton:
		if event.pressed:
			last_press = "%s: %s" % [Input.get_joy_name(event.device), button_name(event.button_index)]
			press_log.append(last_press + ("" if _focused() else "  (ignored: game running, menu not focused)"))
			if press_log.size() > 40:
				press_log = press_log.slice(press_log.size() - 40)
		if not _focused():
			return
		if event.pressed:
			_set_kind(_kind_of(event.device))
		if DPAD.has(event.button_index):
			if event.pressed:
				_start_hold(DPAD[event.button_index], event.device)
			elif _held == DPAD[event.button_index]:
				_held = _stick
	elif event is InputEventJoypadMotion:
		if event.axis != JOY_AXIS_LEFT_X and event.axis != JOY_AXIS_LEFT_Y:
			return
		get_viewport().set_input_as_handled()   # the stick only moves through us
		if not _focused():
			return
		var x := Input.get_joy_axis(event.device, JOY_AXIS_LEFT_X)
		var y := Input.get_joy_axis(event.device, JOY_AXIS_LEFT_Y)
		var dir := _stick
		if maxf(absf(x), absf(y)) < STICK_OFF:
			dir = ""
		elif maxf(absf(x), absf(y)) >= STICK_ON:
			if absf(y) >= absf(x):
				dir = "down" if y > 0 else "up"
			else:
				dir = "right" if x > 0 else "left"
		if dir == _stick:
			return
		_stick = dir
		if dir == "":
			_held = ""
		else:
			_set_kind(_kind_of(event.device))
			_start_hold(dir, event.device)
			_send(dir)   # D-pad presses arrive as real events; stick presses we send


static func button_name(b: int) -> String:
	return {JOY_BUTTON_A: "A / Cross", JOY_BUTTON_B: "B / Circle", JOY_BUTTON_X: "X / Square",
		JOY_BUTTON_Y: "Y / Triangle", JOY_BUTTON_BACK: "Back / Share", JOY_BUTTON_GUIDE: "Guide",
		JOY_BUTTON_START: "Start / Options", JOY_BUTTON_LEFT_STICK: "Left stick click",
		JOY_BUTTON_RIGHT_STICK: "Right stick click", JOY_BUTTON_LEFT_SHOULDER: "LB / L1",
		JOY_BUTTON_RIGHT_SHOULDER: "RB / R1", JOY_BUTTON_DPAD_UP: "D-pad up",
		JOY_BUTTON_DPAD_DOWN: "D-pad down", JOY_BUTTON_DPAD_LEFT: "D-pad left",
		JOY_BUTTON_DPAD_RIGHT: "D-pad right"}.get(b, "button %d" % b)


func _start_hold(dir: String, device: int) -> void:
	_held = dir
	_held_device = device
	_timer = REPEAT_DELAY


func _process(delta: float) -> void:
	if _held == "":
		return
	# Still held? (D-pad button or stick)
	var still := _held == _stick
	for b in DPAD:
		if DPAD[b] == _held and Input.is_joy_button_pressed(_held_device, b):
			still = true
	if not still or not _focused():
		_held = ""
		return
	_timer -= delta
	if _timer <= 0.0:
		_timer = REPEAT_EVERY
		_send(_held)


func _send(dir: String) -> void:
	var press := InputEventAction.new()
	press.action = "ui_" + dir
	press.pressed = true
	Input.parse_input_event(press)
	var release := InputEventAction.new()
	release.action = "ui_" + dir
	release.pressed = false
	Input.parse_input_event(release)


## Button prompt for the current controller: "accept" / "back".
func prompt(button: String) -> Dictionary:
	match kind:
		"playstation":
			return {"accept": {"key": "×", "color": Color("#7aa7ff")},
				"back": {"key": "O", "color": Color("#ff6b6b")}}[button]
		"xbox":
			return {"accept": {"key": "A", "color": Color("#3fbf6b")},
				"back": {"key": "B", "color": Color("#e8663d")}}[button]
	return {"accept": {"key": "Enter", "color": Color("#cfe9ee")},
		"back": {"key": "Esc", "color": Color("#cfe9ee")}}[button]
