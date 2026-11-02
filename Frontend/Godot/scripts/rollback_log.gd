extends RefCounted
## Rollback (NEOcode) match logs: SparkingData/logs/rollback_<date>_<time>.jsonl, one per match
## played with rollback on, written as it goes (so a crash keeps what came before). Each line is
## one JSON object with "t" (ms since the match started): first a "log" header (launcher, PC),
## then Dolphin's events that tell how rollback went: NEOcode stats every ~60 fields (rewinds,
## their depth, wrong guesses, stalls, save / load / re-run times), each PC's re-run speed and the
## rewind budget ("neocode_speed", host), the automatic buffer's choices, the players' ping and
## jitter (every 5 s), checksum checks and differences, rounds. No IP addresses, no chat, no paths.
## Sent by players after test matches, to tune the automatic minimum buffer.

const CrashLog := preload("res://scripts/crash_log.gd")
const KEEP := 30
const EVENTS := ["game_starting", "game_booting", "game_started", "game_stopped", "netcode", "neocode",
	"neocode_speed", "neocode_check", "neocode_diff", "buffer_changed", "buffer_auto", "buffer_mode",
	"round_result", "match_result", "neo_budget", "exit", "crash", "boot_step"]

var _file: FileAccess
var _start := 0
var _next_players := 0
var path := ""


func is_open() -> bool:
	return _file != null


## A match starts with rollback on: a new log.
func open(info: Dictionary) -> void:
	close()
	var dir := CrashLog.folder()
	DirAccess.make_dir_recursive_absolute(dir)
	path = dir.path_join("rollback_%s.jsonl" % CrashLog._stamp())
	_file = FileAccess.open(path, FileAccess.WRITE)
	if _file == null:
		path = ""
		return
	_start = Time.get_ticks_msec()
	_next_players = 0
	var head := {"event": "log", "kind": "rollback", "time": Time.get_datetime_string_from_system(false, true)}
	head.merge(info)
	head["system"] = Array(CrashLog._system_lines())
	_write(head)
	_prune()


## One of Dolphin's events (only the ones that matter for rollback are kept).
func note(name: String, data: Dictionary) -> void:
	if _file == null:
		return
	if name == "players":
		# The players' ping and jitter, every 5 s (Dolphin sends the list every second or so).
		if Time.get_ticks_msec() < _next_players:
			return
		_next_players = Time.get_ticks_msec() + 5000
		var list: Array = []
		for p in data.get("players", []):
			list.append({"name": p.get("name", ""), "pid": p.get("pid", 0), "gc_slot": p.get("gc_slot", -1),
				"ping": p.get("ping", -1), "jitter": p.get("jitter", -1), "quality": p.get("quality", ""),
				"link": p.get("link", ""), "role": p.get("role", "")})
		_write({"event": "players", "players": list})
		return
	if not name in EVENTS:
		return
	var d := data.duplicate()
	d.erase("path")   # (the game's file path: the PC's user name, nothing about rollback)
	_write(d)
	if name in ["game_stopped", "exit", "crash"]:
		close()


func close() -> void:
	if _file:
		_file.close()
	_file = null


func _write(data: Dictionary) -> void:
	var d := data.duplicate()
	d["t"] = Time.get_ticks_msec() - _start
	_file.store_line(CrashLog.scrub(JSON.stringify(d)))
	_file.flush()


static func _prune() -> void:
	var dir := CrashLog.folder()
	var names: Array = Array(DirAccess.get_files_at(dir)).filter(func(n): return String(n).begins_with("rollback_"))
	names.sort()
	while names.size() > KEEP:
		DirAccess.remove_absolute(dir.path_join(names.pop_front()))
