extends "res://scripts/screens/screen.gd"
## The netplay lobby, for hosting, joining and matchmaking ("find") alike: room info, players
## (slot, ping ± jitter, wired/Wi-Fi, quality), messages, pad buffer, Start (host), Leave.
## While the match runs, a held Select opens the small in-game version: messages, buffer and
## "Stop Match" (ends the match for everyone, back to this lobby).
## Battle Lounge (koth, or once Dolphin sends a "koth" event): the Players panel becomes the
## line (P1 = champion, P2 = challenger, then everyone waiting), sets start on their own after a
## short break, and joining during a set waits for it to end.
## kind "training" is Buffer Training: a solo, unlisted lobby that boots straight into the training
## state, so the player can feel a pad buffer of their choice (set live, also from the menu).
## Mode (Player Match): picked in the lobby, not before it. The bar above Messages shows it; the
## host switches it between matches (LB / RB, Q / E, or a click): Dolphin's "mode" command loads
## that mode's battle state for everyone. Battle Lounge and Ranked lobbies keep the mode they
## were opened with (no bar).

const OptionList := preload("res://scripts/ui/option_list.gd")
const InGamePanel := preload("res://scripts/ui/ingame_panel.gd")
const LinkIcon := preload("res://scripts/ui/link_icon.gd")
const ReplayShare := preload("res://scripts/replay_share.gd")

const ERRORS := {
	"not_all_players_have_game": "Not everyone has the game yet.",
	"battle_state_not_ready": "Still checking everyone's battle state. Try again in a moment.",
	"save_data_mismatch": "Someone's save data doesn't match the host's.",
	"start_rejected": "The match couldn't start.",
	"connect_failed": "Couldn't connect to the lobby.",
	"connection_error": "Connection error.",
	"traversal_error": "Room code server error.",
	"game_not_found": "Your game file wasn't found. Was it moved?",
	"invalid_game": "The game file can't be used.",
	"listen_failed": "Couldn't open the port (is another lobby running?).",
	"bad_address": "That code or address isn't valid.",
	"boot_failed": "The game failed to start.",
	"state_file_missing": "The battle state file is missing from SparkingData\\states.",
	"lobby_full": "That lobby already has 2 players. You can watch it instead.",
	"spectators_full": "That lobby already has 2 spectators.",
	"training_solo": "That's a Buffer Training session: it's solo.",
	"koth_need_two": "Battle Lounge needs 2 people in line to start.",
	"ranked_no_spectators": "Ranked matches can't be watched.",
}

var kind := "host"            # host, join, find, watch (spectator: never plays), training (solo)
var mode := "any"
var _args := PackedStringArray()
var _closed_because := ""

var _phase := "connecting"    # connecting, searching, lobby, playing, closing
var _role := ""               # host / client once in a lobby
var _status := ""
var _room := {}
var _public := {}
var _players: Array = []
var _buffer := -1
var _neocode := false     # NEOcode on for this lobby (the host switches it: PgUp + PgDn together)
var _neo_r := -1          # its "R" while a match runs (-1: none)
var _neo_out_of_sync := false
var _match_id := 0           # ranked: the server's id of the match being / last played
var _friends_told := {}      # DRAGON NET accounts already announced in this lobby
var _asking := false         # ranked host: waiting for the other player to approve the start
var _ask_menu: Control = null   # ranked guest: the "start the match?" question on screen
var _chat: PackedStringArray = []
var _codes_available: Array = []   # this game's optional codes the host may switch on (Dolphin's "lobby_codes")
var _codes_on: Array = []          # ...and the ones that are on, for everyone
var _battle := {}
var _logged_buffer := -1
var _auto_started := false    # Buffer Training starts itself once the state is ready
var _auto_retries := 0          # its start refused while Dolphin was still checking: retried
var koth := false             # Battle Lounge lobby (set by the menus, or by a "koth" event)
var _koth := {}               # last "koth" event: state, line, wins, streak, ...
var _koth_waiting := false    # joiner: a set is on, Dolphin retries until it ends
## Ranked Match: Dolphin's King of the Hill set engine for 2 players (Single Battle FT2, Team
## Battle 1 win, no spectators), listed and rated by the ranked server.
var ranked := false
var ranked_lobby := 0         # the lobby's id on the ranked server (host: once listed)
var _ranked := {}             # last lobby status from the ranked server
var _ranked_busy := false
var _reported := false        # this match's result already sent
var _announced := -1          # ranked match id whose result was already shown
## Ranked: this lobby's set is over (a match counted). One set per lobby: no more matches here;
## both players leave and a new ranked lobby is opened for the next set (the server refuses too).
var _set_done := false
var _ranked_timer: Timer

var _info: Label
var _info_right: Label
var _players_box: VBoxContainer
var _players_status: Label
var _players_head: Label
var _actions: Control
var _chat_log: RichTextLabel
var _panel: Control           # in-game menu, while open
var _mode_bar: Control
var _mode_tabs := {}          # mode -> {panel, label}
var _mode_note: Label
var _chat_panel: Control



func _init() -> void:
	super()
	notices = false   # no notification bars here


func setup(p_kind: String, args: PackedStringArray, p_mode: String) -> Node:
	kind = p_kind
	_args = args
	mode = p_mode
	return self


func screen_fade() -> String:
	return "lobby"


func screen_music() -> String:
	if ranked:
		return "ranked"   # music/ranked.* and the look's ranked picture (else the lobby's)
	# Battle Lounge has its own track and background (music/battle_lounge.*; without a file it
	# plays the lobby track).
	return "battle_lounge" if koth else "lobby"


func screen_title() -> String:
	if ranked:
		return tr("Ranked: %s") % Ranked.mode_title(mode)
	if koth:
		return tr("Battle Lounge: %s") % (tr("Any Mode") if mode == "any" else Style.mode_name(mode))
	if is_spectating():
		return tr("Watching: %s") % (tr("Lobby") if mode == "any" else Style.mode_name(mode))
	return "Lobby" if mode == "any" else Style.mode_name(mode)


func on_enter() -> void:
	show_desc_bar = false
	_build()
	Dolphin.event.connect(_on_event)
	_phase = "searching" if kind == "find" else "connecting"
	_status = tr("Looking for a %s lobby...") % Style.mode_name(mode) if kind == "find" else "Connecting..."
	if koth and kind == "find":
		_status = tr("Looking for a Battle Lounge lobby...")
	if not Dolphin.launch(_args):
		app.toast("Couldn't start Dolphin-Sparking (is the Dolphin folder next to the launcher?).")
		app.pop.call_deferred()
		return
	if ranked:
		koth = true   # Dolphin runs the ranked match with the Battle Lounge set engine
		_system(tr("Ranked %s: first to 2 wins (FT2).") % Style.mode_name("single") if mode == "single"
				else tr("Ranked %s: one match decides it.") % Style.mode_name(mode), "#f2b531")
		_system("Leaving or stopping during a ranked match counts as a loss.")
		_ranked_timer = Timer.new()
		_ranked_timer.wait_time = 5.0
		_ranked_timer.timeout.connect(_ranked_tick)
		add_child(_ranked_timer)
		_ranked_timer.start()
	_refresh_all()


func _exit_tree() -> void:
	if Dolphin.event.is_connected(_on_event):
		Dolphin.event.disconnect(_on_event)
	if ranked and ranked_lobby > 0:
		# Off the ranked list / give the seat back. (Ranked.api runs on the autoload: it outlives us.)
		Ranked.api("lobby.php", {"action": "close" if _role == "host" else "leave", "lobby": ranked_lobby})


# --- Ranked --------------------------------------------------------------------------------

