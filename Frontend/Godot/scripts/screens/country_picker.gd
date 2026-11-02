extends "res://scripts/screens/form_screen.gd"
## Your Account > Country: the flag on your DRAGON NET profile card. Every country, by name
## (type the first letters on a keyboard to jump), or None.

const Flags := preload("res://scripts/flags.gd")

var _busy := false
var _typed := ""
var _typed_at := 0


func screen_music() -> String:
	return "netplay"


func screen_title() -> String:
	return "Country"


func screen_desc() -> String:
	return "The flag on your DRAGON NET profile card."


func build_rows() -> Array:
	var rows: Array = [{"type": "action", "key": "none", "label": "None",
		"value": tr("Now") if Ranked.country() == "" else "", "desc": "No flag on your profile card."}]
	for c in Flags.countries():
		rows.append({"type": "action", "key": String(c[0]), "label": String(c[1]), "flag": String(c[0]),
			"value": tr("Now") if Ranked.country() == c[0] else "",
			"desc": tr("Show this flag on your profile card: %s.") % c[1]})
	rows.append({"type": "action", "key": "back", "label": "Back", "desc": "Back to your account."})
	return rows


func on_enter() -> void:
	super()
	list.focus_key(Ranked.country() if Ranked.country() != "" else "none")


## A keyboard: typing letters jumps to the first country starting with them.
func on_input(event: InputEvent) -> bool:
	if event is InputEventKey and event.pressed and not event.echo \
			and event.keycode >= KEY_A and event.keycode <= KEY_Z and not event.ctrl_pressed:
		var ch := char(event.keycode).to_lower()
		if Time.get_ticks_msec() - _typed_at > 900:
			_typed = ""
		_typed += ch
		_typed_at = Time.get_ticks_msec()
		for c in Flags.countries():
			if String(c[1]).to_lower().begins_with(_typed):
				list.focus_key(String(c[0]))
				return true
		return true
	return super(event)


func on_press(key: String) -> void:
	if key == "back":
		on_back()
		return
	if _busy:
		return
	_busy = true
	var code := "" if key == "none" else key
	var res: Dictionary = await Ranked.set_country(code)
	_busy = false
	if not is_inside_tree():
		return
	if res.get("ok", false):
		app.toast(tr("Country: %s") % (Flags.country_name(code) if code != "" else tr("None")))
		app.pop()
	else:
		app.toast(Ranked.error_text(String(res.get("error", ""))), 4.0)
