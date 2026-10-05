extends Node
## Automated walk through every menu and the netplay flow, with screenshots. Started by
## tests/run_ui_tour.py (which supplies a fake lobby server and a second player):
##   godot --path Frontend/Godot -- --ui-tour <config.json>
## Prints "TOUR_EVENT <name>" lines for the harness and "TOUR_RESULT ok|fail" at the end.

var config_path := ""
var app: Control
var out_dir := ""
var failures: PackedStringArray = []
var shots := 0


func _ready() -> void:
	app = get_parent()
	app.ignore_focus = true
	var cfg: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(config_path))
	out_dir = cfg["out_dir"]
	Settings.use_file(cfg["settings_file"])
	for section in cfg.get("settings", {}):
		for key in cfg["settings"][section]:
			Settings.set_value(section, key, cfg["settings"][section][key])
	_run.call_deferred()


func _run() -> void:
	await _tour()
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
	for i in list.rows.size() + 1:
		if list.current_key() == key:
			break
		await press("ui_down")
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


func back() -> void:
	await press("ui_cancel")
	await frames(4)


# --- the tour ----------------------------------------------------------------------------

func _tour() -> void:
	await frames(10)
	check("main menu title", app._title.text == "Main Menu")
	await shot("main_menu")
	await press("ui_down")
	check("Down moves the wheel", top().carousel.current().get("label") == "Video Settings")
	check("description follows the selection", app._desc.text.begins_with("Renderer"))
	await shot("main_menu_video")
	await press("ui_up")

	await choose("Budokai Tenkaichi 3")
	check("game menu", app._title.text == "Tenkaichi 3")
	await shot("game_menu")
	await choose("Netplay")
	check("netplay menu", app._title.text == "Netplay")
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
	await wait_for("second player joined", func(): return lobby._players.size() == 2, 30)
	await wait_for("chat from the joiner", func(): return "hello from Vegeta" in "\n".join(lobby._chat))
	await type_into(lobby._actions, "chat", "Good luck!")
	await wait_for("own chat line shown", func(): return "Good luck!" in "\n".join(lobby._chat))
	print("TOUR_EVENT chat_sent")
	await pick("buffer", lobby._actions)
	await press("ui_right")
	await wait_for("buffer change confirmed", func(): return lobby._buffer == 5)
	await wait_for("pings measured", func():
		for p in lobby._players:
			if not p.get("is_host", false) and String(p.get("quality", "measuring")) == "measuring":
				return false
		return true, 15)
	await shot("lobby_two_players")
	await pick("start", lobby._actions)
	await wait_for("match running", func(): return lobby._phase == "playing", 30)
	await shot("lobby_match_running")

	app.open_ingame_menu()
	await frames(10)
	check("in-game menu open", app.is_ingame_menu_open())
	check("window shrank to the panel", get_window().size == Vector2i(560, 560))
	await shot("ingame_menu_netplay")
	await pick("stop", app._compact.list)
	await wait_for("back in the lobby after Stop Match", func(): return lobby._phase == "lobby", 30)
	check("in-game menu closed", not app.is_ingame_menu_open())
	check("window restored", get_window().content_scale_size == Vector2i(1280, 720))
	await shot("lobby_after_match")
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

	# --- Offline -------------------------------------------------------------------------
	await back()   # find -> player match
	await back()   # -> netplay
	await back()   # -> game menu
	check("back at the game menu", app._title.text == "Tenkaichi 3")
	await choose("Play Offline")
	var play: Control = top()
	await wait_for("offline game running", func(): return play._state == "running", 30)
	await shot("play_offline")
	await pick("buttons", play.list)
	# Dolphin cycles options alphabetically: PlayStation, Vanilla, Xbox.
	await wait_for("button layout switched live", func(): return Settings.get_value("options", "buttons") == "Xbox", 10)
	app.open_ingame_menu()
	await frames(10)
	check("offline in-game menu open", app.is_ingame_menu_open())
	await shot("ingame_menu_offline")
	await pick("resume", app._compact.list)
	check("Back to the game closes it", not app.is_ingame_menu_open())
	await pick("stop", play.list)
	await wait_for("offline game stopped", func(): return app.top() != play, 20)
	await wait_for("Dolphin exited (solo)", func(): return not Dolphin.is_running(), 10)

	await choose("Modifications")
	var mods: Control = top()
	await wait_for("gecko codes loaded", func(): return not mods._loading, 20)
	check("gecko codes listed", mods._codes.size() > 0)
	await pick("custom", mods.list)
	check("custom code selection on", Settings.get_value("gecko", "custom") == true)
	await shot("modifications")
	await back()
	# --- Controller presets: scroll with Right, applied to GCPadNew.ini [GCPad1] ----------
	await choose("Controller Setup")
	var pads: Control = top()
	var preset_row: Dictionary = pads.list.row("preset")
	check("built-in presets listed", "Xbox - Sparking Standard" in preset_row["values"]
			and "PlayStation 5 - Sparking Standard" in preset_row["values"])
	await pick("preset", pads.list)   # Accept on a choice = next: keep -> first preset
	await press("ui_right")           # and one more
	var chosen: String = Settings.get_value("controller", "preset")
	var gc := FileAccess.get_file_as_string(pads.Controllers.gcpad_path())
	var want_dev: String = pads.Controllers.find(chosen).get("device", "?")
	check("preset '%s' written to GCPadNew.ini" % chosen, ("[GCPad1]\nDevice = " + want_dev) in gc)
	check("other ports kept", "[GCPad2]" in gc)
	await shot("controller_setup")
	await type_into(pads.list, "save_as", "Tour Pad")
	check("current mapping saved as preset", FileAccess.file_exists(
			pads.Controllers.user_dir().path_join("Tour Pad.ini")) and Settings.get_value("controller", "preset") == "Tour Pad")
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
	await back()   # categories -> game menu
	await back()   # game menu -> main menu
	await choose("Video Settings")
	await pick("window", top().list)
	await shot("video_settings")
	await back()
	await choose("Options")
	await shot("options")
	await pick("files", top().list)
	await shot("files_and_folders")
