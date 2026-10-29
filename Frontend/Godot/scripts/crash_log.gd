extends RefCounted
## Crash reports, in SparkingData/logs:
##   crash_<date>_<time>.txt           a game (Dolphin) closed unexpectedly: what happened, the
##                                     launcher and PC, the last events and Dolphin's output, and
##                                     Dolphin's own report (dolphin_crash_*.txt, written by
##                                     Dolphin itself when it crashes; Windows: + a .dmp next to it)
##   launcher_crash_<date>_<time>.txt  the launcher itself crashed last time (Godot's log of that run)
## Written in English: they're for whoever looks into the problem. Nothing secret goes in: no
## tokens or passwords (Dolphin's command line has none), IP addresses are masked and chat
## messages left out.

const KEEP_REPORTS := 20   # crash_*.txt / launcher_crash_*.txt / dolphin_crash_*.txt each
const KEEP_DUMPS := 3      # .dmp files are big (a few MB)

static var _ip := RegEx.create_from_string("\\b(\\d{1,3})\\.(\\d{1,3})\\.(\\d{1,3})\\.(\\d{1,3})\\b")
static var _ipv6 := RegEx.create_from_string("\\[?\\b[0-9a-fA-F]{1,4}(:[0-9a-fA-F]{0,4}){3,7}\\]?")


static func folder() -> String:
	return Settings.data_path("logs")


## Masks what shouldn't be shared: IP addresses (yours and other players') and chat text.
static func scrub(text: String) -> String:
	text = _ip.sub(text, "x.x.x.x", true)
	text = _ipv6.sub(text, "x:x:x:x", true)
	return text


static func _scrub_event(line: String) -> String:
	if line.begins_with("{\"event\":\"chat\"") or line.begins_with("> chat "):
		return line.get_slice(",", 0) + ",...}" if line.begins_with("{") else "> chat ..."
	return scrub(line)


static func _stamp() -> String:
	var t := Time.get_datetime_dict_from_system()
	return "%04d%02d%02d_%02d%02d%02d" % [t.year, t.month, t.day, t.hour, t.minute, t.second]


## Exit code as people would search for it: Windows crash codes in hex (0xC0000005).
static func exit_code_text(code: int) -> String:
	if code == -1:
		return "unknown"
	if code < -255 or code > 255:
		return "0x%08X" % (code & 0xFFFFFFFF)
	if code < 0:
		return "%d (signal %d)" % [code, -code]
	return str(code)


static func _system_lines() -> PackedStringArray:
	var out := PackedStringArray()
	var ver := "?"
	var up = Engine.get_main_loop().root.get_node_or_null("Updater") if Engine.get_main_loop() else null
	if up and up.has_method("installed_version"):
		ver = String(up.installed_version())
	out.append("Launcher: %s (Godot %s)" % [ver, Engine.get_version_info().get("string", "?")])
	out.append("System: %s %s, %s, %d CPU threads, %d MB RAM" % [OS.get_name(), OS.get_version(),
			OS.get_processor_name(), OS.get_processor_count(),
			int(OS.get_memory_info().get("physical", 0)) / (1024 * 1024)])
	out.append("Graphics: %s (%s)" % [RenderingServer.get_video_adapter_name(),
			RenderingServer.get_video_adapter_api_version()])
	out.append("Renderer setting: %s" % Settings.renderer())
	return out


