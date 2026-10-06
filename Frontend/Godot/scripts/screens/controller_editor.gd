extends "res://scripts/screens/form_screen.gd"
## Controller Setup > Create / Edit Config: map the GameCube controller by pressing buttons.
## A helper Dolphin (--input-test) reports presses with Dolphin's own device and input names, so
## the saved preset works in the game exactly as Dolphin's own mapping window would make it.
## The top rows double as a live tester: what the menus see and what Dolphin sees.

const Controllers := preload("res://scripts/controllers.gd")

## GameCube controls, in the order they're asked for: [profile key, label].
const CONTROLS := [
	["Buttons/A", "A"], ["Buttons/B", "B"], ["Buttons/X", "X"], ["Buttons/Y", "Y"],
	["Buttons/Z", "Z"], ["Buttons/Start", "Start"], ["Triggers/L", "L"], ["Triggers/R", "R"],
	["Main Stick/Up", "Stick Up"], ["Main Stick/Down", "Stick Down"],
	["Main Stick/Left", "Stick Left"], ["Main Stick/Right", "Stick Right"],
	["C-Stick/Up", "C-Stick Up"], ["C-Stick/Down", "C-Stick Down"],
	["C-Stick/Left", "C-Stick Left"], ["C-Stick/Right", "C-Stick Right"],
	["D-Pad/Up", "D-Pad Up"], ["D-Pad/Down", "D-Pad Down"],
	["D-Pad/Left", "D-Pad Left"], ["D-Pad/Right", "D-Pad Right"],
]
const LISTEN_SECONDS := 6.0
const GUARD_MS := 300   # a press this soon after "listen" is the button that started it

var base := {}            # preset being edited ({} = from scratch)
var _keys := {}           # profile key -> expression (everything, incl. keys we don't edit)
var _device := ""
var _devices: Array = []  # from Dolphin: [{name, source, title}]
var _helper: Object = null
var _helper_state := "starting"   # starting, ready, failed
var _dolphin_sees := "Press any button"
var _listen_key := ""
var _listen_since := 0
var _listen_left := 0.0
var _swallow_until := 0   # ignore menu input until (ms): the press that was just bound
var _held: Dictionary = {}   # inputs Dolphin reports as held right now
var _live_menu: Label
var _live_dolphin: Label


func setup(p_base: Dictionary) -> Node:
	base = p_base
	return self


func screen_music() -> String:
	return "game_menu"


func screen_title() -> String:
	return "Edit Config" if not base.is_empty() else "New Config"


func screen_desc() -> String:
	return "Select a button, press A, then press the button you want for it.\nThe top rows show what your controller is sending."


func on_enter() -> void:
	for kv in base.get("keys", []):
		_keys[kv[0]] = kv[1]
	_device = String(_keys.get("Device", ""))
	super()
	var strip := Style.panel(Color(Style.DARK, 0.85), 10)
	Style.place(strip, 40, 120, 1200, 44)
	add_child(strip)
	_live_menu = Style.label("", 20, Style.INK_LINE, 3, Style.DARK, true)
	_live_menu.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_live_menu.clip_text = true
	Style.place(_live_menu, 20, 0, 560, 44)
	strip.add_child(_live_menu)
	_live_dolphin = Style.label("", 20, Style.GOLD, 3, Style.DARK, true)
	_live_dolphin.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_live_dolphin.clip_text = true
	Style.place(_live_dolphin, 600, 0, 590, 44)
	strip.add_child(_live_dolphin)
	_refresh_live()
	_helper = Dolphin.start_helper(Settings.input_test_args(), _on_helper)
	if _helper == null:
		_helper_state = "failed"
		_refresh_live()


func _exit_tree() -> void:
	if _helper:
		Dolphin.stop_helper(_helper)
		_helper = null


func _text(expr: String) -> String:
	return "-" if expr == "" else expr.replace("`", "")


func build_rows() -> Array:
	var device_names: Array = []
	var device_labels: Array = []
	for d in _devices:
		device_names.append(d["name"])
		device_labels.append(d["name"])
	if _device != "" and not _device in device_names:
		device_names.append(_device)
		device_labels.append(_device + " (not connected)")
	var rows: Array = [
		{"type": "choice", "key": "device", "label": "Controller", "values": device_names,
			"names": device_labels, "value": _device,
			"desc": "The controller this config is for (picked automatically from\nthe first button you press)."},
	]
	for c in CONTROLS:
		rows.append({"type": "action", "key": c[0], "label": c[1], "value": _text(_keys.get(c[0], "")),
			"desc": tr("GameCube %s. Press %s, then the button you want for it.") % [c[1], Pad.prompt("accept")["key"]]})
	rows.append_array([
		{"type": "text", "key": "name", "label": "Save as", "value": String(base.get("name", "")) if not base.get("builtin", false) else "",
			"placeholder": "config name", "max_length": 40,
			"desc": "The name of this config in the preset list."},
		{"type": "action", "key": "save", "label": "Save Config", "color": "#3fbf6b",
			"desc": "Save it to SparkingData\\controllers and use it from now on."},
		{"type": "action", "key": "clear", "label": "Clear All", "color": "#e8663d",
			"desc": "Start the mapping from scratch."},
		{"type": "action", "key": "back", "label": "Back", "desc": "Back to Controller Setup (unsaved changes are lost)."},
	])
	return rows


func _menu_sees() -> String:
	return Pad.last_press if Pad.last_press != "" else "Press any button"


func _dolphin_text() -> String:
	match _helper_state:
		"starting":
			return "Starting..."
		"failed":
			return "Dolphin-Sparking didn't start"
	if _devices.is_empty():
		return "No controllers found"
	return _dolphin_sees


