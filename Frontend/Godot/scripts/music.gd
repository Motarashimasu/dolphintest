extends Node
## Menu background music. Each screen names a track (screen_music(); "" = same as the screen
## below it). A track is a file named after it, looked up in:
##   <SparkingData>/music/<name>.ogg|.mp3      (your own, no re-export needed)
##   res://music/<name>.ogg|.mp3|.wav          (shipped with the frontend)
## A missing track falls back to "main_menu"; no file at all = silence.
## The music fades out while a game runs (Dolphin's window is up) and picks up where it left off
## when the game closes.

const FALLBACK := "main_menu"
const FADE := 0.6
const SILENT_DB := -60.0

var _player: AudioStreamPlayer
var _old: AudioStreamPlayer       # the track fading out during a change
var _track := ""                  # requested track
var _current: AudioStream = null  # stream actually playing
var _game_running := false
var _cache := {}                  # name -> AudioStream (or null when missing)
var _tween: Tween


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_player = AudioStreamPlayer.new()
	add_child(_player)
	_old = AudioStreamPlayer.new()
	add_child(_old)
	Dolphin.event.connect(_on_dolphin_event)


func volume_db() -> float:
	var v := float(Settings.get_value("options", "music_volume")) / 10.0
	return SILENT_DB if v <= 0.0 else linear_to_db(v)


## Called by Main whenever the screen on top changes.
func play(track: String) -> void:
	if track == "":
		track = FALLBACK
	_track = track
	var stream := _find(track)
	if stream == null and track != FALLBACK:
		stream = _find(FALLBACK)
	if stream == _current:
		return   # same music on this screen too: keep it going
	_current = stream
	# Crossfade: the current track moves to the fading player.
	if _player.playing:
		var tmp := _old
		_old = _player
		_player = tmp
		var t := create_tween()
		t.tween_property(_old, "volume_db", SILENT_DB, FADE)
		t.tween_callback(_old.stop)
	_player.stop()
	_player.stream = stream
	if stream == null:
		return
	_player.volume_db = SILENT_DB
	_player.play()
	_player.stream_paused = _game_running
	if not _game_running:
		_fade_to(volume_db())


## Options > Music volume changed.
func apply_volume() -> void:
	if not _game_running and _player.playing:
		_fade_to(volume_db(), 0.15)


func is_audible() -> bool:
	return _player.stream != null and _player.playing and not _player.stream_paused


func is_muted_for_game() -> bool:
	return _game_running


func current_track() -> String:
	return _track


func _fade_to(db: float, time := FADE) -> void:
	if _tween and _tween.is_valid():
		_tween.kill()
	_tween = create_tween()
	_tween.tween_property(_player, "volume_db", db, time)


func set_game_running(running: bool) -> void:
	if running == _game_running:
		return
	_game_running = running
	if _player.stream == null:
		return
	if running:
		# Fade out, then pause (keeps the position for later).
		if _tween and _tween.is_valid():
			_tween.kill()
		_tween = create_tween()
		_tween.tween_property(_player, "volume_db", SILENT_DB, FADE)
		_tween.tween_callback(func(): _player.stream_paused = true)
		if _old.playing:
			_old.stop()
	else:
		_player.stream_paused = false
		if not _player.playing:
			_player.play()
		_fade_to(volume_db())


func _on_dolphin_event(name: String, _data: Dictionary) -> void:
	match name:
		"game_booting", "game_started":
			set_game_running(true)
		"game_stopped", "game_start_aborted", "process_exited":
			set_game_running(false)


## The stream for a track name, or null. Your own files win over the shipped ones.
func _find(name: String) -> AudioStream:
	if _cache.has(name):
		return _cache[name]
	var stream: AudioStream = null
	var user := Settings.data_path("music").path_join(name)
	if FileAccess.file_exists(user + ".ogg"):
		stream = AudioStreamOggVorbis.load_from_file(user + ".ogg")
	elif FileAccess.file_exists(user + ".mp3"):
		var mp3 := AudioStreamMP3.new()
		mp3.data = FileAccess.get_file_as_bytes(user + ".mp3")
		stream = mp3
	if stream == null:
		for ext in ["ogg", "mp3", "wav"]:
			var path := "res://music/%s.%s" % [name, ext]
			if ResourceLoader.exists(path):
				stream = load(path)
				break
	if stream:
		if "loop" in stream:
			stream.loop = true
		elif stream is AudioStreamWAV:
			stream.loop_mode = AudioStreamWAV.LOOP_FORWARD
			stream.loop_end = int(stream.get_length() * stream.mix_rate)
	if stream:
		_cache[name] = stream   # misses aren't cached: a file may be added, or the data folder set
	return stream


## Forget loaded files (e.g. after new ones were dropped into the folder).
func rescan() -> void:
	_cache.clear()
	_current = null
	play(_track)
