extends Node
## DRAGON NET Ranked: talks to the ranked server (Server/ranked, PHP) over HTTPS.
##   - Discord login: the server gives a Discord "Authorize" link, we open it in the browser and
##     poll until the server says it's done; the session token goes in frontend.cfg.
##   - api(endpoint, body) for everything else (lobbies, matches, leaderboard).
## Every call returns a Dictionary; failures come back as {"ok": false, "error": code}.

signal changed   # logged in / out, or the profile changed

const Style := preload("res://scripts/ui/style.gd")

const MODE_CAP := {"single": 2, "team": 1}   # wins that take a ranked match

var profile := {}            # me.php: player, ratings {single, team}, lifetime
var logging_in := false
## How a login link is opened. Tests swap it for a scripted "browser".
var open_url: Callable = func(url: String): OS.shell_open(url)
var _cancel_login := false


func server() -> String:
	var s := String(Settings.get_value("ranked", "server")).strip_edges()
	return s if s.ends_with("/") else s + "/"


func token() -> String:
	return String(Settings.get_value("ranked", "token"))


func logged_in() -> bool:
	return token() != ""


func display_name() -> String:
	return String(Settings.get_value("ranked", "name"))


static func mode_title(mode: String) -> String:
	# "Single Battle FT2": ranked Single Battle is first to 2 wins; Team Battle is one match.
	if mode == "single":
		return TranslationServer.translate("Single Battle FT2")
	return Style.mode_name(mode)


func api(endpoint: String, body := {}) -> Dictionary:
	var req := HTTPRequest.new()
	req.timeout = 20.0
	add_child(req)
	var headers := PackedStringArray(["Content-Type: application/json", "Accept: application/json"])
	if token() != "":
		headers.append("X-Sparking-Token: " + token())
	var err := req.request(server() + endpoint, headers, HTTPClient.METHOD_POST, JSON.stringify(body))
	if err != OK:
		req.queue_free()
		return {"ok": false, "error": "unreachable"}
	var res: Array = await req.request_completed
	req.queue_free()
	if int(res[0]) != HTTPRequest.RESULT_SUCCESS:
		return {"ok": false, "error": "unreachable"}
	var data = JSON.parse_string((res[3] as PackedByteArray).get_string_from_utf8())
	if typeof(data) != TYPE_DICTIONARY:
		return {"ok": false, "error": "bad_response", "http": int(res[1])}
	if int(res[1]) == 401 and token() != "":
		_forget()   # the session ended on the server (logged out elsewhere, reset)
	return data


## Opens Discord's authorize page and waits (up to ~10 min) for the player to approve.
func login() -> Dictionary:
	if logging_in:
		return {"ok": false, "error": "busy"}
	logging_in = true
	_cancel_login = false
	var start := await api("auth.php", {"action": "start"})
	if not start.get("ok", false):
		logging_in = false
		return start
	open_url.call(String(start["url"]))
	var deadline := Time.get_ticks_msec() + int(start.get("expires_in", 600)) * 1000
	var result := {"ok": false, "error": "expired"}
	while not _cancel_login and Time.get_ticks_msec() < deadline:
		await get_tree().create_timer(2.0).timeout
		if _cancel_login:
			break
		var p := await api("auth.php", {"action": "poll", "login": start["login"], "poll": start["poll"]})
		match String(p.get("state", "")):
			"done":
				Settings.set_value("ranked", "token", String(p["token"]))
				Settings.set_value("ranked", "name", String(p.get("player", {}).get("name", "")))
				await refresh()
				result = {"ok": true}
				break
			"error":
				result = {"ok": false, "error": String(p.get("error", "error"))}
				break
			"expired":
				result = {"ok": false, "error": "expired"}
				break
	if _cancel_login:
		result = {"ok": false, "error": "cancelled"}
	logging_in = false
	changed.emit()
	return result


func cancel_login() -> void:
	_cancel_login = true


func refresh() -> Dictionary:
	if not logged_in():
		return {"ok": false, "error": "login_required"}
	var me := await api("me.php")
	if me.get("ok", false):
		profile = me
		Settings.set_value("ranked", "name", String(me["player"]["name"]))
		for mode in ["single", "team"]:
			Settings.set_value("ranked", "last_" + mode, rating(mode))
		changed.emit()
	return me


func logout() -> void:
	if logged_in():
		await api("auth.php", {"action": "logout"})
	_forget()


func _forget() -> void:
	Settings.set_value("ranked", "token", "")
	Settings.set_value("ranked", "last_single", 0)
	Settings.set_value("ranked", "last_team", 0)
	profile = {}
	changed.emit()


func rating(mode: String) -> int:
	return int(profile.get("ratings", {}).get(mode, {}).get("rating", 1000))


## Readable text for a server error code.
static func error_text(code: String) -> String:
	var t := {
		"unreachable": "Couldn't reach the ranked server. Check your connection.",
		"bad_response": "The ranked server sent something unexpected.",
		"discord_not_configured": "Ranked isn't set up on the server yet (Discord login).",
		"login_required": "Log in with Discord first.",
		"denied": "Discord login was cancelled.",
		"expired": "The Discord login timed out. Try again.",
		"cancelled": "Discord login cancelled.",
		"token_exchange": "Discord didn't accept the login. Try again later.",
		"lobby_full": "That ranked lobby already has 2 players.",
		"lobby_gone": "That ranked lobby is gone.",
		"own_lobby": "That's your own lobby.",
		"no_opponent": "Your opponent hasn't checked in with the ranked server yet.",
		"database_error": "The ranked server had a problem. Try again in a moment.",
	}
	return TranslationServer.translate(t.get(code, code.replace("_", " ")))
