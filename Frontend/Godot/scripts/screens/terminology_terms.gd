extends "res://scripts/screens/screen.gd"
## One Terminology category: the terms on the wheel (nothing to pick: scrolling is the point),
## the definition in the description bar, the demo GIF on the right. Terms with a video
## tutorial open it on A.

const Carousel := preload("res://scripts/ui/carousel.gd")
const GifPlayer := preload("res://scripts/ui/gif_player.gd")

var category := {}
var carousel: Control
var _player: Control
var _status: Label
var _debounce: SceneTreeTimer


func setup(p_category: Dictionary) -> Node:
	category = p_category
	return self


func screen_title() -> String:
	return String(category.get("name", "Terminology"))


func screen_desc() -> String:
	return _desc(carousel.current() if carousel else {})


func _desc(item: Dictionary) -> String:
	var t := String(item.get("desc", ""))
	if item.has("tutorial"):
		t += "   (A: watch the video tutorial)"
	return t


## Terms can't be picked: only Move and Back (A opens a tutorial where there is one).
func screen_hints() -> Array:
	return [["▲▼", Style.INK_LINE, "Move"], ["B", Style.POOR, "Back"]]


func on_enter() -> void:
	var color := Color(String(category.get("color", "#f2b531")))
	var items: Array = []
	var terms: Array = category.get("terms", [])
	for i in terms.size():
		var t: Dictionary = terms[i]
		items.append({"label": t["name"], "glyph": str(i + 1), "color": color, "desc": t["desc"],
			"tutorial": t.get("tutorial", "")})
		if not t.has("tutorial"):
			items[-1].erase("tutorial")
	carousel = Carousel.new()
	carousel.position = Vector2(0, 112)
	carousel.fit_width = 600.0
	add_child(carousel)
	carousel.set_items(items, 0)
	carousel.changed.connect(_on_changed)
	carousel.activated.connect(_on_activated)

	var frame := Style.panel(Style.DARK, 14, 4, color)
	Style.place(frame, 868, 112, 392, 400)
	add_child(frame)
	_player = GifPlayer.new()
	Style.place(_player, 12, 12, 368, 376)
	frame.add_child(_player)
	_status = Style.label("", 20, Style.INK_LINE, 0, Color.BLACK, true)
	_status.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_status.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	Style.place(_status, 20, 20, 352, 360)
	frame.add_child(_status)

	var names: Array = []
	for t in terms:
		names.append(t["name"])
	Demos.prefetch(names)
	Demos.demo_ready.connect(_on_demo_ready)
	Demos.status_changed.connect(_on_status)
	_show_demo()


func _exit_tree() -> void:
	if Demos.demo_ready.is_connected(_on_demo_ready):
		Demos.demo_ready.disconnect(_on_demo_ready)
	if Demos.status_changed.is_connected(_on_status):
		Demos.status_changed.disconnect(_on_status)


func _on_status(_text: String) -> void:
	_refresh_status()


func on_input(event: InputEvent) -> bool:
	return carousel.handle_input(event)


func _on_changed(_i: int) -> void:
	app.set_desc(screen_desc())
	_player.stop()
	_refresh_status()
	# Wait until the wheel settles before decoding (fast scrolling would start many decodes).
	var t := get_tree().create_timer(0.25)
	_debounce = t
	await t.timeout
	if _debounce == t and is_inside_tree():
		_show_demo()


func _on_activated(i: int) -> void:
	var url := String(carousel.items[i].get("tutorial", ""))
	if url != "":
		OS.shell_open(url)
		app.toast("Opening the tutorial video...")


func _term() -> String:
	return String(carousel.current().get("label", ""))


func _show_demo() -> void:
	var files := Demos.files_for(_term())
	if files.is_empty():
		_player.stop()
		Demos.want(_term())
	else:
		_player.play(files)
	_refresh_status()


func _on_demo_ready(s: String) -> void:
	if s == Demos.slug(_term()):
		_show_demo()


func _refresh_status() -> void:
	if not Demos.files_for(_term()).is_empty():
		_status.text = ""
		return
	match Demos.index_state():
		"loading", "":
			_status.text = "Downloading demo..."
		"failed":
			_status.text = "No demo yet.\n\n%s\n\nYou can also put a GIF named\n%s.gif\nin SparkingData\\terminology." % [Demos.status, Demos.slug(_term())]
		_:
			_status.text = "Downloading demo..." if Demos.listed(_term()) else "No demo for this one."


func _process(_d: float) -> void:
	# The status hides once the first frame is on screen.
	if _status.text != "" and _player.is_showing():
		_status.text = ""