## Every few seconds: the host lists its lobby once the room is up (then keeps it listed), the
## guest keeps its seat; both get the opponent's rating and the last match's result.
func _ranked_tick() -> void:
	if _ranked_busy or _phase in ["connecting", "searching", "closing"]:
		return
	_ranked_busy = true
	var res := {}
	if _role == "host" and ranked_lobby == 0:
		var join := _ranked_join_target()
		if join == "":
			_ranked_busy = false
			return
		var link := "unknown"
		for p in _players:
			if p.get("is_host", false):
				link = String(p.get("link", "unknown"))
		res = await Ranked.api("lobby.php", {"action": "open", "mode": mode,
			"region": Settings.get_value("player", "region"), "join": join, "link": link})
		if res.get("ok", false):
			ranked_lobby = int(res["lobby"]["id"])
			_system("Your ranked lobby is listed in the Ranked Lobby Browser.", "#3fbf6b")
		else:
			_system(tr("Couldn't list the ranked lobby: %s") % Ranked.error_text(String(res.get("error", ""))), "#e8663d")
	elif ranked_lobby > 0:
		res = await Ranked.api("lobby.php", {"action": "heartbeat" if _role == "host" else "status",
			"lobby": ranked_lobby})
		if res.get("error", "") == "lobby_gone" and _role != "host":
			_system("The ranked lobby closed.", "#e8663d")
	_ranked_busy = false
	if not is_inside_tree() or not res.get("ok", false) or not res.has("lobby"):
		return
	_ranked = res["lobby"]
	for key in ["match", "last_match"]:
		if _ranked.get(key) is Dictionary and int(_ranked[key].get("id", 0)) > _match_id:
			_match_id = int(_ranked[key]["id"])
	_announce_result(_ranked.get("last_match"))
	if _ranked.get("set_done", false):
		_end_set()
	_refresh_all()


## Where the opponent connects: the room code, or (Direct IP) your public address and port.
func _ranked_join_target() -> String:
	if _room.get("state", "") != "ready":
		return ""
	if _room.get("type") == "traversal":
		return String(_room.get("code", ""))
	var public := String(Settings.get_value("netplay", "public_address")).strip_edges()
	if public == "":
		return ""
	return public if ":" in public else "%s:%d" % [public, int(_room.get("port", 2626))]


func _report(result: String, why := "") -> void:
	if _reported or ranked_lobby <= 0:
		return
	_reported = true
	var res := await Ranked.api("match.php", {"action": "forfeit" if result == "forfeit" else "report",
		"lobby": ranked_lobby, "result": result})
	if not is_inside_tree():
		return
	if res.get("ok", false):
		_system(why if why != "" else "Result sent to the ranked server.", "#cfe9ee")
		_announce_result(res.get("match"))
	_ranked_tick()


## Ranked guest: the host wants to start. A question on screen: accept or decline.
func _on_start_asked(host: String) -> void:
	if _ask_menu and is_instance_valid(_ask_menu):
		return
	if _set_done:
		Dolphin.send("answer_start no")   # (one set per lobby)
		return
	Sfx.play("player_join")
	var state := {"answered": false}
	var answer := func(yes: bool):
		if state["answered"]:
			return
		state["answered"] = true
		Dolphin.send("answer_start " + ("yes" if yes else "no"))
		if _ask_menu and is_instance_valid(_ask_menu) and app.top() == _ask_menu:
			app.pop()
		_ask_menu = null
		_system("You accepted: the match starts." if yes else "You declined the match.", "#cfe9ee")
	var items: Array = [
		{"label": "Accept", "glyph": "A", "color": "#3fbf6b", "desc": tr("Start the ranked match against %s now.") % host,
			"action": func(): answer.call(true)},
		{"label": "Decline", "glyph": "D", "color": "#e8663d", "desc": "Not yet: back to the lobby.",
			"action": func(): answer.call(false)},
	]
	_ask_menu = app.menu(tr("%s wants to start") % host, items, "ranked")
	_ask_menu.notices = false
	# Backed out of it (B) without answering: that's a no.
	_ask_menu.tree_exiting.connect(func():
		if not state["answered"] and is_inside_tree():
			state["answered"] = true
			Dolphin.send("answer_start no"))
	if app.is_ingame_menu_open():
		app.close_ingame_menu(false)
	app.push(_ask_menu)
	app.show_window()
	# Unanswered for 30 s: the host stops waiting; so does the question.
	var menu := _ask_menu
	await get_tree().create_timer(30.0).timeout
	if is_instance_valid(menu) and app.top() == menu:
		app.pop()
		if _ask_menu == menu:
			_ask_menu = null


## Players here with a DRAGON NET account who aren't friends yet (nor asked already).
func _friend_candidates() -> Array:
	if not Ranked.logged_in() or Ranked.needs_account:
		return []
	var me := Ranked.display_name().to_lower()
	var asked: Array = Social.outgoing.map(func(o): return String(o.get("name", "")).to_lower())
	var out: Array = []
	for p in _players:
		var acc := String(p.get("account", ""))
		if acc != "" and acc.to_lower() != me and not Social.is_friend(acc) and not acc.to_lower() in asked \
				and not acc in out:
			out.append(acc)
	return out


## Add friend: pick a player in the lobby, they get a friend request.
func _add_friend_menu() -> void:
	var items: Array = []
	for acc in _friend_candidates():
		var name := String(acc)
		items.append({"label": name, "glyph": name.left(1).to_upper(), "color": "#3fbf6b",
			"desc": tr("Send %s a friend request.") % name,
			"action": func():
				app.pop()
				var res: Dictionary = await Social.act("request", {"name": name})
				if not is_inside_tree():
					return
				if res.get("ok", false):
					_system((tr("You and %s are friends now.") if String(res.get("state", "")) == "friends"
						else tr("Friend request sent to %s.")) % name, "#3fbf6b")
				else:
					_system(Ranked.error_text(String(res.get("error", ""))), "#e8663d")
				_refresh_all()})
	items.append({"label": "Back", "glyph": "B", "color": "#8a9bb0", "back": true, "desc": "Back to the lobby."})
	var m: Control = app.menu("Add friend", items, "netplay")
	m.notices = false
	app.push(m)


## A friend (their DRAGON NET account) is in this lobby: the yellow pop-up, once per lobby.
func _announce_friends() -> void:
	var me := Ranked.display_name().to_lower()
	for p in _players:
		var acc := String(p.get("account", ""))
		if acc == "" or acc.to_lower() == me or _friends_told.has(acc.to_lower()) or not Social.is_friend(acc):
			continue
		_friends_told[acc.to_lower()] = true
		app.social_popups.friend_joined(acc)


## A ranked match's replay was saved: note which server match it is, and share it on DRAGON NET
## (Replay Search). Ranked replays are always shared; if it can't be sent now, it's sent later
## (ReplayShare.upload_pending: at login, then every ~10 minutes).
func _on_replay_saved(data: Dictionary) -> void:
	var jp := String(data.get("json", ""))
	var info = JSON.parse_string(FileAccess.get_file_as_string(jp)) if jp != "" else null
	if typeof(info) != TYPE_DICTIONARY:
		return
	info["path"] = String(data.get("dtm", ""))
	info["json_path"] = jp
	if not ranked:
		# Player Match / Battle Lounge: on this PC only, never uploaded.
		info["local"] = true
		var lf := FileAccess.open(jp, FileAccess.WRITE)
		if lf:
			var keep_local: Dictionary = info.duplicate()
			keep_local.erase("path")
			keep_local.erase("json_path")
			lf.store_string(JSON.stringify(keep_local, "\t"))
			lf.close()
		_system("Match recorded: Replays (on this PC only).", "#cfe9ee")
		return
	if _match_id > 0:
		info["match_id"] = _match_id
		var f := FileAccess.open(jp, FileAccess.WRITE)
		if f:
			var keep: Dictionary = info.duplicate()
			keep.erase("path")
			keep.erase("json_path")
			f.store_string(JSON.stringify(keep, "\t"))
			f.close()
	if not Ranked.logged_in() or Ranked.needs_account:
		return
	var res: Dictionary = await ReplayShare.upload(info)
	if not is_inside_tree():
		return
	if res.get("ok", false):
		_system("Replay shared on DRAGON NET (Replay Search).", "#cfe9ee")
	else:
		_system("Couldn't send the replay to DRAGON NET yet: it's sent automatically later.", "#e8663d")


