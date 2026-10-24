extends "res://scripts/screens/form_screen.gd"
## Builds the launcher's own copy of a version (e.g. Sparking! 4.0) from the player's disc
## (scripts/discs.gd): checks the disc file by file, then writes SparkingData/title/<ID>.rvz.
## Shows the progress; a disc that isn't the original is refused with the reason. Back stops
## (nothing half-made is kept). Also does the hash check of a copy whose file date changed.

const GAME_FILTERS := ["*.iso, *.rvz, *.wbfs, *.gcz, *.ciso, *.wia, *.gcm, *.nkit.iso ; Wii disc images", "* ; All files"]

var key := "bt3"
var ver := "PAL"
var disc := ""          # "" = only the hash check of the existing copy
var done: Callable
var job
var _last_pct := -1


func setup(game_key: String, version: String, disc_path: String, on_done := Callable()) -> Control:
	key = game_key
	ver = version
	disc = disc_path.replace("\\", "/")
	done = on_done
	return self


func _init() -> void:
	super()
	notices = false


func _id() -> String:
	return String(Settings.GAMES[key]["versions"][ver])


func _name() -> String:
	return "%s %s" % [Settings.GAMES[key]["title"], Settings.version_name(key, ver)]


func screen_title() -> String:
	return _name()


func screen_music() -> String:
	return "main_menu"


func screen_desc() -> String:
	return _status()


func screen_hints() -> Array:
	return [["B", Style.POOR, "Stop"]] if job and job.state in ["checking", "building", "hashing"] else \
		[["A", Style.GOOD, "Select"], ["B", Style.POOR, "Back"]]


func on_enter() -> void:
	super()
	_start()


func _start() -> void:
	job = Discs.Job.new()
	if disc == "":
		job.start_check(_id())
	else:
		job.start(_id(), disc)
	list.set_rows(build_rows())
	app._refresh_hints()
	app.set_desc(current_desc())


func build_rows() -> Array:
	var rows: Array = []
	if disc != "":
		rows.append({"type": "info", "key": "disc", "label": "Your disc", "value": disc.get_file()})
	rows.append({"type": "info", "key": "progress", "label": "Progress", "value": _progress()})
	if job and not job.disc_info.is_empty():
		rows.append({"type": "info", "key": "found", "label": "Disc found",
			"value": "%s · %s %d" % [job.disc_info.get("game_id", "?"), tr("revision"), int(job.disc_info.get("revision", 0))]})
	if job and job.state == "failed":
		rows.append({"type": "action", "key": "pick", "label": "Pick another disc",
			"desc": _status()})
		rows.append({"type": "action", "key": "copy", "label": "Copy details",
			"desc": tr("Copies what went wrong (your disc's ID, revision and the files that differ)\nto paste in the support channel.")})
		if job.error in ["write", "crashed", "read"] and disc != "":
			rows.append({"type": "action", "key": "retry", "label": "Try again", "desc": _status()})
	rows.append({"type": "action", "key": "back", "label": "Back" if not _busy() else "Stop",
		"desc": _status()})
	return rows


func _busy() -> bool:
	return job != null and job.state in ["checking", "building", "hashing"]


func _progress() -> String:
	if job == null:
		return ""
	match job.state:
		"checking":
			return tr("Checking your disc: %d%%") % int(job.progress * 100.0 / 0.3)
		"building":
			return tr("Building: %d%%") % int((job.progress - 0.3) * 100.0 / 0.65)
		"hashing":
			return tr("Finishing...")
		"done":
			return tr("Done")
		"failed":
			return tr("Stopped")
	return ""


func _status() -> String:
	if job == null:
		return ""
	var n := _name()
	var orig_id := _id()
	match job.state:
		"checking":
			return tr("Checking that this is an original %s disc (%s), file by file.\nThis takes a few minutes.") % [ver, orig_id] \
				if disc != "" else tr("Checking your %s copy.") % n
		"building":
			return tr("Building %s from your disc into SparkingData/title.\nYour disc file isn't changed.") % n
		"hashing":
			return tr("Almost done...")
		"done":
			return tr("%s is ready.") % n
	match job.error:
		"no_tool":
			return tr("DolphinTool wasn't found next to Dolphin (%s).\nUpdate or reinstall the collection.") % job.detail.get_file()
		"wrong_game":
			var where: Array = Settings.game_of_id(job.detail)
			if not where.is_empty() and where[0] == key:
				return tr("That's the %s disc (%s). %s is built from the %s disc (%s).") % [
					where[1], job.detail, n, ver, orig_id]
			return tr("That isn't %s (it's %s). Pick your %s %s disc.") % [
				Settings.GAMES[key]["title"], job.detail, Settings.GAMES[key]["title"], ver]
		"wrong_revision":
			return tr("That's another revision of the disc (%s). %s is built from revision %d.") % [
				job.detail, n, int(Discs.info(orig_id).get("revision", 0))]
		"modified":
			return tr("That copy isn't the original disc: it's been modified or damaged\n(%s). Pick a clean copy of your own %s disc.") % [job.detail.left(220), ver]
		"read", "crashed":
			return tr("Your disc couldn't be read to the end (%s).\nThe file may be damaged or on a drive that was removed.") % job.detail
		"open", "not_disc":
			return tr("That file isn't a Wii disc image Dolphin can read.")
		"bad_recipe":
			return tr("The %s files from the last update are incomplete.\nRestart the launcher to finish the update, then try again.") % n
		"write":
			return tr("The new copy couldn't be written (is the drive full?).\nIt needs about as much space as your disc.")
		"changed":
			return tr("Your %s copy was changed or replaced.\nBuild it again from your disc.") % n
	return job.detail


func _process(_delta: float) -> void:
	if job == null:
		return
	var going: bool = job.poll()
	var pct := int(job.progress * 100.0)
	if pct != _last_pct:
		_last_pct = pct
		list.update_row("progress", {"value": _progress()})
		app.set_desc(current_desc())
	if going:
		return
	set_process(false)
	if job.state == "done":
		app.toast(tr("%s is ready.") % _name(), 4.0)
		app.pop()
		if done.is_valid():
			done.call()
		return
	list.set_rows(build_rows(), "pick")
	app._refresh_hints()
	app.set_desc(current_desc())


func on_press(k: String) -> void:
	match k:
		"pick":
			pick_disc(self, key, ver, func(path: String):
				disc = path.replace("\\", "/")
				set_process(true)
				_start())
		"retry":
			set_process(true)
			_start()
		"copy":
			DisplayServer.clipboard_set(job.report(_name()))
			app.toast(tr("Copied: paste it in the support channel."), 4.0)
		"back":
			on_back()


func on_back() -> void:
	if _busy():
		job.stop()
	app.pop()


## Asks for the disc a version is built from (its original), then `then.call(path)`.
static func pick_disc(screen: Control, game_key: String, version: String, then: Callable) -> void:
	var g: Dictionary = Settings.GAMES[game_key]
	screen.pick_path(false, GAME_FILTERS, Discs.candidate(game_key, version),
			TranslationServer.translate("Select your original %s %s disc (%s)") % [g["title"], version, g["versions"][version]],
			then)


## Picks the disc, then builds the copy (Options > Game Copies, Setup).
static func pick_and_build(screen: Control, game_key: String, version: String, on_done := Callable()) -> void:
	pick_disc(screen, game_key, version, func(path: String):
		screen.app.push(load("res://scripts/screens/disc_build.gd").new().setup(game_key, version, path, on_done)))
