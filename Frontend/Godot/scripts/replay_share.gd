extends RefCounted
## Shared replays on DRAGON NET (Server/ranked/replays.php): share one of this PC's replays,
## search everyone's, and download one to watch it. Downloads go to <SparkingData>/replays/online
## (<id>.dtm, <id>.dtm.sav, <id>.json), apart from this PC's own replays.
## Every function is a coroutine (await it); results look like Ranked.api's: {"ok": ...}.


## Ranked replays must be shared: errors after which trying again won't help (the replay is then
## left alone, "share_error" in its .json).
const FINAL_ERRORS := ["replay_missing", "replay_too_big", "bad_replay"]

static var _pending_running := false
static var _uploading := {}   # .dtm path -> true while it's being sent (never twice at once)


static func online_folder() -> String:
	return Settings.data_path("replays").path_join("online")


static func _sha1(path: String) -> String:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return ""
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA1)
	while f.get_position() < f.get_length():
		ctx.update(f.get_buffer(1 << 20))
	return ctx.finish().hex_encode()


## Shares a replay (an info from the Replays screen: "path" = its .dtm, "json_path"). `progress`
## gets 0..1. Remembers the shared id in the replay's .json ("shared_id").
## -> {"ok": true, "id": n, "exists": bool} or an error.
static func upload(info: Dictionary, progress := Callable()) -> Dictionary:
	if not Ranked.logged_in():
		return {"ok": false, "error": "login_required"}
	# Player Match / Battle Lounge recordings stay on this PC, whatever asks.
	if info.get("local", false) or String(info.get("kind", "ranked")) != "ranked" \
			or "/replays/local/" in String(info.get("path", "")).replace("\\", "/"):
		return {"ok": false, "error": "local_replay"}
	var dtm := String(info.get("path", ""))
	while _uploading.has(dtm):   # already being sent (after the match / pending): wait for it
		await Ranked.get_tree().create_timer(0.5).timeout
	_uploading[dtm] = true
	var res := await _upload(info, progress)
	_uploading.erase(dtm)
	return res


static func _upload(info: Dictionary, progress: Callable) -> Dictionary:
	var dtm := String(info.get("path", ""))
	var sav := dtm + ".sav"
	if not FileAccess.file_exists(dtm) or not FileAccess.file_exists(sav):
		return {"ok": false, "error": "replay_missing"}
	var meta: Dictionary = info.duplicate()
	for k in ["path", "json_path", "shared_id", "online_id"]:
		meta.erase(k)
	var sizes := {"dtm": _size(dtm), "sav": _size(sav)}
	var start := await Ranked.api("replays.php", {"action": "start", "meta": meta,
		"dtm_size": sizes["dtm"], "sav_size": sizes["sav"], "dtm_sha": _sha1(dtm), "sav_sha": _sha1(sav),
		"match": int(info.get("match_id", 0))})
	if not start.get("ok", false):
		return start
	var id := int(start["id"])
	if not start.get("exists", false):
		var chunk := int(start.get("chunk", 262144))
		var total := float(sizes["dtm"] + sizes["sav"])
		var done := 0
		for which in ["dtm", "sav"]:
			var f := FileAccess.open(dtm if which == "dtm" else sav, FileAccess.READ)
			if f == null:
				return {"ok": false, "error": "replay_missing"}
			var offset := 0
			while offset < sizes[which]:
				# Never while a game runs: the upload would eat the netplay connection's bandwidth.
				while Dolphin.in_game:
					await Ranked.get_tree().create_timer(1.0).timeout
				var piece := f.get_buffer(chunk)
				var res := await Ranked.api("replays.php", {"action": "part", "id": id, "which": which,
					"offset": offset, "data": Marshalls.raw_to_base64(piece)})
				if not res.get("ok", false):
					return res
				offset += piece.size()
				done += piece.size()
				if progress.is_valid():
					progress.call(done / maxf(total, 1.0))
		var fin := await Ranked.api("replays.php", {"action": "finish", "id": id})
		if not fin.get("ok", false):
			return fin
	_remember(info, "shared_id", id)
	return {"ok": true, "id": id, "exists": start.get("exists", false)}


static func _size(path: String) -> int:
	var f := FileAccess.open(path, FileAccess.READ)
	return f.get_length() if f else 0


static func _remember(info: Dictionary, key: String, value: Variant) -> void:
	info[key] = value
	var jp := String(info.get("json_path", ""))
	if jp == "":
		return
	var data = JSON.parse_string(FileAccess.get_file_as_string(jp))
	if typeof(data) != TYPE_DICTIONARY:
		return
	data[key] = value
	var f := FileAccess.open(jp, FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify(data, "\t"))


