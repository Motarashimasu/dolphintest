extends "res://scripts/screens/form_screen.gd"
## The automatic update (scripts/updater.gd): opened when a newer build is found (at start, or
## from Options > Updates), it downloads and installs it right away and shows the progress.
## Back = Later: stops the download (what's downloaded is kept for next time) and goes on to
## the menus with this build.


var _shown := ""


func _init() -> void:
	super()
	notices = false


func screen_title() -> String:
	return "Update"


func screen_desc() -> String:
	return _status()


func screen_hints() -> Array:
	return [["B", Style.POOR, "Later"]] if Updater.busy() and Updater.state != "restarting" else \
		[["A", Style.GOOD, "Select"], ["B", Style.POOR, "Back"]]


func build_rows() -> Array:
	var rows := [
		{"type": "info", "key": "version", "label": "Version", "value": Updater.version},
		{"type": "info", "key": "progress", "label": "Downloaded", "value": _progress()},
	]
	if Updater.notes != "":
		rows.append({"type": "info", "key": "notes", "label": "What's new", "value": Updater.notes})
	if Updater.state == "failed":
		rows.append({"type": "action", "key": "retry", "label": "Try again", "desc": _status()})
	rows.append({"type": "action", "key": "later", "label": "Later"})
	return rows


func on_enter() -> void:
	super()
	Updater.changed.connect(_on_changed)
	if Updater.state == "available":
		Updater.install()


func _exit_tree() -> void:
	if Updater.changed.is_connected(_on_changed):
		Updater.changed.disconnect(_on_changed)


func _on_changed() -> void:
	if not is_inside_tree():
		return
	list.update_row("progress", {"value": _progress()})
	app.set_desc(current_desc())
	if Updater.state != _shown:
		_shown = Updater.state
		app._refresh_hints()
	if Updater.state == "up_to_date":
		app.toast(tr("Updated to version %s.") % Updater.version, 4.0)
		app.pop()
	elif Updater.state in ["failed", "idle"]:
		list.set_rows(build_rows())


func _progress() -> String:
	return "%.1f / %.1f MB" % [Updater.done_bytes / 1048576.0, Updater.total_bytes / 1048576.0]


func _status() -> String:
	match Updater.state:
		"available", "downloading":
			return tr("Downloading version %s: %d files.\nBack: later (the update is tried again next time).") % [
				Updater.version, Updater.file_count]
		"applying":
			return "Installing..."
		"restarting":
			return "Restarting to finish the update..."
		"failed":
			return Updater.result_text()
		"idle":
			return "Update stopped. It's tried again next time."
	return ""


func on_press(key: String) -> void:
	if key == "retry":
		Updater.check()
		list.set_rows(build_rows())
	elif key == "later":
		on_back()


func on_back() -> void:
	if Updater.state == "restarting":
		return
	Updater.cancel()
	app.pop()
