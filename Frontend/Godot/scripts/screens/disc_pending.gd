extends "res://scripts/screens/form_screen.gd"
## Shown at start when a built copy (scripts/discs.gd) needs the player: a version that's now
## built from their disc while they have a copy picked the old way, an update of the version
## (a new recipe), or a copy whose file changed. Each row builds / checks it; Later goes on.

const DiscBuild := preload("res://scripts/screens/disc_build.gd")


func _init() -> void:
	super()
	notices = false


func screen_title() -> String:
	return "Game Copies"


func screen_music() -> String:
	return "main_menu"


func screen_desc() -> String:
	return tr("The collection builds its own copy of these versions from your original disc.\nYour disc file is only read, never changed.")


func build_rows() -> Array:
	var rows: Array = []
	for kv in Discs.pending():
		var key: String = kv[0]
		var ver: String = kv[1]
		var id := String(Settings.GAMES[key]["versions"][ver])
		var name := "%s %s" % [Settings.GAMES[key]["title"], Settings.version_name(key, ver)]
		var from := Discs.candidate(key, ver)
		var value := ""
		var desc := ""
		match Discs.state(id) if not Discs.found(id) else "found":
			"found":
				value = tr("Found: checking it")
				desc = tr("Your %s copy was found in SparkingData/title.\nIt's checked once (a minute or so), then it's ready: no need to build it again.") % name
			"changed":
				value = tr("Changed: check it")
				desc = tr("Your %s copy isn't the one that was built (its file changed).\nCheck it, or build it again from your disc.") % name
			"outdated":
				value = tr("Updated: build it again")
				desc = tr("%s was updated. Build your copy again from your disc\n(%s).") % [name, from.get_file() if from != "" else tr("pick it")]
			_:
				value = tr("Build from %s") % from.get_file()
				desc = tr("%s is now built from your original %s disc (%s).\nBuild it from %s? If that isn't your original disc, you can pick another.") % [
					name, ver, id, from.get_file()]
		rows.append({"type": "action", "key": "%s/%s" % [key, ver], "label": name, "value": value, "desc": desc})
	rows.append({"type": "action", "key": "back", "label": "Later",
		"desc": tr("Go on to the menus. Versions that aren't built can't be played until they are.")})
	return rows


func on_enter() -> void:
	super()
	_check_found.call_deferred()


func on_resume() -> void:
	if Discs.pending().is_empty():
		app.pop()
		return
	super()
	_check_found.call_deferred()


## Copies found again after a reinstall are checked right away, one after the other.
func _check_found() -> void:
	if not is_inside_tree() or app.top() != self:
		return
	for kv in Discs.pending():
		var id := String(Settings.GAMES[kv[0]]["versions"][kv[1]])
		if Discs.found(id) and not _checked.has(id):
			_checked[id] = true   # (once: if it fails, the row offers to build it instead)
			app.push(DiscBuild.new().setup(kv[0], kv[1], ""))
			return


var _checked := {}


func on_press(k: String) -> void:
	if k == "back":
		on_back()
		return
	var key := k.get_slice("/", 0)
	var ver := k.get_slice("/", 1)
	var id := String(Settings.GAMES[key]["versions"][ver])
	if Discs.state(id) == "changed":
		app.push(DiscBuild.new().setup(key, ver, ""))
		return
	var from := Discs.candidate(key, ver)
	if from == "":
		DiscBuild.pick_and_build(self, key, ver)
	else:
		app.push(DiscBuild.new().setup(key, ver, from))
