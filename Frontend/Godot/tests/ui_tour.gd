extends Node

const Style := preload("res://scripts/ui/style.gd")
## Automated walk through every menu and the netplay flow, with screenshots. Started by
## tests/run_ui_tour.py (which supplies a fake lobby server and a second player):
##   godot --path Frontend/Godot -- --ui-tour <config.json>
## Prints "TOUR_EVENT <name>" lines for the harness and "TOUR_RESULT ok|fail" at the end.

var config_path := ""
var app: Control
var out_dir := ""
var failures: PackedStringArray = []
var shots := 0
var recorder: Translation


func _ready() -> void:
	app = get_parent()
	app.ignore_focus = true
	Pad.ignore_focus = true
	app.transitions = false   # no half-faded screenshots (the fades get their own check)
	var cfg: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(config_path))
	out_dir = cfg["out_dir"]
	Settings.use_file(cfg["settings_file"])
	for section in cfg.get("settings", {}):
		for key in cfg["settings"][section]:
			Settings.set_value(section, key, cfg["settings"][section][key])
	Music.rescan()
	Lang.apply()
	# Record every text the menus show (English run), to check the Spanish / Italian tables.
	recorder = load("res://tests/string_recorder.gd").new()
	recorder.locale = "en"
	TranslationServer.add_translation(recorder)
	_run.call_deferred()


func _run() -> void:
	await _tour()
	_check_translations()
	print("TOUR_RESULT ", "ok" if failures.is_empty() else "fail")
	for f in failures:
		print("TOUR_FAIL ", f)
	if not failures.is_empty():
		print("--- last Dolphin events ---")
		for l in Dolphin.log_lines.slice(maxi(Dolphin.log_lines.size() - 40, 0)):
			print("  ", l)
	if Dolphin.is_running():
		Dolphin.quit_session(1500)
		await _wait(func(): return not Dolphin.is_running(), 5.0)
	get_tree().quit(0 if failures.is_empty() else 1)


## Every text shown during the (English) tour must be in the Spanish and Italian tables, unless
## it has no words to translate (names, numbers, codes...).
func _check_translations() -> void:
	TranslationServer.remove_translation(recorder)
	var seen: Array = recorder.seen.keys()
	seen.sort()
	var f := FileAccess.open(out_dir.path_join("strings_seen.json"), FileAccess.WRITE)
	f.store_string(JSON.stringify(seen, "  "))
	f.close()
	var ignore: Array = JSON.parse_string(FileAccess.get_file_as_string("res://tests/untranslated_ok.json"))["texts"]
	# Terminology content comes from the community doc and stays in English.
	var term_text := FileAccess.get_file_as_string("res://data/terminology.json")
	for code in ["es", "it"]:
		var table: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://data/translations/%s.json" % code))
		# Text built from a translated template ("Pad buffer: 5" from "Pad buffer: %d") is fine.
		var templates: Array[RegEx] = []
		for k in table:
			if "%s" in k or "%d" in k:
				var rx := "(?s)^" + _regex_escape(k).replace("%s", ".*?").replace("%d", "-?\\d+") + "$"
				templates.append(RegEx.create_from_string(rx))
		var missing: Array = []
		for s in seen:
			if s in ignore or not RegEx.create_from_string("[A-Za-z]{2}").search(s):
				continue
			if JSON.stringify(s).trim_prefix("\"").trim_suffix("\"") in term_text:
				continue
			if s.begins_with("◀") or s.begins_with("★") or s.begins_with("[b]") or "   ·   " in s \
					or RegEx.create_from_string("^\\d+ ms|^[A-Z]{2}$|Sparking Standard|^Tecbox layout|^\\S+  \\(.+\\)$").search(s):
				continue   # composed from translated pieces
			if templates.any(func(rx): return rx.search(s) != null):
				continue
			if String(table.get(s, "")) == "":
				missing.append(s)
		if not missing.is_empty():
			print("    missing in %s.json: %s" % [code, JSON.stringify(missing)])
		check("every text shown has a %s translation (%d missing)" % [code, missing.size()], missing.is_empty())


func _regex_escape(t: String) -> String:
	var out := ""
	for ch in t:
		out += ("\\" + ch) if ch in ".^$*+?()[]{}|\\" else ch
	return out


# --- helpers -----------------------------------------------------------------------------

func check(label: String, cond: bool) -> void:
	print(("  ok   " if cond else "  FAIL ") + label)
	if not cond:
		failures.append(label)


