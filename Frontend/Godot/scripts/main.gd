extends Control
## Root of the frontend: the BT3-style backdrop (sky, header, description bar), a stack of
## screens, the menus' structure, and the window handling around a running game
## (minimise while playing, small always-on-top in-game menu on a held Select).

const Style := preload("res://scripts/ui/style.gd")
const CarouselScreen := preload("res://scripts/screens/carousel_screen.gd")
const SCREENS := "res://scripts/screens/%s.gd"

const BASE_SIZE := Vector2i(1280, 720)

var _stack: Array = []
var _bg: Control
var _header: Control
var _title: Label
var _desc_bar: Control
var _desc: Label
var _hints: HBoxContainer
var _screens: Control
var _overlay: Control        # toast + debug log, above screens
var _toast: Label
var _toast_timer: SceneTreeTimer
var _log_panel: Panel
var _log_text: RichTextLabel

# In-game menu (compact window) state.
var _compact: Control = null
var _saved_window := {}
var _game_rect := Rect2i()   # last `window` event: the game picture, in screen pixels
var ignore_focus := false    # tests: accept input without window focus


func _ready() -> void:
	get_window().min_size = Vector2i(640, 360)
	get_window().title = "DRAGON BALL Sparking! Collection PC"
	_build_backdrop()
	Dolphin.event.connect(_on_dolphin_event)
	push(_main_menu())
	var user_args := OS.get_cmdline_user_args()
	var tour := user_args.find("--ui-tour")
	if tour >= 0 and tour + 1 < user_args.size():
		# Automated test: tests/ui_tour.gd drives the menus (see tests/run_ui_tour.py).
		var t: Node = load("res://tests/ui_tour.gd").new()
		t.config_path = user_args[tour + 1]
		add_child(t)
		return
	if not Settings.is_configured():
		push(load(SCREENS % "setup").new())
		toast("First, tell me where your files are.")


# --- Screen stack ------------------------------------------------------------------------

func push(screen: Control) -> void:
	if not _stack.is_empty():
		_stack.back().visible = false
	screen.app = self
	_stack.append(screen)
	_screens.add_child(screen)
	screen.on_enter()
	_apply_chrome(screen)


func pop() -> void:
	if _stack.size() <= 1:
		return
	var old: Control = _stack.pop_back()
	old.queue_free()
	var top: Control = _stack.back()
	top.visible = true
	_apply_chrome(top)
	top.on_resume()


func replace(screen: Control) -> void:
	var old: Control = _stack.pop_back()
	old.queue_free()
	_stack.append(screen)
	screen.app = self
	_screens.add_child(screen)
	screen.on_enter()
	_apply_chrome(screen)


## Pops screens until `predicate(screen)` is true for the top one (or only the root is left).
func pop_to(predicate: Callable) -> void:
	while _stack.size() > 1 and not predicate.call(_stack.back()):
		pop()


func top() -> Control:
	return _stack.back() if not _stack.is_empty() else null


func _apply_chrome(screen: Control) -> void:
	_title.text = screen.screen_title()
	_header.visible = screen.show_header
	_desc_bar.visible = screen.show_desc_bar
	set_desc(screen.screen_desc())


func set_title(text: String) -> void:
	_title.text = text


func set_desc(text: String) -> void:
	_desc.text = text


func toast(text: String, seconds := 3.0) -> void:
	_toast.text = text
	_toast.visible = true
	var t := get_tree().create_timer(seconds)
	_toast_timer = t
	await t.timeout
	if _toast_timer == t:
		_toast.visible = false


## Opens a screen that launches Dolphin, or Setup first if paths are missing.
func open_checked(script_name: String) -> void:
	if require_setup():
		open(script_name)


func open(script_name: String) -> Control:
	var s: Control = load(SCREENS % script_name).new()
	push(s)
	return s


## Every launch goes through here: missing paths open the Setup screen instead.
func require_setup() -> bool:
	if Settings.is_configured():
		return true
	toast("Missing: " + ", ".join(Settings.missing_paths()))
	open("setup")
	return false


# --- Menus -------------------------------------------------------------------------------

