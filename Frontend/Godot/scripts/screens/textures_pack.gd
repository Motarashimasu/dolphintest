extends "res://scripts/screens/form_screen.gd"
## Options > Enhanced textures: the HD texture pack is an optional download (an Updater pack),
## not part of the update. Download gets only it, and only the files that aren't already here
## with the right content (a copy from an older install is found and kept). Once here it's kept
## up to date with the updates. Remove deletes it again. The download carries on while the
## player leaves this screen (Options shows its progress).

var pack := Updater.TEXTURES_PACK
var _shown := ""


func _init() -> void:
	super()
	notices = false


func screen_title() -> String:
	return "Enhanced textures"


func screen_desc() -> String:
	return "The HD texture pack: sharper characters, stages and menus.\nAn optional download: the game works without it (Legacy textures)."


func _downloading() -> bool:
	return Updater.pack_job == pack and Updater.busy()


func build_rows() -> Array:
	var info := Updater.pack_info(pack)
	var rows: Array = [{"type": "info", "key": "status", "label": "Status", "value": _status(info)}]
	if info["known"]:
		rows.append({"type": "info", "key": "size", "label": "Size",
			"value": tr("%s  (%d files)") % [_size(int(info["bytes"])), int(info["files"])]})
	if _downloading() or (Updater.pack_job == pack and Updater.state in ["failed", "idle"]):
		rows.append({"type": "info", "key": "progress", "label": "Downloaded", "value": _progress()})
	if _downloading():
		rows.append({"type": "action", "key": "stop", "label": "Stop",
			"desc": "Stop the download. What's downloaded is kept: Download carries on from there."})
	else:
		var have := bool(info["installed"])
		rows.append({"type": "action", "key": "download", "label": "Check for damaged files" if have else "Download",
			"desc": "Compares your files with the current pack and downloads only what's missing or different." if have \
				else "Downloads the pack (only the files you don't have yet).\nNeeds a DRAGON NET login. You can keep using the menus meanwhile."})
		if int(info["present"]) > 0:
			rows.append({"type": "action", "key": "remove", "label": "Remove",
				"desc": "Deletes the pack's files to free the space. Graphics: Enhanced then shows\nthe original textures. You can download it again any time."})
	rows.append({"type": "action", "key": "back", "label": "Back",
		"desc": "Back to Options. A download carries on meanwhile." if _downloading() else "Back to Options."})
	return rows


func _status(info: Dictionary) -> String:
	if Updater.pack_job == pack:
		match Updater.state:
			"checking":
				return tr("Checking your files...")
			"downloading":
				return tr("Downloading: %d files") % Updater.file_count
			"applying":
				return tr("Installing...")
			"failed", "no_login", "off":
				return Updater.result_text()
			"idle":
				return tr("Stopped. Download carries on from where it was.")
	if not info["known"]:
		if Updater.state == "failed" or Updater.state == "no_login":
			return Updater.result_text()
		return tr("Installed") if info["wanted"] else tr("Unknown yet: Download checks it")
	if info["installed"]:
		return tr("Installed")
	if int(info["present"]) > 0:
		return tr("Partly here (%d of %d files)") % [int(info["present"]), int(info["files"])]
	return tr("Not installed")


static func _size(b: int) -> String:
	return "%.1f GB" % (b / 1073741824.0) if b >= 1073741824 else "%.0f MB" % ceil(b / 1048576.0)


func _progress() -> String:
	return "%s / %s" % [_size(Updater.done_bytes), _size(Updater.total_bytes)]


func on_enter() -> void:
	super()
	Updater.changed.connect(_on_changed)


func _exit_tree() -> void:
	if Updater.changed.is_connected(_on_changed):
		Updater.changed.disconnect(_on_changed)


func _on_changed() -> void:
	if not is_inside_tree() or app.top() != self:
		return
	if Updater.state != _shown:
		_shown = Updater.state
		list.set_rows(build_rows(), list.current_key())
		app._refresh_hints()
	else:
		list.update_row("progress", {"value": _progress()})
		list.update_row("status", {"value": _status(Updater.pack_info(pack))})
	app.set_desc(current_desc())


func on_press(key: String) -> void:
	match key:
		"download":
			if Dolphin.is_running():
				app.toast(tr("Close the game first."), 3.0)
				return
			if Updater.busy():
				app.toast(tr("An update is running: try again when it's done."), 3.0)
				return
			var was := bool(Updater.pack_info(pack)["installed"])
			var end: String = await Updater.install_pack(pack)
			if not is_inside_tree():
				return
			list.set_rows(build_rows(), "back")
			if end == "up_to_date" and Updater.pack_job == pack:
				app.toast(tr("Enhanced textures: all files OK.") if was and Updater.file_count == 0 \
					else tr("Enhanced textures installed."), 4.0)
				Sfx.play("select")
		"stop":
			Updater.cancel()
		"remove":
			var m: Control = app.menu("Remove Enhanced textures?", [
				{"label": "Remove", "glyph": "X", "color": "#e8663d",
					"desc": "Delete the pack's files. You can download it again any time.",
					"action": func():
						app.pop()
						var n: int = await Updater.remove_pack(pack)
						if is_inside_tree():
							list.set_rows(build_rows(), "back")
							app.toast(tr("Close the game first.") if n < 0 else tr("Enhanced textures removed."), 3.0)},
				{"label": "Keep", "glyph": "B", "color": "#8a9bb0", "back": true, "desc": "Keep the pack."},
			], "main_menu")
			m.notices = false
			app.push(m)
		_:
			super(key)
