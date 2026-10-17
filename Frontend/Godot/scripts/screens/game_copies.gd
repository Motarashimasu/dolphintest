extends "res://scripts/screens/form_screen.gd"
## Options > Game Copies > a game: where each version's disc image is (NTSC-U, PAL, NTSC-J) and
## which one Play Offline runs. DRAGON NET asks which version to play when there's more than one.
## A picked file's version is read from the disc (its ID); when it can't be (GCZ...), the player
## says which version it is.

const GAME_FILTERS := ["*.iso, *.rvz, *.wbfs, *.gcz, *.ciso, *.wia, *.gcm ; Wii disc images", "* ; All files"]

var key := "bt3"


func setup(game_key: String) -> Control:
	key = game_key
	return self


func _init() -> void:
	super()
	notices = false


func screen_title() -> String:
	return Settings.GAMES[key]["title"]


func screen_music() -> String:
	return "main_menu"


func screen_desc() -> String:
	return tr("Where your %s copies are, one per version.") % Settings.GAMES[key]["title"]


static func file_text(path: String) -> String:
	if path == "":
		return TranslationServer.translate("Not set")
	if FileAccess.file_exists(path):
		return path.get_file()
	return TranslationServer.translate("(missing) %s") % path.get_file()


func build_rows() -> Array:
	var g: Dictionary = Settings.GAMES[key]
	var rows: Array = []
	for v in Settings.VERSIONS:
		rows.append({"type": "action", "key": v, "label": v,
			"value": file_text(Settings.copy_path(key, v)),
			"desc": tr("Your %s %s disc image (%s).\nThe version is checked when you pick it.") % [g["title"], v, g["versions"][v]]})
	var owned := Settings.owned_versions(key)
	if owned.is_empty():
		rows.append({"type": "info", "key": "offline", "label": "Play Offline uses", "value": tr("No copy yet")})
	else:
		rows.append({"type": "choice", "key": "offline", "label": "Play Offline uses", "values": owned,
			"value": Settings.offline_version(key),
			"desc": "The version Play Offline runs.\nDRAGON NET asks which one when you have more than one."})
	rows.append({"type": "action", "key": "back", "label": "Back", "desc": "Back to the game list."})
	return rows


func on_value(k: String, value: Variant) -> void:
	if k == "offline":
		Settings.set_offline_version(key, String(value))


func on_press(k: String) -> void:
	if k == "back":
		on_back()
		return
	if not k in Settings.VERSIONS:
		return
	if not Settings.has_copy(key, k) and Settings.copy_path(key, k) == "":
		_pick(k)
		return
	# Set (or gone missing): change it or take it out.
	var items: Array = [
		{"label": "Change file", "glyph": "F", "color": "#3fa9f5",
			"desc": tr("Pick another %s %s disc image.") % [Settings.GAMES[key]["title"], k],
			"action": func():
				app.pop()
				_pick(k)},
		{"label": "Remove", "glyph": "X", "color": "#e8663d",
			"desc": tr("Forget this copy (the file stays where it is)."),
			"action": func():
				Settings.set_value("games", "%s_%s" % [key, k], "")
				app.pop()},
		{"label": "Back", "glyph": "B", "color": "#8a9bb0", "back": true, "desc": "Keep it as it is."},
	]
	app.push(app.menu("Game Copy", items, "main_menu"))


func _pick(ver: String) -> void:
	pick_path(false, GAME_FILTERS, Settings.copy_path(key, ver),
			tr("Select your %s %s game file") % [Settings.GAMES[key]["title"], ver],
			func(path: String): store(self, path, key, ver, func(): list.set_rows(build_rows(), ver)))


## A disc image was picked for `game_key` (`ver`: the version it's meant to be, "" = any): files it
## under the version its disc ID says, else asks which version it is. `done` after it's stored.
static func store(screen: Control, path: String, game_key: String, ver: String, done: Callable) -> void:
	path = path.replace("\\", "/")
	var app: Node = screen.app
	var where: Array = Settings.game_of_id(Settings.read_disc_id(path))
	if where.is_empty():
		if ver != "":
			Settings.set_copy(game_key, ver, path)
			done.call()
			return
		_ask_version(app, path, game_key, done)
		return
	if where[0] != game_key:
		app.toast(TranslationServer.translate("That's %s (%s): saved as that game's copy.") % [
			Settings.GAMES[where[0]]["title"], where[1]], 5.0)
	elif ver != "" and where[1] != ver:
		app.toast(TranslationServer.translate("That's the %s version: saved as your %s copy.") % [where[1], where[1]], 5.0)
	Settings.set_copy(where[0], where[1], path)
	done.call()


static func _ask_version(app: Node, path: String, game_key: String, done: Callable) -> void:
	var g: Dictionary = Settings.GAMES[game_key]
	var items: Array = []
	for v in Settings.VERSIONS:
		items.append({"label": v, "glyph": String(v).left(1), "color": g["color"],
			"desc": TranslationServer.translate("%s\nis the %s %s (%s).") % [path.get_file(), g["title"], v, g["versions"][v]],
			"action": func():
				Settings.set_copy(game_key, v, path)
				app.pop()
				done.call()})
	items.append({"label": "Back", "glyph": "B", "color": "#8a9bb0", "back": true,
		"desc": "Don't use this file."})
	app.push(app.menu("Which version?", items, "main_menu"))