func _menu(title: String, items: Array) -> Control:
	return CarouselScreen.new().setup(title, items)


func _main_menu() -> Control:
	return _menu("Main Menu", [
		{"label": Settings.GAME["title"], "glyph": "3", "color": "#f2b531",
			"desc": "%s.\nPlay offline or online, set up controllers and codes." % Settings.GAME["full_title"],
			"action": func(): push(_game_menu())},
		{"label": "Video Settings", "glyph": "V", "color": "#9b6be6",
			"desc": "Renderer (OpenGL or Vulkan), resolution,\nand windowed or borderless.",
			"action": func(): open("video_settings")},
		{"label": "Options", "glyph": "O", "color": "#2ec4c4",
			"desc": "Button layout, HD textures, aspect ratio,\nyour files and other preferences.",
			"action": func(): open("options")},
		{"label": "Exit", "glyph": "X", "color": "#8a9bb0", "desc": "Close the collection.",
			"action": quit_app},
	])


func _game_menu() -> Control:
	return _menu("Tenkaichi 3", [
		{"label": "Play Offline", "glyph": "P", "color": "#f2b531",
			"desc": "Play on your own, with your own save data.\nSingle Battle, Team Battle, story mode: everything the game has.",
			"action": open_checked.bind("play_offline")},
		{"label": "Netplay", "glyph": "N", "color": "#3fa9f5",
			"desc": "Fight other players online. Browse public lobbies,\nhost a match, or let matchmaking find you one.",
			"action": func(): push(_netplay_menu())},
		{"label": "Controller Setup", "glyph": "C", "color": "#4cc38a",
			"desc": "Set up your controller for this game.",
			"action": func(): open("controller_setup")},
		{"label": "Modifications", "glyph": "M", "color": "#e8663d",
			"desc": "Turn this game's Gecko codes on or off\nfor offline play.",
			"action": open_checked.bind("modifications")},
		{"label": "Back", "glyph": "B", "color": "#8a9bb0", "back": true,
			"desc": "Back to the main menu."},
	])


func _netplay_menu() -> Control:
	return _menu("Netplay", [
		{"label": "Lobby Browser", "glyph": "L", "color": "#3fa9f5",
			"desc": "Public lobbies of players on this same version:\nmode, host, region and connection. Pick one to join.",
			"action": open_checked.bind("lobby_browser")},
		{"label": "Player Match", "glyph": "P", "color": "#f2b531",
			"desc": "Host your own lobby, or find a match\nfor the mode you want to play.",
			"action": func(): push(_player_match_menu())},
		{"label": "Ranked Match", "glyph": "R", "color": "#c94bd6", "disabled": true,
			"disabled_text": "Ranked Match is a work in progress.",
			"desc": "Work in progress."},
		{"label": "Back", "glyph": "B", "color": "#8a9bb0", "back": true,
			"desc": "Back to the game menu."},
	])


func _player_match_menu() -> Control:
	return _menu("Player Match", [
		{"label": "Host", "glyph": "H", "color": "#f2b531",
			"desc": "Create a lobby: room code or IP, Single or Team Battle,\nyour name, and whether it shows in the Lobby Browser.",
			"action": open_checked.bind("host_options")},
		{"label": "Find", "glyph": "F", "color": "#3fa9f5",
			"desc": "Pick Single Battle, Team Battle or Any, and get put in\nthe nearest open lobby (or host one others can find).",
			"action": open_checked.bind("find_match")},
		{"label": "Back", "glyph": "B", "color": "#8a9bb0", "back": true,
			"desc": "Back to the netplay menu."},
	])


func quit_app() -> void:
	if Dolphin.is_running():
		Dolphin.quit_session(2000)
		await Dolphin.exited
	get_tree().quit()


# --- Input -------------------------------------------------------------------------------

func _input(event: InputEvent) -> void:
	# A text field being edited lets go on Back / Up / Down (controller-friendly).
	var f := get_viewport().gui_get_focus_owner()
	if f is LineEdit and (event.is_action_pressed("ui_cancel") or event.is_action_pressed("ui_up")
			or event.is_action_pressed("ui_down")):
		f.release_focus()
		get_viewport().set_input_as_handled()


