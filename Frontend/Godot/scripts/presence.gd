extends Node
## Discord Rich Presence: what the player is doing, on their Discord profile.
##
## Runs Dolphin-Sparking's presence helper (`--discord-presence <app id>`, see Docs/SPARKING.md),
## which talks to the Discord app on this PC. The application ID and image names are in
## res://data/discord.json. Nothing happens without Discord running, and Options > Discord status
## turns it off.
##
## Shows:
##  - menus:    "In the menus"            (time in the launcher)
##  - offline:  "Playing offline"         (time in the game)
##  - lobby:    "Single Battle lobby", "Waiting for players (1 of 2)"
##  - match:    "Single Battle", "vs <opponent>"   (time in the match)
## A public lobby you host also gets Discord's "Ask to Join" button: friends who press it join
## your lobby straight from Discord (requests are accepted automatically, the lobby is public
## anyway). Private lobbies never show a way in.

const Style := preload("res://scripts/ui/style.gd")

signal joined_from_discord(target: String, koth: bool)

const CONFIG := "res://data/discord.json"
const UPDATE_EVERY := 1.0
const RETRY_EVERY := 15.0
const JOIN_PREFIX := "spk1:"
const KOTH_JOIN_PREFIX := "spk1k:"   # a Battle Lounge lobby: joining waits out a running set

var connected := false      # the Discord app accepted us
var discord_user := ""      # "name" once connected

var _config := {}
var _helper: Object = null
var _retry := 0.0
var _tick := 0.0
var _sent := ""             # last presence line sent (to skip repeats)
var _phase_key := ""        # what the elapsed timer belongs to
var _phase_start := 0


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	var data = JSON.parse_string(FileAccess.get_file_as_string(CONFIG))
	_config = data if data is Dictionary else {}


func enabled() -> bool:
	return String(_config.get("app_id", "")) != "" and bool(Settings.get_value("options", "discord"))


func _process(delta: float) -> void:
	if not enabled():
		if _helper:
			stop()
		return
	if _helper == null:
		_retry -= delta
		if _retry <= 0.0:
			_retry = RETRY_EVERY
			_start()
		return
	_tick -= delta
	if _tick <= 0.0:
		_tick = UPDATE_EVERY
		_update()


func _start() -> void:
	if Settings.dolphin_path() == "" or not FileAccess.file_exists(Settings.dolphin_path()):
		return
	_helper = Dolphin.start_helper(PackedStringArray(["--discord-presence", String(_config["app_id"])]),
			_on_event)
	_sent = ""


## Turns presence off (Options) or before quitting.
func stop() -> void:
	if _helper:
		var h := _helper
		_helper = null
		connected = false
		Dolphin.stop_helper(h)


func _on_event(data: Dictionary) -> void:
	match String(data.get("event", "")):
		"connected":
			connected = true
			discord_user = String(data.get("username", ""))
			_sent = ""   # Discord (re)started: send the presence again
		"disconnected":
			connected = false
		"join":
			var secret := String(data.get("secret", ""))
			if secret.begins_with(KOTH_JOIN_PREFIX):
				joined_from_discord.emit(secret.substr(KOTH_JOIN_PREFIX.length()), true)
			elif secret.begins_with(JOIN_PREFIX):
				joined_from_discord.emit(secret.substr(JOIN_PREFIX.length()), false)
		"join_request":
			# Only public lobbies offer "Ask to Join", so let them in.
			Dolphin.helper_send(_helper, "respond %s yes" % String(data.get("user_id", "")))
			var app := _app()
			if app and app.has_method("toast"):
				app.toast(tr("%s is joining from Discord.") % String(data.get("username", "Someone")))
		"process_exited":
			_helper = null
			connected = false
			_retry = RETRY_EVERY


func _app() -> Node:
	return get_tree().current_scene


func _lobby() -> Node:
	var app := _app()
	if app == null or not "_stack" in app:
		return null
	for s in app._stack:
		if s.has_method("make_ingame_panel") and "_phase" in s:
			return s
	return null


