extends "res://scripts/screens/form_screen.gd"
## DRAGON NET > Quick Match: searching the pool for a Single Battle opponent (scripts/
## quick_match.gd does the work). Buffer Training can be played while waiting: the Accept /
## Decline pop-up comes up over it when someone is found. Leaving this screen stops searching.


func _init() -> void:
	super()
	notices = false


func screen_music() -> String:
	return "netplay"


func screen_title() -> String:
	return "Quick Match"


func screen_desc() -> String:
	return "Single Battle against the next player who's searching.\nPlay Buffer Training while you wait: you'll be asked when a match is found."


func on_enter() -> void:
	super()
	QuickMatch.changed.connect(_on_changed)
	if QuickMatch.state == "idle":
		QuickMatch.start()
	_tick()


func on_resume() -> void:
	super()
	_on_changed()


func _exit_tree() -> void:
	if QuickMatch.changed.is_connected(_on_changed):
		QuickMatch.changed.disconnect(_on_changed)
	QuickMatch.stop()


func _tick() -> void:
	# The waiting time counts up.
	while is_inside_tree():
		if list and QuickMatch.state == "searching":
			list.update_row("status", {"value": _status()})
		await get_tree().create_timer(1.0).timeout


func _on_changed() -> void:
	if is_inside_tree() and list and app.top() == self:
		list.set_rows(build_rows(), list.current_key())


func _status() -> String:
	var name := String(QuickMatch.opponent.get("name", "?"))
	match QuickMatch.state:
		"searching":
			var secs := maxi(0, int(Time.get_unix_time_from_system()) - QuickMatch.since)
			return tr("Searching for a player...  %s") % ("%d:%02d" % [secs / 60, secs % 60])
		"connecting":
			return tr("Found %s: connecting...") % name
		"asking":
			return tr("Found %s") % name
		"waiting":
			return tr("Waiting for %s to accept...") % name
		"starting":
			return tr("Both accepted: starting...")
		"failed":
			return tr("Quick Match isn't available: %s") % QuickMatch.error
	return tr("Not searching")


func build_rows() -> Array:
	var rows: Array = [{"type": "info", "key": "status", "label": "Quick Match", "value": _status(),
		"desc": QuickMatch.error if QuickMatch.error != "" else screen_desc()}]
	if QuickMatch.state in ["searching", "connecting", "asking", "waiting"]:
		rows.append({"type": "info", "key": "pool", "label": "Players searching",
			"value": str(maxi(QuickMatch.searching, 1 if QuickMatch.state == "searching" else 0)),
			"desc": "Players searching right now, you included."})
		rows.append({"type": "action", "key": "training", "label": "Buffer Training", "color": "#3fbf6b",
			"disabled": Dolphin.is_running(),
			"desc": "Play while you wait. When a match is found you're asked to accept;\nif both accept, training closes and the match starts."})
		rows.append({"type": "action", "key": "stop", "label": "Stop searching", "color": "#e8663d",
			"desc": "Leave the Quick Match pool."})
	else:
		rows.append({"type": "action", "key": "search", "label": "Search again", "color": "#3fbf6b",
			"desc": "Back into the Quick Match pool."})
		rows.append({"type": "action", "key": "back", "label": "Back", "desc": "Back to the DRAGON NET menu."})
	return rows


func on_press(key: String) -> void:
	match key:
		"training":
			app.open_buffer_training()
		"search":
			QuickMatch.start()
		"stop":
			QuickMatch.stop()
			on_back()
		_:
			super(key)
