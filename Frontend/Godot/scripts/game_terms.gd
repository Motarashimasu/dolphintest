extends Translation
## Each game's own words for its modes. Budokai Tenkaichi 2 calls its 2-vs-2 mode "Tag Battle";
## Tenkaichi 3 calls it "Team Battle". The scripts and translation tables say "Team Battle"; while
## the menus are on a game with its own name for it, every text that goes through the translation
## server (labels, tr(), TranslationServer.translate) gets that game's word instead.
##
## One of these is registered per language (Lang): `table` is that language's table ({} for
## English). A text with no swap left to make returns "" (= no translation: shown as it is).

## Per game: [language's text, the game's own] pairs, longest first. "en" applies to the English
## key too, so a translated text can be looked up under the game's own English key first.
const SWAPS := {
	"bt2": {
		"en": [["Team Battle", "Tag Battle"]],
		"es": [["Combate por equipos", "Combate Tag"], ["combate por equipos", "combate Tag"],
			["Por equipos", "Tag"], ["el de equipos", "el Tag"], ["por equipos", "Tag"]],
		"it": [["Battaglia a squadre", "Battaglia Tag"], ["battaglia a squadre", "battaglia Tag"],
			["Scontro a squadre", "Scontro Tag"], ["scontro a squadre", "scontro Tag"],
			["quello a squadre", "quello Tag"], ["A squadre", "Tag"], ["a squadre", "Tag"]],
	},
}

var table := {}   # this language's table: English text -> translated text


func _get_message(src_message: StringName, _context: StringName) -> StringName:
	var src := String(src_message)
	var swaps: Dictionary = SWAPS.get(String(Settings.game), {})
	var found = table.get(src)
	if swaps.is_empty():
		return StringName(found) if found != null else &""
	# The game's own English text has its own translation? (e.g. a "Tag Battle" entry)
	var own_en := _swap(src, swaps.get("en", []))
	if own_en != src and table.has(own_en):
		return StringName(table[own_en])
	if found != null:
		return StringName(_swap(String(found), swaps.get(locale, [])))
	if locale == "en":
		return StringName(own_en) if own_en != src else &""
	# Not a table text (already translated, or built from pieces): swap this language's words.
	var own := _swap(_swap(src, swaps.get("en", [])), swaps.get(locale, []))
	return StringName(own) if own != src else &""


static func _swap(text: String, pairs: Array) -> String:
	for p in pairs:
		if text.contains(p[0]):
			text = text.replace(p[0], p[1])
	return text