## Ranked: the set counted. No more matches in this lobby.
func _end_set() -> void:
	if _set_done:
		return
	_set_done = true
	_asking = false
	_system("The ranked set is over. To play another, leave the lobby and open (or join) a new ranked lobby.", "#f2b531")
	_refresh_actions()


func _announce_result(m: Variant) -> void:
	if typeof(m) != TYPE_DICTIONARY or int(m.get("id", -1)) == _announced:
		return
	match String(m.get("state", "")):
		"done":
			_announced = int(m["id"])
			var d := int(m.get("rating_change", 0))
			if m.get("you_won", false):
				_system(tr("Ranked win! Rating %+d.") % d, "#3fbf6b")
			else:
				_system(tr("Ranked loss. Rating %+d.") % d, "#e8663d")
			Ranked.refresh()
			_end_set()
		"void":
			_announced = int(m["id"])
			_system("That ranked match didn't count (the two results didn't match).", "#e8663d")


# --- Layout ------------------------------------------------------------------------------

func _build() -> void:
	var strip := Style.panel(Color(Style.INK, 0.95), 14, 3, Style.PANEL_BORDER)
	Style.place(strip, 40, 112, 1200, 56)
	add_child(strip)
	_info = Style.label("", 24, Color.WHITE, 3, Style.DARK, true)
	_info.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	Style.place(_info, 20, 0, 760, 56)
	strip.add_child(_info)
	_info_right = Style.label("", 20, Style.INK_LINE, 0, Color.BLACK, true)
	_info_right.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_info_right.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	Style.place(_info_right, 700, 0, 480, 56)
	strip.add_child(_info_right)

	var pp := Style.skin_panel(14)
	Style.place(pp, 40, 180, 640, 262)
	add_child(pp)
	var ph := Style.label("Players", 24, Style.GOLD, 3, Style.DARK, true)
	Style.place(ph, 18, 8, 200, 34)
	pp.add_child(ph)
	_players_head = ph
	_players_status = Style.label("", 18, Style.INK_LINE, 0, Color.BLACK, true)
	_players_status.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_players_status.clip_text = true
	Style.place(_players_status, 200, 12, 424, 28)
	pp.add_child(_players_status)
	_players_box = VBoxContainer.new()
	_players_box.add_theme_constant_override("separation", 6)
	Style.place(_players_box, 14, 48, 612, 204)
	pp.add_child(_players_box)

	_actions = OptionList.new()
	_actions.row_height = 46
	_actions.font_size = 22
	_actions.label_width = 0.5
	Style.place(_actions, 40, 456, 640, 244)
	add_child(_actions)
	_actions.pressed.connect(_on_press)
	_actions.value_changed.connect(_on_value)

	_build_mode_bar()

	var cp := Style.skin_panel(14)
	Style.place(cp, 700, 262, 540, 438)
	add_child(cp)
	_chat_panel = cp
	var ch := Style.label("Messages", 24, Style.GOLD, 3, Style.DARK, true)
	Style.place(ch, 18, 8, 300, 34)
	cp.add_child(ch)
	_chat_log = RichTextLabel.new()
	_chat_log.bbcode_enabled = true
	_chat_log.scroll_following = true
	_chat_log.add_theme_font_override("normal_font", Style.body_font())
	_chat_log.add_theme_font_size_override("normal_font_size", 19)
	_chat_log.add_theme_font_size_override("bold_font_size", 19)
	Style.place(_chat_log, 18, 48, 504, 374)
	cp.add_child(_chat_log)


# --- Mode ----------------------------------------------------------------------------------

const MODES := ["single", "team"]

## The mode bar (right, above Messages): the lobby's two modes, the current one lit.
func _build_mode_bar() -> void:
	_mode_bar = Style.skin_panel(14)
	Style.place(_mode_bar, 700, 180, 540, 70)
	add_child(_mode_bar)
	var head := Style.label("Mode", 22, Style.GOLD, 3, Style.DARK, true)
	head.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	Style.place(head, 18, 0, 90, 70)
	_mode_bar.add_child(head)
	var x := 104.0
	for m in MODES:
		var p := Style.panel(Style.INK, 10, 3, Style.INK_LINE)
		Style.place(p, x, 12, 184, 46)
		p.mouse_filter = Control.MOUSE_FILTER_STOP
		p.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
		p.gui_input.connect(func(e):
			if e is InputEventMouseButton and e.pressed and e.button_index == MOUSE_BUTTON_LEFT:
				_switch_mode(m))
		_mode_bar.add_child(p)
		var l := Style.label("", 19, Color.WHITE, 3, Color.BLACK, true)
		l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		l.mouse_filter = Control.MOUSE_FILTER_IGNORE
		Style.place(l, 0, 0, 184, 46)
		p.add_child(l)
		_mode_tabs[m] = {"panel": p, "label": l}
		x += 192.0
	_mode_note = Style.label("", 15, Style.INK_LINE, 0, Color.BLACK, true)
	_mode_note.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_mode_note.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_mode_note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_mode_note.mouse_filter = Control.MOUSE_FILTER_IGNORE
	Style.place(_mode_note, 486, 4, 50, 62)
	_mode_bar.add_child(_mode_note)


## Player Match lobbies (not Battle Lounge, Ranked or Buffer Training) have the mode bar; the
## others give Messages the whole column.
func has_mode_bar() -> bool:
	return not (koth or ranked or is_training())


func _refresh_mode_bar() -> void:
	if not _mode_bar:
		return
	var shown := has_mode_bar()
	if _mode_bar.visible != shown or _chat_panel.position.y != (262.0 if shown else 180.0):
		_mode_bar.visible = shown
		Style.place(_chat_panel, 700, 262 if shown else 180, 540, 438 if shown else 520)
		Style.place(_chat_log, 18, 48, 504, 374 if shown else 456)
	if not shown:
		return
	var can := can_switch_mode()
	for m in _mode_tabs:
		var t: Dictionary = _mode_tabs[m]
		var on: bool = m == mode
		(t["label"] as Label).text = Style.mode_name(m)
		var sb: StyleBoxFlat = (t["panel"] as Panel).get_theme_stylebox("panel")
		sb.bg_color = Style.GOOD if on else Style.INK
		sb.border_color = Color("#fff27a") if on else Style.INK_LINE
		(t["panel"] as Panel).modulate.a = 1.0 if on or can else 0.45
		(t["panel"] as Panel).mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND if can and not on \
				else Control.CURSOR_ARROW
	# Who can change it, and how: the pad's shoulder buttons (keyboard Q / E) for the host.
	for c in _mode_note.get_children():
		c.queue_free()
	_mode_note.text = ""
	if can:
		var icons := Pad.prompt_icon_row("LB RB", 24)
		if icons:
			Style.place(icons, 0, 19, 50, 24)
			_mode_note.add_child(icons)
		else:
			_mode_note.text = "Q E"
	elif _role != "host" and _phase in ["lobby", "playing"]:
		_mode_note.text = tr("Host's pick")


## Player Match host, between matches: Single / Team can be switched.
func can_switch_mode() -> bool:
	return _role == "host" and has_mode_bar() and _phase == "lobby"


