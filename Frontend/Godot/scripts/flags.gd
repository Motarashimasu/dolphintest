extends RefCounted
## Country flags for DRAGON NET profiles: data/flags/flags.png holds every flag (48 x 36, from
## flag-icons, MIT: data/flags/LICENSE-flag-icons.txt), flags.json where each one is.
## Codes are ISO 3166-1 alpha-2 in lowercase ("it"), plus "gb-eng" / "gb-sct" / "gb-wls".

const ATLAS := "res://data/flags/flags.png"
const INDEX := "res://data/flags/flags.json"

static var _index := {}
static var _atlas: Texture2D
static var _cache := {}


static func _load() -> void:
	if not _index.is_empty():
		return
	var data = JSON.parse_string(FileAccess.get_file_as_string(INDEX))
	_index = data if data is Dictionary else {"flags": {}}
	_atlas = load(ATLAS)


static func has(code: String) -> bool:
	_load()
	return _index.get("flags", {}).has(code)


## The flag of `code`, or null.
static func texture(code: String) -> Texture2D:
	_load()
	if _cache.has(code):
		return _cache[code]
	var flags: Dictionary = _index.get("flags", {})
	if not flags.has(code) or _atlas == null:
		return null
	var i := int(flags[code])
	var w := int(_index.get("w", 48))
	var h := int(_index.get("h", 36))
	var cols := int(_index.get("cols", 16))
	var t := AtlasTexture.new()
	t.atlas = _atlas
	t.region = Rect2((i % cols) * w, (i / cols) * h, w, h)
	_cache[code] = t
	return t


## The country's name in the menu language.
static func country_name(code: String) -> String:
	_load()
	var extra: Dictionary = _index.get("names", {})
	if extra.has(code):
		return TranslationServer.translate(String(extra[code]))
	return TranslationServer.get_country_name(code.to_upper())


## Every country, sorted by name: [[code, name], ...].
static func countries() -> Array:
	_load()
	var out: Array = []
	for code in _index.get("flags", {}):
		out.append([code, country_name(code)])
	out.sort_custom(func(a, b): return String(a[1]).naturalnocasecmp_to(String(b[1])) < 0)
	return out