func frames(n := 6) -> void:
	for i in n:
		await get_tree().process_frame


func shot(name: String) -> void:
	await frames(20)  # let tweens finish (0.22 s)
	shots += 1
	var img := get_viewport().get_texture().get_image()
	img.save_png(out_dir.path_join("%02d_%s.png" % [shots, name]))


func press(action: String) -> void:
	var e := InputEventAction.new()
	e.action = action
	e.pressed = true
	Input.parse_input_event(e)
	await frames(2)
	var r := InputEventAction.new()
	r.action = action
	r.pressed = false
	Input.parse_input_event(r)
	await frames(3)


func _wait(cond: Callable, seconds := 20.0) -> bool:
	var end := Time.get_ticks_msec() + int(seconds * 1000)
	while Time.get_ticks_msec() < end:
		if cond.call():
			return true
		await get_tree().process_frame
	return false


func wait_for(label: String, cond: Callable, seconds := 20.0) -> bool:
	var ok: bool = await _wait(cond, seconds)
	check(label, ok)
	return ok


func top() -> Control:
	return app.top()


## On a carousel screen: press Down until `label` is selected (wheel wraps), then Accept.
func choose(label: String) -> void:
	var c: Control = top().carousel
	for i in c.items.size():
		if c.current().get("label") == label:
			break
		await press("ui_down")
	check("carousel reaches '%s'" % label, c.current().get("label") == label)
	await press("ui_accept")
	await frames(4)


## On a form/lobby screen: move to the row with `key` using Up/Down, then Accept.
func pick(key: String, list: Control = null) -> void:
	if list == null:
		list = top().list if "list" in top() else top()._actions
	var seen: Array = []
	for i in list.rows.size() + 1:
		if list.current_key() == key:
			break
		seen.append(list.current_key())
		await press("ui_down")
	if list.current_key() != key:
		print("    visited: ", seen)
	check("row '%s' reachable" % key, list.current_key() == key)
	await press("ui_accept")
	await frames(4)


func type_into(list: Control, key: String, text: String) -> void:
	await pick(key, list)
	var edit: LineEdit = null
	for n in list._nodes:
		if n.edit and n.edit.has_focus():
			edit = n.edit
	check("text field '%s' is editing" % key, edit != null)
	if edit:
		edit.text = text
		edit.text_submitted.emit(text)
	await frames(4)


func stick(y: float) -> void:
	var e := InputEventJoypadMotion.new()
	e.device = 0
	e.axis = JOY_AXIS_LEFT_Y
	e.axis_value = y
	Input.parse_input_event(e)
	await frames(3)


func back() -> void:
	await press("ui_cancel")
	await frames(4)


# --- the tour ----------------------------------------------------------------------------

