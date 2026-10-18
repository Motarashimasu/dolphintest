extends "res://scripts/screens/form_screen.gd"
## The DRAGON NET account: Ranked Match > Profile, Friends, and the stop before any ranked or
## friends screen while logged out.
##   Logged out: username + password, Log in / Create account. A ranked profile from before
##   accounts (made with Discord): "Convert my Discord ranked profile" logs in with Discord once
##   (opens the browser, waits for the approval), then asks for its new username + password.
##   Logged in: the account, your ratings and records, Log out.

var _then: Callable          # where to go once logged in (e.g. the Ranked Lobby Browser)
var _status := ""
var _busy := false
var _username := ""
var _password := ""


func setup(then := Callable()) -> Node:
	_then = then
	return self


func screen_music() -> String:
	return "netplay"


func screen_title() -> String:
	if Ranked.logged_in() and Ranked.needs_account:
		return "Your New Account"
	return "Your Account" if Ranked.logged_in() else "DRAGON NET Login"


func screen_desc() -> String:
	if Ranked.logged_in():
		return "Your DRAGON NET account: ranked ratings and records."
	return "Ranked and friends need a DRAGON NET account: one per player,\nso ratings can't be reset."


func on_enter() -> void:
	super()
	Ranked.changed.connect(_on_changed)
	if Ranked.logged_in():
		_status = tr("Loading your profile...")
		list.set_rows(build_rows())
		var me := await Ranked.refresh()
		if not is_inside_tree():
			return
		_status = "" if me.get("ok", false) else Ranked.error_text(String(me.get("error", "")))
		list.set_rows(build_rows())


func _exit_tree() -> void:
	if Ranked.changed.is_connected(_on_changed):
		Ranked.changed.disconnect(_on_changed)
	if Ranked.logging_in:
		Ranked.cancel_login()


func _on_changed() -> void:
	if is_inside_tree():
		app.set_title(screen_title())
		list.set_rows(build_rows())


func build_rows() -> Array:
	var rows: Array = []
	if _status != "":
		rows.append({"type": "info", "key": "status", "label": _status, "value": ""})
	if Ranked.logging_in and _discord:
		rows.append({"type": "info", "key": "waiting", "label": "Approve the login in your browser...",
			"value": "", "desc": "Discord opened in your browser. Press Authorize there,\nthen come back here."})
		rows.append({"type": "action", "key": "cancel", "label": "Cancel", "color": "#e8663d"})
		return rows
	if not Ranked.logged_in():
		rows.append_array([
			{"type": "text", "key": "username", "label": "Username", "value": _username, "max_length": 20,
				"desc": "Your DRAGON NET name: 3-20 letters, digits, _ . or -.\nFriends find you by it."},
			{"type": "text", "key": "password", "label": "Password", "value": _password, "max_length": 128,
				"secret": true, "desc": "At least 6 characters."},
			{"type": "action", "key": "login", "label": "Log in", "color": "#3fbf6b",
				"desc": "Log in to your DRAGON NET account."},
			{"type": "action", "key": "create", "label": "Create account", "color": "#f2b531",
				"desc": "Make a new DRAGON NET account with this username and password."},
			{"type": "action", "key": "discord", "label": "Convert my Discord ranked profile", "color": "#5865f2",
				"desc": "Played ranked with a Discord login before? Log in with Discord once,\nthen pick a username and password: your ratings stay."},
			{"type": "action", "key": "back", "label": "Back", "desc": "Back."},
		])
		return rows
	if Ranked.needs_account:
		rows.append_array([
			{"type": "info", "key": "discord_name", "label": "Discord profile", "value": Ranked.display_name()},
			{"type": "text", "key": "username", "label": "New username", "value": _username, "max_length": 20,
				"desc": "Your DRAGON NET name from now on: 3-20 letters, digits, _ . or -."},
			{"type": "text", "key": "password", "label": "New password", "value": _password, "max_length": 128,
				"secret": true, "desc": "At least 6 characters. You'll log in with these from now on."},
			{"type": "action", "key": "claim", "label": "Save my account", "color": "#3fbf6b",
				"desc": "Your ranked ratings and records stay with it."},
			{"type": "action", "key": "logout", "label": "Cancel", "color": "#e8663d", "desc": "Log out again."},
		])
		return rows
	var p: Dictionary = Ranked.profile.get("player", {})
	rows.append({"type": "info", "key": "name", "label": "Account", "value": String(p.get("name", Ranked.display_name()))})
	if p.get("banned", false):
		rows.append({"type": "info", "key": "banned", "label": "Your ranked profile is suspended.",
			"value": String(p.get("ban_reason", "")), "desc": "You can't play ranked matches until an admin lifts it."})
	var season: Dictionary = Ranked.profile.get("season", {})
	if not season.is_empty():
		rows.append({"type": "info", "key": "season", "label": "Season", "value": String(season.get("name", ""))})
	for mode in ["single", "team"]:
		var r: Dictionary = Ranked.profile.get("ratings", {}).get(mode, {})
		rows.append({"type": "info", "key": "rating_" + mode, "label": Ranked.mode_title(mode),
			"value": tr("%d   ·   %d-%d") % [int(r.get("rating", 1000)), int(r.get("wins", 0)), int(r.get("losses", 0))],
			"desc": "Rating, then wins-losses in this mode."})
	var life: Dictionary = Ranked.profile.get("lifetime", {})
	rows.append({"type": "info", "key": "lifetime", "label": "All-time record",
		"value": "%d-%d" % [int(life.get("wins", 0)), int(life.get("losses", 0))]})
	if _then.is_valid():
		rows.append({"type": "action", "key": "continue", "label": "Continue", "color": "#3fbf6b"})
	rows.append({"type": "action", "key": "logout", "label": "Log out", "color": "#e8663d",
		"desc": "Log out on this PC (your account stays)."})
	rows.append({"type": "action", "key": "back", "label": "Back", "desc": "Back."})
	return rows


