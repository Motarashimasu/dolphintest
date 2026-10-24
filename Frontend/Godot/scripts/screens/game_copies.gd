extends "res://scripts/screens/form_screen.gd"
## Options > Game Copies > a game: where each version's disc image is (NTSC-U, PAL, NTSC-J) and
## which one Play Offline runs. DRAGON NET asks which version to play when there's more than one.
## A picked file's version is read from the disc (its ID); when it can't be (GCZ...), the player
## says which version it is. A version with a disc recipe (e.g. 4.0) is built from the player's
## original disc instead (scripts/discs.gd, disc_build.gd): its copy can only be built, not picked.

const DiscBuild := preload("res://scripts/screens/disc_build.gd")

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


## A built copy's state, for the Game Copies row.
static func built_text(id: String) -> String:
	match Discs.state(id):
		"ready":
			return TranslationServer.translate("Built from your disc")
		"outdated":
			return TranslationServer.translate("Updated: build it again")
		"changed":
			return TranslationServer.translate("Changed: check it")
	return TranslationServer.translate("Not set")


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
		var id := String(g["versions"][v])
		if Discs.has_recipe(id):
			rows.append({"type": "action", "key": v, "label": Settings.version_name(key, v),
				"value": built_text(id),
				"desc": tr("%s %s is built from your original %s disc (%s).\nThe launcher makes and keeps its own copy: pick your disc to build it.") % [
					g["title"], Settings.version_name(key, v), v, id]})
			continue
		rows.append({"type": "action", "key": v, "label": v,
			"value": file_text(Settings.copy_path(key, v)),
			"desc": tr("Your %s %s disc image (%s).\nThe version is checked when you pick it.") % [g["title"], v, g["versions"][v]]})
	# Locked versions after the playable ones (the cursor starts on a playable one).
	for v in Settings.LOCKED_VERSIONS:
		rows.append({"type": "action", "key": v, "label": v, "value": tr("Not supported yet"),
			"disabled": true, "desc": tr("The %s version isn't supported yet. It will be unlocked later.") % v})
	var owned := Settings.owned_versions(key)
	if owned.is_empty():
		rows.append({"type": "info", "key": "offline", "label": "Play Offline uses", "value": tr("No copy yet")})
	else:
		rows.append({"type": "choice", "key": "offline", "label": "Play Offline uses", "values": owned,
			"names": owned.map(func(v): return Settings.version_name(key, v)),
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
	var id := String(Settings.GAMES[key]["versions"][k])
	if Discs.has_recipe(id):
		_built_menu(k, id)
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


## A built version: build it (again) from a disc, check it, or remove it.
func _built_menu(k: String, id: String) -> void:
	var refresh := func(): list.set_rows(build_rows(), k)
	var st := Discs.state(id)
	if st == "missing" and Discs.candidate(key, k) == "":
		DiscBuild.pick_and_build(self, key, k, refresh)
		return
	var name := Settings.version_name(key, k)
	var items: Array = []
	var again := Discs.candidate(key, k)
	if st in ["outdated", "missing"] and again != "":
		items.append({"label": "Build again", "glyph": "R", "color": "#3fbf6b",
			"desc": tr("Build %s again from %s.") % [name, again.get_file()],
			"action": func(): app.replace(DiscBuild.new().setup(key, k, again, refresh))})
	if st == "changed":
		items.append({"label": "Check it", "glyph": "C", "color": "#3fbf6b",
			"desc": tr("Check that your %s copy is still the one that was built.") % name,
			"action": func(): app.replace(DiscBuild.new().setup(key, k, "", refresh))})
	items.append({"label": "Build from a disc", "glyph": "F", "color": "#3fa9f5",
		"desc": tr("Pick your original %s disc (%s) and build %s from it.") % [k, id, name],
		"action": func():
			app.pop()
			DiscBuild.pick_and_build(self, key, k, refresh)})
	items.append({"label": "Copy details", "glyph": "D", "color": "#8a9bb0",
		"desc": tr("Copies your %s copy's details (state, fingerprint, the disc it was built from)\nto paste in the support channel.") % name,
		"action": func():
			DisplayServer.clipboard_set(copy_report(key, k))
			app.toast(tr("Copied: paste it in the support channel."), 4.0)})
	if st != "missing":
		items.append({"label": "Remove", "glyph": "X", "color": "#e8663d",
			"desc": tr("Delete the launcher's %s copy (your disc file stays).") % name,
			"action": func():
				Discs.remove(id)
				app.pop()})
	items.append({"label": "Back", "glyph": "B", "color": "#8a9bb0", "back": true, "desc": "Keep it as it is."})
	app.push(app.menu("Game Copy", items, "main_menu"))


## A built copy, for support: same disc for everyone means the same fingerprint (SHA-256).
static func copy_report(game_key: String, ver: String) -> String:
	var id := String(Settings.GAMES[game_key]["versions"][ver])
	var info := Discs.info(id)
	var sha := String(Settings._cfg.get_value("discs", id + "_sha256", ""))
	var renderer := String(Settings.get_value("video", "renderer"))
	return "\n".join(PackedStringArray([
		"DRAGON BALL Sparking! Collection: game copy",
		"Launcher: %s, %s" % [Updater.installed_version(), OS.get_name()],
		"Version: %s %s (%s, revision %d, recipe %s)" % [Settings.GAMES[game_key]["title"],
			Settings.version_name(game_key, ver), id, int(info.get("revision", 0)), info.get("made", "?")],
		"State: %s" % Discs.state(id),
		"Fingerprint: %s" % (sha.left(16) if sha != "" else "-"),
		"Built from: %s" % (Discs.original(id).get_file() if Discs.original(id) != "" else "-"),
		"Renderer: %s, graphics %s" % [renderer, Settings.get_value("options", "graphics")],
		"GPU: %s" % RenderingServer.get_video_adapter_name(),
	]))


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
		if ver != "" and Discs.has_recipe(String(Settings.GAMES[game_key]["versions"][ver])):
			app.push(DiscBuild.new().setup(game_key, ver, path, done))
			return
		if ver != "":
			Settings.set_copy(game_key, ver, path)
			done.call()
			return
		_ask_version(app, path, game_key, done)
		return
	if where[1] in Settings.LOCKED_VERSIONS:
		app.toast(TranslationServer.translate("That's the %s version, which isn't supported yet.") % where[1], 5.0)
		return
	var id := String(Settings.GAMES[where[0]]["versions"][where[1]])
	if Discs.has_recipe(id):
		# Built, not picked: this disc is the original it's built from (checked there).
		app.push(DiscBuild.new().setup(where[0], where[1], path, done))
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
		items.append({"label": Settings.version_name(game_key, v), "glyph": String(v).left(1), "color": g["color"],
			"desc": TranslationServer.translate("%s\nis the %s %s (%s).") % [path.get_file(), g["title"], v, g["versions"][v]],
			"action": func():
				app.pop()
				if Discs.has_recipe(String(g["versions"][v])):
					app.push(DiscBuild.new().setup(game_key, v, path, done))
					return
				Settings.set_copy(game_key, v, path)
				done.call()})
	items.append({"label": "Back", "glyph": "B", "color": "#8a9bb0", "back": true,
		"desc": "Don't use this file."})
	app.push(app.menu("Which version?", items, "main_menu"))