func _unhandled_input(event: InputEvent) -> void:
	# Controllers deliver events even when this window is in the background (game running).
	if not get_window().has_focus() and not ignore_focus:
		return
	if event is InputEventKey and event.pressed and event.keycode == KEY_F12:
		_toggle_log()
		get_viewport().set_input_as_handled()
		return
	if _compact:
		if _compact.has_method("handle_input") and _compact.handle_input(event):
			get_viewport().set_input_as_handled()
		elif event.is_action_pressed("ui_cancel"):
			close_ingame_menu()
			get_viewport().set_input_as_handled()
		return
	var t := top()
	if t == null:
		return
	if t.on_input(event):
		get_viewport().set_input_as_handled()
	elif event.is_action_pressed("ui_cancel"):
		t.on_back()
		get_viewport().set_input_as_handled()


# --- Running game: window handling -------------------------------------------------------

func _on_dolphin_event(name: String, data: Dictionary) -> void:
	match name:
		"window":
			if data.get("open", false):
				_game_rect = Rect2i(int(data.get("x", 0)), int(data.get("y", 0)),
						int(data.get("width", 0)), int(data.get("height", 0)))
		"game_started":
			if Settings.get_value("options", "minimize_while_playing"):
				get_window().mode = Window.MODE_MINIMIZED
		"game_stopped", "process_exited":
			if _compact:
				close_ingame_menu(false)
			show_window()
		"menu_request":
			open_ingame_menu()


func show_window() -> void:
	var w := get_window()
	if w.mode == Window.MODE_MINIMIZED:
		w.mode = Window.MODE_WINDOWED
	w.grab_focus()
	DisplayServer.window_move_to_foreground()


## Held Select in game: shrink this window to a small always-on-top panel over the game.
func open_ingame_menu() -> void:
	if _compact:
		return
	var t := top()
	if t == null or not t.has_method("make_ingame_panel"):
		return
	var panel: Control = t.make_ingame_panel()
	if panel == null:
		return
	var w := get_window()
	_saved_window = {"mode": w.mode, "size": w.size, "position": w.position}
	var psize := Vector2i(panel.size)
	_compact = panel
	_bg.visible = false
	_header.visible = false
	_desc_bar.visible = false
	_screens.visible = false
	add_child(panel)
	move_child(panel, _overlay.get_index())
	if w.mode != Window.MODE_WINDOWED:
		w.mode = Window.MODE_WINDOWED
	w.content_scale_size = psize
	w.min_size = psize
	w.size = psize
	if _game_rect.size.x > 0:
		w.position = _game_rect.position + (_game_rect.size - psize) / 2
	else:
		var screen := DisplayServer.screen_get_usable_rect(w.current_screen)
		w.position = screen.position + (screen.size - psize) / 2
	w.always_on_top = true
	# The game ignores the controller while the menu has focus.
	Dolphin.send("background_input off")
	show_window()


func close_ingame_menu(back_to_game := true) -> void:
	if not _compact:
		return
	_compact.queue_free()
	_compact = null
	Dolphin.send("background_input on")
	var w := get_window()
	w.always_on_top = false
	w.content_scale_size = BASE_SIZE
	w.min_size = Vector2i(640, 360)
	w.size = _saved_window.get("size", BASE_SIZE)
	w.position = _saved_window.get("position", w.position)
	_bg.visible = true
	_screens.visible = true
	var t := top()
	if t:
		_apply_chrome(t)
	# Minimising hands the focus back to the game window.
	if back_to_game and Dolphin.is_running():
		w.mode = Window.MODE_MINIMIZED


func is_ingame_menu_open() -> bool:
	return _compact != null


# --- Backdrop ----------------------------------------------------------------------------

