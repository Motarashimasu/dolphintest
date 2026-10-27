extends Node
## Quick Match (DRAGON NET > Quick Match): search the pool for a Single Battle opponent. While
## searching the player can be in Buffer Training (the normal session). Once the server pairs two
## players (Server/ranked/quick.php), a second Dolphin (a helper) connects them in a private room:
## the host (picked at random, pad 1) opens it and posts its code, the guest joins. With the real
## ping and connection in hand, both get a pop-up: Accept / Decline. Both accept: Buffer Training
## closes, each says it's ready, the helper becomes the session (Dolphin.adopt_helper) and the
## lobby screen opens on it; the host starts the Single Battle. One declines, can't connect or
## doesn't answer: the other is told, both are searching again (not paired with each other again
## for a few minutes).

signal changed

const LobbyScreen := preload("res://scripts/screens/lobby.gd")
const Style := preload("res://scripts/ui/style.gd")
const POLL := 2.0                 # s between status polls
const MEASURE_WAIT := 5000        # ms at most to wait for a measured ping before asking

## idle, searching, connecting (paired: the room is being set up), asking (the pop-up is up),
## waiting (you accepted, the other hasn't yet), starting (both accepted), playing (the lobby
## screen has it), failed (couldn't reach the server)
var state := "idle"
var since := 0                    # unix time the search started (server's)
var searching := 0                # players searching right now (server's count)
var opponent := {}                # {name, link, region} from the server; ping / link from Dolphin
var error := ""
var match_id := 0
var role := ""                    # host / guest

var _poll_at := 0.0
var _busy := false
var _helper: Object = null
var _helper_match := 0
var _room := {}                   # the helper's last "room" event (host)
var _players: Array = []          # the helper's last "players" event
var _opp_seen_at := 0
var _menu: Control = null         # the Accept / Decline pop-up
var _seen_ended := 0              # the last called-off pair already reported
var _answered := false


func app() -> Node:
	return get_tree().root.get_node_or_null("Main")


func active() -> bool:
	return state != "idle" and state != "playing"


## Starts searching (needs the DRAGON NET login; Main checks it first).
func start() -> void:
	if active():
		return
	_reset_pair()
	state = "searching"
	error = ""
	since = int(Time.get_unix_time_from_system())
	changed.emit()
	await _search()


## Stops searching (and calls off a pair not agreed yet).
func stop() -> void:
	if state == "idle":
		return
	var was := state
	state = "idle"
	_close_menu()
	if was != "playing":
		_stop_helper()
		Ranked.api("quick.php", {"action": "leave"})
	changed.emit()


## The lobby screen of the Quick Match was left: back to idle (the player can search again).
func match_over() -> void:
	if state == "playing":
		state = "idle"
		_helper = null
		changed.emit()


func _search() -> void:
	_busy = true
	var res: Dictionary = await Ranked.api("quick.php", {"action": "search", "game": Settings.game,
		"version": String(Settings.GAME["id"]), "region": Settings.get_value("player", "region"),
		"link": "unknown"})
	_busy = false
	_on_status(res)


func _process(delta: float) -> void:
	if not active() or _busy:
		return
	_poll_at -= delta
	if _poll_at > 0.0:
		return
	_poll_at = POLL
	_busy = true
	var res: Dictionary = await Ranked.api("quick.php", {"action": "status"})
	_busy = false
	if active():
		_on_status(res)


func _on_status(res: Dictionary) -> void:
	if not res.get("ok", false):
		if String(res.get("error", "")) in ["unreachable", "bad_response", "database_error"]:
			error = Ranked.error_text(String(res.get("error", "")))
			changed.emit()
			return   # (tried again at the next poll)
		error = Ranked.error_text(String(res.get("error", "")))
		state = "failed"
		_stop_helper()
		_close_menu()
		changed.emit()
		return
	error = ""
	searching = int(res.get("searching", 0))
	if res.has("since"):
		since = int(res["since"])
	var ended: Dictionary = res.get("ended", {})
	if not ended.is_empty() and int(ended.get("id", 0)) != _seen_ended and int(ended.get("id", 0)) == match_id:
		_seen_ended = int(ended["id"])
		_called_off(ended)
	if String(res.get("state", "")) == "idle":
		await _search()   # (dropped from the pool, e.g. after a long hitch: back in)
		return
	var m: Dictionary = res.get("match", {})
	if m.is_empty():
		if state != "searching":
			_reset_pair()
			state = "searching"
		changed.emit()
		return
	_on_match(m)
	changed.emit()