func _switch_mode(to: String) -> void:
	if to == mode or not to in MODES:
		return
	if not can_switch_mode():
		if _role == "host" and _phase == "playing":
			app.toast(tr("The mode can be changed between matches."), 2.5)
		elif _role != "host" and _phase == "lobby" and has_mode_bar():
			app.toast(tr("The host picks the mode."), 2.5)
		return
	Sfx.play("move")
	Settings.set_value("netplay", "mode", to)   # the next lobby opens with it
	Dolphin.send("mode " + to)


func _step_mode(step: int) -> void:
	_switch_mode(MODES[wrapi(MODES.find(mode) + step, 0, MODES.size())] if mode in MODES else MODES[0])


func _on_lobby_mode(m: String) -> void:
	if not m in MODES:
		return
	var changed := m != mode
	mode = m
	app.set_title(screen_title())
	if changed:
		_system(tr("Mode: %s.") % Style.mode_name(m), "#f2b531")


func _refresh_all() -> void:
	_refresh_info()
	_refresh_players()
	_refresh_actions()
	_refresh_panel()
	_refresh_mode_bar()
	var hints := screen_hints()
	if hints != _hints_shown and app and app.top() == self:
		_hints_shown = hints
		app._refresh_hints()


var _hints_shown: Array = []

func screen_hints() -> Array:
	var h: Array = [["▲▼", Style.INK_LINE, "Move"], ["A", Style.GOOD, "Select"], ["B", Style.POOR, "Back"]]
	if can_switch_mode():
		h.push_front(["LB RB", Style.INK_LINE, "Mode"])
	return h


func _refresh_info() -> void:
	var left := ""
	if is_training():
		left = _status if _phase in ["connecting", "searching"] else tr("Solo · Pad buffer %s") % (str(_buffer) if _buffer > 0 else "?")
	elif _role == "host" or not _room.is_empty():
		match _room.get("state", ""):
			"ready":
				if _room.get("type") == "traversal":
					left = tr("Room code:  %s") % String(_room.get("code", ""))
				else:
					var addrs: Array = _room.get("addresses", [])
					var addr := String(addrs[0]) if not addrs.is_empty() else "?"
					if not ":" in addr:
						addr += ":%d" % int(_room.get("port", 2626))
					if Settings.get_value("netplay", "public_address") != "" and _room.get("public", false):
						addr = "%s:%d" % [Settings.get_value("netplay", "public_address"), int(_room.get("port", 2626))]
					left = tr("Address:  %s") % addr
			"failed":
				left = "Room code server unreachable"
			"connecting":
				left = "Getting a room code..."
	if left == "":
		left = _status if _phase in ["connecting", "searching"] else ("Hosting" if _role == "host" else "Joined lobby")
	_info.text = tr(left)
	var right: Array = [Ranked.mode_title(mode) if ranked else Style.mode_name(mode)]
	if ranked:
		right.append(tr("Ranked · %s") % String(Settings.get_value("player", "region")) if ranked_lobby > 0 or _role != "host"
				else tr("Ranked · listing..."))
	elif is_training():
		right.append(tr("Solo"))
	elif _role == "host":
		if _public.get("listed", false):
			right.append(tr("Public · %s") % String(_public.get("region", Settings.get_value("player", "region"))))
		elif _public.has("error"):
			right.append(tr("Not listed (lobby server)"))
		elif _room.get("public", false):
			right.append(tr("Public · listing..."))
		else:
			right.append(tr("Private"))
	if _neocode and not is_training():
		right.append("NEOcode" + (" · R %d" % _neo_r if _phase == "playing" and _neo_r >= 0 else ""))
	_info_right.text = "   ·   ".join(right)


func _refresh_players() -> void:
	for c in _players_box.get_children():
		c.queue_free()
	_players_status.text = _status
	if _phase in ["connecting", "searching"]:
		var l := Style.label(_status, 26, Color.WHITE, 3, Style.DARK, true)
		l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		l.custom_minimum_size = Vector2(600, 120)
		l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		_players_box.add_child(l)
		_players_status.text = ""
		return
	if koth and not _koth.is_empty():
		_refresh_line()
		return
	_players_head.text = tr("Players")
	_players_head.size.x = 200
	_players_status.position.x = 200
	_players_status.size.x = 424
	_players_box.add_theme_constant_override("separation", 6)
	var sorted := _playing()
	sorted.sort_custom(func(a, b):
		var sa: int = a.get("gc_slot", -1)
		var sb: int = b.get("gc_slot", -1)
		return (sa if sa > 0 else 99) < (sb if sb > 0 else 99))
	for p in sorted:
		_players_box.add_child(_player_row(p))
	var watching := _watching()
	if not watching.is_empty():
		var head := Style.label(tr("Spectators (%d/2)") % watching.size(), 18, Style.GOLD, 3, Style.DARK, true)
		head.custom_minimum_size = Vector2(612, 24)
		_players_box.add_child(head)
		for p in watching:
			_players_box.add_child(_player_row(p, true))


## Battle Lounge: the line in order (P1 champion, P2 challenger, #3... waiting), compact rows
## so all 8 fit; watchers are counted in the corner.
func _refresh_line() -> void:
	var by_pid := {}
	for p in _players:
		by_pid[int(p.get("pid", 0))] = p
	var line: Array = _koth.get("line", [])
	var watching := _watching().size()
	var head := tr("Players %d/2") % line.size() if ranked else tr("Line %d/8") % (line.size() + watching)
	if watching > 0:
		head += "  ·  " + tr("%d watching") % watching
	_players_head.text = head
	_players_head.size.x = 300
	_players_status.position.x = 320
	_players_status.size.x = 304
	_players_box.add_theme_constant_override("separation", 1)
	for e in line:
		var pos := int(e.get("pos", 0))
		var p: Dictionary = by_pid.get(int(e.get("pid", 0)), {"name": e.get("name", "?")})
		_players_box.add_child(_line_row(pos, p, String(e.get("name", "?"))))


func _line_row(pos: int, p: Dictionary, name: String) -> Control:
	var row := Panel.new()
	var mine := pos == int(_koth.get("local_pos", -1))
	row.add_theme_stylebox_override("panel", Style.box(Color(0.25, 0.2, 0.05, 0.45) if mine else Color(0, 0, 0, 0.25 if pos < 2 else 0.15), 6))
	row.custom_minimum_size = Vector2(612, 24)
	var badge := Style.panel(Style.GOLD if pos == 0 else (Color("#3fa9f5") if pos == 1 else Style.MUTED), 6)
	Style.place(badge, 4, 2, 44, 20)
	row.add_child(badge)
	var bl := Style.label("P%d" % (pos + 1) if pos < 2 else "#%d" % (pos + 1), 14, Style.DARK, 0, Color.BLACK, true)
	bl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	bl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	Style.place(bl, 0, 0, 44, 20)
	badge.add_child(bl)
	var text := ("★ " if p.get("is_host", false) else "") + name
	if ranked:
		for who in [_ranked.get("host"), _ranked.get("guest")]:
			if typeof(who) == TYPE_DICTIONARY and String(who.get("name", "")) == name:
				text += "   " + tr("Rating %d") % int(who.get("rating", 1000))
	elif pos == 0 and int(_koth.get("streak", 0)) > 0 and String(_koth.get("champion", "")) == name:
		text += "   " + tr("Champion · %d in a row") % int(_koth.get("streak", 0))
	var nl := Style.label(text, 17, Style.GOLD if pos == 0 else Color.WHITE, 2, Style.DARK, true)
	nl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	nl.clip_text = true
	nl.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	Style.place(nl, 58, 0, 330, 24)
	row.add_child(nl)
	var link: Control = LinkIcon.new()
	link.link = String(p.get("link", ""))
	Style.place(link, 400, 3, 18, 18)
	row.add_child(link)
	var ping_text := "%d ms" % int(p.get("ping", 0))
	if int(p.get("jitter", -1)) >= 0:
		ping_text += " ±%d" % int(p.get("jitter", -1))
	if p.get("is_host", false) and _role == "host":
		ping_text = "host"
	var q := String(p.get("quality", "measuring"))
	var pl := Style.label(ping_text, 16, Style.quality_color(q), 2, Style.DARK, true)
	pl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	pl.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	Style.place(pl, 430, 0, 150, 24)
	row.add_child(pl)
	var dot := Style.panel(Style.quality_color(q), 6)
	Style.place(dot, 590, 7, 10, 10)
	row.add_child(dot)
	return row