func _tour() -> void:
	await frames(10)
	check("main menu title", app._title.text == "Main Menu")
	check("menu look loaded from look/menu_look.tres", Style.look != null and Style.look.resource_path == Style.LOOK_PATH
			and app._title.label_settings.font_color == Style.look.title_color)
	var before_mouse: int = top().carousel.index
	for b in [MOUSE_BUTTON_WHEEL_DOWN, MOUSE_BUTTON_LEFT]:
		var m := InputEventMouseButton.new()
		m.button_index = b
		m.pressed = true
		m.position = Vector2(300, 112 + 152 + 64 + 30)   # the row below the selection
		Input.parse_input_event(m)
		await frames(3)
	check("mouse does nothing (controller/keyboard only)", top().carousel.index == before_mouse
			and app._title.text == "Main Menu")
	check("backdrop scene in place", app._bg_image != null and app._scenery != null and app._scenery.visible)
	await frames(30)
	check("main menu music playing", Music.current_track() == "main_menu" and Music.is_audible())
	await shot("main_menu")
	await press("ui_down")
	check("Down moves the wheel", top().carousel.current().get("label") == "Video Settings")
	check("description follows the selection", app._desc.text == "Change your video settings here.")
	await shot("main_menu_video")
	await press("ui_up")

	# Controller: the left stick moves the wheel once, and keeps moving while held.
	var c0: int = top().carousel.index
	var moves := [0]
	var count := func(_i): moves[0] += 1
	top().carousel.changed.connect(count)
	await stick(1.0)
	check("stick down moves the wheel once", moves[0] == 1)
	await get_tree().create_timer(0.7).timeout
	check("holding the stick repeats (%d moves)" % moves[0], moves[0] >= 3)
	await stick(0.0)
	var m1: int = moves[0]
	await get_tree().create_timer(0.5).timeout
	check("letting go stops it", moves[0] == m1)
	top().carousel.changed.disconnect(count)
	while top().carousel.index != c0:
		await press("ui_up")

	check("Dolphin-Sparking found automatically", Settings._found_dolphin != "")
	var solo := Settings.solo_args()
	var host := Settings.host_args("single", false, false)
	check("offline: match HUD off by default, health % on",
			"--hud" in solo and solo[solo.find("--hud") + 1] == "off" and solo[solo.find("--hud-health") + 1] == "on")
	check("netplay: match HUD on", host[host.find("--hud") + 1] == "on")

	await choose("Budokai Tenkaichi 3")
	check("game menu", app._title.text == "Tenkaichi 3")
	await shot("game_menu")
	await choose("DRAGON NET")
	check("DRAGON NET menu", app._title.text == "DRAGON NET")
	# Fast presses: rows must end up where the wheel says, whatever was still animating.
	for i in 3:
		await press("ui_down")
	await frames(30)
	var rows_y: Array = []
	for r in top().carousel._rows:
		if r.modulate.a > 0.01:
			rows_y.append(int(r.position.y))
	check("no two visible rows overlap", rows_y.size() == Array(rows_y).reduce(func(acc, y): return acc if y in acc else acc + [y], []).size())
	await choose("Ranked Match")
	check("Ranked shows WIP toast", app._toast.visible and "work in progress" in app._toast.text)
	await shot("netplay_menu_ranked_wip")
	await choose("Player Match")
	await shot("player_match")

	# --- Host a public direct lobby; the harness joins it as "Vegeta" -------------------
	await choose("Host")
	check("host options", app._title.text == "Host a Lobby")
	var list: Control = top().list
	await pick("traversal", list)  # Accept on a choice = next value: Room code -> Direct IP
	check("connection switched to Direct IP", Settings.get_value("netplay", "traversal") == false)
	await shot("host_options")
	await pick("start", list)
	var lobby: Control = top()
	check("lobby screen", lobby.has_method("make_ingame_panel") and lobby.kind == "host")
	await wait_for("host lobby ready", func(): return lobby._phase == "lobby" and lobby._room.get("state") == "ready")
	await wait_for("lobby listed publicly", func(): return lobby._public.get("listed", false))
	print("TOUR_EVENT host_ready")
	await shot("lobby_waiting")
	check("lobby music", Music.current_track() == "lobby" and Music.is_audible())
	await wait_for("second player joined", func(): return lobby._players.size() == 2, 30)
	var icons: Array = []
	for row in lobby._players_box.get_children():
		for c in row.get_children():
			if c.has_method("_plug"):
				icons.append(c.link)
	check("lobby shows a connection icon per player (%s)" % [icons], icons.size() == 2 and "wireless" in icons)
	await wait_for("chat from the joiner", func(): return "hello from Vegeta" in "\n".join(lobby._chat))
	await type_into(lobby._actions, "chat", "Good luck!")
	await wait_for("own chat line shown", func(): return "Good luck!" in "\n".join(lobby._chat))
	print("TOUR_EVENT chat_sent")
	await pick("buffer", lobby._actions)
	await press("ui_right")
	await wait_for("buffer change confirmed", func(): return lobby._buffer == 5)
	# Automatic pad buffer: the host switches it on; the number row is then Dolphin's.
	await pick("buffer_mode", lobby._actions)   # Accept on a choice row steps it: Manual -> Automatic
	await wait_for("automatic pad buffer on", func():
		return "\n".join(Dolphin.log_lines).contains('"event":"buffer_mode","auto":true'), 10)
	check("buffer number locked while automatic", lobby._actions.row("buffer").get("disabled", false))
	await shot("lobby_buffer_auto")
	await wait_for("pings measured", func():
		for p in lobby._players:
			if not p.get("is_host", false) and String(p.get("quality", "measuring")) == "measuring":
				return false
		return true, 15)
	await shot("lobby_two_players")
	await pick("start", lobby._actions)
	await wait_for("match running", func(): return lobby._phase == "playing", 30)
	await shot("lobby_match_running")
	await wait_for("music faded out while the match runs", func(): return Music.is_muted_for_game() and not Music.is_audible(), 5)

	app.open_ingame_menu()
	await frames(10)
	check("in-game menu open", app.is_ingame_menu_open())
	check("menu owns the controller (even unfocused)", Pad.menu_open and Pad._focused())
	await wait_for("game told to ignore the controller", func():
		return "\n".join(Dolphin.log_lines).contains('"event":"background_input","enabled":false'), 5)
	check("window shrank to the panel", get_window().size == Vector2i(560, 560))
	check("in-game menu window has no frame", get_window().borderless)
	await shot("ingame_menu_netplay")
	await pick("stop", app._compact.list)
	await wait_for("back in the lobby after Stop Match", func(): return lobby._phase == "lobby", 30)
	check("in-game menu closed", not app.is_ingame_menu_open() and not Pad.menu_open)
	check("frame back after the in-game menu", not get_window().borderless)
	check("music back after the match", not Music.is_muted_for_game() and Music.is_audible())
	check("window restored", get_window().content_scale_size == Vector2i(1280, 720))
	check("match started with the automatic pad buffer",
			"\n".join(lobby._chat).contains(tr("Automatic pad buffer: %d (%s).").split(":")[0]))
	await shot("lobby_after_match")
	print("TOUR_EVENT joiner_leave")   # Vegeta leaves: the player_leave sound
	await wait_for("player_leave sound when Vegeta leaves", func(): return Sfx.played.has("player_leave"), 20)
	await back()  # B -> Leave Lobby row
	check("B selects Leave Lobby", lobby._actions.current_key() == "leave")
	await back()  # B again -> leave
	await wait_for("lobby closed", func(): return not is_instance_valid(lobby) or app.top() != lobby, 15)
	await wait_for("Dolphin exited", func(): return not Dolphin.is_running(), 10)
	print("TOUR_EVENT host_left")

	# --- Lobby Browser: the harness's public "Piccolo" Team Battle lobby ---------------
	await back()   # host options -> player match
	await back()   # player match -> netplay
	await choose("Lobby Browser")
	var browser: Control = top()
	await wait_for("lobby list loaded", func(): return not browser._loading, 20)
	var piccolo := ""
	for r in browser.list.rows:
		if String(r.get("key", "")).begins_with("lobby:") and r.get("label") == "Piccolo":
			piccolo = r["key"]
	check("Piccolo's lobby listed", piccolo != "")
	check("Battle Lounge lobbies stay out of the regular browser",
			not browser.list.rows.any(func(r): return r.get("label") == "Trunks"))
	await shot("lobby_browser")
	if piccolo != "":
		await pick(piccolo, browser.list)
		var joined: Control = top()
		check("joined as client", joined != browser and joined.kind == "join")
		await wait_for("joined lobby ready", func(): return joined._phase == "lobby" and joined._role == "client")
		await wait_for("joined: two players", func(): return joined._players.size() == 2, 15)
		check("joined lobby shows Team Battle", joined.mode == "team")
		await frames(30)
		await shot("lobby_joined_as_guest")
		await back()
		await back()
		await wait_for("left Piccolo's lobby", func(): return app.top() == browser, 15)
		await wait_for("Dolphin exited (guest)", func(): return not Dolphin.is_running(), 10)
		# Watch the same lobby: a spectator, listed apart from the players, can't start anything.
		await wait_for("browser list back", func(): return not browser._loading, 20)
		var watch_key := ""
		for r in browser.list.rows:
			if String(r.get("key", "")).begins_with("watch:") and "Piccolo" in String(r.get("label", "")):
				watch_key = r["key"]
		check("Watch offered for Piccolo's lobby", watch_key != "" and not browser.list.row(watch_key).get("disabled", false))
		if watch_key != "":
			await pick(watch_key, browser.list)
			var watcher: Control = top()
			check("watching as a spectator", watcher != browser and watcher.is_spectating())
			await wait_for("watching: lobby ready", func(): return watcher._phase == "lobby", 20)
			await wait_for("listed under Spectators", func():
				return watcher._watching().any(func(p): return p.get("name") == "Goku"), 15)
			check("Piccolo listed as a player", watcher._playing().any(func(p): return p.get("name") == "Piccolo"))
			check("no Start Match for a spectator", watcher._actions.row("start").is_empty())
			check("title says watching", app._title.text.begins_with(tr("Watching: %s").split(":")[0]))
			await frames(30)
			await shot("lobby_watching")
			await back()
			await back()
			await wait_for("stopped watching", func(): return app.top() == browser, 15)
			await wait_for("Dolphin exited (spectator)", func(): return not Dolphin.is_running(), 10)

	# --- Find: no Single Battle lobby open -> hosts one and waits -----------------------
	await back()   # browser -> netplay
	await choose("Player Match")
	await choose("Find")
	var find_list: Control = top().list
	await pick("find_mode", find_list)   # any -> single
	check("find mode Single Battle", Settings.get_value("netplay", "find_mode") == "single")
	await pick("search", find_list)
	var finder: Control = top()
	await wait_for("matchmaking hosts a lobby", func(): return "Hosting a public" in "\n".join(finder._chat), 30)
	await shot("find_hosting")
	await back()  # Cancel row is the only one: B leaves
	await wait_for("search cancelled", func(): return app.top() != finder, 15)
	await wait_for("Dolphin exited (find)", func(): return not Dolphin.is_running(), 10)

	await back()   # find options -> player match
	await back()   # player match -> netplay

	# --- Battle Lounge: its own menu, browser lists only KOTH lobbies, the line ---------
	await choose("Battle Lounge")
	check("Battle Lounge menu", app._title.text == "Battle Lounge")
	await shot("koth_menu")
	await choose("Lobby Browser")
	var kb: Control = top()
	check("Battle Lounge browser", kb.koth and app._title.text == "Battle Lounges")
	await wait_for("KOTH lobby list loaded", func(): return not kb._loading, 20)
	var trunks := ""
	for r in kb.list.rows:
		if String(r.get("key", "")).begins_with("lobby:") and r.get("label") == "Trunks":
			trunks = r["key"]
	check("Trunks' Battle Lounge lobby listed", trunks != "")
	check("regular lobbies stay out of the Battle Lounge browser",
			not kb.list.rows.any(func(r): return r.get("label") == "Piccolo"))
	await shot("koth_lobby_browser")
	if trunks != "":
		await pick(trunks, kb.list)
		var kl: Control = top()
		check("joined the Battle Lounge lobby", kl != kb and kl.koth and "--koth" in kl._args)
		await wait_for("in Trunks' line, second", func():
			return (kl._koth.get("line", []) as Array).size() == 2 and int(kl._koth.get("local_pos", -1)) == 1, 25)
		check("Trunks holds pad 1", String(kl._koth.get("line", [{}])[0].get("name", "")) == "Trunks")
		check("Players panel shows the line", kl._players_head.text.begins_with(tr("Line")))
		check("title says Battle Lounge", app._title.text.begins_with(tr("Battle Lounge: %s").split(":")[0]))
		check("Battle Lounge has its own music track", Music.current_track() == "battle_lounge")
		await frames(30)
		await shot("koth_lobby_line")
		await back()
		await back()
		await wait_for("left Trunks' lobby", func(): return app.top() == kb, 15)
		await wait_for("Dolphin exited (Battle Lounge)", func(): return not Dolphin.is_running(), 10)
	await back()   # browser -> Battle Lounge menu
	await choose("Host")
	check("Battle Lounge host options", app._title.text == "Host a Battle Lounge")
	check("host lobby is Battle Lounge", top().koth)
	await shot("koth_host_options")
	await back()   # -> Battle Lounge menu
	await back()   # -> DRAGON NET

	# --- Buffer Training: solo, boots the training state, buffer changed live ------------
	var c: Control = top().carousel
	for i in c.items.size():
		if c.current().get("label") == "Buffer Training":
			break
		await press("ui_down")
	await frames(20)
	check("Buffer Training description", "emulate an online environment" in String(c.current().get("desc", "")))
	await shot("netplay_menu_buffer_training")
	await choose("Buffer Training")
	var training: Control = top()
	check("training lobby", training.has_method("is_training") and training.is_training())
	check("training: unlisted direct host", "--netplay-direct" in training._args and not "--public" in training._args
			and training._args[training._args.find("--mode") + 1] == "training")
	await wait_for("training starts by itself", func(): return training._phase == "playing", 40)
	check("training booted the Training state", "\n".join(Dolphin.log_lines).contains('"battle_state":"training.sst"'))
	check("no chat row in solo", training._actions.row("chat").is_empty())
	check("no automatic buffer in training", training._actions.row("buffer_mode").is_empty())
	await shot("buffer_training_running")
	app.open_ingame_menu()
	await frames(10)
	check("training menu open", app.is_ingame_menu_open())
	var before: int = training._buffer
	await pick("buffer", app._compact.list)
	await press("ui_right")
	await press("ui_right")
	await wait_for("buffer changed live while training", func(): return training._buffer == before + 2, 10)
	await shot("ingame_menu_training")
	await pick("stop", app._compact.list)
	await wait_for("training stopped", func(): return training._phase == "lobby", 30)
	check("Start Training enabled when solo", not training._actions.row("start").get("disabled", true))
	await shot("buffer_training_lobby")
	await back()
	await back()
	await wait_for("left training", func(): return app.top() != training, 15)
	await wait_for("Dolphin exited (training)", func(): return not Dolphin.is_running(), 10)

	# --- Offline -------------------------------------------------------------------------
	await back()   # netplay -> game menu
	check("back at the game menu", app._title.text == "Tenkaichi 3")
	await choose("Play Offline")
	var play: Control = top()
	await wait_for("offline game running", func(): return play._state == "running", 30)
	await wait_for("music muted for the offline game", func(): return not Music.is_audible(), 5)
	await shot("play_offline")
	# While the game runs the controller is the game's: the menus behind it ignore pad presses.
	Pad.ignore_focus = false
	var sel_before: int = play.list.index
	for b in [JOY_BUTTON_DPAD_DOWN, JOY_BUTTON_A]:
		for pressed in [true, false]:
			var jb := InputEventJoypadButton.new()
			jb.button_index = b
			jb.pressed = pressed
			Input.parse_input_event(jb)
			await frames(3)
	check("menus ignore the controller while the game runs",
			not Pad.accepts() and play.list.index == sel_before and play._state == "running")
	Pad.ignore_focus = true
	await pick("buttons", play.list)
	# Dolphin cycles options alphabetically: PlayStation, Vanilla, Xbox.
	await wait_for("button layout switched live", func(): return Settings.get_value("options", "buttons") == "Xbox", 10)
	app.open_ingame_menu()
	await frames(10)
	check("offline in-game menu open", app.is_ingame_menu_open())
	await shot("ingame_menu_offline")
	await pick("resume", app._compact.list)
	check("Back to the game closes it", not app.is_ingame_menu_open())
	await wait_for("Back to the game hands the focus to Dolphin", func():
		return "\n".join(Dolphin.log_lines).contains('"event":"focus_game"'), 5)
	await pick("stop", play.list)
	await wait_for("offline game stopped", func(): return app.top() != play, 20)
	await wait_for("Dolphin exited (solo)", func(): return not Dolphin.is_running(), 10)
	await frames(10)
	check("music resumes after the game closes", Music.is_audible() and Music.current_track() == "game_menu")

	await choose("Modifications")
	check("modifications submenu", app._title.text == "Modifications")
	await shot("modifications_menu")
	await choose("Button Prompts")
	var bp: Control = top()
	check("button prompts named GameCube/PlayStation/Xbox", bp.list.row("Vanilla").get("label") == "GameCube"
			and bp.list.row("PlayStation").get("label") == "PlayStation" and bp.list.row("Xbox").get("label") == "Xbox")
	await pick("PlayStation", bp.list)
	check("button prompts set to PlayStation", Settings.get_value("options", "buttons") == "PlayStation")
	await shot("button_prompts")
	await back()
	check("menu shows the new choice", "Now: PlayStation" in app._desc.text)
	await choose("Graphics")
	var gr: Control = top()
	await pick("Legacy", gr.list)
	check("graphics set to Legacy", Settings.get_value("options", "graphics") == "Legacy")
	await shot("graphics")
	await back()
	await choose("Codes")
	var mods: Control = top()
	await wait_for("gecko codes loaded", func(): return not mods._loading, 20)
	check("gecko codes listed", mods._codes.size() > 0)
	await pick("custom", mods.list)
	check("custom code selection on", Settings.get_value("gecko", "custom") == true)
	await shot("modifications")
	await back()
	await back()   # Modifications -> game menu
	# --- Controller presets: scroll with Right, applied to GCPadNew.ini [GCPad1] ----------
	await choose("Controller Setup")
	var pads: Control = top()
	var preset_row: Dictionary = pads.list.row("preset")
	check("built-in presets listed", "Xbox One - Sparking Standard" in preset_row["values"]
			and "Xbox 360 - Sparking Standard" in preset_row["values"]
			and "PlayStation 5 - Sparking Standard" in preset_row["values"])
	await pick("preset", pads.list)   # Accept on a choice = next: keep -> first preset
	await press("ui_right")           # and one more
	var chosen: String = Settings.get_value("controller", "preset")
	var gc := FileAccess.get_file_as_string(pads.Controllers.gcpad_path())
	var want_dev: String = pads.Controllers.find(chosen).get("device", "?")
	check("preset '%s' written to GCPadNew.ini" % chosen, ("[GCPad1]\nDevice = " + want_dev) in gc)
	check("other ports kept", "[GCPad2]" in gc)
	await shot("controller_setup")
	# Create a config by "pressing" buttons (Dolphin's input test, fed fake events here).
	await pick("new", pads.list)
	var ed: Control = top()
	check("config editor open", app._title.text == "New Config")
	await wait_for("Dolphin input test running", func(): return ed._helper_state == "ready", 20)
	ed._on_helper({"event": "devices", "devices": [{"name": "XInput/0/Gamepad", "source": "XInput", "title": "Gamepad"}]})
	await frames(5)
	check("controller picked from Dolphin's list", ed._device == "XInput/0/Gamepad")
	await pick("Buttons/A", ed.list)          # A on the row: wait for a press
	check("listening for a press", ed._listen_key == "Buttons/A")
	ed._listen_since = Time.get_ticks_msec()   # "right after": the frames above can take a while on a slow test machine
	ed._on_helper({"event": "input", "device": "XInput/0/Gamepad", "input": "Button A", "pressed": true})
	check("the press that started listening isn't bound", ed._keys.get("Buttons/A", "") == "")
	await get_tree().create_timer(0.4).timeout
	ed._on_helper({"event": "input", "device": "XInput/0/Gamepad", "input": "Button X", "pressed": true})
	check("next press bound to A", ed._keys.get("Buttons/A") == "`Button X`")
	check("moved on to B", ed.list.current_key() == "Buttons/B")
	check("Dolphin sees shows the press", "Button X" in ed._live_dolphin.text)
	await frames(40)
	await pick("Triggers/L", ed.list)
	await get_tree().create_timer(0.4).timeout
	ed._on_helper({"event": "input", "device": "XInput/0/Gamepad", "input": "Trigger R", "pressed": true})
	check("L bound, analog too", ed._keys.get("Triggers/L") == "`Trigger R`" and ed._keys.get("Triggers/L-Analog") == "`Trigger R`")
	await frames(40)
	await shot("controller_editor")
	await type_into(ed.list, "name", "Tour Pad")
	await pick("save", ed.list)
	var saved := FileAccess.get_file_as_string(pads.Controllers.user_dir().path_join("Tour Pad.ini"))
	check("config saved", "Device = XInput/0/Gamepad" in saved and "Buttons/A = `Button X`" in saved
			and "Triggers/L-Analog = `Trigger R`" in saved)
	check("saved config selected", Settings.get_value("controller", "preset") == "Tour Pad" and app.top() == pads)
	await wait_for("helper Dolphin stopped", func():
		return Dolphin._helpers.all(func(h): return h["proc"] == Presence._helper), 10)
	await back()

	# --- Tenkaichi Terminology -------------------------------------------------------------
	await choose("Tenkaichi Terminology")
	check("terminology menu", app._title.text == "Terminology")
	await shot("terminology_categories")
	await choose("Movement")
	var terms: Control = top()
	check("terms screen", terms.has_method("_show_demo") and terms.carousel.current().get("label") == "Drifting")
	check("definition in the description bar", app._desc.text.begins_with("Holding any direction"))
	await wait_for("Drifting demo downloaded and playing", func(): return terms._player.is_showing(), 30)
	await frames(40)
	await shot("terminology_drifting")
	await press("ui_accept")   # nothing to pick: stays here
	check("terms are not selectable", app.top() == terms)
	await press("ui_down")
	check("Down moves to Dashing", terms.carousel.current().get("label") == "Dashing")
	await wait_for("Dashing demo playing", func(): return terms._player.is_showing(), 30)
	await shot("terminology_dashing")
	await back()
	await choose("Blast-2")
	var b2: Control = top()
	for i in 3:
		await press("ui_down")
	check("Blast-2 Boost selected", b2.carousel.current().get("label") == "Blast-2 Boost")
	await wait_for("both Blast-2 Boost demos downloaded", func(): return Demos.files_for("Blast-2 Boost").size() == 2, 30)
	await wait_for("Blast-2 Boost demo playing", func(): return b2._player.is_showing(), 30)
	await shot("terminology_blast2_boost")
	await back()
	await choose("Defense")
	var df: Control = top()
	for i in 16:
		await press("ui_down")
	check("long name shrunk to fit", df.carousel.current().get("label").begins_with("Emergency Blaster Wave")
			and df.carousel._rows[df.carousel.index].get_node("Text").label_settings.font_size < 46)
	await wait_for("no-demo message", func(): return "No demo" in df._status.text, 10)
	await shot("terminology_long_name")
	await back()
	var cats: Control = top().carousel
	for i in cats.items.size():
		if cats.current().get("label") == "Contributors":
			break
		await press("ui_down")
	await frames(10)
	check("contributors list the writers", "Tecchan" in app._desc.text
			and "Creatful_Chaos" in app._desc.text)
	await shot("terminology_contributors")
	await back()   # categories -> game menu
	await back()   # game menu -> main menu
	await choose("Video Settings")
	await pick("window", top().list)
	await shot("video_settings")
	await back()
	await choose("Options")
	await shot("options")
	check("Options has Profile, no Files & Folders", top().list.row("profile").get("label") == "Profile"
			and top().list.row("files").is_empty())
	await back()
	app.open("setup")
	await shot("first_run_setup")

	# Splash (skipped at startup for the tour): shows, and any button skips it.
	app._show_splash()
	await frames(5)
	check("splash shows", app.is_splash_showing())
	await shot("splash")
	await press("ui_accept")
	check("a button skips the splash", not app.is_splash_showing())

	# Sound effects: every one was asked for at the right moment; a file in SparkingData\sounds
	# is picked up, and an empty slot stays silent.
	for s in ["move", "select", "back", "player_join", "player_leave", "message", "game_start"]:
		check("sound effect played: " + s, s in Sfx.played)
	check("sound file from SparkingData\\sounds", Sfx.stream_for("select") is AudioStreamWAV)
	check("empty sound slot is silent", Sfx.stream_for("player_leave") == null)

	# A read-only game folder (installed under Program Files): explained instead of hanging.
	check("this test's data folder is writable", Settings.data_writable())
	app.push(app._read_only_screen())
	await frames(5)
	await shot("read_only_folder")
	check("read-only screen offers Exit", top().carousel.current().get("label") == "Exit")
	app.pop()

	# Menu transitions: dark fade between menus, white into a DRAGON NET lobby.
	app.transitions = true
	app.push(app._game_menu())
	await frames(1)
	check("changing menus fades in from black", app._fade.visible and app._fade.color.r < 0.1 and app._fade.color.a > 0.5)
	app._fade_tween.pause()   # freeze it halfway for the screenshot
	app._fade.color.a = 0.55
	await shot("fade_dark")
	app._fade_tween.play()
	await wait_for("fade finished", func(): return not app._fade.visible, 3)
	app.pop()
	var fake_lobby: Control = load("res://scripts/screens/lobby.gd").new()
	check("lobby screens ask for the lobby fade", fake_lobby.screen_fade() == "lobby")
	app._transition(fake_lobby)
	await frames(1)
	check("entering a lobby fades in from white", app._fade.visible and app._fade.color.r > 0.9 and app._fade.color.a > 0.5)
	app._fade_tween.pause()   # freeze it halfway for the screenshot
	app._fade.color.a = 0.55
	await shot("fade_white")
	app._fade_tween.play()
	fake_lobby.free()
	await wait_for("lobby fade finished", func(): return not app._fade.visible, 3)
	app.transitions = false

	# Languages: the first-launch picker, then a few menus in Spanish and Italian.
	TranslationServer.remove_translation(recorder)   # (Godot falls back to "en" for missing texts)
	app.push(app._language_menu(true))
	await frames(5)
	await shot("language_picker")
	check("language picker lists three", top().carousel.items.size() == 3)
	app.pop()
	for code in ["es", "it"]:
		Lang.set_language(code)
		app.push(app._main_menu())
		await frames(5)
		await shot("main_menu_" + code)
		check("main menu in " + code, app._title.get_text() == "Main Menu" and app._title.label_settings != null)
		app.push(app._game_menu())
		await frames(5)
		await shot("game_menu_" + code)
		app.open("options")
		await frames(5)
		await shot("options_" + code)
		app.pop()
		app.open("host_options")
		await frames(5)
		await shot("host_options_" + code)
		app.pop()
		app.pop()
		app.pop()
	Lang.set_language("en")
	check("the shown title is translated", TranslationServer.translate("Main Menu") == "Main Menu")
