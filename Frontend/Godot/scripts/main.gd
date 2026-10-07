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
var _bg_image: TextureRect
var _scenery: Control
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
	Style.load_skin()
	Input.mouse_mode = Input.MOUSE_MODE_HIDDEN   # menus are controller / keyboard only
	if not "--ui-tour" in OS.get_cmdline_user_args():
		get_window().mode = menu_window_mode()
	_build_backdrop()
	Dolphin.event.connect(_on_dolphin_event)
	Presence.joined_from_discord.connect(_on_discord_join)
	Pad.kind_changed.connect(func(_k): _refresh_hints())
	var user_args := OS.get_cmdline_user_args()
	var tour := user_args.find("--ui-tour")
	# F9 (skin reload) rebuilds the scene: straight back to the menu, no splash.
	var reloading: bool = Engine.get_meta("skin_reload", false)
	Engine.set_meta("skin_reload", false)
	if tour < 0 and not "--no-splash" in user_args and not reloading:
		_show_splash()
	push(_main_menu())
	var lang_check := user_args.find("--lang-check")
	if lang_check >= 0 and not reloading:
		Settings.use_file(user_args[lang_check + 1])
		Pad.ignore_focus = true
		ignore_focus = true
		get_tree().root.add_child.call_deferred(load("res://tests/lang_check.gd").new())
	elif lang_check >= 0:
		ignore_focus = true
	if "--pad-check" in user_args:
		add_child(load("res://tests/pad_check.gd").new())
		return
	if tour >= 0 and tour + 1 < user_args.size():
		# Automated test: tests/ui_tour.gd drives the menus (see tests/run_ui_tour.py).
		var t: Node = load("res://tests/ui_tour.gd").new()
		t.config_path = user_args[tour + 1]
		add_child(t)
		return
	var reopen: String = Engine.get_meta("reopen", "")
	Engine.set_meta("reopen", "")
	if reopen != "":
		open(reopen)   # e.g. Options, after switching the language
	if not Settings.data_writable():
		push(_read_only_screen())
	elif not Lang.chosen():
		push(_language_menu(true))
	elif Settings.needs_setup():
		push(load(SCREENS % "setup").new())


## SparkingData can't be written (installed under Program Files...): nothing would be saved and
## Dolphin would hang at boot. Say so plainly instead.
func _read_only_screen() -> Control:
	var where := Settings.data_dir().replace("/", "\\")
	var s := _menu("Can't save here", [
		{"label": "Exit", "glyph": "X", "color": "#e8663d",
			"desc": tr("This folder is read-only for the launcher:\n%s\nMove the whole game folder somewhere like Documents or C:\\Games (not Program Files),\nor run the launcher as administrator.") % where,
			"action": func(): get_tree().quit()},
		{"label": "Continue anyway", "glyph": "C", "color": "#8a9bb0",
			"desc": tr("Settings won't be saved and games may not start."),
			"back": true},
	])
	return s


## First launch (and Options > Language): pick the menus' language. Each item speaks its own
## language, so it's readable whatever is set now.
func _language_menu(first_launch := false) -> Control:
	var items: Array = []
	var desc := {
		"en": "Menus in English.\nYou can change this later in Options.",
		"es": "Menús en español.\nPuedes cambiarlo más tarde en Opciones.",
		"it": "Menu in italiano.\nPuoi cambiarlo più tardi in Opzioni.",
	}
	for code in Lang.LANGUAGES:
		items.append({"label": Lang.NAMES[code], "glyph": code.to_upper(), "color": "#f2b531",
			"desc": desc[code], "action": func(): choose_language(code)})
	var s := _menu("Language / Idioma / Lingua", items)
	s.set_meta("first_launch", first_launch)
	return s