## What the Battle Lounge is doing right now, for the status corner and the menus.
func koth_status() -> String:
	if _koth.is_empty():
		return ""
	var line: Array = _koth.get("line", [])
	var cap := int(_koth.get("cap", 2))
	var w: Array = _koth.get("wins", [0, 0])
	var p1 := String(line[0].get("name", "?")) if line.size() > 0 else "?"
	var p2 := String(line[1].get("name", "?")) if line.size() > 1 else "?"
	match String(_koth.get("state", "")):
		"waiting":
			return tr("Waiting for an opponent") if ranked else tr("Waiting for a challenger (2 needed)")
		"ready":
			return tr("Ready: press Start Match") if _role == "host" else tr("Waiting for the host to start")
		"next":
			return tr("Next set: %s vs %s in %d") % [p1, p2, int(_koth.get("next_in", 0))]
		"playing":
			return tr("%s %d - %d %s  (first to %d)") % [p1, int(w[0]), int(w[1]), p2, cap]
		"decided":
			return tr("Set over: %s %d - %d %s") % [p1, int(w[0]), int(w[1]), p2]
	return ""


func _koth_line_size() -> int:
	return (_koth.get("line", []) as Array).size()


## Players (they hold a controller port) and spectators (they only watch).
func _playing() -> Array:
	return _players.filter(func(p): return String(p.get("role", "player")) != "spectator")


func _watching() -> Array:
	return _players.filter(func(p): return String(p.get("role", "player")) == "spectator")


func is_spectating() -> bool:
	return kind == "watch"


func is_training() -> bool:
	return kind == "training"


func _player_row(p: Dictionary, spectator := false) -> Control:
	var row := Panel.new()
	row.add_theme_stylebox_override("panel", Style.box(Color(0, 0, 0, 0.25 if not spectator else 0.15), 8))
	row.custom_minimum_size = Vector2(612, 44)
	var slot: int = p.get("gc_slot", -1)
	var badge := Style.panel(Style.GOLD if slot == 1 else (Color("#3fa9f5") if slot == 2 else Style.MUTED), 8)
	Style.place(badge, 6, 6, 52, 32)
	row.add_child(badge)
	var bl := Style.label(tr("SPEC") if spectator else ("P%d" % slot if slot > 0 else "--"), 16 if spectator else 18,
			Style.DARK, 0, Color.BLACK, true)
	bl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	bl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	Style.place(bl, 0, 0, 52, 32)
	badge.add_child(bl)
	var name := String(p.get("name", "?"))
	if p.get("is_host", false):
		name = "★ " + name
	var nl := Style.label(name, 22, Color.WHITE, 3, Style.DARK, true)
	nl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	nl.clip_text = true
	nl.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	Style.place(nl, 70, 0, 250, 44)
	row.add_child(nl)
	var link: Control = LinkIcon.new()
	link.link = String(p.get("link", ""))
	Style.place(link, 350, 9, 26, 26)
	row.add_child(link)
	var ping := int(p.get("ping", 0))
	var jitter := int(p.get("jitter", -1))
	var ping_text := "%d ms" % ping + (" ±%d" % jitter if jitter >= 0 else "")
	if p.get("is_host", false) and _role == "host":
		ping_text = "host"
	var q := String(p.get("quality", "measuring"))
	var pl := Style.label(ping_text, 20, Style.quality_color(q), 3, Style.DARK, true)
	pl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	pl.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	Style.place(pl, 410, 0, 140, 44)
	row.add_child(pl)
	var dot := Style.panel(Style.quality_color(q), 8)
	Style.place(dot, 566, 14, 16, 16)
	row.add_child(dot)
	var status := String(p.get("status", "ok"))
	if status != "ok" and status != "":
		nl.text += "  (" + tr(status.replace("_", " ")) + ")"
	return row


func _action_rows(in_game_menu: bool) -> Array:
	if _phase in ["connecting", "searching"]:
		return [{"type": "action", "key": "leave", "label": "Cancel", "color": "#e8663d"}]
	var host := _role == "host"
	var rows: Array = []
	if in_game_menu:
		rows.append({"type": "action", "key": "resume", "label": "Back to the game"})
	elif host:
		var can_start: bool = _koth_line_size() >= 2 and String(_koth.get("state", "")) in ["ready", "next"] if koth \
				else _playing().size() >= (1 if is_training() else 2)
		var start_row := {"type": "action", "key": "start", "label": "Start Training" if is_training() else "Start Match",
			"color": "#3fbf6b", "disabled": _phase == "playing" or not can_start or _asking or (ranked and _set_done)}
		if ranked and _set_done:
			start_row["desc"] = tr("The ranked set is over: one set per lobby.\nLeave and open a new ranked lobby to play again.")
		rows.append(start_row)
	if not is_training():   # nobody to talk to in a solo session
		rows.append({"type": "text", "key": "chat", "label": "Message", "value": "", "placeholder": tr("Press %s to type") % Pad.prompt("accept")["key"],
			"max_length": 200})
	if not ranked and not is_training() and not is_spectating():
		rows.append({"type": "toggle", "key": "record", "label": "Record matches",
			"value": bool(Settings.get_value("netplay", "record_matches")), "on_text": "On", "off_text": "Off",
			"desc": "Saves your matches here as replays (Replays), from the next match on.\nKept on this PC only: never uploaded."})
	var to_add := _friend_candidates()
	if not to_add.is_empty():
		rows.append({"type": "action", "key": "add_friend", "label": "Add friend",
			"value": "   ·   ".join(to_add) if to_add.size() <= 2 else tr("%d players") % to_add.size(),
			"desc": "Send a friend request to a player in this lobby (their DRAGON NET account)."})
	if host and is_training():
		# The point of the mode: any buffer, changed live (no automatic mode, there's no ping).
		rows.append({"type": "number", "key": "buffer", "label": "Pad buffer", "min": 1, "max": 20, "step": 1,
			"value": _buffer if _buffer > 0 else int(Settings.get_value("netplay", "buffer"))})
	elif host:
		var auto: bool = Settings.get_value("netplay", "buffer_auto")
		rows.append({"type": "choice", "key": "buffer_mode", "label": "Pad buffer mode", "values": [false, true],
			"names": ["Manual", "Automatic"], "value": auto})
		rows.append({"type": "number", "key": "buffer", "label": "Pad buffer", "min": 1, "max": 20, "step": 1,
			"value": _buffer if _buffer > 0 else int(Settings.get_value("netplay", "buffer")), "disabled": auto})
	else:
		rows.append({"type": "info", "key": "buffer", "label": "Pad buffer",
			"value": str(_buffer) if _buffer > 0 else "?"})
	# The game's optional codes ([Sparking.LobbyCodes], e.g. Tenkaichi 2 JP's Ground & Pound fix):
	# off unless the host switches them on, then on for both players. Not during a match.
	if not in_game_menu:
		for i in _codes_available.size():
			var code := String(_codes_available[i])
			var on := code in _codes_on
			if host:
				rows.append({"type": "toggle", "key": "lc:%d" % i, "label": code, "value": on,
					"disabled": _phase == "playing",
					"desc": "Host option: switch it on for both players' games. Off by default."})
			else:
				rows.append({"type": "info", "key": "lc:%d" % i, "label": code,
					"value": tr("On") if on else tr("Off"),
					"desc": "Host option: the host switches it on for both players' games."})
	if not is_spectating() and (in_game_menu or is_training()):
		var setting := Settings.input_display_key(is_training())
		rows.append({"type": "action", "key": "input_display", "label": "Input history",
			"value": "On" if Settings.get_value("options", setting) else "Off",
			"desc": "Your inputs down the side of the game: frames held, direction (dot = neutral), buttons."})
		if is_training():   # nobody else plays the other port (never in online matches)
			var other := Settings.input_display_key(true, true)
			rows.append({"type": "action", "key": "input_display_other", "label": "P2 input history",
				"value": "On" if Settings.get_value("options", other) else "Off",
				"desc": "The other port's inputs down the right side."})
	# Battle Lounge: step down to the back of the line (forfeiting the set if you're fighting).
	if koth and not ranked and not is_spectating() and int(_koth.get("local_pos", -1)) >= 0:
		var fighting: bool = _phase == "playing" and int(_koth.get("local_pos", -1)) < 2
		rows.append({"type": "action", "key": "step_down", "label": "Step down", "color": "#f2b531",
			"desc": "Forfeit this set and go to the back of the line." if fighting else "Go to the back of the line."})
	# A spectator's Stop only ends their own view; the match goes on for the players.
	var stop_label := "Stop Watching" if is_spectating() else ("Stop Training" if is_training() else "Stop Match")
	if ranked:
		stop_label = "Forfeit Match"   # stopping a ranked match is a loss
	elif koth and _role != "host" and int(_koth.get("local_pos", -1)) >= 2:
		stop_label = "Stop Watching"   # waiting in line: only this view stops, the set goes on
	elif koth and _role == "host":
		stop_label = "Stop Set"        # the host referees: pauses the ladder until Start
	if in_game_menu:
		rows.append({"type": "action", "key": "stop", "label": stop_label, "color": "#e8663d"})
	else:
		if host and _room.get("type") == "traversal" and _room.has("code"):
			rows.append({"type": "action", "key": "copy", "label": "Copy room code", "value": String(_room["code"])})
		if _phase == "playing":
			rows.append({"type": "action", "key": "stop", "label": stop_label, "color": "#e8663d"})
		rows.append({"type": "action", "key": "leave", "label": "Leave Lobby", "color": "#e8663d"})
	return rows


