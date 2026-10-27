extends Node
## Runs DolphinNoGUI.exe (the Dolphin-Sparking build) and talks to it:
##   - stdout lines "[SPARKING] {json}" become `event(name, data)` signals (main thread);
##   - commands go to its stdin, one per line (`send("chat hi")`).
## One "session" process at a time (solo game, netplay host/join/find), plus short-lived
## "query" processes (lobby list, Gecko code list) that report their events to a callback.

signal event(name: String, data: Dictionary)
signal exited(code: int)

const PREFIX := "[SPARKING] "
const Controllers := preload("res://scripts/controllers.gd")


class Proc:
	extends RefCounted
	static var _keep_alive: Array = []  # see close()
	var pid := -1
	var stdio: FileAccess
	var stderr: FileAccess
	var threads: Array[Thread] = []
	var mutex := Mutex.new()
	var lines: Array[String] = []
	var finished := false
	var exit_code := -1

	func start(exe: String, args: PackedStringArray) -> bool:
		# Linux: a Dolphin copied from Windows, unpacked by hand or put in by an update may have
		# lost its "executable" mark, and then it won't start.
		if OS.get_name() == "Linux" and FileAccess.file_exists(exe) \
				and FileAccess.get_unix_permissions(exe) & 0b001001001 == 0:
			FileAccess.set_unix_permissions(exe, 493)   # rwxr-xr-x
		var r := OS.execute_with_pipe(exe, args)
		if r.is_empty():
			return false
		pid = r["pid"]
		stdio = r["stdio"]
		stderr = r["stderr"]
		var t_out := Thread.new()
		t_out.start(_read_loop.bind(stdio, true))
		threads.append(t_out)
		# stderr must be drained too, or a chatty Dolphin blocks once the pipe buffer fills.
		var t_err := Thread.new()
		t_err.start(_read_loop.bind(stderr, false))
		threads.append(t_err)
		return true

	func _read_loop(f: FileAccess, keep: bool) -> void:
		while true:
			var line := f.get_line()
			if line.is_empty() and (f.eof_reached() or f.get_error() != OK):
				break
			if keep and line.begins_with(PREFIX):
				mutex.lock()
				lines.append(line.substr(PREFIX.length()))
				mutex.unlock()
		if keep:
			mutex.lock()
			finished = true
			mutex.unlock()

	func take_lines() -> Array[String]:
		mutex.lock()
		var out := lines.duplicate()
		lines.clear()
		mutex.unlock()
		return out

	func is_finished() -> bool:
		mutex.lock()
		var f := finished
		mutex.unlock()
		return f and not OS.is_process_running(pid)

	func send(line: String) -> void:
		# Writing to the pipe of a process that already exited raises SIGPIPE, which would kill
		# this frontend: only write while its stdout is still open and the process is alive.
		mutex.lock()
		var done := finished
		mutex.unlock()
		if done or not OS.is_process_running(pid):
			return
		if stdio and stdio.is_open():
			stdio.store_line(line)
			stdio.flush()

	func close() -> void:
		for t in threads:
			if t.is_started():
				t.wait_to_finish()
		threads.clear()
		# Godot 4.3 on Linux/macOS: freeing a pipe FileAccess also closes fd 0 (the frontend's
		# stdin); the next execute_with_pipe then gets fd 0 for the child's stdin and closes it in
		# the child, so the first command kills us with SIGPIPE. Keep finished pipes alive
		# (a couple of fds per launch) instead of freeing them.
		if OS.get_name() != "Windows":
			_keep_alive.append_array([stdio, stderr])


var _session: Proc
var _queries: Array = []  # [{proc, callback, events}]
var _helpers: Array = []  # [{proc, callback}] long-running helpers (start_helper)
var log_lines: PackedStringArray = []  # last events, for the debug panel
## A game is booting or being played (offline or netplay): the controller belongs to the game.
var in_game := false

## Boot watchdog: a game that hasn't drawn a frame `boot_timeout` seconds (options; default 10,
## 0 = off) after it starts booting is hung (black or frozen window): Dolphin is killed and
## "boot_hung" is emitted. Armed at launch for a game (-e: offline, replays) and at
## "game_booting" for netplay; paused while netplay syncs saves; disarmed by the first "stats"
## with frames drawn (fps > 0), or when the boot ends any other way.
var _boot_deadline := 0      # Time.get_ticks_msec() to give up at; 0 = not watching
var _boot_paused := false    # (netplay save sync: re-armed at its end)
var boot_watch_override := -1.0   # tests: seconds instead of the setting (-1 = the setting)


func _boot_timeout() -> float:
	if boot_watch_override >= 0.0:
		return boot_watch_override
	return float(Settings.get_value("options", "boot_timeout"))


func _arm_boot_watch() -> void:
	_boot_paused = false
	var t := _boot_timeout()
	_boot_deadline = Time.get_ticks_msec() + int(t * 1000.0) if t > 0.0 else 0


func _disarm_boot_watch() -> void:
	_boot_deadline = 0
	_boot_paused = false


## True while a starting game is being watched (tests, debug).
func boot_watching() -> bool:
	return _boot_deadline > 0 or _boot_paused


func _watch_boot(name: String, data: Dictionary) -> void:
	match name:
		"game_booting":
			_arm_boot_watch()
		"sync_begin":
			if _boot_deadline > 0:
				_boot_deadline = 0
				_boot_paused = true
		"sync_end":
			if _boot_paused:
				_arm_boot_watch()
		"stats":
			if float(data.get("fps", 0)) > 0.0:
				_disarm_boot_watch()   # frames on screen: it started
		"game_stopped", "game_start_aborted", "boot_failed":
			_disarm_boot_watch()
		"error":
			if String(data.get("code", "")) == "boot_failed":
				_disarm_boot_watch()