## Switches the language and rebuilds the menus in it (no splash), coming back to `reopen`.
func choose_language(code: String, reopen := "") -> void:
	Lang.set_language(code)
	Engine.set_meta("skin_reload", true)
	Engine.set_meta("reopen", reopen)
	# After this input event is done (the scene it belongs to is about to go away).
	get_tree().reload_current_scene.call_deferred()


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
	if _bg_image:
		_bg_image.texture = Style.background(music_for_stack())
		if _scenery:
			_scenery.visible = _bg_image.texture == null
	set_desc(screen.current_desc() if screen.has_method("current_desc") else screen.screen_desc())
	if not _splash:
		Music.play(music_for_stack())
	_refresh_hints()


## Button hints for the top screen, in the controller's own prompts (A/B, ×/O or Enter/Esc).
func _refresh_hints() -> void:
	var t := top()
	if t == null:
		return
	for c in _hints.get_children():
		c.queue_free()
	for h in t.screen_hints():
		_hints.add_child(_hint(h[0], h[1], h[2]))


## The music of the top screen, or of the nearest screen below that names one.
func music_for_stack() -> String:
	for i in range(_stack.size() - 1, -1, -1):
		var m: String = _stack[i].screen_music()
		if m != "":
			return m
	return ""


func set_title(text: String) -> void:
	_title.text = text


func set_desc(text: String) -> void:
	_desc.text = text
	# Long definitions get a smaller font so they fit the bar.
	var ls := _desc.label_settings
	var size := 28
	while size > 17:
		var h := ls.font.get_multiline_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, _desc.size.x, size).y
		if h * 1.2 <= _desc.size.y:
			break
		size -= 1
	ls.font_size = size


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
	if not Settings.data_writable():
		toast(tr("The game folder is read-only (Program Files?). Move it, or run as administrator."), 5.0)
		return false
	if Settings.is_configured():
		return true
	toast(tr("Missing: %s") % ", ".join(Settings.missing_paths()))
	open("setup")   # only the missing parts can be fixed there
	return false


# --- Menus -------------------------------------------------------------------------------

func _menu(title: String, items: Array, music := "") -> Control:
	return CarouselScreen.new().setup(title, items, 0, music)


func _main_menu() -> Control:
	return _menu("Main Menu", [
		{"label": Settings.GAME["title"], "glyph": "3", "color": "#f2b531",
			"desc": tr("%s.\nPlay offline or online, set up controllers and codes.") % Settings.GAME["full_title"],
			"action": func(): push(_game_menu())},
		{"label": "Video Settings", "glyph": "V", "color": "#9b6be6",
			"desc": "Change your video settings here.",
			"action": func(): open("video_settings")},
		{"label": "Options", "glyph": "O", "color": "#2ec4c4",
			"desc": "Aspect ratio, music, health %, match HUD\nand other preferences.",
			"action": func(): open("options")},
		{"label": "Exit", "glyph": "X", "color": "#8a9bb0", "desc": "Close the collection.",
			"action": quit_app},
	], "main_menu")


func _game_menu() -> Control:
	var items: Array = [
		{"label": "Play Offline", "glyph": "P", "color": "#f2b531",
			"desc": "Play on your own, with your own save data.\nSingle Battle, Team Battle, story mode: everything the game has.",
			"action": open_checked.bind("play_offline")},
		{"label": "DRAGON NET", "glyph": "D", "color": "#3fa9f5",
			"desc": "Fight other players online. Browse public lobbies,\nhost a match, or let matchmaking find you one.",
			"action": func(): push(_netplay_menu())},
		{"label": "Controller Setup", "glyph": "C", "color": "#4cc38a",
			"desc": "Set up your controller for this game.",
			"action": func(): open("controller_setup")},
		{"label": "Modifications", "glyph": "M", "color": "#e8663d",
			"desc": "Graphics (Enhanced / Legacy), button prompts\n(GameCube / PlayStation / Xbox) and codes.",
			"action": func(): push(_modifications_menu())},
		{"label": "Tenkaichi Terminology", "glyph": "T", "color": "#ffd23f",
			"desc": "What every mechanic and tech is called, what it does, and a demo of each.\nCreated by Majin Xu & Creatful_Chaos of 'BT3 North America'.",
			"action": func(): push(_terminology_menu())},
		{"label": "Back", "glyph": "B", "color": "#8a9bb0", "back": true,
			"desc": "Back to the main menu."},
	]
	if dev_tools():
		items.insert(items.size() - 1, {"label": "Capture Battle States", "glyph": "S", "color": "#9b6be6",
			"desc": "Developer: record the states every DRAGON NET match boots into.\nRuns with the netplay save and the game's default codes (PAL60 = 30 fps).",
			"action": open_capture})
	return _menu("Tenkaichi 3", items, "game_menu")


