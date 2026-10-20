extends Translation
## Each game's own words for its modes. Budokai Tenkaichi 2 calls its 2-vs-2 mode "Tag Battle";
## Tenkaichi 3 calls it "Team Battle". The scripts and translation tables say "Team Battle"; while
## the menus are on a game with its own name for it, every text that goes through the translation
## server (labels, tr(), TranslationServer.translate) gets that game's word instead.
## Also each language's own names for the games (LANG_SWAPS: the Japanese releases' names).
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
		"ja": [["チームバトル", "タッグバトル"]],
	},
}

## Per language, whatever game the menus are on: the games' own names there, longest first. The
## Japanese releases are Sparking! METEOR (Tenkaichi 3) and Sparking! NEO (Tenkaichi 2): the
## scripts' English names (Settings.GAMES title / short / full_title) become those in every text
## shown, also in texts built from pieces ("Your %s copy...").
const LANG_SWAPS := {
	"ja": [["Dragon Ball Z: Budokai Tenkaichi 3", "ドラゴンボールZ Sparking! METEOR"],
		["Dragon Ball Z: Budokai Tenkaichi 2", "ドラゴンボールZ Sparking! NEO"],
		["Budokai Tenkaichi 3", "Sparking! METEOR"], ["Budokai Tenkaichi 2", "Sparking! NEO"],
		["Tenkaichi 3", "Sparking! METEOR"], ["Tenkaichi 2", "Sparking! NEO"]],
}

var table := {}   # this language's table: English text -> translated text


func _get_message(src_message: StringName, _context: StringName) -> StringName:
	var src := String(src_message)
	var swaps: Dictionary = SWAPS.get(String(Settings.game), {})
	var names: Array = LANG_SWAPS.get(locale, [])
	var found = table.get(src)
	var out := ""
	if swaps.is_empty():
		out = String(found) if found != null else src
	else:
		# The game's own English text has its own translation? (e.g. a "Tag Battle" entry)
		var own_en := _swap(src, swaps.get("en", []))
		if own_en != src and table.has(own_en):
			out = String(table[own_en])
		elif found != null:
			out = _swap(String(found), swaps.get(locale, []))
		elif locale == "en":
			out = own_en
		else:
			# Not a table text (already translated, or built from pieces): swap this language's words.
			out = _swap(own_en, swaps.get(locale, []))
	out = _swap(out, names)
	return StringName(out) if found != null or out != src else &""


static func _swap(text: String, pairs: Array) -> String:
	for p in pairs:
		if text.contains(p[0]):
			text = text.replace(p[0], p[1])
	return text