func _refresh_actions() -> void:
	if _actions.is_editing():
		return  # don't rebuild under the player's typing
	_actions.set_rows(_action_rows(false))


func _refresh_panel() -> void:
	if not (_panel and is_instance_valid(_panel)):
		_panel = null
		return
	if not _panel.list.is_editing():
		_panel.list.set_rows(_action_rows(true))
	var box: RichTextLabel = _panel.body.get_node("Log")
	box.text = _players_line() + "\n" + "\n".join(_chat.slice(maxi(_chat.size() - 6, 0)))


func _players_line() -> String:
	if koth and not _koth.is_empty():
		var pos := int(_koth.get("local_pos", -1))
		var where := tr("You're on pad %d") % (pos + 1) if pos in [0, 1] else (tr("You're #%d in line") % (pos + 1) if pos >= 2 else "")
		return "[b]%s[/b]    %s" % [_esc(koth_status()), _esc(where)]
	var parts: Array = []
	for p in _players:
		var slot: int = p.get("gc_slot", -1)
		parts.append("[b]%s[/b] %s %d ms" % ["P%d" % slot if slot > 0 else "--", _esc(p.get("name", "?")),
			int(p.get("ping", 0))])
	return "    ".join(parts)


# --- In-game menu ------------------------------------------------------------------------

func make_ingame_panel() -> Control:
	if _phase != "playing":
		return null
	var panel: Control = InGamePanel.new().setup("Training Menu" if is_training() else ("Ranked Match" if ranked else "Match Menu"),
			_action_rows(true), 170, Vector2(560, 560))
	var box := RichTextLabel.new()
	box.name = "Log"
	box.bbcode_enabled = true
	box.scroll_following = true
	box.add_theme_font_size_override("normal_font_size", 17)
	box.add_theme_font_size_override("bold_font_size", 17)
	box.add_theme_stylebox_override("normal", Style.box(Color(0, 0, 0, 0.3), 8))
	Style.place(box, 0, 0, panel.body.size.x, panel.body.size.y)
	panel.body.add_child(box)
	panel.pressed.connect(_on_press)
	panel.value_changed.connect(_on_value)
	_panel = panel
	_refresh_panel()
	return panel


# --- Input -------------------------------------------------------------------------------

func on_input(event: InputEvent) -> bool:
	# Host: LB / RB (keyboard Q / E, not while typing a message) switch the mode.
	if not _actions.is_editing():
		var step := 0
		if event is InputEventJoypadButton and event.pressed:
			if event.button_index == JOY_BUTTON_LEFT_SHOULDER:
				step = -1
			elif event.button_index == JOY_BUTTON_RIGHT_SHOULDER:
				step = 1
		elif event is InputEventKey and event.pressed and not event.echo:
			if event.keycode == KEY_Q:
				step = -1
			elif event.keycode == KEY_E:
				step = 1
		if step != 0 and can_switch_mode():
			_step_mode(step)
			return true
	# Hidden: PgUp + PgDn together switch NEOcode (host).
	if event is InputEventKey and event.pressed and not event.echo \
			and event.keycode in [KEY_PAGEUP, KEY_PAGEDOWN] \
			and Input.is_key_pressed(KEY_PAGEUP) and Input.is_key_pressed(KEY_PAGEDOWN):
		_toggle_neocode()
		return true
	return _actions.handle_input(event)


## NEOcode is Tenkaichi 3's only for now.
func _neocode_allowed() -> bool:
	return bool(Settings.GAMES[Settings.game]["neocode"])


func _toggle_neocode() -> void:
	if _role != "host" or is_training() or not _neocode_allowed():
		return
	if _phase == "playing":
		_system("NEOcode can't be switched during a match.", "#e8663d")
		return
	var on := not _neocode
	Settings.set_value("netplay", "neocode", on)
	Dolphin.send("netcode " + ("neocode" if on else "delay"))


func on_back() -> void:
	# B jumps to Leave/Cancel; B again there leaves.
	if _actions.current_key() == "leave":
		_on_press("leave")
	else:
		_actions.focus_key("leave")


func _on_press(key: String) -> void:
	match key:
		"start":
			if ranked:
				_start_ranked()
			else:
				Dolphin.send("start")
		"add_friend":
			_add_friend_menu()
		"copy":
			DisplayServer.clipboard_set(String(_room.get("code", "")))
			app.toast("Room code copied")
		"stop":
			if ranked and _phase == "playing":
				_report("forfeit", "You forfeited the ranked match.")
			Dolphin.send("stop")
			app.close_ingame_menu(false)
		"resume":
			app.close_ingame_menu()
		"step_down":
			Dolphin.send("step_down")
			if _phase == "playing":
				app.close_ingame_menu()
		"input_display", "input_display_other":
			var setting := Settings.input_display_key(is_training(), key == "input_display_other")
			var on := not bool(Settings.get_value("options", setting))
			Settings.set_value("options", setting, on)
			Dolphin.send(key + " " + ("on" if on else "off"))
			_refresh_actions()
			_refresh_panel()
		"leave":
			if ranked and _phase == "playing":
				_report("forfeit", "You left the ranked match: it counts as a loss.")
			_phase = "closing"
			_status = "Leaving..."
			app.close_ingame_menu(false)
			Dolphin.quit_session()
			_refresh_all()


