extends "res://scripts/screens/form_screen.gd"
## Main Menu > Friends (needs the DRAGON NET account): add someone by username, friend requests
## (accept / decline), and the friends list with who's online (green). A friend coming online
## also pops up over the menus (scripts/ui/social_popups.gd).

var _add := ""
var _status := ""


func _init() -> void:
	super()
	notices = false


func screen_title() -> String:
	return "Friends"


func screen_music() -> String:
	return "main_menu"


func screen_desc() -> String:
	return tr("Logged in as %s. Friends see when you're online.") % Ranked.display_name()


func on_enter() -> void:
	super()
	Social.updated.connect(_on_updated)
	Social.poll()


func _exit_tree() -> void:
	if Social.updated.is_connected(_on_updated):
		Social.updated.disconnect(_on_updated)


func _on_updated() -> void:
	if is_inside_tree():
		list.set_rows(build_rows(), list.current_key())


func build_rows() -> Array:
	var rows: Array = []
	if _status != "":
		rows.append({"type": "info", "key": "status", "label": _status, "value": ""})
	rows.append({"type": "text", "key": "add", "label": "Add a friend", "value": _add, "max_length": 20,
		"placeholder": tr("Username"), "desc": "Type their DRAGON NET username: they get a friend request."})
	for r in Social.incoming:
		rows.append({"type": "action", "key": "in:%d" % int(r["id"]), "label": String(r["name"]),
			"value": tr("wants to be friends"), "color": "#f2b531",
			"desc": tr("%s sent you a friend request. Accept or decline it.") % String(r["name"])})
	var online: Array = Social.friends.filter(func(f): return f.get("online", false))
	var offline: Array = Social.friends.filter(func(f): return not f.get("online", false))
	if Social.friends.is_empty():
		rows.append({"type": "info", "key": "none",
			"label": "No friends yet." if Social.polled else "Loading...", "value": ""})
	else:
		rows.append({"type": "info", "key": "count", "label": tr("Friends: %d online of %d") % [online.size(), Social.friends.size()], "value": ""})
	for f in online + offline:
		var on: bool = f.get("online", false)
		rows.append({"type": "action", "key": "f:%d" % int(f["id"]), "label": String(f["name"]),
			"value": tr("Online") if on else tr("Offline"), "color": "#3fbf6b" if on else "",
			"desc": tr("%s is online now.") % String(f["name"]) if on else tr("%s is offline.") % String(f["name"])})
	for r in Social.outgoing:
		rows.append({"type": "action", "key": "out:%d" % int(r["id"]), "label": String(r["name"]),
			"value": tr("request sent"), "desc": "Waiting for them to accept. Press to cancel the request."})
	rows.append({"type": "action", "key": "back", "label": "Back", "desc": "Back to the main menu."})
	return rows


func on_value(key: String, value: Variant) -> void:
	if key != "add":
		return
	_add = String(value).strip_edges()
	if _add == "":
		return
	var res: Dictionary = await Social.act("request", {"name": _add})
	if not is_inside_tree():
		return
	if res.get("ok", false):
		_status = tr("You're now friends with %s.") % String(res["name"]) if res.get("state") == "friends" \
				else tr("Friend request sent to %s.") % String(res["name"])
		_add = ""
	else:
		_status = Ranked.error_text(String(res.get("error", "")))
	list.set_rows(build_rows(), "add")


func on_press(key: String) -> void:
	var colon := key.find(":")
	if colon < 0:
		super(key)
		return
	var kind := key.left(colon)
	var id := int(key.substr(colon + 1))
	var name := String(list.row(key).get("label", ""))
	var items: Array = []
	match kind:
		"in":
			items = [
				{"label": "Accept", "glyph": "A", "color": "#3fbf6b", "desc": tr("Be friends with %s.") % name,
					"action": func(): _do("accept", id)},
				{"label": "Decline", "glyph": "D", "color": "#e8663d", "desc": tr("Decline %s's request.") % name,
					"action": func(): _do("decline", id)},
			]
		"out":
			items = [{"label": "Cancel request", "glyph": "C", "color": "#e8663d",
				"desc": tr("Take back your request to %s.") % name, "action": func(): _do("decline", id)}]
		"f":
			items = [{"label": "Remove friend", "glyph": "R", "color": "#e8663d",
				"desc": tr("Stop being friends with %s.") % name, "action": func(): _do("remove", id)}]
	items.append({"label": "Back", "glyph": "B", "color": "#8a9bb0", "back": true, "desc": "Back to Friends."})
	var m: Control = app.menu(name, items, "main_menu")
	m.notices = false
	app.push(m)


func _do(action: String, id: int) -> void:
	app.pop()
	var res: Dictionary = await Social.act(action, {"id": id})
	if is_inside_tree() and not res.get("ok", false):
		_status = Ranked.error_text(String(res.get("error", "")))
		list.set_rows(build_rows())
