extends Node
## Languages: English (the text in the scripts), Spanish and Italian.
##
## Every text the menus show is written in English in the scripts; Godot looks it up in the
## current language's table when it draws a label (Labels translate their text automatically),
## and code that builds text from pieces calls tr() on the template first.
## The tables are data/translations/<code>.json: { "English text": "translated text", ... }.
## A text missing from a table is simply shown in English. Edit them with any text editor.

const LANGUAGES := ["en", "es", "it"]
const NAMES := {"en": "English", "es": "Español", "it": "Italiano"}
const DIR := "res://data/translations/"

var _loaded := {}   # code -> Translation


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	apply()


## The chosen language ("" = not chosen yet: the first launch asks).
func current() -> String:
	return String(Settings.get_value("options", "language"))


func chosen() -> bool:
	return current() in LANGUAGES


func set_language(code: String) -> void:
	Settings.set_value("options", "language", code)
	apply()


func apply() -> void:
	var code := current() if chosen() else "en"
	if code != "en" and not _loaded.has(code):
		var t := load_table(code)
		if t:
			TranslationServer.add_translation(t)
			_loaded[code] = t
	TranslationServer.set_locale(code)


static func load_table(code: String) -> Translation:
	var path := DIR + code + ".json"
	if not FileAccess.file_exists(path):
		return null
	var data = JSON.parse_string(FileAccess.get_file_as_string(path))
	if not data is Dictionary:
		push_warning("Bad translation file: " + path)
		return null
	var t := Translation.new()
	t.locale = code
	for k in data:
		if String(k).begins_with("_"):
			continue   # "_comment" etc.
		var v := String(data[k])
		if v != "":
			t.add_message(String(k), v)
	return t


## For static code (no Node.tr()).
static func t(text: String) -> String:
	return TranslationServer.translate(text)
