extends "res://scripts/screens/form_screen.gd"
## Modifications > Training Display: hitboxes and frame data in offline games, from the Stats &
## Frame Data Overlay of BT3 Phantom Mods (used with its creator's permission). Just the switch:
## on, the next offline game shows them from the start. Never online: DRAGON NET matches and
## replays run without it (Settings.solo_args only).


func _init() -> void:
	super()
	notices = false


func screen_music() -> String:
	return "game_menu"


func screen_title() -> String:
	return "Training Display"


func screen_desc() -> String:
	return "Hitboxes and frame data in offline games.\nNever online: DRAGON NET matches always run without it."


func build_rows() -> Array:
	var available := Settings.training_display_available()
	return [
		{"type": "toggle", "key": "training_display", "label": "Training Display",
			"value": bool(Settings.get_value("options", "training_display")) and available,
			"disabled": not available, "on_text": "On", "off_text": "Off",
			"desc": "Hitboxes and frame data in your next offline game.\nNever online." if available
				else "Made for the PAL version (Sparking! 4.0) for now: pick it in\nOptions > Game Copies to use the Training Display."},
	]


func on_value(key: String, value: Variant) -> void:
	if key == "training_display":
		Settings.set_value("options", "training_display", bool(value))
		app.toast(tr("Training Display: on from your next offline game.") if value else tr("Training Display: off."), 3.0)
