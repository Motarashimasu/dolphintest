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
	vegeta_token = String(cfg.get("vegeta_token", ""))
	_settings_from_another_pc(String(cfg["settings_file"]).get_base_dir().path_join("other_pc.cfg"))
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


## Settings copied from another PC (e.g. shipped inside an installer): its disc paths and its
## DRAGON NET login are dropped, setup runs again, the options stay.
func _settings_from_another_pc(path: String) -> void:
	var f := ConfigFile.new()
	f.set_value("paths", "machine", "someone-elses-pc")
	f.set_value("paths", "setup_done", true)
	f.set_value("games", "bt3_PAL", "E:/Their Stuff/BT3.iso")
	f.set_value("games", "bt3_offline", "PAL")
	f.set_value("ranked", "token", "f".repeat(64))
	f.set_value("ranked", "name", "tecchan")
	f.set_value("options", "graphics", "Legacy")
	f.save(path)
	Settings.use_file(path)
	Settings._check_machine()
	var mine := Settings.machine_id() != ""
	check("settings from another PC: its game paths and login are forgotten, setup runs again", not mine or (
		Settings.copy_path("bt3", "PAL") == "" and Settings.get_value("ranked", "token") == ""
		and Settings.get_value("ranked", "name") == "" and Settings.get_value("paths", "setup_done") == false
		and Settings.get_value("paths", "machine") == Settings.machine_id()))
	check("...the options are kept", Settings.get_value("options", "graphics") == "Legacy")
	Settings._check_machine()
	check("this PC's own settings are left alone", Settings.get_value("options", "graphics") == "Legacy"
		and Settings.get_value("paths", "machine") == Settings.machine_id())
	DirAccess.remove_absolute(path)


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
			if "%s" in k or "%d" in k or "%+d" in k:
				var rx := "(?s)^" + _regex_escape(k).replace("%\\+d", "[+-]\\d+").replace("%s", ".*?") \
						.replace("%d", "-?\\d+") + "$"
				templates.append(RegEx.create_from_string(rx))
		var missing: Array = []
		for s in seen:
			if s in ignore or not RegEx.create_from_string("[A-Za-z]{2}").search(s):
				continue
			if JSON.stringify(s).trim_prefix("\"").trim_suffix("\"") in term_text:
				continue
			if s.begins_with("◀") or s.begins_with("★") or s.begins_with("[b]") or "   ·   " in s \
					or RegEx.create_from_string("^\\d+ ms|^[A-Z]{2}$|Sparking Standard|^Tecbox layout|^\\S+  \\(.+\\)$|^#\\d+   |   Rating \\d+$| \\([a-z_]+\\)$").search(s):
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


var vegeta_token := ""


## social.php as Vegeta (the harness's ranked host).
func as_vegeta(body: Dictionary) -> Dictionary:
	var req := HTTPRequest.new()
	add_child(req)
	req.request(Ranked.server() + "social.php", PackedStringArray(["Content-Type: application/json",
		"X-Sparking-Token: " + vegeta_token]), HTTPClient.METHOD_POST, JSON.stringify(body))
	var res: Array = await req.request_completed
	req.queue_free()
	var data = JSON.parse_string((res[3] as PackedByteArray).get_string_from_utf8())
	return data if data is Dictionary else {}