func _refresh_live() -> void:
	if _live_menu:
		_live_menu.text = tr("Menu sees:  %s") % _menu_sees()
		_live_dolphin.text = tr("Dolphin sees:  %s") % _dolphin_text()


## The live readout stays above the list (it doesn't scroll away).
func list_rect() -> Rect2:
	return Rect2(70, 196, 1140, 292)


func _process(delta: float) -> void:
	if list == null:
		return
	if _live_menu and _live_menu.text != tr("Menu sees:  %s") % _menu_sees():
		_refresh_live()
	if _listen_key != "":
		_listen_left -= delta
		if _listen_left <= 0.0:
			_stop_listening("Nothing pressed.")
		else:
			list.update_row(_listen_key, {"value": tr("Press a button...  %d") % ceili(_listen_left)})


func _on_helper(e: Dictionary) -> void:
	match String(e.get("event", "")):
		"devices":
			_devices = e.get("devices", [])
			if _helper_state != "ready":
				_helper_state = "ready"
			if _device == "" and not _devices.is_empty():
				_device = _pick_default_device()
			list.set_rows(build_rows())
		"input":
			var dev := String(e["device"])
			var inp := String(e["input"])
			var key := dev + "|" + inp
			if not e.get("pressed", false):
				_held.erase(key)
				return
			_held[key] = true
			_dolphin_sees = "%s: %s" % [dev, inp]
			_refresh_live()
			if _listen_key != "" and Time.get_ticks_msec() - _listen_since > GUARD_MS:
				_bind(dev, inp)
		"process_exited":
			if _helper_state != "failed":
				_helper_state = "failed"
				_helper = null
				_refresh_live()


## A gamepad rather than the keyboard/mouse, if there is one.
func _pick_default_device() -> String:
	for d in _devices:
		if not "Keyboard" in String(d["name"]) and not "Mouse" in String(d["name"]):
			return d["name"]
	return _devices[0]["name"]


func _bind(dev: String, inp: String) -> void:
	var key := _listen_key
	if dev != _device:
		# The first press decides the controller; after that, stick to one.
		var any_bound := false
		for c in CONTROLS:
			if _keys.get(c[0], "") != "":
				any_bound = true
		if any_bound and _device != "":
			app.toast(tr("That press came from another controller (%s).") % dev)
			return
		_device = dev
		list.update_row("device", {"value": dev})
	var expr := "`%s`" % inp
	_keys[key] = expr
	if key == "Triggers/L":
		_keys["Triggers/L-Analog"] = expr
	elif key == "Triggers/R":
		_keys["Triggers/R-Analog"] = expr
	_stop_listening("")
	# Menus ignore this press (and its release); then move on to the next control.
	_swallow_until = Time.get_ticks_msec() + 500
	var i := -1
	for n in CONTROLS.size():
		if CONTROLS[n][0] == key:
			i = n
	if i >= 0 and i + 1 < CONTROLS.size():
		list.focus_key(CONTROLS[i + 1][0])


func _listen(key: String) -> void:
	if _helper_state != "ready":
		app.toast(tr("Dolphin isn't reading controllers (%s).") % _dolphin_text())
		return
	_listen_key = key
	_listen_since = Time.get_ticks_msec()
	_listen_left = LISTEN_SECONDS


func _stop_listening(message: String) -> void:
	var key := _listen_key
	_listen_key = ""
	if key != "":
		list.update_row(key, {"value": _text(_keys.get(key, ""))})
	if message != "":
		app.toast(message, 1.5)


func on_input(event: InputEvent) -> bool:
	# While waiting for a press, and right after one, the menus stay still.
	if _listen_key != "":
		if event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
			_stop_listening("Cancelled.")
		return true
	if Time.get_ticks_msec() < _swallow_until:
		return true
	return super(event)


func on_value(key: String, value: Variant) -> void:
	if key == "device":
		_device = String(value)


func on_press(key: String) -> void:
	match key:
		"save":
			_save()
		"clear":
			for c in CONTROLS:
				_keys.erase(c[0])
			_keys.erase("Triggers/L-Analog")
			_keys.erase("Triggers/R-Analog")
			list.set_rows(build_rows(), "Buttons/A")
		"back":
			on_back()
		_:
			if key.contains("/"):
				_listen(key)


func _save() -> void:
	var name := String(list.get_value("name")).strip_edges()
	if name == "":
		app.toast("Give the config a name first.")
		list.focus_key("name")
		return
	if _device == "":
		app.toast("No controller yet: press a button to pick one.")
		return
	var keys: Array = [["Device", _device]]
	var done := {"Device": true}
	for c in CONTROLS:
		if _keys.get(c[0], "") != "":
			keys.append([c[0], _keys[c[0]]])
		done[c[0]] = true
	# Sensible defaults, then anything else the base config had (dead zones, rumble, ...).
	var extra := {"Triggers/L-Analog": _keys.get("Triggers/L-Analog", ""), "Triggers/R-Analog": _keys.get("Triggers/R-Analog", ""),
		"Main Stick/Dead Zone": _keys.get("Main Stick/Dead Zone", "15."),
		"C-Stick/Dead Zone": _keys.get("C-Stick/Dead Zone", "15."),
		"Options/Always Connected": _keys.get("Options/Always Connected", "True")}
	for k in _keys:
		if not done.has(k) and not extra.has(k):
			extra[k] = _keys[k]
	for k in extra:
		if String(extra[k]) != "":
			keys.append([k, extra[k]])
	var saved := Controllers.save_preset(name, keys)
	if saved == "":
		app.toast("Couldn't save the config.")
		return
	Settings.set_value("controller", "preset", saved)
	Controllers.apply(Controllers.find(saved))
	app.toast(tr("Saved and selected: %s") % saved)
	app.pop()