## The server's view of our pair.
func _on_match(m: Dictionary) -> void:
	if int(m["id"]) != match_id:
		_reset_pair()
		match_id = int(m["id"])
		role = String(m.get("role", "guest"))
		opponent = m.get("opponent", {})
		state = "connecting"
		Sfx.play("player_join")
	match String(m.get("state", "")):
		"pairing":
			if _helper == null and _helper_match != match_id:
				if role == "host":
					_start_helper(Settings.quick_host_args())
				elif String(m.get("room", "") if m.get("room") != null else "") != "":
					_start_helper(Settings.quick_join_args(String(m["room"])))
		"go":
			if state in ["connecting", "asking", "waiting"]:
				_close_menu()
				state = "starting"
				_get_ready()
			elif state == "starting" and role == "host" and m.get("you_ready", false) and m.get("they_ready", false):
				_play()   # (the guest's lobby is already up: it took over as soon as it was ready)


func _called_off(ended: Dictionary) -> void:
	var name := String(opponent.get("name", "?"))
	var msg := ""
	match String(ended.get("state", "")):
		"declined":
			msg = tr("You declined the match. Still searching...") if ended.get("by_you", false) \
					else tr("%s declined the match. Still searching...") % name
		"left":
			msg = tr("%s stopped searching. Still searching...") % name
		"expired":
			msg = tr("The match wasn't accepted in time. Still searching...") if not ended.get("by_you", false) \
					else tr("You didn't answer in time. Still searching...")
		_:
			msg = tr("Couldn't connect to %s. Still searching...") % name
	_close_menu()
	_stop_helper()
	_reset_pair()
	state = "searching"
	if app():
		app().toast(msg, 4.0)


func _reset_pair() -> void:
	match_id = 0
	role = ""
	opponent = {}
	_room = {}
	_players = []
	_opp_seen_at = 0
	_answered = false
	_helper_match = 0


# --- The connection (helper Dolphin) ------------------------------------------------------

func _start_helper(args: PackedStringArray) -> void:
	_helper_match = match_id
	load("res://scripts/controllers.gd").apply_selected()   # (the match boots in this process)
	_helper = Dolphin.start_helper(args, _on_helper_event.bind(match_id))
	if _helper == null:
		Ranked.api("quick.php", {"action": "fail", "match": match_id, "reason": "no_dolphin"})


func _stop_helper() -> void:
	if _helper:
		Dolphin.stop_helper(_helper)
	_helper = null


func _on_helper_event(e: Dictionary, for_match: int) -> void:
	if for_match != match_id or state == "playing":
		return
	match String(e.get("event", "")):
		"room":
			_room = e
			if role == "host" and String(e.get("state", "")) == "ready":
				var target := String(e.get("code", ""))
				if String(e.get("type", "")) == "direct":   # (tests: no room code server)
					target = "127.0.0.1:%d" % int(e.get("port", Settings.QUICK_PORT))
				Ranked.api("quick.php", {"action": "room", "match": match_id, "room": target})
			elif String(e.get("state", "")) == "failed":
				Ranked.api("quick.php", {"action": "fail", "match": match_id, "reason": "room_code_server"})
		"players":
			_players = e.get("players", [])
			var o := _opponent_entry()
			if not o.is_empty():
				if _opp_seen_at == 0:
					_opp_seen_at = Time.get_ticks_msec()
				var measured := String(o.get("quality", "measuring")) != "measuring"
				if state == "connecting" and (measured or Time.get_ticks_msec() - _opp_seen_at > MEASURE_WAIT):
					_ask()
				elif state == "asking":
					_refresh_menu()
		"error":
			var code := String(e.get("code", ""))
			if code in ["connect_failed", "traversal_error", "connection_error", "listen_failed", "lobby_full", "bad_address"]:
				Ranked.api("quick.php", {"action": "fail", "match": match_id, "reason": code})
		"process_exited":
			if state in ["connecting", "asking", "waiting", "starting"]:
				_helper = null
				Ranked.api("quick.php", {"action": "fail", "match": match_id, "reason": "dolphin_exited"})
		"connection_lost":
			if state in ["connecting", "asking", "waiting", "starting"]:
				Ranked.api("quick.php", {"action": "fail", "match": match_id, "reason": "connection_lost"})