## Shares every ranked replay of this PC not shared yet (one that couldn't be sent after its
## match: offline, server down...). At startup / login; one run at a time. -> how many were sent.
static func upload_pending() -> int:
	if _pending_running or not Ranked.logged_in() or Ranked.needs_account:
		return 0
	_pending_running = true
	var sent := 0
	var replays: Array = load("res://scripts/screens/replays.gd").load_all()
	for info in replays:
		if int(info.get("shared_id", 0)) > 0 or String(info.get("share_error", "")) != "":
			continue
		var res: Dictionary = await upload(info)
		if res.get("ok", false):
			sent += 1
			continue
		var err := String(res.get("error", ""))
		if err == "upload_broken" and int(info.get("share_tries", 0)) == 0:
			_remember(info, "share_tries", 1)   # once more next time
			continue
		if err in FINAL_ERRORS or err == "upload_broken":
			_remember(info, "share_error", err)
			continue
		break   # server unreachable / busy / limits: try again next time
	_pending_running = false
	return sent


## {q, mode (single / team / ""), page} -> {"ok", "replays": [...], "more"}. The current game's.
static func search(q: String, mode: String, page: int) -> Dictionary:
	var body := {"action": "search", "q": q, "page": page}
	if mode != "":
		body["mode"] = mode
	return await Ranked.api("replays.php", body)


## A downloaded replay's info (with "path"), or {} if it isn't here.
static func downloaded(id: int) -> Dictionary:
	var jp := online_folder().path_join("%d.json" % id)
	var dtm := online_folder().path_join("%d.dtm" % id)
	if not FileAccess.file_exists(jp) or not FileAccess.file_exists(dtm) or not FileAccess.file_exists(dtm + ".sav"):
		return {}
	var info = JSON.parse_string(FileAccess.get_file_as_string(jp))
	if typeof(info) != TYPE_DICTIONARY:
		return {}
	info["path"] = dtm
	info["json_path"] = jp
	return info


## Downloads shared replay `id` (unless it's here already) -> {"ok", "info"} (info ready for
## replay_player.gd).
static func download(id: int, progress := Callable()) -> Dictionary:
	var have := downloaded(id)
	if not have.is_empty():
		return {"ok": true, "info": have}
	var got := await Ranked.api("replays.php", {"action": "get", "id": id})
	if not got.get("ok", false):
		return got
	var entry: Dictionary = got["replay"]
	DirAccess.make_dir_recursive_absolute(online_folder())
	var dtm := online_folder().path_join("%d.dtm" % id)
	var parts := [["dtm", dtm], ["sav", dtm + ".sav"]]
	for i in parts.size():
		var which: String = parts[i][0]
		var dest: String = parts[i][1]
		var step := func(p: float) -> void:
			if progress.is_valid():
				progress.call((i + p) / 2.0)
		var res := await _fetch(Ranked.server() + "replays.php?action=file&id=%d&which=%s" % [id, which],
				dest + ".part", step)
		if not res.get("ok", false):
			DirAccess.remove_absolute(dest + ".part")
			return res
		DirAccess.remove_absolute(dest)
		DirAccess.rename_absolute(dest + ".part", dest)
	var info: Dictionary = entry.get("meta", {}) if entry.get("meta") is Dictionary else {}
	info["online_id"] = id
	info["dtm"] = "%d.dtm" % id
	info["uploader"] = entry.get("uploader", "")
	for k in ["players", "wins", "winner", "seconds", "date", "game_id"]:
		if not info.has(k) and entry.has(k):
			info[k] = entry[k]
	var f := FileAccess.open(online_folder().path_join("%d.json" % id), FileAccess.WRITE)
	if f == null:
		return {"ok": false, "error": "write_failed"}
	f.store_string(JSON.stringify(info, "\t"))
	f.close()
	return {"ok": true, "info": downloaded(id)}


static func _fetch(url: String, dest: String, progress: Callable) -> Dictionary:
	var req := HTTPRequest.new()
	req.timeout = 120.0
	req.download_file = dest
	req.download_chunk_size = 262144
	Ranked.add_child(req)
	var err := req.request(url, PackedStringArray(["Accept: application/octet-stream"]))
	if err != OK:
		req.queue_free()
		return {"ok": false, "error": "unreachable"}
	var state := {"done": false, "result": 0, "code": 0}   # (lambdas can't assign outer locals)
	req.request_completed.connect(func(result: int, code: int, _h, _b):
		state["done"] = true
		state["result"] = result
		state["code"] = code, CONNECT_ONE_SHOT)
	while not state["done"]:
		var size := req.get_body_size()
		if size > 0:
			progress.call(clampf(float(req.get_downloaded_bytes()) / size, 0.0, 1.0))
		await Ranked.get_tree().process_frame
	req.queue_free()
	if int(state["result"]) != HTTPRequest.RESULT_SUCCESS or not FileAccess.file_exists(dest):
		return {"ok": false, "error": "unreachable"}
	if int(state["code"]) != 200:
		return {"ok": false, "error": "no_such_replay" if int(state["code"]) == 404 else "unreachable"}
	var code := int(state["code"])
	return {"ok": true, "status": code}
