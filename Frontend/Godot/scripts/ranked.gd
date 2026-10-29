extends Node
## DRAGON NET Ranked: talks to the ranked server (Server/ranked, PHP) over HTTPS.
##   - DRAGON NET accounts: username + password, made here (account.php register / login); the
##     session token goes in frontend.cfg. The same account has friends (scripts/social.gd).
##   - A ranked profile from before accounts was made with a Discord login: login() still runs
##     that (the server gives a Discord "Authorize" link, we open it in the browser and poll),
##     once, so its owner can give it a username + password (claim()); `needs_account` until then.
##   - api(endpoint, body) for everything else (lobbies, matches, leaderboard).
## Every call returns a Dictionary; failures come back as {"ok": false, "error": code}.

signal changed   # logged in / out, or the profile changed

const Style := preload("res://scripts/ui/style.gd")
const HttpWait := preload("res://scripts/util/http_wait.gd")

const MODE_CAP := {"single": 2, "team": 1}   # wins that take a ranked match

var profile := {}            # me.php: player, ratings {single, team}, lifetime (of profile.game)
var logging_in := false
var needs_account := false   # logged in with Discord, the profile has no username + password yet
## How a login link is opened. Tests swap it for a scripted "browser".
var open_url: Callable = func(url: String): OS.shell_open(url)
var _cancel_login := false
var _use_mirror := false     # see server()


## The server in use: [ranked] server, or its mirror once the server couldn't be reached from
## here (antivirus / router / ISP filters) and the mirror could. Back to the server next start.
func server() -> String:
	return _slash(String(Settings.get_value("ranked", "mirror" if _use_mirror else "server")))


func mirror() -> String:
	var m := String(Settings.get_value("ranked", "mirror")).strip_edges()
	return _slash(m) if m != "" else ""


static func _slash(s: String) -> String:
	s = s.strip_edges()
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


## Each game has its own ladder on the server (Budokai Tenkaichi 2: b2single / b2team) and a
## lobby plays one disc version. The screens speak plain modes (single, team) for the game the
## menus are on; this turns them into the server's and back.
static func _to_server(endpoint: String, body: Dictionary) -> Dictionary:
	var b := body.duplicate()
	var prefix := String(Settings.GAMES[Settings.game]["ranked_prefix"])
	b["game"] = Settings.game
	if String(b.get("mode", "")) in ["single", "team"]:
		b["mode"] = prefix + String(b["mode"])
	if endpoint == "lobby.php" and String(b.get("action", "")) in ["open", "list"]:
		b["version"] = Settings.GAME["id"]
	return b


static func _from_server(v: Variant) -> Variant:
	if v is Dictionary:
		var d: Dictionary = v
		for k in d.keys():
			d[k] = _from_server(d[k])
		var m = d.get("mode")
		if m is String and (m as String).begins_with("b2"):
			d["mode"] = (m as String).substr(2)
	elif v is Array:
		for i in (v as Array).size():
			v[i] = _from_server(v[i])
	return v


func api(endpoint: String, body := {}) -> Dictionary:
	body = _to_server(endpoint, body)
	var res := await _post(server(), endpoint, body)
	# Couldn't get through at all (not an answer from the server): the other address, once. If
	# that one works, it's the one used from now on (until the launcher restarts).
	if res.has("result") and mirror() != "":
		var other := _slash(String(Settings.get_value("ranked", "server"))) if _use_mirror else mirror()
		var again := await _post(other, endpoint, body)
		if not again.has("result"):
			_use_mirror = not _use_mirror
			return again
	return res


func _post(base: String, endpoint: String, body: Dictionary) -> Dictionary:
	var req := HTTPRequest.new()
	add_child(req)   # (timed out by the real clock below, not req.timeout: util/http_wait.gd)
	var headers := PackedStringArray(["Content-Type: application/json", "Accept: application/json"])
	if token() != "":
		headers.append("X-Sparking-Token: " + token())
	var err := req.request(base + endpoint, headers, HTTPClient.METHOD_POST, JSON.stringify(body))
	if err != OK:
		req.queue_free()
		return {"ok": false, "error": "unreachable", "result": -1}
	var res: Array = await HttpWait.done(req, 20.0)
	req.queue_free()
	if int(res[0]) != HTTPRequest.RESULT_SUCCESS:
		# Say which way it failed: a refused secure connection or an unknown name is something on
		# the player's side (antivirus web protection, router / ISP filters, DNS), not "no internet".
		var why := "unreachable"
		if int(res[0]) == HTTPRequest.RESULT_TLS_HANDSHAKE_ERROR:
			why = "secure_refused"
		elif int(res[0]) == HTTPRequest.RESULT_CANT_RESOLVE:
			why = "cant_resolve"
		return {"ok": false, "error": why, "result": int(res[0])}   # (HTTPRequest.Result)
	var data = JSON.parse_string((res[3] as PackedByteArray).get_string_from_utf8())
	if typeof(data) != TYPE_DICTIONARY:
		return {"ok": false, "error": "bad_response", "http": int(res[1])}
	if int(res[1]) == 401 and token() != "":
		_forget()   # the session ended on the server (logged out elsewhere, reset)
	return _from_server(data)


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
				needs_account = bool(p.get("needs_account", false))
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


## Logs in to a DRAGON NET account (`create`: makes it first). {"ok": true} or an error code.
func account_login(username: String, password: String, create := false) -> Dictionary:
	if logging_in:
		return {"ok": false, "error": "busy"}
	logging_in = true
	var res := await api("account.php", {"action": "register" if create else "login",
		"username": username.strip_edges(), "password": password})
	if res.get("ok", false):
		Settings.set_value("ranked", "token", String(res["token"]))
		Settings.set_value("ranked", "name", String(res["player"]["name"]))
		needs_account = false
		await refresh()
	logging_in = false
	changed.emit()
	return res