var _discord := false   # the login running is the Discord one


func on_value(key: String, value: Variant) -> void:
	match key:
		"username":
			_username = String(value)
		"password":
			_password = String(value)


## Logged in (or the account just made): go on to where we were headed, else show the profile.
func _logged_in() -> void:
	Sfx.play("start")
	app.toast(tr("Logged in as %s") % Ranked.display_name())
	_password = ""
	if _then.is_valid():
		var next := _then
		app.pop()
		next.call()
		return
	app.set_title(screen_title())
	list.set_rows(build_rows())


func on_press(key: String) -> void:
	match key:
		"login", "create":
			if _busy:
				return
			_busy = true
			_status = tr("Creating your account...") if key == "create" else tr("Logging in...")
			list.set_rows(build_rows(), key)
			var res: Dictionary = await Ranked.account_login(_username, _password, key == "create")
			_busy = false
			if not is_inside_tree():
				return
			_status = "" if res.get("ok", false) else Ranked.error_text(String(res.get("error", "")))
			if res.get("ok", false):
				_logged_in()
				return
			list.set_rows(build_rows(), key)
		"claim":
			if _busy:
				return
			_busy = true
			var res: Dictionary = await Ranked.claim(_username, _password)
			_busy = false
			if not is_inside_tree():
				return
			if res.get("ok", false):
				_status = ""
				_logged_in()
				return
			_status = Ranked.error_text(String(res.get("error", "")))
			list.set_rows(build_rows(), "claim")
		"discord":
			_status = ""
			_discord = true
			# Show the waiting rows as soon as the login has started (it sets logging_in first).
			(func(): list.set_rows(build_rows(), "cancel")).call_deferred()
			var res: Dictionary = await Ranked.login()
			_discord = false
			if not is_inside_tree():
				return
			_status = "" if res.get("ok", false) else Ranked.error_text(String(res.get("error", "")))
			if res.get("ok", false) and not Ranked.needs_account:
				_logged_in()   # (already converted before)
				return
			_username = ""
			_password = ""
			app.set_title(screen_title())
			list.set_rows(build_rows(), "username" if Ranked.needs_account else "discord")
		"cancel":
			Ranked.cancel_login()
		"continue":
			var next := _then
			app.pop()
			next.call()
		"logout":
			await Ranked.logout()
			if is_inside_tree():
				app.set_title(screen_title())
				list.set_rows(build_rows())
		_:
			super(key)