## Friends (in the DRAGON NET menus), a friend coming online, an admin message.
func friends_and_popups() -> void:
	Settings.use_game("bt3")
	app.push(app._netplay_menu())
	await frames(10)
	await choose("Friends")
	var fr: Control = top()
	check("Friends screen (logged in as Goku)", app._title.text == "Friends" and "Goku" in fr.screen_desc())
	await type_into(fr.list, "add", "vegeta")
	await wait_for("friend request sent", func(): return "Friend request sent to Vegeta" in fr._status, 15)
	check("waiting for Vegeta", Social.outgoing.any(func(r): return r["name"] == "Vegeta"))
	var p := await as_vegeta({"action": "poll"})
	var goku_id := -1
	for r in p.get("incoming", []):
		if r["name"] == "Goku":
			goku_id = int(r["id"])
	check("Vegeta got the request", goku_id > 0)
	await as_vegeta({"action": "accept", "id": goku_id})
	await Social.poll()
	await frames(5)
	check("a new friend isn't announced as coming online", app.social_popups._toast == null
			and app.social_popups._toasts.is_empty())
	check("Vegeta on the friends list, online", Social.friends.size() == 1 and Social.friends[0]["name"] == "Vegeta"
			and Social.friends[0]["online"] and String(fr.list.row("f:%d" % int(Social.friends[0]["id"])).get("value")) == "Online")
	await shot("friends")
	# A friend coming online: the green bar slides in from the right with a sprite.
	# (Vegeta's launcher starts again: a new "came online" time, even within the online window.)
	await get_tree().create_timer(1.1).timeout
	await as_vegeta({"action": "poll", "start": true})
	await Social.poll()
	await wait_for("online pop-up shown", func(): return app.social_popups._toast != null, 5)
	var t: Control = app.social_popups._toast
	await get_tree().create_timer(0.6).timeout
	check("online pop-up: centre right, a quarter of the screen at most (%s, %s)" % [t.position, t.size], t.position.x >= 1280 - 330
			and t.size.x <= 321 and t.position.y > 100 and t.position.y + t.size.y < 620)
	check("online pop-up: green bar, sprite, name", t.get_child(0) is Panel
			and t.get_children().any(func(c): return c is TextureRect and c.texture != null)
			and "Vegeta" in t.get_child(0).get_child(1).text)
	await shot("friend_online_popup")
	await wait_for("online pop-up gone by itself", func(): return app.social_popups._toast == null, 8)
	# A friend in the same netplay lobby: the same pop-up with a yellow bar.
	check("netplay tells the lobby this PC's DRAGON NET account",
			"--account" in Settings.join_args("1.2.3.4:2626") and Settings.join_args("1.2.3.4:2626")[Settings.join_args("1.2.3.4:2626").find("--account") + 1] == "Goku")
	check("friends are recognised by account name, any case", Social.is_friend("VEGETA") and not Social.is_friend("Trunks"))
	app.social_popups.friend_joined("Vegeta")
	await wait_for("lobby pop-up shown", func(): return app.social_popups._toast != null, 5)
	var lt: Control = app.social_popups._toast
	await get_tree().create_timer(0.6).timeout
	var bar: Panel = lt.get_child(0)
	check("lobby pop-up: yellow bar, 'has entered the lobby!'",
			(bar.get_theme_stylebox("panel") as StyleBoxFlat).bg_color.is_equal_approx(Color("#e3b21b"))
			and bar.get_child(2).text == tr("has entered the lobby!"))
	await shot("friend_lobby_popup")
	await wait_for("lobby pop-up gone by itself", func(): return app.social_popups._toast == null, 8)
	# An admin message: the striped box until it's closed with a button; once.
	Social.message.emit(990001, "Server maintenance tonight at 22:00 UTC. Ranked will be back in an hour.")
	await wait_for("message shown", func(): return app.social_popups.has_message_open(), 5)
	await frames(15)
	await shot("admin_message")
	var before: String = top().list.current_key()
	await press("ui_down")
	check("the menu behind doesn't move while it's open", top().list.current_key() == before)
	await press("ui_accept")
	check("closed with a button", not app.social_popups.has_message_open())
	await back()
	check("back in the DRAGON NET menu", app._title.text.begins_with("DRAGON NET"))
	await back()
	check("back at the main menu", app._title.text == "Main Menu")