## A profile from before accounts (just logged in with Discord) gets its username + password.
func claim(username: String, password: String) -> Dictionary:
	var res := await api("account.php", {"action": "claim", "username": username.strip_edges(),
		"password": password})
	if res.get("ok", false) or String(res.get("error", "")) == "already_claimed":
		needs_account = false
		await refresh()
	changed.emit()
	return res


func refresh() -> Dictionary:
	if not logged_in():
		return {"ok": false, "error": "login_required"}
	var me := await api("me.php")
	if me.get("ok", false):
		profile = me
		Settings.set_value("ranked", "name", String(me["player"]["name"]))
		for mode in ["single", "team"]:
			Settings.set_value("ranked", _last_key(mode), rating(mode))
		changed.emit()
	return me


## The account's profile picture: `img` must be Pictures.SIZE square (the crop screen makes it);
## null removes it. -> {"ok", "picture": its URL or null}; the profile is refreshed.
func set_picture(img: Image) -> Dictionary:
	var res: Dictionary
	if img == null:
		res = await api("account.php", {"action": "picture_remove"})
	else:
		res = await api("account.php", {"action": "picture",
			"data": Marshalls.raw_to_base64(img.save_png_to_buffer())})
		if res.get("ok", false) and res.get("picture") is String:
			load("res://scripts/pictures.gd").remember(String(res["picture"]), img)
	if res.get("ok", false):
		await refresh()
	return res


## The logged-in player's picture URL ("" = none).
func picture() -> String:
	var p = profile.get("player", {}).get("picture")
	return String(p) if p is String else ""


func logout() -> void:
	if logged_in():
		await api("auth.php", {"action": "logout"})
	_forget()


func _forget() -> void:
	Settings.set_value("ranked", "token", "")
	needs_account = false
	for key in Settings.GAMES:
		for mode in ["single", "team"]:
			Settings.set_value("ranked", String(Settings.GAMES[key]["ranked_prefix"]) + "last_" + mode, 0)
	profile = {}
	changed.emit()


func rating(mode: String) -> int:
	return int(profile.get("ratings", {}).get(mode, {}).get("rating", 1000))


## The profile is the current game's (refresh() after switching games).
func has_profile() -> bool:
	return not profile.is_empty() and String(profile.get("game", "bt3")) == Settings.game


## The rating plate's last known rating of `mode`, per game (b2last_single...).
func last_rating(mode: String) -> int:
	return int(Settings.get_value("ranked", _last_key(mode)))


static func _last_key(mode: String) -> String:
	return String(Settings.GAMES[Settings.game]["ranked_prefix"]) + "last_" + mode


static func _server_host() -> String:
	return String(Settings.get_value("ranked", "server")).get_slice("://", 1).get_slice("/", 0)


## Readable text for a server error code.
static func error_text(code: String) -> String:
	var t := {
		"unreachable": "Couldn't reach the ranked server. Check your connection.",
		"bad_response": "The ranked server sent something unexpected.",
		"secure_refused": "The secure connection to DRAGON NET was refused on the way. Antivirus web\nprotection, router security or your network may be blocking %s: allow it or try another network.",
		"cant_resolve": "Couldn't look up the DRAGON NET server (%s). Check your connection, or try\nanother DNS (e.g. 1.1.1.1).",
		"discord_not_configured": "The Discord login isn't set up on the server.",
		"login_required": "Log in to your DRAGON NET account first.",
		"wrong_login": "Wrong username or password.",
		"username_taken": "That username is taken.",
		"bad_username": "Usernames are 3-20 letters, digits, _ . or - (no spaces).",
		"bad_password": "Passwords need at least 6 characters.",
		"too_many_attempts": "Too many wrong passwords: wait 5 minutes and try again.",
		"no_discord_profile": "No ranked profile for that Discord account: create an account instead.",
		"already_claimed": "This profile already has an account.",
		"no_such_player": "No player with that username.",
		"own_name": "That's you.",
		"already_friends": "You're already friends.",
		"too_many_friends": "Friends list full (200).",
		"no_request": "That request is gone.",
		"denied": "Discord login was cancelled.",
		"expired": "The Discord login timed out. Try again.",
		"cancelled": "Discord login cancelled.",
		"token_exchange": "Discord didn't accept the login. Try again later.",
		"lobby_full": "That ranked lobby already has 2 players.",
		"set_done": "That ranked lobby's set is over: open or join a new ranked lobby.",
		"lobby_gone": "That ranked lobby is gone.",
		"own_lobby": "That's your own lobby.",
		"no_opponent": "Your opponent hasn't checked in with the ranked server yet.",
		"database_error": "The ranked server had a problem. Try again in a moment.",
		"banned": "Your ranked profile is suspended.",
		"bad_picture": "That picture can't be used (PNG, JPEG or WebP only).",
		"bad_picture_size": "The picture has to be cropped first.",
		"picture_too_small": "That picture is too small (at least 32 x 32).",
		"no_such_replay": "That replay isn't on DRAGON NET any more.",
		"replay_missing": "The replay's files are missing.",
		"replay_too_big": "That replay is too big to share.",
		"too_many_uploads": "You've shared a lot of replays today: try again tomorrow.",
		"upload_broken": "The upload got damaged on the way. Try again.",
		"write_failed": "Couldn't save the replay (is the folder read-only?).",
	}
	var text := String(TranslationServer.translate(t.get(code, code.replace("_", " "))))
	if code in ["secure_refused", "cant_resolve"]:
		text = text % _server_host()
	return text