func open_capture() -> void:
	if require_setup():
		push(load(SCREENS % "play_offline").new().setup(true))


## Developer tools (Options > Developer tools, or --dev): battle state capture.
static func dev_tools() -> bool:
	return bool(Settings.get_value("options", "dev_tools")) or "--dev" in OS.get_cmdline_user_args()


var _terminology: Dictionary = {}


func terminology() -> Dictionary:
	if _terminology.is_empty():
		var data = JSON.parse_string(FileAccess.get_file_as_string("res://data/terminology.json"))
		_terminology = data if data is Dictionary else {"categories": []}
	return _terminology


func _terminology_menu() -> Control:
	var doc := terminology()
	var items: Array = []
	for c in doc.get("categories", []):
		var cat: Dictionary = c
		items.append({"label": cat["name"], "glyph": cat["glyph"], "color": cat["color"],
			"desc": tr("%s\n%d terms.") % [cat["desc"], cat["terms"].size()],
			"action": func(): push(load(SCREENS % "terminology_terms").new().setup(cat))})
	items.append({"label": "Contributors", "glyph": "C", "color": "#8a9bb0",
		"desc": String(doc.get("contributors", ""))})
	items.append({"label": "Back", "glyph": "B", "color": "#8a9bb0", "back": true,
		"desc": "Back to the game menu."})
	return _menu("Terminology", items, "terminology")


func _modifications_menu() -> Control:
	return _menu("Modifications", [
		{"label": "Graphics", "glyph": "G", "color": "#9b6be6",
			"desc": func(): return tr("Enhanced (HD textures) or Legacy (original textures).\nNow: %s") % Settings.get_value("options", "graphics"),
			"action": func(): push(load(SCREENS % "variant_picker").new().setup("graphics"))},
		{"label": "Button Prompts", "glyph": "B", "color": "#3fa9f5",
			"desc": func(): return tr("GameCube, PlayStation or Xbox buttons in the game.\nNow: %s") % Settings.option_name("buttons", Settings.get_value("options", "buttons")),
			"action": func(): push(load(SCREENS % "variant_picker").new().setup("buttons"))},
		{"label": "Codes", "glyph": "C", "color": "#e8663d",
			"desc": "Turn this game's codes on or off\nfor offline play.",
			"action": open_checked.bind("modifications")},
		{"label": "Back", "glyph": "B", "color": "#8a9bb0", "back": true,
			"desc": "Back to the game menu."},
	], "game_menu")


func _netplay_menu() -> Control:
	return _menu("DRAGON NET", [
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
	], "netplay")


func _player_match_menu() -> Control:
	return _menu("Player Match", [
		{"label": "Host", "glyph": "H", "color": "#f2b531",
			"desc": "Create a lobby: room code or IP, Single or Team Battle,\nyour name, and whether it shows in the Lobby Browser.",
			"action": open_checked.bind("host_options")},
		{"label": "Find", "glyph": "F", "color": "#3fa9f5",
			"desc": "Pick Single Battle, Team Battle or Any, and get put in\nthe nearest open lobby (or host one others can find).",
			"action": open_checked.bind("find_match")},
		{"label": "Back", "glyph": "B", "color": "#8a9bb0", "back": true,
			"desc": "Back to the DRAGON NET menu."},
	], "netplay")


