extends RefCounted
## Controller presets: Dolphin GameCube pad profiles (.ini with a [Profile] section) that the
## frontend copies into the profile's Config/GCPadNew.ini as [GCPad1], the mapping the game
## uses (offline and in netplay). Presets come from two places, the second winning on a name
## clash:
##   res://presets/controllers/*.ini        shipped with the frontend
##   <SparkingData>/controllers/*.ini       your own (Save current mapping, or copy Dolphin
##                                           profiles from User/Config/Profiles/GCPad here)
## An optional [Sparking] section with `Match = xbox, xinput` lets "Auto" pick the preset when
## a controller with one of those words in its name is connected. Dolphin ignores that section.
## (No class_name, so the project runs without the editor's class cache: `preload` this.)

const BUILTIN_DIR := "res://presets/controllers"
const AUTO := "auto"   # pick by connected controller, else keep
const KEEP := "keep"   # leave GCPadNew.ini as it is


static func user_dir() -> String:
	return Settings.data_path("controllers")


static func gcpad_path() -> String:
	return Settings.data_path(Settings.get_value("paths", "profile")).path_join("Config/GCPadNew.ini")


## Dolphin-style ini: {section: [[key, value], ...]} keeping order. Keys are the raw text left of
## the first " = " / "=", values are everything right of it (backticks, |, & kept as-is).
static func parse_ini(text: String) -> Dictionary:
	var out := {}
	var section := ""
	for raw in text.split("\n"):
		var line := raw.strip_edges()
		if line == "" or line.begins_with("#") or line.begins_with(";"):
			continue
		if line.begins_with("[") and line.ends_with("]"):
			section = line.substr(1, line.length() - 2)
			if not out.has(section):
				out[section] = []
			continue
		var eq := line.find("=")
		if eq < 0 or section == "":
			continue
		out[section].append([line.substr(0, eq).strip_edges(), line.substr(eq + 1).strip_edges()])
	return out


static func write_ini(sections: Dictionary) -> String:
	var lines := PackedStringArray()
	for s in sections:
		lines.append("[%s]" % s)
		for kv in sections[s]:
			lines.append("%s = %s" % [kv[0], kv[1]])
	return "\n".join(lines) + "\n"


static func _value(pairs: Array, key: String, default := "") -> String:
	for kv in pairs:
		if kv[0] == key:
			return kv[1]
	return default


static func _load_dir(dir: String, into: Dictionary, builtin: bool) -> void:
	var d := DirAccess.open(dir)
	if d == null:
		return
	for f in d.get_files():
		if f.get_extension().to_lower() != "ini":
			continue
		var path := dir.path_join(f)
		var ini := parse_ini(FileAccess.get_file_as_string(path))
		var keys: Array = ini.get("Profile", ini.get("GCPad1", []))
		if keys.is_empty():
			continue
		var match_words: Array = []
		for w in _value(ini.get("Sparking", []), "Match").split(",", false):
			match_words.append(w.strip_edges().to_lower())
		var name := f.get_basename()
		into[name] = {"name": name, "path": path, "builtin": builtin, "keys": keys,
			"device": _value(keys, "Device", "?"), "match": match_words,
			"notes": _value(ini.get("Sparking", []), "Notes")}


## Every preset, sorted by name.
static func list() -> Array:
	var all := {}
	_load_dir(BUILTIN_DIR, all, true)
	_load_dir(user_dir(), all, false)
	var names := all.keys()
	names.sort_custom(func(a, b): return String(a).naturalnocasecmp_to(b) < 0)
	var out: Array = []
	for n in names:
		out.append(all[n])
	return out


static func find(name: String) -> Dictionary:
	for p in list():
		if p["name"] == name:
			return p
	return {}


static func connected_pads() -> PackedStringArray:
	var names := PackedStringArray()
	for id in Input.get_connected_joypads():
		names.append(Input.get_joy_name(id))
	return names


## The preset "Auto" would use right now (first connected pad that matches one), or {}.
static func auto_pick() -> Dictionary:
	var presets := list()
	for pad in connected_pads():
		var lower := pad.to_lower()
		for p in presets:
			for w in p["match"]:
				if w != "" and w in lower:
					return p
	return {}


## The preset the current setting resolves to ({} = keep GCPadNew.ini as it is).
static func selected() -> Dictionary:
	var choice: String = Settings.get_value("controller", "preset")
	if choice == KEEP:
		return {}
	if choice == AUTO:
		return auto_pick()
	return find(choice)


## Writes a preset into GCPadNew.ini as [GCPad1]; other sections (ports 2-4) are kept.
static func apply(preset: Dictionary) -> bool:
	if preset.is_empty():
		return false
	var path := gcpad_path()
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var ini := parse_ini(FileAccess.get_file_as_string(path)) if FileAccess.file_exists(path) else {}
	var sections := {"GCPad1": preset["keys"]}
	for s in ini:
		if s != "GCPad1":
			sections[s] = ini[s]
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return false
	f.store_string(write_ini(sections))
	return true


## Called before every game launch.
static func apply_selected() -> void:
	apply(selected())


## The mapping currently in GCPadNew.ini's [GCPad1].
static func current_keys() -> Array:
	var path := gcpad_path()
	if not FileAccess.file_exists(path):
		return []
	return parse_ini(FileAccess.get_file_as_string(path)).get("GCPad1", [])


## Saves the current [GCPad1] mapping as <SparkingData>/controllers/<name>.ini.
static func save_current_as(name: String) -> String:
	var keys := current_keys()
	if keys.is_empty():
		return ""
	var clean := name.strip_edges().validate_filename()
	if clean == "":
		return ""
	DirAccess.make_dir_recursive_absolute(user_dir())
	var path := user_dir().path_join(clean + ".ini")
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return ""
	f.store_string(write_ini({"Profile": keys}))
	return clean


## Short "A = ..., B = ..." line for the description bar.
static func summary(preset: Dictionary) -> String:
	var parts: Array = []
	for b in ["A", "B", "X", "Y", "Z", "Start"]:
		var v := _value(preset.get("keys", []), "Buttons/" + b)
		if v != "":
			parts.append("%s: %s" % [b, v.replace("`", "")])
	return ",  ".join(parts)
