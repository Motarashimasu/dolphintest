extends SceneTree
## godot --headless --path Frontend/Godot -s tests/gif_check.gd -- <dir with *.gif>
## Decodes every GIF and writes dec_<name>_<n>.png + timing (compared by tests/gif_check.py).
const Gif := preload("res://scripts/util/gif.gd")

func _init() -> void:
	var dir: String = OS.get_cmdline_user_args()[0]
	for f in DirAccess.get_files_at(dir):
		if f.get_extension() != "gif":
			continue
		var t := Time.get_ticks_msec()
		var anim := Gif.decode(FileAccess.get_file_as_bytes(dir.path_join(f)), Vector2i(int(OS.get_cmdline_user_args()[1]), 10000) if OS.get_cmdline_user_args().size() > 1 else Vector2i.ZERO)
		var ms := Time.get_ticks_msec() - t
		print("GIF %s frames=%d ms=%d error='%s' delays=%s" % [f, anim.frames.size(), ms, anim.error, Array(anim.delays).slice(0, 8)])
		for i in anim.frames.size():
			anim.frames[i].save_png(dir.path_join("dec_%s_%d.png" % [f.get_basename(), i]))
	quit()