func quit_app() -> void:
	if Dolphin.is_running():
		Dolphin.quit_session(2000)
		await Dolphin.exited
	get_tree().quit()


# --- Input -------------------------------------------------------------------------------

func _input(event: InputEvent) -> void:
	# Controller and keyboard only: the mouse would steal the selection (hover, clicks, wheel).
	if event is InputEventMouse:
		get_viewport().set_input_as_handled()
		return
	# The controller belongs to the game while it runs (unless the in-game menu is open). Dropped
	# here, before the menus' own input handling sees it.
	if (event is InputEventJoypadButton or event is InputEventJoypadMotion) and not Pad.accepts():
		Pad.note_ignored(event)
		get_viewport().set_input_as_handled()
		return
	# A text field being edited lets go on Back / Up / Down (controller-friendly).
	var f := get_viewport().gui_get_focus_owner()
	if f is LineEdit and (event.is_action_pressed("ui_cancel") or event.is_action_pressed("ui_up")
			or event.is_action_pressed("ui_down")):
		f.release_focus()
		get_viewport().set_input_as_handled()


## Marks the event as used, unless this screen just left the tree (e.g. a language switch).
func _handled() -> void:
	if is_inside_tree():
		get_viewport().set_input_as_handled()


func _unhandled_input(event: InputEvent) -> void:
	# Controllers deliver events even when this window is in the background (game running).
	if not get_window().has_focus() and not ignore_focus and Dolphin.is_running() and not _compact:
		return
	if _splash:
		if event.is_pressed() and not event.is_echo() and not event is InputEventMouseMotion:
			_end_splash()
		_handled()
		return
	if event is InputEventKey and event.pressed and event.keycode == KEY_F9:
		# After saving look/menu_look.tres or Backdrop.tscn in the editor: reload and rebuild.
		Style.load_skin()
		Sfx.reload()
		Engine.set_meta("skin_reload", true)
		get_tree().reload_current_scene()
		_handled()
		return
	if event is InputEventKey and event.pressed and event.keycode == KEY_F12:
		_toggle_log()
		_handled()
		return
	if _compact:
		if _compact.has_method("handle_input") and _compact.handle_input(event):
			_handled()
		elif event.is_action_pressed("ui_cancel"):
			Sfx.play("back")
			close_ingame_menu()
			_handled()
		return
	var t := top()
	if t == null:
		return
	if t.on_input(event):
		_handled()
	elif event.is_action_pressed("ui_cancel"):
		Sfx.play("back")
		t.on_back()
		_handled()


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
		"alert":
			# Dolphin's own warnings and errors (it answers them itself): show them here too.
			if String(data.get("severity", "")) in ["warning", "critical"]:
				var text := String(data.get("text", "")).split("\n")[0]
				toast("Dolphin: " + text.left(160), 6.0)


## "Ask to Join" accepted in Discord: open that lobby (unless something is already running).
func _on_discord_join(target: String) -> void:
	show_window()
	if Dolphin.is_running():
		toast("Leave the current lobby or game first, then join from Discord again.", 4.0)
		return
	var lobby: Control = load(SCREENS % "lobby").new()
	push(lobby.setup("join", Settings.join_args(target), "any"))


## Brings the menus back (after a game): in the player's chosen display mode.
func show_window() -> void:
	var w := get_window()
	if w.mode == Window.MODE_MINIMIZED or (not _compact and w.mode != menu_window_mode()):
		w.mode = menu_window_mode()
	w.grab_focus()
	DisplayServer.window_move_to_foreground()


## Video Settings > Menu display: borderless fullscreen (default) or a window.
func menu_window_mode() -> Window.Mode:
	return Window.MODE_WINDOWED if Settings.get_value("video", "menu_display") == "window" \
			else Window.MODE_FULLSCREEN


