extends Node
## Tools/sparking_disc_test.py: the launcher's side of built copies (scripts/discs.gd) with the
## test's made-up discs and recipe. Run: godot --path Frontend/Godot -- --disc-check <settings.cfg>
## (settings: [paths] data / dolphin; env DISC_ORIG, DISC_MOD, DISC_US = disc images).
## Prints "DISC_CHECK ok|FAIL <what>" lines and "DISC_CHECK_END".

const DiscBuild := preload("res://scripts/screens/disc_build.gd")
const DiscPending := preload("res://scripts/screens/disc_pending.gd")
const GameCopies := preload("res://scripts/screens/game_copies.gd")

var fails := 0


func _ready() -> void:
	_run.call_deferred()


func check(cond: bool, what: String, extra := "") -> void:
	print("DISC_CHECK %s %s%s" % ["ok  " if cond else "FAIL", what, "" if cond or extra == "" else " " + extra])
	if not cond:
		fails += 1


func _job(id: String, disc: String) -> Variant:
	var job = Discs.Job.new()
	if disc == "":
		job.start_check(id)
	else:
		job.start(id, disc)
	var t := Time.get_ticks_msec()
	while job.poll() and Time.get_ticks_msec() - t < 120000:
		await get_tree().process_frame
	return job


func _run() -> void:
	var app: Node = get_parent()
	var id := "RDSPAF"
	var orig := OS.get_environment("DISC_ORIG")
	var built := Discs.built_path(id)

	check(Discs.has_recipe(id), "the recipe is found")
	check(Settings.version_name("bt3", "PAL") == "4.0", "PAL is shown as 4.0", Settings.version_name("bt3", "PAL"))
	check(Settings.version_name("bt3", "NTSC-J") == "NTSC-J", "NTSC-J keeps its name (no recipe)")
	check(Discs.state(id) == "missing" and not Settings.has_copy("bt3", "PAL"), "no copy before it's built")
	# A copy picked the old way (here: the original itself) is what it offers to build from.
	Settings._cfg.set_value("games", "bt3_PAL", orig)
	check(Discs.pending().has(["bt3", "PAL"]), "an old-style copy makes it pending")
	check(Discs.candidate("bt3", "PAL") == orig, "and is the disc it offers to build from")
	check(Settings.copy_path("bt3", "PAL") == built, "the version plays the built copy, never the picked file")

	var job = await _job(id, OS.get_environment("DISC_MOD"))
	check(job.state == "failed" and job.error == "modified", "a modded disc is refused", "%s %s" % [job.error, job.detail])
	check("files differ from the original" in job.detail, "every differing file is listed, not just the first", job.detail)
	var report: String = job.report("4.0")
	check("Disc: RDSPAF, revision 0" in report and "Wanted: 4.0 (RDSPAF, revision 0)" in report
			and "Result: modified" in report, "Copy details: the disc's ID, revision and what differs", report)
	job = await _job(id, OS.get_environment("DISC_US"))
	check(job.state == "failed" and job.error == "wrong_game" and job.detail == "RDSE70", "another version is refused")
	check(not Settings.has_copy("bt3", "PAL"), "still no copy")

	# Through the screen, as a player does it.
	var screen: Control = DiscBuild.new().setup("bt3", "PAL", orig)
	app.push(screen)
	var t := Time.get_ticks_msec()
	while is_instance_valid(screen) and screen.is_inside_tree() and Time.get_ticks_msec() - t < 120000:
		await get_tree().process_frame
	check(not is_instance_valid(screen) or not screen.is_inside_tree(), "the build screen finishes and closes")
	check(Discs.state(id) == "ready" and Settings.has_copy("bt3", "PAL"), "built: the copy is ready", Discs.state(id))
	check(FileAccess.file_exists(built) and Discs.original(id) == orig, "in SparkingData/title, original remembered")
	Settings.use_game("bt3", "PAL")
	check(Settings.game_path() == built, "the game runs the built copy")
	check(Discs.pending().is_empty(), "nothing pending")
	var copy_rep := GameCopies.copy_report("bt3", "PAL")
	check("State: ready" in copy_rep and "Fingerprint: " + String(Settings._cfg.get_value("discs", "RDSPAF_sha256")).left(16) in copy_rep,
			"Game Copies' Copy details: state and fingerprint", copy_rep)

	# Its date changes (copied, restored from a backup...): checked by hash, still the same.
	var bytes := FileAccess.get_file_as_bytes(built)
	OS.delay_msec(1100)
	var f := FileAccess.open(built, FileAccess.WRITE)
	f.store_buffer(bytes)
	f.close()
	check(Discs.state(id) == "changed" and not Settings.has_copy("bt3", "PAL"), "a touched copy needs the check")
	check(Discs.pending().has(["bt3", "PAL"]), "pending")
	job = await _job(id, "")
	check(job.state == "done" and Discs.state(id) == "ready", "same contents: ready again", "%s %s" % [job.error, Discs.state(id)])

	# Replaced by another file: not a copy any more.
	OS.delay_msec(1100)
	bytes[bytes.size() / 2] ^= 0xFF
	f = FileAccess.open(built, FileAccess.WRITE)
	f.store_buffer(bytes)
	f.close()
	job = await _job(id, "")
	check(job.state == "failed" and job.error == "changed" and not Settings.has_copy("bt3", "PAL"), "a replaced copy is refused")

	# The pending screen offers to build it again from the remembered original.
	var pend: Control = DiscPending.new()
	app.push(pend)
	await get_tree().process_frame
	check(pend.list.rows.size() == 2 and String(pend.list.rows[0]["key"]) == "bt3/PAL", "the pending screen lists it")
	app.pop()

	job = await _job(id, orig)
	check(job.state == "done" and Discs.state(id) == "ready", "built again from the original")

	# An update of the recipe: outdated until built again.
	var rp := Discs.recipe_path(id)
	var text := FileAccess.get_file_as_string(rp)
	f = FileAccess.open(rp, FileAccess.WRITE)
	f.store_string(text.replace("\"made\":\"", "\"made\":\"updated "))
	f.close()
	check(Discs.state(id) == "outdated" and not Settings.has_copy("bt3", "PAL"), "a new recipe: outdated")
	check(GameCopies.built_text(id) != "", "Game Copies shows it")
	job = await _job(id, orig)
	check(job.state == "done" and Discs.state(id) == "ready", "rebuilt for the new recipe")

	# Stopped half-way: nothing half-made is kept.
	var stopping = Discs.Job.new()
	stopping.start(id, orig)
	for i in 3:
		await get_tree().process_frame
	stopping.stop()
	check(not FileAccess.file_exists(built) and Discs.state(id) == "missing", "a stopped build leaves no copy")

	# The setup screen asks for the version first when one is built from a disc.
	var setup: Control = load("res://scripts/screens/setup.gd").new()
	app.push(setup)
	await get_tree().process_frame
	setup.on_press("game_bt3")
	await get_tree().process_frame
	var top: Control = app.top()
	var labels: Array = []
	if top != setup and top.get("items") != null:
		labels = (top.get("items") as Array).map(func(it): return String(it.get("label", "")))
	check(labels.has("4.0") and labels.has("NTSC-J"), "Setup asks the version first: 4.0 / NTSC-J", str(labels))
	print("DISC_CHECK_END ", fails)
	get_tree().quit()