## Budokai Tenkaichi 2's tab, game copies per version, the version picked for DRAGON NET.
func games_and_versions() -> void:
	# Versions are read from the disc images (ISO, WBFS, RVZ / WIA, CISO), else the file name.
	var dir := Settings.data_path("tour_discs")
	DirAccess.make_dir_recursive_absolute(dir)
	var make := func(name: String, magic: PackedByteArray, at: int, id: String) -> String:
		var bytes := PackedByteArray()
		bytes.resize(maxi(at + 6, 0x8010))
		for i in magic.size():
			bytes[i] = magic[i]
		if magic == "WBFS".to_ascii_buffer():
			bytes[8] = 9   # 512-byte sectors: the disc header copy at 0x200
		for i in 6:
			bytes[at + i] = id.unicode_at(i)
		var f := FileAccess.open(dir.path_join(name), FileAccess.WRITE)
		f.store_buffer(bytes)
		f.close()
		return dir.path_join(name)
	var iso: String = make.call("a.iso", PackedByteArray(), 0, "RDSE70")
	var wbfs: String = make.call("b.wbfs", "WBFS".to_ascii_buffer(), 0x200, "RDBPAF")
	var rvz: String = make.call("c.rvz", "RVZ\u0001".to_ascii_buffer(), 0x58, "RDSJAF")
	var ciso: String = make.call("d.ciso", "CISO".to_ascii_buffer(), 0x8000, "RDBE70")
	var named: String = make.call("Budokai Tenkaichi 2 (RDBJAF).gcz", "\u00b1\u000b\u00c0\u0001".to_ascii_buffer(), 0x100, "zzzzzz")
	check("disc IDs read: ISO, WBFS, RVZ, CISO, file name", [Settings.read_disc_id(iso), Settings.read_disc_id(wbfs),
			Settings.read_disc_id(rvz), Settings.read_disc_id(ciso), Settings.read_disc_id(named)]
			== ["RDSE70", "RDBPAF", "RDSJAF", "RDBE70", "RDBJAF"])
	check("disc IDs name the game and version", Settings.game_of_id("RDBPAF") == ["bt2", "PAL"]
			and Settings.game_of_id("RDSE70") == ["bt3", "NTSC-U"] and Settings.game_of_id("GZLE01") == [])
	# DRAGON NET saves: a folder per version; the old single folder becomes BT3 PAL's.
	check("netplay save folder per version", Settings.netplay_save_dir("RDBJAF").ends_with("saves/netplay/RDBJAF")
			and DirAccess.dir_exists_absolute(Settings.netplay_save_dir("RDBJAF")))
	var host_nand := Settings.host_args("single", false, false)
	check("netplay boots the version's save folder", host_nand[host_nand.find("--nand") + 1].ends_with("saves/netplay/RDSPAF"))
	var real_data: String = Settings.get_value("paths", "data")
	var old_data := Settings.data_path("tour_old_layout")
	DirAccess.make_dir_recursive_absolute(old_data.path_join("saves/netplay/title/00010000/52445350/data"))
	FileAccess.open(old_data.path_join("saves/netplay/title/00010000/52445350/data/DBZT3"), FileAccess.WRITE).store_string("save")
	Settings.set_value("paths", "data", old_data)
	check("old netplay save moved into saves/netplay/RDSPAF", FileAccess.file_exists(
			old_data.path_join("saves/netplay/RDSPAF/title/00010000/52445350/data/DBZT3"))
			and not DirAccess.dir_exists_absolute(old_data.path_join("saves/netplay/title"))
			and DirAccess.dir_exists_absolute(old_data.path_join("saves/netplay/RDBJAF")))
	Settings.set_value("paths", "data", real_data)
	check("the old single game path became the BT3 PAL copy", Settings.has_copy("bt3", "PAL")
			and Settings.owned_versions("bt3") == ["PAL"] and Settings.offline_version("bt3") == "PAL")

	# Budokai Tenkaichi 2: its own game menu (no Terminology), its own music track names.
	await choose("Budokai Tenkaichi 2")
	check("BT2 game menu", app._title.text == "Tenkaichi 2" and app.game_on_stack() == "bt2"
			and Settings.game == "bt2")
	check("BT2 menu: same items, no Terminology", top().carousel.items.map(func(it): return it["label"])
			== ["Play Offline", "DRAGON NET", "Controller Setup", "Modifications", "Back"])
	check("BT2 menus: their own music (none here: the main menu's)", app.music_for_stack() == "bt2_game_menu"
			and Music.current_track() == "bt2_game_menu")
	check("BT2's picture variants fall back within BT2", Style.track_parent("bt2_ranked", Style.BACKGROUND_PARENT) == "bt2_lobby")
	check("no BT2 copy yet: Play Offline says to add one", "Add your copy first" in app._desc.text)
	await shot("bt2_game_menu")
	# No BT2 copy yet: DRAGON NET says so and opens its Game Copies page.
	await choose("DRAGON NET")
	check("no BT2 copy: its Game Copies page", app._title.text == "Budokai Tenkaichi 2" and "list" in top()
			and top().list.row("NTSC-U").get("value") == "Not set")
	await shot("game_copies_bt2_empty")
	# A copy picked for the wrong row lands under the version its disc says.
	var gc: Control = top()
	gc.store(gc, wbfs, "bt2", "NTSC-U", func(): gc.list.set_rows(gc.build_rows()))
	await frames(5)
	check("picked for NTSC-U, it's PAL: saved as the PAL copy", Settings.copy_path("bt2", "PAL") == wbfs
			and Settings.copy_path("bt2", "NTSC-U") == "" and Settings.offline_version("bt2") == "PAL")
	gc.store(gc, ciso, "bt2", "NTSC-U", func(): gc.list.set_rows(gc.build_rows()))
	await frames(5)
	check("BT2 NTSC-U and PAL copies", Settings.owned_versions("bt2") == ["NTSC-U", "PAL"])
	await shot("game_copies_bt2")
	await back()
	# Two copies: DRAGON NET asks which version first.
	await choose("DRAGON NET")
	check("version picker before DRAGON NET", app._title.text == "Which version?"
			and top().carousel.items.size() == 3)
	await shot("bt2_version_picker")
	await choose("PAL")
	check("DRAGON NET on BT2 PAL", app._title.text == "DRAGON NET (PAL)" and Settings.GAME["id"] == "RDBPAF"
			and Settings.host_args("single", false, false)[-1] == wbfs)
	check("BT2's netplay music track", app.music_for_stack() == "bt2_netplay")
	await shot("bt2_netplay_menu")
	# Ranked talks to BT2's own ladder, on this version.
	var srv: Dictionary = Ranked._to_server("lobby.php", {"action": "open", "mode": "single"})
	check("ranked: BT2 ladder and version", srv["mode"] == "b2single" and srv["game"] == "bt2" and srv["version"] == "RDBPAF")
	check("ranked: the server's BT2 modes read back as plain ones",
			Ranked._from_server({"lobbies": [{"mode": "b2team"}]})["lobbies"][0]["mode"] == "team")
	# NEOcode is Tenkaichi 3's only for now.
	var fake_lobby: Control = load("res://scripts/screens/lobby.gd").new()
	check("no NEOcode in BT2 lobbies", not fake_lobby._neocode_allowed())
	fake_lobby.free()
	await back()   # DRAGON NET -> game menu (the picker was replaced)
	check("back at the BT2 game menu", app._title.text == "Tenkaichi 2")
	await back()

	# Options > Game Copies: every game, every version.
	await choose("Options")
	await pick("copies", top().list)
	check("Game Copies lists the games", app._title.text == "Game Copies" and top().carousel.items.size() == 3)
	await shot("game_copies_games")
	await choose("Budokai Tenkaichi 3")
	var g3: Control = top()
	check("BT3 copies page", app._title.text == "Budokai Tenkaichi 3" and g3.list.row("PAL").get("value") != "Not set")
	g3.store(g3, iso, "bt3", "", func(): g3.list.set_rows(g3.build_rows()))
	await frames(5)
	check("a BT3 NTSC-U copy added", Settings.owned_versions("bt3") == ["NTSC-U", "PAL"]
			and Settings.offline_version("bt3") == "PAL")
	await pick("offline", g3.list)   # Accept on a choice = next value: PAL -> NTSC-U
	check("Play Offline now uses NTSC-U", Settings.offline_version("bt3") == "NTSC-U")
	await shot("game_copies_bt3")
	await pick("offline", g3.list)   # back to PAL
	await pick("NTSC-U", g3.list)    # a set copy: change or remove
	await shot("game_copy_change")
	await choose("Remove")
	check("NTSC-U copy removed", Settings.owned_versions("bt3") == ["PAL"])
	await back()
	await back()
	await back()
	check("back at the main menu", app._title.text == "Main Menu")
	Settings.use_game("bt3")


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