## The other player in the room: the host for the guest, the other player for the host.
func _opponent_entry() -> Dictionary:
	for p in _players:
		if role == "guest" and p.get("is_host", false):
			return p
		if role == "host" and not p.get("is_host", false) and String(p.get("role", "player")) == "player":
			return p
	return {}


func opponent_ping() -> String:
	var o := _opponent_entry()
	if o.is_empty():
		return "?"
	# Same as the lobby's: "42 ms ±3" (± the jitter, once measured).
	var t := "%d ms" % int(o.get("ping", 0))
	if int(o.get("jitter", -1)) >= 0:
		t += " ±%d" % int(o.get("jitter", -1))
	return t


func opponent_link() -> String:
	var o := _opponent_entry()
	return Style.link_name(String(o.get("link", opponent.get("link", "unknown"))))


# --- The question --------------------------------------------------------------------------

func _ask() -> void:
	state = "asking"
	changed.emit()
	var a := app()
	if a == null:
		return
	Sfx.play("player_join")
	var name := String(opponent.get("name", "?"))
	_menu = a.menu(tr("Match found: %s") % name, [
		{"label": "Accept", "glyph": "A", "color": "#3fbf6b", "desc": func(): return _menu_desc(),
			"action": func(): _answer(true)},
		{"label": "Decline", "glyph": "D", "color": "#e8663d", "desc": func(): return _menu_desc(),
			"action": func(): _answer(false)},
	], "netplay")
	_menu.notices = false
	# Backed out of it (B) without answering: that's a decline.
	var m := _menu
	_menu.tree_exiting.connect(func():
		if _menu == m and not _answered and state == "asking":
			_answer(false, false))
	if a.is_ingame_menu_open():
		a.close_ingame_menu(false)
	a.push(_menu)
	a.show_window()


func _menu_desc() -> String:
	return tr("Single Battle against %s.\nPing: %s    Connection: %s") % [String(opponent.get("name", "?")),
		opponent_ping(), opponent_link()]


func _refresh_menu() -> void:
	var a := app()
	if a and _menu and is_instance_valid(_menu) and a.top() == _menu:
		a.set_desc(_menu_desc())


func _answer(yes: bool, pop := true) -> void:
	if _answered:
		return
	_answered = true
	var m := _menu
	_menu = null
	var a := app()
	if pop and a and m and is_instance_valid(m) and a.top() == m:
		a.pop()
	if yes:
		state = "waiting"
		changed.emit()
		Ranked.api("quick.php", {"action": "answer", "match": match_id, "accept": true})
	else:
		Ranked.api("quick.php", {"action": "answer", "match": match_id, "accept": false})


func _close_menu() -> void:
	var a := app()
	var m := _menu
	_menu = null
	if a and m and is_instance_valid(m) and a.top() == m:
		_answered = true   # (not a decline: it went away)
		a.pop()


# --- Both accepted ---------------------------------------------------------------------------

## Buffer Training closes (the match needs the game), then the server is told we're ready.
func _get_ready() -> void:
	var id := match_id
	if Dolphin.is_running():
		# (Buffer Training's screen: it's closing on purpose, not "The lobby closed.")
		var a := app()
		if a:
			for s in a._stack:
				if s.get("kind") == "training":
					s._phase = "closing"
		Dolphin.quit_session(3000)
		while Dolphin.is_running():
			await get_tree().process_frame
	if match_id != id or state != "starting":
		return
	var res: Dictionary = await Ranked.api("quick.php", {"action": "ready", "match": match_id})
	# The guest's lobby screen takes over now, so it's there before the host can start.
	if role == "guest" and match_id == id and state == "starting" and res.get("ok", false):
		_play()


## The connection becomes the session and the lobby screen takes it over (the guest as soon as
## it's ready; the host once both are, and it then starts the match).
func _play() -> void:
	var a := app()
	if a == null or not Dolphin.adopt_helper(_helper):
		Ranked.api("quick.php", {"action": "fail", "match": match_id, "reason": "adopt"})
		return
	state = "playing"
	Ranked.api("quick.php", {"action": "leave"})   # (off the pool; the agreed match stands)
	var lobby: Control = LobbyScreen.new()
	lobby.setup("quick", PackedStringArray(), "single")
	lobby.adopt(role, _room, _players)
	a.push(lobby)
	changed.emit()
