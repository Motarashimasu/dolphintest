extends Node
## The collection's own game copies (Docs/DISCS.md). For a version with a recipe
## (SparkingData/discs/<disc ID>/recipe.json, sent by updates), the launcher doesn't play the
## player's disc image: it builds its own copy from it (Tools/sparking_disc.py, DolphinTool's
## sparking-disc), e.g. Sparking! 4.0 from the player's original PAL disc, into
## SparkingData/title/<ID>.rvz, and plays only that.
##
## The copy is locked: its size, date and SHA-256 are kept in the settings ([discs]); if the file
## is replaced or changed it no longer counts as a copy until it's built again from a disc (a full
## hash check first, in case only its date changed). A new recipe (an update of 4.0) makes it
## "outdated": built again from the same original disc, which is remembered.
##
## Versions without a recipe work as before: the picked disc image is played as it is.

const STATES := ["none", "ready", "missing", "changed", "outdated"]


static func recipe_path(id: String) -> String:
	return Settings.data_path("discs/%s/recipe.json" % id) if Settings.data_dir() != "" else ""


static func has_recipe(id: String) -> bool:
	return id != "" and recipe_path(id) != "" and FileAccess.file_exists(recipe_path(id))


static var _info_cache := {}

## The recipe's name ("4.0"), disc ID and revision of the original (the big lists aren't kept).
static func info(id: String) -> Dictionary:
	if not has_recipe(id):
		return {}
	var p := recipe_path(id)
	var stamp := "%d:%d" % [FileAccess.get_modified_time(p), _size(p)]
	if _info_cache.get(id, {}).get("stamp", "") == stamp:
		return _info_cache[id]
	var d = JSON.parse_string(FileAccess.get_file_as_string(p))
	var out := {"stamp": stamp, "name": id, "game_id": id, "revision": 0, "made": ""}
	if d is Dictionary:
		out["name"] = String(d.get("name", id))
		out["game_id"] = String(d.get("game_id", id))
		out["revision"] = int(d.get("revision", 0))
		out["made"] = String(d.get("made", ""))
	_info_cache[id] = out
	return out


## What players see for a version: the recipe's name ("4.0"), else the version ("NTSC-J").
static func version_name(key: String, ver: String) -> String:
	var id := String(Settings.GAMES[key]["versions"].get(ver, ""))
	return String(info(id).get("name", ver)) if has_recipe(id) else ver


static func built_path(id: String) -> String:
	return Settings.data_path("title/%s.rvz" % id)


static func _size(path: String) -> int:
	var f := FileAccess.open(path, FileAccess.READ)
	return f.get_length() if f else -1


static func _lock(id: String, field: String) -> Variant:
	return Settings._cfg.get_value("discs", "%s_%s" % [id, field], "")


static func _set_lock(id: String, fields: Dictionary) -> void:
	for k in fields:
		Settings._cfg.set_value("discs", "%s_%s" % [id, k], fields[k])
	Settings._cfg.save(Settings._path)


## The player's original disc this copy was built from ("" = none yet).
static func original(id: String) -> String:
	return String(_lock(id, "original"))


## "none" (no recipe: the old way), "ready", "missing" (never built, or the file is gone),
## "changed" (the file isn't the one built: needs the hash check), "outdated" (a new recipe).
static func state(id: String) -> String:
	if not has_recipe(id):
		return "none"
	var p := built_path(id)
	if String(_lock(id, "sha256")) == "" or not FileAccess.file_exists(p):
		return "missing"
	if _size(p) != int(_lock(id, "size")) or FileAccess.get_modified_time(p) != int(_lock(id, "mtime")):
		return "changed"
	if String(_lock(id, "recipe")) != FileAccess.get_sha256(recipe_path(id)):
		return "outdated"
	return "ready"


static func ready(id: String) -> bool:
	return state(id) == "ready"


## The disc image to start building from: the remembered original, else the copy the player
## picked before recipes (the old [games] path, unless that's the built copy itself).
static func candidate(key: String, ver: String) -> String:
	var id := String(Settings.GAMES[key]["versions"][ver])
	for p in [original(id), String(Settings._cfg.get_value("games", "%s_%s" % [key, ver], ""))]:
		if p != "" and p != built_path(id) and FileAccess.file_exists(p):
			return p
	return ""


## Versions with a recipe whose copy needs the player's attention at start: built before but
## not ready now, or a copy picked before recipes existed (it becomes the candidate original).
static func pending() -> Array:
	var out: Array = []
	if Settings.data_dir() == "":
		return out
	for key in Settings.GAME_ORDER:
		for ver in Settings.VERSIONS:
			var id := String(Settings.GAMES[key]["versions"][ver])
			var s := state(id)
			if s in ["changed", "outdated"] or (s == "missing" and candidate(key, ver) != ""):
				out.append([key, ver])
	return out


## Forget the built copy (and delete it: it's only the launcher's).
static func remove(id: String) -> void:
	if FileAccess.file_exists(built_path(id)):
		DirAccess.remove_absolute(built_path(id))
	_set_lock(id, {"sha256": "", "size": 0, "mtime": 0, "recipe": ""})


## DolphinTool, next to Dolphin.
static func tool_path() -> String:
	var dir := Settings.dolphin_path().get_base_dir()
	return dir.path_join("DolphinTool.exe" if OS.get_name() == "Windows" else "dolphin-tool")