func _build_backdrop() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	_bg = Control.new()
	_bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_bg)
	var sky := ColorRect.new()
	sky.color = Style.SKY
	sky.mouse_filter = Control.MOUSE_FILTER_IGNORE
	Style.place(sky, 0, 0, 1280, 720)
	_bg.add_child(sky)
	for c in [[640, 40, 260, 70, 0.85], [720, 18, 150, 70, 0.85], [980, 430, 240, 60, 0.7]]:
		var cloud := Style.panel(Color(Style.CLOUD, c[4]), 40)
		Style.place(cloud, c[0], c[1], c[2], c[3])
		_bg.add_child(cloud)
	var ground := ColorRect.new()
	ground.color = Style.GROUND
	ground.mouse_filter = Control.MOUSE_FILTER_IGNORE
	Style.place(ground, 0, 470, 1280, 60)
	_bg.add_child(ground)

	_desc_bar = Style.panel(Style.INK)
	var sb: StyleBoxFlat = _desc_bar.get_theme_stylebox("panel")
	sb.border_width_top = 4
	sb.border_color = Style.INK_LINE
	Style.place(_desc_bar, 0, 530, 1280, 190)
	add_child(_desc_bar)
	_desc = Style.label("", 28, Color.WHITE)
	_desc.label_settings.line_spacing = 8
	_desc.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	Style.place(_desc, 56, 30, 1000, 120)
	_desc_bar.add_child(_desc)
	_hints = HBoxContainer.new()
	_hints.add_theme_constant_override("separation", 22)
	_hints.alignment = BoxContainer.ALIGNMENT_END
	Style.place(_hints, 640, 140, 600, 36)
	_desc_bar.add_child(_hints)
	for h in [["▲▼", Style.INK_LINE, "Move"], ["A", Style.GOOD, "Select"], ["B", Style.POOR, "Back"]]:
		_hints.add_child(_hint(h[0], h[1], h[2]))

	_header = Control.new()
	_header.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_header)
	var emblem := Style.panel(Style.DARK, 42, 5, Style.GOLD)
	Style.place(emblem, 28, 18, 84, 84)
	_header.add_child(emblem)
	var star := Style.label("★", 44, Style.GOLD, 0, Color.BLACK, true)
	star.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	star.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	Style.place(star, 0, 0, 84, 84)
	emblem.add_child(star)
	_title = Style.label("", 64, Style.TITLE, 8, Style.TITLE_EDGE, true, 6)
	_title.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	Style.place(_title, 130, 14, 1100, 90)
	_header.add_child(_title)

	_screens = Control.new()
	_screens.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_screens)

	_overlay = Control.new()
	_overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_overlay)
	_toast = Style.label("", 20, Color.WHITE)
	_toast.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_toast.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_toast.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	var toast_bg := Style.panel(Style.DARK, 10)
	toast_bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	toast_bg.offset_left = -14
	toast_bg.offset_right = 14
	toast_bg.offset_top = -8
	toast_bg.offset_bottom = 8
	toast_bg.show_behind_parent = true
	_toast.add_child(toast_bg)
	Style.place(_toast, 840, 466, 400, 48)
	_toast.visible = false
	_overlay.add_child(_toast)

	_log_panel = Style.panel(Color(0, 0, 0, 0.85), 8)
	Style.place(_log_panel, 20, 20, 1240, 680)
	_log_panel.visible = false
	_overlay.add_child(_log_panel)
	_log_text = RichTextLabel.new()
	_log_text.scroll_following = true
	_log_text.add_theme_font_size_override("normal_font_size", 13)
	Style.place(_log_text, 12, 12, 1216, 656)
	_log_panel.add_child(_log_text)


func _hint(key: String, color: Color, text: String) -> Control:
	var box := HBoxContainer.new()
	box.add_theme_constant_override("separation", 8)
	var badge := Style.panel(color, 15)
	badge.custom_minimum_size = Vector2(34 if key.length() > 1 else 30, 30)
	var k := Style.label(key, 14, Style.INK, 0, Color.BLACK, true)
	k.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	k.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	k.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	badge.add_child(k)
	box.add_child(badge)
	box.add_child(Style.label(text, 17, Style.INK_LINE, 0, Color.BLACK, true))
	return box


func _toggle_log() -> void:
	_log_panel.visible = not _log_panel.visible
	if _log_panel.visible:
		_log_text.text = "Dolphin events (F12 to close)\n" + "\n".join(Dolphin.log_lines)