func apply_menu_display() -> void:
	if _compact or Dolphin.is_running():
		return
	var w := get_window()
	w.mode = menu_window_mode()
	if w.mode == Window.MODE_WINDOWED:
		w.size = BASE_SIZE
		w.move_to_center()


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
	# The game ignores the controller from now on; this menu takes it, focused or not.
	Dolphin.send("background_input off")
	Pad.menu_open = true
	var w := get_window()
	_saved_window = {"mode": w.mode, "size": w.size, "position": w.position}
	_compact = panel
	_bg.visible = false
	_header.visible = false
	_desc_bar.visible = false
	_screens.visible = false
	add_child(panel)
	move_child(panel, _overlay.get_index())
	# Leaving fullscreen / minimised takes the OS a moment; size the window once it has.
	if w.mode != Window.MODE_WINDOWED:
		w.mode = Window.MODE_WINDOWED
		await get_tree().process_frame
		await get_tree().process_frame
	if _compact != panel:
		return   # closed again meanwhile
	_place_compact(Vector2i(panel.size))
	w.always_on_top = true
	show_window()
	# Some window managers re-apply the old geometry after a restore: place it once more.
	await get_tree().create_timer(0.15).timeout
	if _compact == panel:
		_place_compact(Vector2i(panel.size))


func _place_compact(psize: Vector2i) -> void:
	var w := get_window()
	w.content_scale_size = psize
	w.min_size = psize
	w.size = psize
	if _game_rect.size.x > 0:
		w.position = _game_rect.position + (_game_rect.size - psize) / 2
	else:
		var screen := DisplayServer.screen_get_usable_rect(w.current_screen)
		w.position = screen.position + (screen.size - psize) / 2


func close_ingame_menu(back_to_game := true) -> void:
	if not _compact:
		return
	_compact.queue_free()
	_compact = null
	Pad.menu_open = false
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
	if back_to_game and Dolphin.is_running():
		# Windows won't give the focus back by itself: Dolphin raises its own window (it can,
		# while we're still the foreground app), then this one gets out of the way.
		Dolphin.send("focus_game")
		await get_tree().create_timer(0.12).timeout
		if not _compact and Dolphin.is_running():
			w.mode = Window.MODE_MINIMIZED
			Dolphin.send("focus_game")   # in case minimising activated something else
	elif not Dolphin.is_running():
		w.mode = menu_window_mode()


func is_ingame_menu_open() -> bool:
	return _compact != null


# --- Splash ------------------------------------------------------------------------------

## Shown over the menu at startup: fade in, hold, fade out. Any button skips it. The picture is
## res://splash/splash.png (also Godot's own boot splash, so the two join up seamlessly).
const SPLASH_IMAGE := "res://splash/splash.png"
const SPLASH_HOLD := 2.0

var _splash: Control = null
var _splash_tween: Tween


func _show_splash() -> void:
	_splash = ColorRect.new()
	_splash.color = Color.BLACK
	_splash.mouse_filter = Control.MOUSE_FILTER_STOP
	Style.place(_splash, 0, 0, 1280, 720)
	add_child(_splash)
	if ResourceLoader.exists(SPLASH_IMAGE):
		var pic := TextureRect.new()
		pic.texture = load(SPLASH_IMAGE)
		pic.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		pic.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
		pic.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		pic.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_splash.add_child(pic)
	# Godot's boot splash showed the same picture: hold it, then fade to the menu.
	_splash_tween = create_tween()
	_splash_tween.tween_interval(SPLASH_HOLD)
	_splash_tween.tween_property(_splash, "modulate:a", 0.0, 0.5)
	_splash_tween.tween_callback(_end_splash)


func _end_splash() -> void:
	if not _splash:
		return
	if _splash_tween and _splash_tween.is_valid():
		_splash_tween.kill()
	_splash.queue_free()
	_splash = null
	Music.play(music_for_stack())