## Writes the report for a Dolphin process that ended unexpectedly; returns its path ("" if the
## logs folder can't be written). `info`: kind ("crash" / "closed" / "boot_hung"), summary, args,
## code, events (last events and commands), output (Dolphin's last console lines), crash (the
## "crash" event, if Dolphin sent one), in_game, role ("session" / "helper").
static func write_game_report(info: Dictionary) -> String:
	var dir := folder()
	DirAccess.make_dir_recursive_absolute(dir)
	var path := dir.path_join("crash_%s.txt" % _stamp())
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return ""
	var kind := String(info.get("kind", "closed"))
	var what: String = {
		"crash": "The game crashed.",
		"closed": "The game closed without saying why (it may have crashed, or been closed by another program).",
		"boot_hung": "The game didn't start (no picture), so the launcher closed it.",
	}.get(kind, kind)
	f.store_line("DRAGON BALL Sparking! Collection PC - %s" % what)
	f.store_line("Time: %s" % Time.get_datetime_string_from_system(false, true))
	if String(info.get("summary", "")) != "":
		f.store_line("What: %s" % scrub(String(info["summary"])))
	f.store_line("Exit code: %s" % exit_code_text(int(info.get("code", -1))))
	f.store_line("During a game: %s    Which: %s" % ["yes" if info.get("in_game", false) else "no",
			String(info.get("role", "session"))])
	for l in _system_lines():
		if l != "":
			f.store_line(l)
	f.store_line("Dolphin: %s" % Settings.dolphin_path().get_file())
	f.store_line("Started with: %s" % scrub(" ".join(PackedStringArray(info.get("args", [])))))
	var crash: Dictionary = info.get("crash", {})
	var dump := String(crash.get("dump", ""))
	if dump != "":
		f.store_line("Minidump: %s  (send it along with this file)" % dump.get_file())
	var report := String(crash.get("report", ""))
	if report != "" and FileAccess.file_exists(report):
		f.store_line("")
		f.store_line("=== Dolphin's crash report (%s) ===" % report.get_file())
		var r := FileAccess.get_file_as_string(report)
		for line in r.split("\n"):
			f.store_line(_scrub_event(line.trim_prefix("  ")) if line.begins_with("  {") else scrub(line))
	f.store_line("")
	f.store_line("=== Last events and commands (oldest first) ===")
	for line in info.get("events", []):
		f.store_line(_scrub_event(String(line)))
	f.store_line("")
	f.store_line("=== Dolphin's last console output ===")
	for line in info.get("output", []):
		f.store_line(scrub(String(line)))
	f.close()
	prune()
	return path


## The launcher itself crashed last time? Godot keeps one log per run (user://logs: godot.log is
## this run's, the others are earlier runs, newest last); the previous run's log says
## "Program crashed" if it did. Then it's copied to launcher_crash_<date>_<time>.txt. Returns
## its path, or "".
static func check_previous_launcher_run() -> String:
	var logs := "user://logs"
	var d := DirAccess.open(logs)
	if d == null:
		return ""
	var older: Array[String] = []
	for name in d.get_files():
		if name.begins_with("godot") and name.ends_with(".log") and name != "godot.log":
			older.append(name)
	if older.is_empty():
		return ""
	older.sort()   # godot<YYYY-MM-DDTHH.MM.SS>.log: by time
	var prev := logs.path_join(older[-1])
	var text := FileAccess.get_file_as_string(prev)
	if not ("Program crashed" in text or "CrashHandlerException" in text):
		return ""
	var dir := folder()
	DirAccess.make_dir_recursive_absolute(dir)
	var out := dir.path_join("launcher_crash_%s.txt" % older[-1].trim_prefix("godot").trim_suffix(".log")
			.replace("-", "").replace("T", "_").replace(".", ""))
	if FileAccess.file_exists(out):
		return ""   # already reported
	var f := FileAccess.open(out, FileAccess.WRITE)
	if f == null:
		return ""
	f.store_line("DRAGON BALL Sparking! Collection PC - the launcher crashed (%s)" % older[-1])
	for l in _system_lines():
		if l != "":
			f.store_line(l)
	f.store_line("")
	f.store_line("=== The launcher's log of that run ===")
	f.store_string(scrub(text))
	f.close()
	prune()
	return out


## Keeps the newest reports of each kind.
static func prune() -> void:
	var dir := folder()
	var d := DirAccess.open(dir)
	if d == null:
		return
	var groups := {"crash_": [], "launcher_crash_": [], "dolphin_crash_txt": [], "dolphin_crash_dmp": []}
	for name in d.get_files():
		if name.begins_with("dolphin_crash_"):
			groups["dolphin_crash_" + name.get_extension()] = groups.get("dolphin_crash_" + name.get_extension(), []) + [name]
		elif name.begins_with("launcher_crash_"):
			groups["launcher_crash_"].append(name)
		elif name.begins_with("crash_") and name.ends_with(".txt"):
			groups["crash_"].append(name)
	for key in groups:
		var names: Array = groups[key]
		names.sort()
		var keep := KEEP_DUMPS if key == "dolphin_crash_dmp" else KEEP_REPORTS
		while names.size() > keep:
			d.remove(names.pop_front())