func Replays_title(r: Dictionary) -> String:
	return load("res://scripts/screens/replays.gd").title_of(r)


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


## The hidden NEOcode switch: PgUp, then PgDn while PgUp is still held.
func pgup_pgdn() -> void:
	for k in [KEY_PAGEUP, KEY_PAGEDOWN]:
		var e := InputEventKey.new()
		e.keycode = k
		e.physical_keycode = k
		e.pressed = true
		Input.parse_input_event(e)
		await frames(2)
	for k in [KEY_PAGEDOWN, KEY_PAGEUP]:
		var e := InputEventKey.new()
		e.keycode = k
		e.physical_keycode = k
		e.pressed = false
		Input.parse_input_event(e)
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


## B leaves a lobby: the first press goes to Leave Lobby, the next one leaves. (When the focus is
## already on Leave, from the "Cancel" row while connecting, one press does it.)
func leave_lobby(lobby: Control) -> void:
	await back()
	if is_instance_valid(lobby) and app.top() == lobby and lobby._phase != "closing":
		await back()


# --- the tour ----------------------------------------------------------------------------

func _tour() -> void:
	await frames(10)
	check("main menu title", app._title.text == "Main Menu")
	check("menu look loaded from look/menu_look.tres", Style.look != null and Style.look.resource_path == Style.LOOK_PATH
			and (app._title.material as ShaderMaterial).get_shader_parameter("top_color") == Style.look.title_color
			and app._title.label_settings.outline_color == Style.look.title_outline_color)
	# Notification bars: the ranked server's example text has a blue line (nothing red / yellow).
	var nt: Control = app.notifier
	nt.refresh()
	await wait_for("notification bar: blue slides in after the first 5 s", func(): return nt.current == "blue", 25.0)
	check("notification bar: never before 5 s", nt.shown == ["blue"] and Time.get_ticks_msec() >= 5000)
	check("notification bar: server text (Welcome to DRAGON NET...)", nt._text.text.begins_with("Welcome to DRAGON NET"))
	await get_tree().create_timer(1.5).timeout
	check("notification bar: in place, picture at the right edge", is_equal_approx(nt._bar.position.x, 0.0)
			and nt._sprite.visible and is_equal_approx(nt._sprite.position.x + nt._sprite.size.x, 1280.0))
	await shot("notification_blue")
	app.open("options")
	await wait_for("notification bar: leaves on Options", func(): return nt.current == "", 3.0)
	back()
	await frames(10)
	nt.texts = {"red": "Update 1.2 is out!", "blue": "Blue news", "yellow": ""}
	nt._next = 1   # mid-rotation: red is still next whenever there's red text... once per turn
	nt._due_ms = 0
	await wait_for("notification bar: takes turns (blue next, then red)", func(): return nt.current != "" and nt.current != "leaving", 3.0)
	check("notification bar: rotation goes on from where it was", nt.shown.back() == "blue")
	nt._leave(true)
	nt._due_ms = 0
	await wait_for("notification bar: red's turn", func(): return nt.shown.back() == "red", 3.0)
	await frames(30)
	await shot("notification_red")
	check("notification bar: red has its picture", nt._sprite.visible and nt._sprite.texture != null)
	nt._leave(true)
	await wait_for("notification bar: red gone", func(): return nt.current == "", 3.0)
	nt.texts = {"red": "", "blue": "", "yellow": "Goku reached the global Top 5 in Single Battle FT2!"}
	nt._due_ms = 0
	await frames(20)
	check("notification bar: no yellow (Tenkaichi 3 ranked news) on the main menu", nt.current == "")
	app.push(app._game_menu("bt3"))   # (pushed directly: no game-file prompt this early)
	await wait_for("notification bar: yellow in the Tenkaichi 3 menu", func(): return nt.current == "yellow", 3.0)
	await get_tree().create_timer(1.0).timeout
	await shot("notification_yellow")
	app.pop()
	await wait_for("notification bar: yellow leaves outside the Tenkaichi 3 menus", func(): return nt.current == "", 3.0)
	nt.paused = true   # the rest of the tour without bars
	await wait_for("notification bar: gone", func(): return nt.current == "", 3.0)
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
	check("Down moves the wheel to Budokai Tenkaichi 2", top().carousel.current().get("label") == "Budokai Tenkaichi 2")
	check("description follows the selection", "Sparking! NEO" in app._desc.text)
	await shot("main_menu_bt2")
	await press("ui_down")
	check("then Video Settings (Friends moved to DRAGON NET)", top().carousel.current().get("label") == "Video Settings"
			and app._desc.text == "Change your video settings here.")
	await shot("main_menu_video")
	await press("ui_up")
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
	check("input history off by default (solo and matches)",
			solo[solo.rfind("--input-display") + 1] == "off" and host[host.rfind("--input-display") + 1] == "off")
	var tr_args := Settings.training_args()
	check("Buffer Training: input history on by default (its own switch, given last)",
			tr_args[tr_args.rfind("--input-display") + 1] == "on")
	check("online matches: never the opponent's input history",
			host[host.rfind("--input-display-other") + 1] == "off" and solo[solo.rfind("--input-display-other") + 1] == "off")

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
	await shot("netplay_menu")
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
	# Hidden: PgUp + PgDn switch NEOcode on (the joiner is told too).
	await pgup_pgdn()
	await wait_for("NEOcode switched on", func(): return lobby._neocode, 10)
	check("NEOcode shown in the lobby info", "NEOcode" in lobby._info_right.text)
	check("NEOcode notice in the chat", tr("NEOcode on.") in "\n".join(lobby._chat))
	check("nothing in the lobby says rollback", not "rollback" in ("\n".join(lobby._chat) + lobby._info_right.text).to_lower())
	await shot("lobby_neocode")
	await pick("start", lobby._actions)
	await wait_for("match running", func(): return lobby._phase == "playing", 30)
	await pgup_pgdn()
	check("NEOcode can't be switched during a match", lobby._neocode and
			tr("NEOcode can't be switched during a match.") in "\n".join(lobby._chat))
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
	await pgup_pgdn()   # NEOcode back off (it's remembered for the next lobby)
	await wait_for("NEOcode switched off", func(): return not lobby._neocode, 10)
	check("NEOcode off: gone from the lobby info", not "NEOcode" in lobby._info_right.text)
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
		await leave_lobby(joined)
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
			await leave_lobby(watcher)
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
		check("Step down row in the line", kl._actions.row("step_down").get("label") == "Step down")
		await pick("step_down", kl._actions)
		await wait_for("stepped down: last in line (Trunks stays first)", func():
			return "\n".join(kl._chat).contains(tr("%s stepped down to the back of the line.") % "Goku"), 15)
		await leave_lobby(kl)
		await wait_for("left Trunks' lobby", func(): return app.top() == kb, 15)
		await wait_for("Dolphin exited (Battle Lounge)", func(): return not Dolphin.is_running(), 10)
	await back()   # browser -> Battle Lounge menu
	await choose("Host")
	check("Battle Lounge host options", app._title.text == "Host a Battle Lounge")
	check("host lobby is Battle Lounge", top().koth)
	await shot("koth_host_options")
	await back()   # -> Battle Lounge menu
	await back()   # -> DRAGON NET

	# --- Ranked Match: DRAGON NET account, ranked lobby browser, an FT2 match, leaderboard ----
	await choose("Ranked Match")
	check("Ranked Match menu", app._title.text == "Ranked Match")
	await shot("ranked_menu")
	await choose("Leaderboard")
	var lb: Control = top()
	await wait_for("leaderboard loaded", func(): return not lb._loading, 15)
	check("leaderboard: nobody yet", lb._rows.is_empty() and lb._error == "")
	await back()
	await choose("Lobby Browser")
	var rlogin: Control = top()
	check("ranked asks for the DRAGON NET login first", app._title.text == "DRAGON NET Login")
	await type_into(rlogin.list, "username", "Goku")
	await type_into(rlogin.list, "password", "tour-pass-1")
	check("the password is hidden", rlogin.list._nodes.any(func(n): return n.edit != null and n.edit.secret))
	await pick("login", rlogin.list)
	await wait_for("no such account yet", func(): return "Wrong username" in rlogin._status, 15)
	await shot("ranked_login")
	await pick("create", rlogin.list)
	await wait_for("account made, logged in", func(): return app.top() != rlogin, 30)
	check("the account name is the ranked name", Ranked.display_name() == "Goku" and Ranked.logged_in())
	var rb: Control = top()
	check("on to the Ranked Lobby Browser", app._title.text == "Ranked Lobbies")
	await wait_for("ranked lobbies loaded", func(): return not rb._loading, 15)
	var vk := ""
	for r in rb.list.rows:
		if String(r.get("key", "")).begins_with("lobby:") and r.get("label") == "Vegeta":
			vk = r["key"]
	check("Vegeta's ranked lobby listed with his rating", vk != "" and "1000" in String(rb.list.row(vk).get("value", "")))
	await shot("ranked_lobby_browser")
	if vk != "":
		await pick(vk, rb.list)
		var rl: Control = top()
		check("in a ranked lobby", rl != rb and rl.ranked)
		check("title says FT2", "FT2" in app._title.text)
		check("ranked lobby has its own music track", Music.current_track() == "ranked")
		check("players are told it's first to 2", "\n".join(rl._chat).contains("FT2"))
		await wait_for("both players in the ranked lobby", func(): return rl._koth_line_size() == 2, 30)
		await wait_for("ratings from the ranked server", func(): return not rl._ranked.is_empty(), 20)
		await frames(30)
		await shot("ranked_lobby")
		print("TOUR_EVENT ranked_ready")
		await wait_for("the host asks to start: a pop-up", func():
			return app.top() != rl and tr("%s wants to start") % "Vegeta" == app._title.text, 30)
		await shot("ranked_start_question")
		await choose("Accept")
		check("answered: back in the lobby", app.top() == rl)
		await wait_for("ranked match running", func(): return rl._phase == "playing", 60)
		# The harness pokes the host's health; this player's game sees the first round too (the
		# real game has the same memory on both sides), which starts its replay recording.
		await get_tree().create_timer(1.0).timeout
		for addr in ["80001100", "80001104"]:
			Dolphin.send("poke %s 42C80000" % addr)
		await wait_for("ranked win reported and rated", func():
			return "\n".join(rl._chat).contains(tr("Ranked win! Rating %+d.") % 16), 60)
		await wait_for("profile shows the new rating", func(): return Ranked.rating("single") == 1016, 20)
		await wait_for("back in the ranked lobby", func(): return rl._phase == "lobby", 30)
		await wait_for("the ranked replay is shared on DRAGON NET by itself", func():
			return "\n".join(rl._chat).contains(tr("Replay shared on DRAGON NET (Replay Search).")), 60)
		await frames(20)
		await shot("ranked_after_match")
		await leave_lobby(rl)
		await wait_for("left the ranked lobby", func(): return app.top() == rb, 20)
		await wait_for("Dolphin exited (ranked)", func(): return not Dolphin.is_running(), 10)
	await back()   # ranked browser -> Ranked Match menu
	await choose("Leaderboard")
	lb = top()
	await wait_for("leaderboard loaded again", func(): return not lb._loading, 15)
	check("Goku leads Single Battle FT2 with 1016, 1-0", not lb._rows.is_empty()
			and lb._rows[0].get("name") == "Goku" and int(lb._rows[0].get("rating", 0)) == 1016
			and int(lb._rows[0].get("wins", 0)) == 1)
	await shot("ranked_leaderboard")
	lb.on_value("board_region", Settings.REGIONS[0])   # a region where nothing was played
	await wait_for("region board loaded", func(): return not lb._loading, 15)
	check("a region where nobody played is empty", lb._rows.is_empty())
	lb.on_value("board_region", "EU")
	await wait_for("EU board loaded", func(): return not lb._loading, 15)
	check("EU (where the lobby was hosted) has both players", lb._rows.size() == 2)
	lb.on_value("board_mode", "all")
	await wait_for("all-time board loaded", func(): return not lb._loading, 15)
	check("all-time record board", lb._rows.size() == 2 and not lb._rows[0].has("rating"))
	await shot("ranked_leaderboard_alltime")
	lb.on_value("board_mode", "single")
	lb.on_value("board_region", "global")
	await back()
	await choose("Profile")
	await wait_for("profile loaded", func(): return top()._status == "", 15)
	await shot("ranked_profile")
	# Profile picture: a 300 x 200 picture goes through the cropper (moved, made smaller, torn off).
	var acct: Control = top()
	var src := Image.create(300, 200, false, Image.FORMAT_RGBA8)
	src.fill(Color("#2266cc"))
	src.fill_rect(Rect2i(200, 60, 80, 80), Color("#ffcc00"))
	acct.open_picture(src)
	await frames(10)
	var crop: Control = top()
	check("not square: the cropper opens", crop != acct and app._title.text == tr("Profile Picture"))
	check("the frame starts as the biggest centred square", crop._crop == Rect2(50, 0, 200, 200))
	crop.nudge(Vector2(500, 0), -100)   # far right (stops at the edge), half the size
	check("moved to the right edge and made smaller (%s)" % crop._crop, crop._crop.size.x == 100.0 and crop._crop.end.x == 300.0)
	await frames(5)
	await shot("picture_crop")
	var out: Image = crop.result()
	check("the cut is %d x %d" % [out.get_width(), out.get_height()], out.get_width() == 128 and out.get_height() == 128)
	check("it's the part under the frame (yellow square)", out.get_pixel(64, 64).is_equal_approx(Color("#ffcc00")))
	await press("ui_accept")
	await wait_for("torn off and saved", func(): return app.top() == acct and acct._status == tr("Picture saved."), 20)
	check("the account has its picture now", Ranked.picture().contains("pic.php?id="))
	await frames(20)
	await shot("ranked_profile_picture")
	await back()
	# Replays: the ranked match above was recorded by Dolphin; watch it back to its end.
	await choose("Replays")
	var rp: Control = top()
	check("Replays screen", app._title.text == "Replays")
	var rk := ""
	for r in rp.list.rows:
		if String(r.get("key", "")).begins_with("replay:") and "Goku" in String(r.get("label", "")):
			rk = r["key"]
	check("the ranked match was saved as a replay (%s)" % rp.list.row(rk).get("label", "none"), rk != "")
	await shot("replays")
	check("the shared replay is marked shared", rk != "" and int(rp._replays[int(rk.get_slice(":", 1))].get("shared_id", 0)) > 0)
	if rk != "":
		await pick(rk, rp.list)
		check("replay menu: watch, share, delete", top() != rp and "carousel" in top())
		await shot("replay_menu")
		await choose("Watch")
		var player: Control = top()
		check("replay player opened", player != rp and app._title.text == "Replay")
		await wait_for("replay playing", func(): return player._state in ["playing", "ended"], 60)
		await shot("replay_playing")
		await wait_for("replay plays to its end", func(): return is_instance_valid(player) and player._state == "ended", 180)
		await wait_for("the replay closes by itself, back to the list", func(): return app.top() == rp, 30)
		await wait_for("Dolphin exited (replay)", func(): return not Dolphin.is_running(), 10)
	# Replay Search: the shared replay is there for everyone; download it.
	await pick("search", rp.list)
	var rs: Control = top()
	check("Replay Search screen", app._title.text == "Replay Search")
	await wait_for("shared replays listed", func(): return rs._searched and not rs._busy, 20)
	check("the shared match is found (%d results)" % rs._results.size(), rs._results.size() >= 1
			and "Goku" in Replays_title(rs._results[0]))
	rs.on_value("q", "nobody_like_this")
	await wait_for("searched again", func(): return not rs._busy, 20)
	check("a name nobody has: nothing", rs._results.is_empty() and not rs.list.row("none").is_empty())
	rs.on_value("q", "gok")
	await wait_for("searched by part of a name", func(): return not rs._busy and rs._results.size() >= 1, 20)
	await shot("replay_search")
	await pick("r:0", rs.list)
	await choose("Download")
	var rid := int(rs._results[0]["id"])
	await wait_for("downloaded", func(): return not rs._busy and rs._status == tr("Downloaded."), 60)
	check("the download is a full replay", not load("res://scripts/replay_share.gd").downloaded(rid).is_empty())
	await shot("replay_search_downloaded")
	await back()   # Replay Search -> Replays
	await back()
	await back()   # Ranked Match -> DRAGON NET
	# Logged in: the rating plate slides in while Ranked Match is selected, out when it isn't.
	var nm: Control = top()
	await wait_for("rating plate shown on Ranked Match", func():
		return nm.bumper and nm.bumper.is_shown() and nm.bumper._values[0].text == "1016", 10)
	await frames(30)
	await shot("ranked_rating_bumper")
	await press("ui_up")
	await frames(30)
	check("rating plate slides away off Ranked Match", not nm.bumper.is_shown())

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
	check("training menu: input history row, on", app._compact.list.row("input_display").get("value") == "On")
	await pick("input_display", app._compact.list)   # (pick presses it)
	await wait_for("input history switched off live", func():
		return "\n".join(Dolphin.log_lines).contains('"event":"input_display","enabled":false'), 10)
	check("training's own switch saved, the general one untouched",
			Settings.get_value("options", "training_input_display") == false
			and Settings.get_value("options", "input_display") == false)
	await shot("ingame_menu_training_input_off")
	await press("ui_accept")
	await wait_for("input history back on", func():
		return "\n".join(Dolphin.log_lines).contains('"event":"input_display","enabled":true'), 10)
	check("row says On again", app._compact.list.row("input_display").get("value") == "On")
	check("training menu: P2 input history row (off)", app._compact.list.row("input_display_other").get("value") == "Off")
	await pick("input_display_other", app._compact.list)
	await wait_for("P2 input history on in training", func():
		return "\n".join(Dolphin.log_lines).contains('"other":true'), 10)
	check("training's P2 switch saved", Settings.get_value("options", "training_input_display_other") == true)
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

	# The Rollback Test is hidden now (the screen is still there for testing builds).
	check("no Rollback Test in the DRAGON NET menu",
			not top().carousel.items.any(func(it): return "Rollback" in String(it.get("label", ""))))

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
	check("Codes open on the offline version's tab", mods._version == "PAL")
	await wait_for("gecko codes loaded", func(): return mods._codes.has("RDSPAF"), 20)
	check("gecko codes listed", mods._codes["RDSPAF"].size() > 0)
	await pick("custom", mods.list)
	check("custom code selection on (BT3 PAL's)", Settings.gecko_custom("RDSPAF") == true)
	await shot("modifications")
	# Another version: its own codes (none in this build yet) and its own choice.
	var shoulder := InputEventJoypadButton.new()
	shoulder.button_index = JOY_BUTTON_RIGHT_SHOULDER
	shoulder.pressed = true
	Input.parse_input_event(shoulder)
	await frames(3)
	check("RB: the NTSC-J tab", mods._version == "NTSC-J")
	await wait_for("NTSC-J codes looked up", func(): return mods._codes.has("RDSJAF"), 20)
	check("NTSC-J: no codes yet, its own selection", not mods.list.row("none").is_empty()
			and Settings.gecko_custom("RDSJAF") == false)
	await shot("modifications_ntsc_j")
	var key_q := InputEventKey.new()
	key_q.keycode = KEY_Q
	key_q.pressed = true
	Input.parse_input_event(key_q)
	await frames(3)
	check("Q: back to PAL, still custom", mods._version == "PAL" and mods.list.row("custom").get("value") == true)
	var solo_codes := Settings.solo_args()
	check("offline launch uses PAL's custom codes", "--gecko" in solo_codes or "--no-gecko" in solo_codes)
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
	var chosen: String = pads.Controllers.choice()
	check("the choice is Tenkaichi 3's", Settings.get_value("controller", "bt3_preset") == chosen)
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
	check("saved config selected, in Tenkaichi 3's own folder", pads.Controllers.choice() == "Tour Pad"
			and app.top() == pads and pads.Controllers.user_dir().ends_with("controllers/bt3"))
	await wait_for("helper Dolphin stopped", func():
		return Dolphin._helpers.all(func(h): return h["proc"] == Presence._helper), 10)
	# Budokai Tenkaichi 2: its own presets (not Tenkaichi 3's) and its own choice.
	Settings.use_game("bt2")
	var bt2_names: Array = pads.Controllers.list().map(func(p): return p["name"])
	check("BT2 doesn't list Tenkaichi 3's presets", not "Tour Pad" in bt2_names
			and not "Xbox One - Sparking Standard" in bt2_names)
	check("BT2 has its own choice", pads.Controllers.choice() == pads.Controllers.AUTO)
	pads.Controllers.set_choice(pads.Controllers.KEEP)
	Settings.use_game("bt3")
	check("Tenkaichi 3's choice untouched", pads.Controllers.choice() == "Tour Pad")
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
	var sm_args := func():
		var a: PackedStringArray = Settings.common_args()
		return a[a.find("--smooth-motion") + 1] if a.has("--smooth-motion") else ""
	check("Smooth Motion: off by default", not Settings.get_value("video", "smooth_motion")
			and sm_args.call() == "off")
	await pick("smooth_motion", top().list)
	check("Smooth Motion: turned on (--smooth-motion on), says it's frame interpolation",
			Settings.get_value("video", "smooth_motion") and sm_args.call() == "on"
			and app._desc.text.begins_with("Frame interpolation"))
	await shot("video_settings_smooth_motion")
	top().on_value("smooth_motion", false)
	await pick("window", top().list)
	await shot("video_settings")
	await back()
	await choose("Options")
	await shot("options")
	check("Options has Profile, no Files & Folders", top().list.row("profile").get("label") == "Profile"
			and top().list.row("files").is_empty())
	await back()
	await games_and_versions()
	await friends_and_popups()
	app.open("setup")
	await shot("first_run_setup")
	check("setup asks for one copy of each game", top().list.row("game_bt3").get("value", "").begins_with("PAL")
			and top().list.row("game_bt2").get("label") == "Budokai Tenkaichi 2")

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
	app.push(app._game_menu("bt3"))
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
		app.push(app._game_menu("bt3"))
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