func is_running() -> bool:
	return _session != null


## Starts the session process (solo game or netplay). False if one is already running or the
## executable can't be started.
func launch(args: PackedStringArray) -> bool:
	if _session:
		push_warning("Dolphin is already running")
		return false
	# The chosen controller preset goes into GCPadNew.ini before every game.
	Controllers.apply_selected()
	# Dolphin reports the frame rate every second while a game runs: the boot watchdog's sign
	# that the game really started.
	if not "--stats-interval" in args:
		args = args.duplicate()
		args.append_array(["--stats-interval", "1000"])
	var p := Proc.new()
	if not p.start(Settings.dolphin_path(), args):
		return false
	_session = p
	_log("launch: " + " ".join(args))
	if "-e" in args and not "--netplay-host" in args and not "--netplay-game" in args:
		_arm_boot_watch()      # offline game / replay: booting now
	else:
		_disarm_boot_watch()   # netplay: armed when the game boots ("game_booting")
	# Handshake: from now on, if this frontend closes, Dolphin quits too.
	p.send("hello")
	return true


func send(command: String) -> void:
	if _session:
		_log("> " + command)
		_session.send(command)


## Asks the session to quit; kills it if it hasn't exited after `grace_ms`.
func quit_session(grace_ms := 4000) -> void:
	if not _session:
		return
	var p := _session
	p.send("quit")
	await get_tree().create_timer(grace_ms / 1000.0).timeout
	if _session == p and OS.is_process_running(p.pid):
		OS.kill(p.pid)


## Runs Dolphin once (e.g. --list-lobbies) and calls `callback(events: Array)` with every
## event it printed, once it exits.
func query(args: PackedStringArray, callback: Callable) -> bool:
	var p := Proc.new()
	if not p.start(Settings.dolphin_path(), args):
		return false
	_queries.append({"proc": p, "callback": callback, "events": []})
	return true


## Starts a helper Dolphin that runs alongside everything else (e.g. --input-test) and calls
## `on_event(event: Dictionary)` for each event it prints (on the main thread), then
## {"event": "process_exited"} when it ends. Returns a handle for stop_helper(), or null.
func start_helper(args: PackedStringArray, on_event: Callable) -> Object:
	var p := Proc.new()
	if not p.start(Settings.dolphin_path(), args):
		return null
	p.send("hello")   # from now on, closing this frontend also ends the helper
	_helpers.append({"proc": p, "callback": on_event})
	return p


func helper_send(handle: Object, line: String) -> void:
	if handle:
		handle.send(line)


## Makes a helper the session (Quick Match: the connection both players accepted becomes the
## match): its events now come as `event` signals, and it's the process the menus control.
## False if a session is still running or the helper is gone.
func adopt_helper(handle: Object) -> bool:
	if _session or handle == null:
		return false
	for h in _helpers:
		if h["proc"] == handle:
			if (handle as Proc).is_finished():
				return false
			_helpers.erase(h)
			_session = handle
			_disarm_boot_watch()   # (armed when its game boots, like any netplay session)
			_log("adopted helper as the session")
			return true
	return false


func stop_helper(handle: Object) -> void:
	if handle == null:
		return
	var p: Proc = handle
	p.send("quit")
	await get_tree().create_timer(1.5).timeout
	if OS.is_process_running(p.pid):
		OS.kill(p.pid)


func _process(_delta: float) -> void:
	for h in _helpers.duplicate():
		var hp: Proc = h["proc"]
		for raw in hp.take_lines():
			var data = JSON.parse_string(raw)
			if data is Dictionary and h["callback"].is_valid():
				h["callback"].call(data)
		if hp.is_finished():
			_helpers.erase(h)
			hp.close()
			if h["callback"].is_valid():
				h["callback"].call({"event": "process_exited"})

	if _session:
		for raw in _session.take_lines():
			var data = JSON.parse_string(raw)
			if data is Dictionary and data.has("event"):
				if data["event"] != "stats":
					_log(raw)
				_track_game(String(data["event"]))
				_watch_boot(String(data["event"]), data)
				event.emit(String(data["event"]), data)
		if _boot_deadline > 0 and Time.get_ticks_msec() > _boot_deadline and not _session.is_finished():
			var secs := _boot_timeout()
			_disarm_boot_watch()
			_log("boot watchdog: no frame after %.0f s, killing Dolphin" % secs)
			event.emit("boot_hung", {"event": "boot_hung", "seconds": secs})
			OS.kill(_session.pid)
		if _session.is_finished():
			var p := _session
			_session = null
			_disarm_boot_watch()
			p.close()
			var code := 0
			in_game = false
			event.emit("process_exited", {"event": "process_exited"})
			exited.emit(code)

	for q in _queries.duplicate():
		var p: Proc = q["proc"]
		for raw in p.take_lines():
			var data = JSON.parse_string(raw)
			if data is Dictionary:
				q["events"].append(data)
		if p.is_finished():
			_queries.erase(q)
			p.close()
			if q["callback"].is_valid():  # the screen that asked may be gone
				q["callback"].call(q["events"])


func _log(line: String) -> void:
	log_lines.append(line)
	if log_lines.size() > 300:
		log_lines = log_lines.slice(log_lines.size() - 300)


func _exit_tree() -> void:
	for h in _helpers:
		if OS.is_process_running(h["proc"].pid):
			OS.kill(h["proc"].pid)
	if _session and OS.is_process_running(_session.pid):
		_session.send("quit")
		OS.delay_msec(300)
		if OS.is_process_running(_session.pid):
			OS.kill(_session.pid)


func _track_game(name: String) -> void:
	match name:
		"game_booting", "game_started":
			in_game = true
		"game_stopped", "game_start_aborted", "boot_failed":
			in_game = false
