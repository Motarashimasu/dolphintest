extends "res://scripts/screens/screen.gd"
## The netplay lobby, for hosting, joining and matchmaking ("find") alike: room info, players
## (slot, ping ± jitter, wired/Wi-Fi, quality), messages, pad buffer, Start (host), Leave.
## While the match runs, a held Select opens the small in-game version: messages, buffer and
## "Stop Match" (ends the match for everyone, back to this lobby).
## kind "training" is Buffer Training: a solo, unlisted lobby that boots straight into the training
## state, so the player can feel a pad buffer of their choice (set live, also from the menu).

const OptionList := preload("res://scripts/ui/option_list.gd")
const InGamePanel := preload("res://scripts/ui/ingame_panel.gd")
const LinkIcon := preload("res://scripts/ui/link_icon.gd")

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
var _chat: PackedStringArray = []
var _battle := {}
var _logged_buffer := -1
var _auto_started := false    # Buffer Training starts itself once the state is ready

var _info: Label
var _info_right: Label
var _players_box: VBoxContainer
var _players_status: Label
var _actions: Control
var _chat_log: RichTextLabel
var _panel: Control           # in-game menu, while open


func setup(p_kind: String, args: PackedStringArray, p_mode: String) -> Node:
	kind = p_kind
	_args = args
	mode = p_mode
	return self


func screen_fade() -> String:
	return "lobby"


func screen_music() -> String:
	return "lobby"


func screen_title() -> String:
	if is_spectating():
		return tr("Watching: %s") % (tr("Lobby") if mode == "any" else Style.mode_name(mode))
	return "Lobby" if mode == "any" else Style.mode_name(mode)


func on_enter() -> void:
	show_desc_bar = false
	_build()
	Dolphin.event.connect(_on_event)
	_phase = "searching" if kind == "find" else "connecting"
	_status = tr("Looking for a %s lobby...") % Style.mode_name(mode) if kind == "find" else "Connecting..."
	if not Dolphin.launch(_args):
		app.toast("Couldn't start Dolphin-Sparking (is the Dolphin folder next to the launcher?).")
		app.pop.call_deferred()
		return
	_refresh_all()


func _exit_tree() -> void:
	if Dolphin.event.is_connected(_on_event):
		Dolphin.event.disconnect(_on_event)


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

	var cp := Style.skin_panel(14)
	Style.place(cp, 700, 180, 540, 520)
	add_child(cp)
	var ch := Style.label("Messages", 24, Style.GOLD, 3, Style.DARK, true)
	Style.place(ch, 18, 8, 300, 34)
	cp.add_child(ch)
	_chat_log = RichTextLabel.new()
	_chat_log.bbcode_enabled = true
	_chat_log.scroll_following = true
	_chat_log.add_theme_font_override("normal_font", Style.body_font())
	_chat_log.add_theme_font_size_override("normal_font_size", 19)
	_chat_log.add_theme_font_size_override("bold_font_size", 19)
	Style.place(_chat_log, 18, 48, 504, 456)
	cp.add_child(_chat_log)


func _refresh_all() -> void:
	_refresh_info()
	_refresh_players()
	_refresh_actions()
	_refresh_panel()


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
	var right: Array = [Style.mode_name(mode)]
	if is_training():
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
		rows.append({"type": "action", "key": "start", "label": "Start Training" if is_training() else "Start Match",
			"color": "#3fbf6b", "disabled": _phase == "playing" or _playing().size() < (1 if is_training() else 2)})
	if not is_training():   # nobody to talk to in a solo session
		rows.append({"type": "text", "key": "chat", "label": "Message", "value": "", "placeholder": tr("Press %s to type") % Pad.prompt("accept")["key"],
			"max_length": 200})
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
	# A spectator's Stop only ends their own view; the match goes on for the players.
	var stop_label := "Stop Watching" if is_spectating() else ("Stop Training" if is_training() else "Stop Match")
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
	var panel: Control = InGamePanel.new().setup("Training Menu" if is_training() else "Match Menu",
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
	return _actions.handle_input(event)


func on_back() -> void:
	# B jumps to Leave/Cancel; B again there leaves.
	if _actions.current_key() == "leave":
		_on_press("leave")
	else:
		_actions.focus_key("leave")


func _on_press(key: String) -> void:
	match key:
		"start":
			Dolphin.send("start")
		"copy":
			DisplayServer.clipboard_set(String(_room.get("code", "")))
			app.toast("Room code copied")
		"stop":
			Dolphin.send("stop")
			app.close_ingame_menu(false)
		"resume":
			app.close_ingame_menu()
		"leave":
			_phase = "closing"
			_status = "Leaving..."
			app.close_ingame_menu(false)
			Dolphin.quit_session()
			_refresh_all()


func _on_value(key: String, value: Variant) -> void:
	match key:
		"chat":
			var text := String(value).strip_edges()
			if text != "":
				Dolphin.send("chat " + text)
			# Clear the field once the edit has finished.
			_clear_chat_fields.call_deferred()
		"buffer":
			Settings.set_value("netplay", "buffer", int(value))
			Dolphin.send("buffer %d" % int(value))
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
		"lobby_opening":
			if _phase != "searching":
				_status = "Connecting..."
		"matchmaking":
			_on_matchmaking(data)
		"lobby_ready":
			_role = String(data.get("role", "client"))
			_phase = "lobby"
			_players = []
			_status = "Waiting for players..." if _role == "host" else "Waiting for the host to start"
			if is_training():
				_status = "Loading Training Mode..."
			if _role == "host":
				_buffer = int(Settings.get_value("netplay", "buffer"))
				_send_buffer_mode()
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
		"public":
			_public = data
			if data.has("error"):
				_system(tr("Couldn't list the lobby publicly (%s).") % data["error"], "#e8663d")
		"players":
			_players = data.get("players", [])
			if _phase == "lobby":
				if is_training():
					_status = "Ready" if _auto_started else "Loading Training Mode..."
				elif _role == "host":
					_status = "Ready to start" if _playing().size() >= 2 else "Waiting for players..."
		"player_joined":
			Sfx.play("player_join")
			_system(tr("%s joined.") % data.get("name", "?"))
		"player_left":
			Sfx.play("player_leave")
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
			# Buffer Training goes straight in once the training state is checked.
			if is_training() and not _auto_started and _phase == "lobby" and data.get("active", false) \
					and data.get("ready", false):
				_auto_started = true
				Dolphin.send("start")
		"game_starting":
			_status = "Match starting..."
			_system("Training starting..." if is_training() else "Match starting...")
		"sync_begin":
			_status = "Syncing save data..."
		"game_started":
			_phase = "playing"
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
		"connection_lost":
			_system("Connection lost.", "#e8663d")
			app.toast("Connection lost")
		"error":
			var code := String(data.get("code", "error"))
			var msg: String = ERRORS.get(code, code.replace("_", " "))
			if data.has("reason"):
				msg += " (%s)" % data["reason"]
			elif data.has("message"):
				msg += " (%s)" % data["message"]
			_system(msg, "#e8663d")
			if _phase in ["connecting", "searching"]:
				_status = msg
			if code in ["lobby_full", "spectators_full"]:
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