func is_splash_showing() -> bool:
	return _splash != null


# --- Backdrop ----------------------------------------------------------------------------

func _build_backdrop() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	_bg = Control.new()
	_bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_bg)
	# The background is a scene you can edit in the Godot editor (scenes/Backdrop.tscn). Its
	# "MenuPicture" shows the look's per-menu pictures; "Scenery" hides while one is shown.
	var backdrop: Node = load("res://scenes/Backdrop.tscn").instantiate()
	_bg.add_child(backdrop)
	_bg_image = backdrop.get_node_or_null("MenuPicture")
	_scenery = backdrop.get_node_or_null("Scenery")

	_desc_bar = Style.panel(Style.INK)
	var sb: StyleBoxFlat = _desc_bar.get_theme_stylebox("panel")
	sb.border_width_top = 4
	sb.border_color = Style.INK_LINE
	Style.place(_desc_bar, 0, 530, 1280, 190)
	add_child(_desc_bar)
	var desc_tex := Style.DESC_IMAGE
	if desc_tex:
		var pic := TextureRect.new()
		pic.texture = desc_tex
		pic.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		pic.stretch_mode = TextureRect.STRETCH_SCALE
		pic.mouse_filter = Control.MOUSE_FILTER_IGNORE
		pic.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		_desc_bar.add_child(pic)
	_desc = Style.label("", 28, Style.DESC_TEXT)
	_desc.label_settings.line_spacing = 8
	_desc.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	Style.place(_desc, 56, 30, 1000, 120)
	_desc_bar.add_child(_desc)
	_hints = HBoxContainer.new()
	_hints.add_theme_constant_override("separation", 22)
	_hints.alignment = BoxContainer.ALIGNMENT_END
	Style.place(_hints, 640, 140, 600, 36)
	_desc_bar.add_child(_hints)

	_header = Control.new()
	_header.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_header)
	_title = Style.label("", Style.TITLE_SIZE, Style.TITLE, Style.TITLE_OUTLINE, Style.TITLE_EDGE, true,
			Style.TITLE_SHADOW)
	_title.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	Style.place(_title, 40, 14, 1200, 90)
	_header.add_child(_title)

	_screens = Control.new()
	_screens.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_screens)

	_overlay = Control.new()
	_overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_overlay)
	_toast = Style.label("", 20, Style.TOAST_TEXT)
	_toast.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_toast.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_toast.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	var toast_bg := Style.panel(Style.TOAST_BG, 10)
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
	if key == "A" or key == "B":
		var p: Dictionary = Pad.prompt("accept" if key == "A" else "back")
		key = p["key"]
		color = p["color"]
	var box := HBoxContainer.new()
	box.add_theme_constant_override("separation", 8)
	var badge := Style.panel(color, 15)
	badge.custom_minimum_size = Vector2(maxf(30, 14 + 9 * key.length()), 30)
	var k := Style.label(key, 14, Style.INK, 0, Color.BLACK, "button")
	k.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	k.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	k.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	badge.add_child(k)
	box.add_child(badge)
	box.add_child(Style.label(text, 17, Style.INK_LINE, 0, Color.BLACK, "button"))
	return box


func _toggle_log() -> void:
	_log_panel.visible = not _log_panel.visible
	if _log_panel.visible:
		var pads := PackedStringArray()
		for id in Input.get_connected_joypads():
			pads.append("%d: %s" % [id, Input.get_joy_name(id)])
		_log_text.text = "Controllers: %s\nWindow focused: %s\nController presses:\n  %s\n\nDolphin events (F12 to close)\n%s" % [
			", ".join(pads) if not pads.is_empty() else "none", get_window().has_focus(),
			"\n  ".join(Pad.press_log) if not Pad.press_log.is_empty() else "(none yet)", "\n".join(Dolphin.log_lines)]