## Ranked: the server opens the match first (both players checked in), then Dolphin starts it.
func _start_ranked() -> void:
	if _set_done:
		_system("The ranked set is over. To play another, leave the lobby and open (or join) a new ranked lobby.", "#f2b531")
		return
	if ranked_lobby <= 0:
		_system("The ranked lobby isn't listed yet. Try again in a moment.", "#e8663d")
		return
	if _asking:
		return
	# The other player approves first (a pop-up on their screen).
	_asking = true
	var other := _other_player_name()
	_system(tr("Waiting for %s to accept the match...") % other, "#cfe9ee")
	Dolphin.send("ask_start")
	_refresh_actions()
	await get_tree().create_timer(30.0).timeout
	if is_inside_tree() and _asking:
		_asking = false
		_system(tr("%s didn't answer. Press Start Match to ask again.") % other, "#e8663d")
		_refresh_actions()


func _other_player_name() -> String:
	for p in _players:
		if not p.get("is_host", false) and String(p.get("role", "player")) == "player":
			return String(p.get("name", "?"))
	return "?"


## Ranked host: the other player answered.
func _on_start_answered(data: Dictionary) -> void:
	if not _asking:
		return
	_asking = false
	_refresh_actions()
	if not data.get("accepted", false):
		_system(tr("%s declined the match.") % String(data.get("name", "?")), "#e8663d")
		return
	_system(tr("%s accepted. Starting!") % String(data.get("name", "?")), "#3fbf6b")
	var res := await Ranked.api("match.php", {"action": "start", "lobby": ranked_lobby})
	if not is_inside_tree():
		return
	if res.get("ok", false):
		Dolphin.send("start")
	else:
		_system(Ranked.error_text(String(res.get("error", ""))), "#e8663d")


func _on_value(key: String, value: Variant) -> void:
	match key:
		"record":
			var on := bool(value)
			Settings.set_value("netplay", "record_matches", on)
			Dolphin.send("record_replays " + (Settings.local_replay_dir() if on else "off"))
			_system("Recording your matches (kept on this PC only)." if on else "Not recording matches.", "#cfe9ee")
		"chat":
			var text := String(value).strip_edges()
			if text != "":
				Dolphin.send("chat " + text)
			# Clear the field once the edit has finished.
			_clear_chat_fields.call_deferred()
		"buffer":
			Settings.set_value("netplay", "buffer", int(value))
			Dolphin.send("buffer %d" % int(value))
		_ when key.begins_with("lc:"):
			var code := String(_codes_available[int(key.substr(3))])
			var on: Array = _codes_on.duplicate()
			on.erase(code)
			if value:
				on.push_front(code)   # first: Dolphin keeps it over another of its exclusive group
			Dolphin.send("codes " + ("|".join(on) if not on.is_empty() else "none"))
		"buffer_mode":
			Settings.set_value("netplay", "buffer_auto", bool(value))
			_send_buffer_mode()
			_actions.update_row("buffer", {"disabled": bool(value)})
			_refresh_panel()


## Host: automatic ("buffer auto": Dolphin picks it at the start and after each KO) or the number.
func _send_buffer_mode() -> void:
	if Settings.get_value("netplay", "buffer_auto") and not is_training():
		Dolphin.send("buffer auto")
	else:
		Dolphin.send("buffer %d" % int(Settings.get_value("netplay", "buffer")))


func _clear_chat_fields() -> void:
	_actions.update_row("chat", {"value": ""})
	if _panel and is_instance_valid(_panel):
		_panel.list.update_row("chat", {"value": ""})


# --- Dolphin events ----------------------------------------------------------------------

func _esc(s: Variant) -> String:
	return String(s).replace("[", "[lb]")


func _system(text: String, color := "#cfe9ee") -> void:
	_add_chat("[color=%s]%s[/color]" % [color, _esc(tr(text))])


func _add_chat(line: String) -> void:
	_chat.append(line)
	if _chat.size() > 200:
		_chat = _chat.slice(_chat.size() - 200)
	_chat_log.append_text(line + "\n")
	_refresh_panel()


