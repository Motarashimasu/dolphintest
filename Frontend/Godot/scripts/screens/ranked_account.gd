extends "res://scripts/screens/form_screen.gd"
## Ranked Match > Profile, and the stop before any ranked screen while logged out: Discord login
## (opens the browser, waits for the approval), then your ratings and records, and Log out.

var _then: Callable          # where to go once logged in (e.g. the Ranked Lobby Browser)
var _status := ""
var _busy := false


func setup(then := Callable()) -> Node:
	_then = then
	return self


func screen_music() -> String:
	return "netplay"


func screen_title() -> String:
	return "Ranked Profile" if Ranked.logged_in() else "Ranked Login"


func screen_desc() -> String:
	if Ranked.logged_in():
		return "Your ranked ratings and records."
	return "Ranked needs a Discord login: one Discord account is one ranked profile,\nso ratings can't be reset."


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
	if not Ranked.logged_in():
		if Ranked.logging_in:
			rows.append({"type": "info", "key": "waiting", "label": "Approve the login in your browser...",
				"value": "", "desc": "Discord opened in your browser. Press Authorize there,\nthen come back here."})
			rows.append({"type": "action", "key": "cancel", "label": "Cancel", "color": "#e8663d"})
		else:
			rows.append({"type": "action", "key": "login", "label": "Log in with Discord", "color": "#5865f2",
				"desc": "Opens Discord in your browser. Press Authorize there:\nyour Discord name becomes your ranked name."})
			rows.append({"type": "action", "key": "back", "label": "Back", "desc": "Back to Ranked Match."})
		return rows
	var p: Dictionary = Ranked.profile.get("player", {})
	rows.append({"type": "info", "key": "name", "label": "Discord", "value": String(p.get("name", Ranked.display_name()))})
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
		"desc": "Forget the Discord login on this PC (your ranked profile stays)."})
	rows.append({"type": "action", "key": "back", "label": "Back", "desc": "Back to Ranked Match."})
	return rows


func on_press(key: String) -> void:
	match key:
		"login":
			_status = ""
			# Show the waiting rows as soon as the login has started (it sets logging_in first).
			(func(): list.set_rows(build_rows(), "cancel")).call_deferred()
			var res: Dictionary = await Ranked.login()
			if not is_inside_tree():
				return
			if res.get("ok", false):
				Sfx.play("start")
				app.toast(tr("Logged in as %s") % Ranked.display_name())
				if _then.is_valid():
					var next := _then
					app.pop()
					next.call()
					return
				_status = ""
			else:
				_status = Ranked.error_text(String(res.get("error", "")))
			list.set_rows(build_rows())
		"cancel":
			Ranked.cancel_login()
		"continue":
			var next := _then
			app.pop()
			next.call()
		"logout":
			await Ranked.logout()
			if is_inside_tree():
				list.set_rows(build_rows())
		_:
			super(key)
