extends Node
## Tools/update_test.py: runs one automatic update against its test servers and prints the
## result. Run: godot --path Frontend/Godot -- --update-check <settings.cfg>
## (settings [update] root / key, [ranked] server / token; env UPDATE_OWN = the install's
## "launcher" files, relative, comma-separated). UPDATE_PACK = a pack's id: UPDATE_ACTION
## "install" downloads it (Updater.install_pack), "remove" deletes it, "info" only reports.

func _ready() -> void:
	_run.call_deferred()


func _run() -> void:
	if OS.get_environment("UPDATE_PS_SAMPLE") != "":
		# The Windows restart script for a path with !, ' and Japanese in it (read by the test).
		var root := "C:/Games/DBZ Sparking! Collection/Goku's ドラゴン"
		print("PS_SAMPLE_BEGIN\n", Updater.powershell_script(4242,
			{"DRAGON BALL Sparking! Collection.pck": root + "/SparkingData/update/download/abc"},
			root, root + "/DRAGON BALL Sparking! Collection.exe"), "PS_SAMPLE_END")
		get_tree().quit()
		return
	var flags := {"restarted": false}   # (a lambda can't assign this function's locals)
	Updater.restart_hook = func(): flags["restarted"] = true
	# UPDATE_HITCH_MS: the launcher hangs right before it asks for the download links (as build
	# 206 did while hashing): the request must not "time out" because of the hang.
	var hitch := int(OS.get_environment("UPDATE_HITCH_MS")) if OS.get_environment("UPDATE_HITCH_MS") != "" else 0
	if hitch > 0:
		var once := {"done": false}
		Updater.changed.connect(func():
			if Updater.state == "downloading" and not once["done"]:
				once["done"] = true
				OS.delay_msec(hitch))
	var own := OS.get_environment("UPDATE_OWN")
	if own != "":
		Updater.own_files_override = Array(own.split(","))
	var pack := OS.get_environment("UPDATE_PACK")
	var action := OS.get_environment("UPDATE_ACTION")
	var state := ""
	var removed := 0
	if pack == "" or action == "":
		state = await Updater.check()
	elif action == "install":
		state = await Updater.install_pack(pack)
	elif action == "remove":
		removed = await Updater.remove_pack(pack)
	print("UPDATE_RESULT ", JSON.stringify({"state": state, "error": Updater.error,
		"version": Updater.version, "files": Updater.file_count, "bytes": Updater.total_bytes,
		"restarted": flags["restarted"], "installed_version": Updater.installed_version(),
		"pack": Updater.pack_info(pack) if pack != "" else {}, "removed": removed}))
	get_tree().quit()