func _on_event(name: String, data: Dictionary) -> void:
	match name:
		"replay_saved":
			_on_replay_saved(data)
		"start_asked":
			_on_start_asked(String(data.get("from", "?")))
		"start_answered":
			_on_start_answered(data)
		"koth_step_down":
			_system(tr("%s stepped down to the back of the line.") % String(data.get("name", "?")), "#f2b531")
		"lobby_opening":
			if _phase != "searching":
				_status = "Connecting..."
		"matchmaking":
			_on_matchmaking(data)
		"koth":
			_koth = data
			# Ranked: the deciding KO. Each player reports from their own side.
			if ranked and String(data.get("state", "")) == "decided":
				var pos := int(data.get("local_pos", -1))
				var w: Array = data.get("wins", [0, 0])
				if pos in [0, 1]:
					_report("win" if int(w[pos]) >= int(data.get("cap", 2)) else "loss")
			if not koth:
				koth = true   # joined by code / Discord: the lounge's title, music and background
				app.refresh_chrome()
			if _phase in ["lobby", "playing"]:
				var st := koth_status()
				if st != "":
					_status = st
		"koth_set":
			var kw: Array = data.get("wins", [0, 0])
			if ranked:
				_system(tr("%s wins the ranked match %d-%d!") % [data.get("winner", "?"), int(kw[0]), int(kw[1])], "#f2b531")
			else:
				_system(tr("%s wins the set %d-%d! %s goes to the back of the line.") % [data.get("winner", "?"),
						int(kw[0]), int(kw[1]), data.get("loser", "?")], "#f2b531")
			if int(data.get("streak", 0)) >= 2 and not ranked:
				_system(tr("%s: %d sets in a row.") % [data.get("winner", "?"), int(data.get("streak", 0))], "#f2b531")
		"koth_waiting":
			_koth_waiting = true
			_status = "A set is being played: you'll get in line as soon as it ends..."
		"lobby_ready":
			_koth_waiting = false
			_role = String(data.get("role", "client"))
			_phase = "lobby"
			_players = []
			_status = "Waiting for players..." if _role == "host" else "Waiting for the host to start"
			if is_training():
				_status = "Loading Training Mode..."
			if _role == "host":
				_buffer = int(Settings.get_value("netplay", "buffer"))
				_send_buffer_mode()
				if Settings.get_value("netplay", "neocode") and not is_training() and _neocode_allowed():
					Dolphin.send("netcode neocode")
			if is_training():
				_system("Buffer Training: change the pad buffer here or from the menu (hold Select) while you play.")
			elif is_spectating():
				_system("You're watching: spectators can't play, only chat.")
			else:
				_system("Lobby open." if _role == "host" else "Joined the lobby.")
		"room":
			_room = data
			if data.has("mode") and String(data["mode"]) != "":
				mode = String(data["mode"])
				app.set_title(screen_title())
		"lobby_mode":
			_on_lobby_mode(String(data.get("mode", "")))
		"public":
			_public = data
			if data.has("error"):
				_system(tr("Couldn't list the lobby publicly (%s).") % data["error"], "#e8663d")
		"players":
			_players = data.get("players", [])
			_announce_friends()
			_maybe_auto_start()
			if _phase == "lobby":
				if is_training():
					_status = "Ready" if _auto_started else "Loading Training Mode..."
				elif koth and not _koth.is_empty():
					_status = koth_status()
				elif _role == "host":
					_status = "Ready to start" if _playing().size() >= 2 else "Waiting for players..."
		"player_joined":
			Sfx.play("player_join")
			_system(tr("%s joined.") % data.get("name", "?"))
		"player_left":
			Sfx.play("player_leave")
			if ranked and _phase == "playing":
				_report("win", "Your opponent left the ranked match: it counts as your win.")
			_system(tr("%s left.") % data.get("name", "?"))
		"chat":
			if data.get("self", false):
				_add_chat("[color=#f2b531][b]%s:[/b][/color] %s" % [_esc(data.get("from", "You")), _esc(data.get("text", ""))])
			else:
				# Dolphin sends "Name[pid]: text" for players, plain text for its own notices.
				var text := String(data.get("text", ""))
				var m := RegEx.create_from_string("^(.+?)\\[\\d+\\]: (.*)$").search(text)
				if m:
					Sfx.play("message")
					_add_chat("[color=#7fd0ff][b]%s:[/b][/color] %s" % [_esc(m.get_string(1)), _esc(m.get_string(2))])
				else:
					_system(text)
		"buffer_mode":
			_system(tr("Pad buffer: automatic (set at the start and after each KO).") if data.get("auto", false)
					else tr("Pad buffer: manual."))
		"buffer_auto":
			if data.has("skipped"):
				_system(tr("Automatic pad buffer: still measuring the ping, kept %d.") % _buffer)
			else:
				var to := int(data.get("to", _buffer))
				var why: String = tr("ping %d ms ± %d") % [int(data.get("ping", 0)), int(data.get("jitter", 0))]
				if data.get("reason", "") == "match_start":
					_system(tr("Automatic pad buffer: %d (%s).") % [to, why])
				else:
					_system(tr("Pad buffer %d → %d after the KO (%s).") % [int(data.get("from", _buffer)), to, why])
				_logged_buffer = to   # the buffer_changed that follows isn't news
		"buffer_changed":
			var b := int(data.get("buffer", _buffer))
			if b != _logged_buffer:
				_system(tr("Pad buffer: %d") % b)
				_logged_buffer = b
			_buffer = b
		"battle_state":
			_battle = data
			_maybe_auto_start()
		"lobby_codes":
			var was: Array = _codes_on
			_codes_available = data.get("available", [])
			_codes_on = data.get("on", [])
			for code in _codes_on:
				if not code in was:
					_system(tr("%s: on for this lobby's matches.") % code, "#9be7ff")
			for code in was:
				if not code in _codes_on and code in _codes_available:
					_system(tr("%s: off.") % code, "#9be7ff")
			_refresh_actions()
		"game_starting":
			_reported = false
			_status = "Match starting..."
			_system("Training starting..." if is_training() else "Match starting...")
		"sync_begin":
			_status = "Syncing save data..."
		"game_started":
			_phase = "playing"
			_neo_out_of_sync = false
			_status = "Watching the match (hold Select for the menu)" if is_spectating() \
					else ("Training (hold Select to change the pad buffer)" if is_training()
					else "Match in progress (hold Select for the menu)")
		"game_stopped", "game_start_aborted":
			if _phase == "playing" or _phase == "lobby":
				_phase = "lobby"
				_status = "Back in the lobby"
				_system("Training stopped." if is_training() else "Match ended.")
		"round_result":
			var wins: Dictionary = data.get("wins", {})
			var parts: Array = []
			for n in wins:
				parts.append("%s %d" % [n, int(wins[n])])
			_system(tr("Round %d: %s wins.  (%s)") % [int(data.get("round", 0)), data.get("winner", "?"), " - ".join(parts)], "#f2b531")
		"desync":
			_system(tr("Desync detected at frame %s.") % str(data.get("frame", "?")), "#e8663d")
		"netcode":
			var on := String(data.get("mode", "")) == "neocode"
			if on != _neocode:
				_neocode = on
				_system("NEOcode on." if on else "NEOcode off.", "#9be7ff")
			_refresh_info()
		"neocode":
			match String(data.get("state", "")):
				"on":
					_neo_r = int(data.get("r", 0))
				"failed":
					_neo_r = -1
					_system(tr("NEOcode stopped (%s): the match goes on with the normal netcode.") % String(data.get("reason", "?")), "#e8663d")
				"off":
					_neo_r = -1
			_refresh_info()
		"neocode_check":
			if not data.get("match", true) and not _neo_out_of_sync:
				_neo_out_of_sync = true
				_system("NEOcode: the players' games are out of sync.", "#e8663d")
		"connection_lost":
			_system("Connection lost.", "#e8663d")
			app.toast("Connection lost")
		"error":
			var code := String(data.get("code", "error"))
			# Battle Lounge: refused because a set is on. Dolphin retries; nothing to report.
			if code == "game_running" or (_koth_waiting and code == "connect_failed"):
				return
			# Buffer Training's own start, a moment before Dolphin finished checking the save /
			# battle state (solo: nobody else's to mismatch): try again shortly, quietly.
			if is_training() and _auto_started and _phase == "lobby" and _auto_retries < 20 \
					and code in ["save_data_mismatch", "battle_state_not_ready"]:
				_auto_retries += 1
				get_tree().create_timer(0.5).timeout.connect(func():
					if is_inside_tree() and _phase == "lobby":
						Dolphin.send("start"))
				return
			var msg: String = ERRORS.get(code, code.replace("_", " "))
			if data.has("reason"):
				msg += " (%s)" % data["reason"]
			elif data.has("message"):
				msg += " (%s)" % data["message"]
			_system(msg, "#e8663d")
			if _phase in ["connecting", "searching"]:
				_status = msg
			if code in ["lobby_full", "spectators_full", "ranked_no_spectators"]:
				_closed_because = msg   # turned away: say why instead of "The lobby closed."
		"process_exited":
			if _closed_because != "":
				app.toast(_closed_because, 5.0)
			elif _phase != "closing":
				app.toast("The lobby closed.")
			app.pop_to(func(s): return s != self)
			return
		_:
			return
	_refresh_all()


## Buffer Training goes straight in once the training state is checked: either the battle state
## event says ready, or the player list shows the host's own check came back ok after it.
func _maybe_auto_start() -> void:
	if not is_training() or _auto_started or _phase != "lobby" or not _battle.get("active", false):
		return
	var checked: bool = _battle.get("ready", false) or (not _players.is_empty()
			and _players.all(func(p): return String(p.get("state_status", "")) == "ok"))
	if checked:
		_auto_started = true
		Dolphin.send("start")


func _on_matchmaking(d: Dictionary) -> void:
	var m := Style.mode_name(String(d.get("mode", mode)))
	match String(d.get("state", "")):
		"searching":
			_phase = "searching"
			_status = tr("Looking for a %s lobby...") % m
		"candidates":
			_status = tr("Found %d open lobbies...") % int(d.get("count", 0)) if int(d.get("count", 0)) > 0 else "No open lobby found..."
		"joining":
			_phase = "searching"
			_status = tr("Joining %s (%s, %s)...") % [d.get("host", "?"), d.get("region", "?"), Style.link_name(d.get("link", ""))]
		"retry":
			_phase = "searching"
			_status = "That lobby didn't work out. Trying the next..."
			_players = []
			_role = ""
			_room = {}
		"hosting":
			_status = tr("No open lobby: hosting a public %s lobby.\nWaiting for an opponent...") % m
			_system(tr("Hosting a public %s lobby; others searching will find it.") % m)
		"matched":
			_status = "Opponent found!"
			_system(tr("Opponent found! You're P%d.") % int(d.get("port", 0)), "#3fbf6b")
		"cancelled":
			_status = "Search cancelled"
		"lobby_server_unreachable":
			_status = "Lobby server unreachable. Try again later, or Host / join by code."
			_system(_status, "#e8663d")