static func hash_file(path: String) -> String:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return ""
	var hc := HashingContext.new()
	hc.start(HashingContext.HASH_SHA256)
	while f.get_position() < f.get_length():
		hc.update(f.get_buffer(4 << 20))
	return hc.finish().hex_encode()


## One build (or hash check) of a copy, run in the background: poll() it each frame.
##   state: "checking" (the player's disc), "building", "hashing", "done", "failed", "stopped"
##   progress: 0..1 over the whole job. error / detail: dolphin-tool's error code and text.
class Job:
	extends RefCounted
	var id := ""
	var disc := ""
	var state := "checking"
	var progress := 0.0
	var error := ""
	var detail := ""
	var pid := -1
	var _thread: Thread
	var _mutex := Mutex.new()
	var _lines: Array[String] = []
	var _ended := false
	var _hash := ""
	var _hash_thread: Thread

	## Build the copy of `id` from the disc image `disc_path`.
	func start(disc_id: String, disc_path: String) -> bool:
		id = disc_id
		disc = disc_path
		var tool := Discs.tool_path()
		if not FileAccess.file_exists(tool):
			_fail("no_tool", tool)
			return false
		if OS.get_name() == "Linux" and FileAccess.get_unix_permissions(tool) & 0b001001001 == 0:
			FileAccess.set_unix_permissions(tool, 493)
		DirAccess.make_dir_recursive_absolute(Discs.built_path(id).get_base_dir())
		var user := Settings.data_path("update/disc_tool")   # DolphinTool's own temporary files
		DirAccess.make_dir_recursive_absolute(user)
		Discs._set_lock(id, {"sha256": "", "original": disc})   # (not a copy until it's done)
		var r := OS.execute_with_pipe(tool, PackedStringArray([
			"sparking-disc", "-i", ProjectSettings.globalize_path(disc), "-r", Discs.recipe_path(id),
			"-o", Discs.built_path(id), "-u", user]))
		if r.is_empty():
			_fail("no_tool", tool)
			return false
		pid = r["pid"]
		_thread = Thread.new()
		_thread.start(_read.bind(r["stdio"] as FileAccess, r["stderr"] as FileAccess))
		return true

	## Only the hash check of a copy whose date or size changed ("changed").
	func start_check(disc_id: String) -> void:
		id = disc_id
		state = "hashing"
		_hash_thread = Thread.new()
		_hash_thread.start(func(): _hash = Discs.hash_file(Discs.built_path(id)))

	func _read(out: FileAccess, err: FileAccess) -> void:
		while true:
			var line := out.get_line()
			if line.is_empty() and (out.eof_reached() or out.get_error() != OK):
				break
			_mutex.lock()
			_lines.append(line)
			_mutex.unlock()
		while not err.eof_reached() and err.get_error() == OK:
			err.get_line()
		_mutex.lock()
		_ended = true
		_mutex.unlock()

	func _fail(code: String, text: String) -> void:
		state = "failed"
		error = code
		detail = text

	## Call every frame. True while it's still going.
	func poll() -> bool:
		if state in ["done", "failed", "stopped"]:
			return false
		if state == "hashing":
			if _hash_thread and not _hash_thread.is_alive():
				_hash_thread.wait_to_finish()
				_hash_thread = null
				_finish_hash()
			return state == "hashing"
		_mutex.lock()
		var lines := _lines.duplicate()
		_lines.clear()
		var ended := _ended
		_mutex.unlock()
		for line: String in lines:
			if line.begins_with("stage build"):
				state = "building"
			elif line.begins_with("progress "):
				var f := float(line.get_slice(" ", 1))
				progress = f * 0.3 if state == "checking" else 0.3 + f * 0.65
			elif line.begins_with("error "):
				var rest := line.substr(6)
				_fail(rest.get_slice(" ", 0), rest.substr(rest.find(" ") + 1) if " " in rest else "")
			elif line.begins_with("done "):
				state = "hashing"
				progress = 0.95
				_hash_thread = Thread.new()
				_hash_thread.start(func(): _hash = Discs.hash_file(Discs.built_path(id)))
		if ended and state in ["checking", "building"]:
			_fail("crashed", "DolphinTool stopped without finishing")
		if _thread and (ended or not state in ["checking", "building"]):
			_thread.wait_to_finish()   # (DolphinTool has said its last line: it's ending)
			_thread = null
		return not state in ["done", "failed", "stopped"]

	func _finish_hash() -> void:
		var p := Discs.built_path(id)
		if _hash == "":
			_fail("write", p)
			return
		var expected := String(Discs._lock(id, "sha256"))
		if disc == "" and expected != "" and _hash != expected:
			_fail("changed", p)    # (the hash check: it really isn't the copy that was built)
			return
		if disc == "" and expected == "":
			_fail("changed", p)
			return
		Discs._set_lock(id, {"sha256": _hash, "size": Discs._size(p),
			"mtime": FileAccess.get_modified_time(p),
			"recipe": FileAccess.get_sha256(Discs.recipe_path(id)) if disc != "" else Discs._lock(id, "recipe")})
		progress = 1.0
		state = "done"

	func stop() -> void:
		if pid > 0 and OS.is_process_running(pid):
			OS.kill(pid)
		state = "stopped"
		if _thread:
			_thread.wait_to_finish()
			_thread = null
		if _hash_thread:
			_hash_thread.wait_to_finish()
			_hash_thread = null
		if disc != "":
			Discs.remove(id)    # (a half-written copy)
