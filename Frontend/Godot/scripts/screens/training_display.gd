extends "res://scripts/screens/form_screen.gd"
## Modifications > Training Display: hitboxes, hurtboxes, pushboxes, stats and frame data in
## offline games, from the Stats & Frame Data Overlay of BT3 Phantom Mods (used with its
## creator's permission). One switch here; the overlay's own shortcut shows each display in the
## match. Never online: DRAGON NET matches and replays run without it (Settings.solo_args only).


func _init() -> void:
	super()
	notices = false


func screen_music() -> String:
	return "game_menu"


func screen_title() -> String:
	return "Training Display"


func screen_desc() -> String:
	return "Hitboxes, hurtboxes and frame data in offline games.\nNever online: DRAGON NET matches always run without it."


func build_rows() -> Array:
	var available := Settings.training_display_available()
	var on := bool(Settings.get_value("options", "training_display"))
	var rows: Array = [
		{"type": "toggle", "key": "training_display", "label": "Training Display", "value": on and available,
			"disabled": not available, "on_text": "On", "off_text": "Off",
			"desc": "On: your next offline game starts with the overlay loaded (it can't be added to a\ngame that's already running). Offline only." if available
				else "Made for the PAL version (Sparking! 4.0) for now: pick it in\nOptions > Game Copies to use the Training Display."},
		{"type": "info", "key": "show", "label": "Show it in a match", "value": "Camera Type + Ascend + Descend",
			"desc": "Hold all three for every display, or add a direction for one:\nUp: Stats   Down: Frame Data   Left: Hurtboxes   Right: Hitboxes   Transform: Pushboxes."},
		{"type": "info", "key": "frames", "label": "Frame data", "value": "Startup · Active · Recovery",
			"desc": "Each action's startup, active and recovery frames, total frames and frame advantage,\nwith fighter and projectile timelines. Read-only: it changes nothing in the fight."},
		{"type": "info", "key": "settings", "label": "Its settings", "value": "Game Options > Right",
			"desc": "In the game's Options menu, press Right for Mod Settings > Stats And Frame Data Overlay:\nwhich readings to show, where the boxes sit. Nothing shows? Switch its overlay on there."},
		{"type": "info", "key": "credit", "label": "Made by", "value": "BT3 Phantom Mods",
			"desc": "The Stats & Frame Data Overlay from BT3 Phantom Mods, included with its creator's permission.\nIt runs with a faster emulated CPU, as its creator sets it up."},
		{"type": "action", "key": "back", "label": "Back", "desc": "Back to Modifications."},
	]
	return rows


func on_value(key: String, value: Variant) -> void:
	if key == "training_display":
		Settings.set_value("options", "training_display", bool(value))
		app.toast(tr("Training Display: on from your next offline game.") if value else tr("Training Display: off."), 3.0)