## What to show right now, as the helper's presence JSON.
func current() -> Dictionary:
	var p := {
		"large_image": _config.get("large_image", ""),
		"large_text": _config.get("large_text", ""),
		"small_image": _config.get("small_image", ""),
		"small_text": _config.get("small_text", ""),
	}
	var key := "menus"
	var lobby := _lobby()
	if lobby:
		var mode_name: String = Style.mode_name(String(lobby.mode))
		# Only the two fighters count (spectators are listed separately).
		var players: Array = lobby._playing() if lobby.has_method("_playing") else lobby._players
		var count := maxi(players.size(), 1)
		var training: bool = lobby.has_method("is_training") and lobby.is_training()
		if training:
			# Solo: no party, no Ask to Join.
			key = "training"
			p["details"] = tr("DRAGON NET: %s") % mode_name
			p["state"] = tr("Practicing with pad buffer %d") % int(lobby._buffer) if int(lobby._buffer) > 0 \
					else tr("Practicing")
		elif bool(lobby.get("ranked")):
			# Ranked: the mode (FT2) and the opponent; never a way in (the ranked browser lists it).
			key = "ranked_" + String(lobby._phase)
			p["details"] = tr("Ranked: %s") % Ranked.mode_title(String(lobby.mode))
			var me := Ranked.display_name()
			var opp := ""
			for pl in players:
				if String(pl.get("name", "")) != me:
					opp = String(pl.get("name", ""))
			if String(lobby._phase) == "playing" and opp != "":
				p["state"] = tr("vs %s") % opp
			elif opp != "":
				p["state"] = tr("In the lobby")
			else:
				p["state"] = tr("Waiting for an opponent")
		elif bool(lobby.get("koth")) and not (lobby._koth as Dictionary).is_empty():
			# Battle Lounge: where you are in the line, the set score while it's on.
			var k: Dictionary = lobby._koth
			var line: Array = k.get("line", [])
			var pos := int(k.get("local_pos", -1))
			key = "koth_" + String(lobby._phase)
			p["details"] = tr("Battle Lounge: %s") % mode_name if lobby.mode != "any" else tr("Battle Lounge")
			if String(k.get("state", "")) in ["playing", "decided"] and line.size() >= 2:
				var w: Array = k.get("wins", [0, 0])
				p["state"] = tr("%s %d - %d %s") % [line[0].get("name", "?"), int(w[0]), int(w[1]), line[1].get("name", "?")]
			elif pos == 0 and int(k.get("streak", 0)) > 0:
				p["state"] = tr("Champion · %d in a row") % int(k.get("streak", 0))
			elif pos >= 0:
				p["state"] = tr("#%d in line") % (pos + 1)
			else:
				p["state"] = tr("Watching")
			p["party_size"] = maxi(line.size(), 1)
			p["party_max"] = 8
			var ktarget := _join_target(lobby)
			if ktarget != "":
				p["party_id"] = "spk-" + ktarget.sha256_text().left(16)
				if lobby._role == "host" and bool(lobby._public.get("listed", false)):
					p["join_secret"] = KOTH_JOIN_PREFIX + ktarget
		else:
			match String(lobby._phase):
				"playing":
					key = "match"
					p["details"] = tr("DRAGON NET: %s") % mode_name if lobby.mode != "any" else tr("DRAGON NET match")
					var me := String(Settings.get_value("player", "nickname"))
					var others: Array = []
					for pl in players:
						var n := String(pl.get("name", ""))
						if n != "" and n != me:
							others.append(n)
					p["state"] = tr("vs %s") % ", ".join(others) if not others.is_empty() else tr("Match in progress")
					if lobby.has_method("is_spectating") and lobby.is_spectating():
						var fighters: Array = []
						for pl in lobby._playing():
							fighters.append(String(pl.get("name", "?")))
						p["state"] = tr("Watching %s") % " vs ".join(fighters)
				"searching":
					key = "searching"
					p["details"] = tr("DRAGON NET")
					p["state"] = tr("Looking for a %s lobby") % mode_name if lobby.mode != "any" else tr("Looking for a lobby")
				_:
					key = "lobby"
					p["details"] = (tr("%s lobby") % mode_name) if lobby.mode != "any" else tr("DRAGON NET lobby")
					p["state"] = tr("Waiting for players") if count < 2 else tr("In the lobby")
					p["party_size"] = count
					p["party_max"] = 2
					var target := _join_target(lobby)
					if target != "":
						p["party_id"] = "spk-" + target.sha256_text().left(16)
						if lobby._role == "host" and bool(lobby._public.get("listed", false)):
							p["join_secret"] = JOIN_PREFIX + target
	elif Dolphin.in_game:
		key = "offline"
		p["details"] = "Budokai Tenkaichi 3"
		p["state"] = tr("Playing offline")
	else:
		p["details"] = tr("In the menus")
	if key != _phase_key:
		_phase_key = key
		_phase_start = int(Time.get_unix_time_from_system())
	p["start"] = _phase_start
	return p


## How others reach the lobby we host: the room code (traversal), or the public address:port of a
## direct lobby. "" when there's no way in from outside.
func _join_target(lobby: Node) -> String:
	var room: Dictionary = lobby._room
	if room.get("state", "") != "ready":
		return ""
	if room.get("type") == "traversal":
		return String(room.get("code", ""))
	var public_address := String(Settings.get_value("netplay", "public_address"))
	if public_address != "":
		return "%s:%d" % [public_address, int(room.get("port", 2626))]
	return ""


func _update() -> void:
	var line := "presence " + JSON.stringify(current())
	if line != _sent:
		_sent = line
		Dolphin.helper_send(_helper, line)


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST or what == NOTIFICATION_PREDELETE:
		if _helper:
			Dolphin.helper_send(_helper, "quit")
