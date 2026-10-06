extends Node
## Sound effects. The sounds are set in res://look/menu_sounds.tres (Inspector slots), or as
## files named after a slot in <SparkingData>/sounds or res://sounds (move.wav, ...). Missing =
## silent. Volume: Options > Sound effects.
##
## Played by: the menu wheel and settings lists (move, select), Main (back), the lobby
## (player_join, player_leave, message) and Dolphin's game_starting / game_booting (game_start).

const SOUNDS_PATH := "res://look/menu_sounds.tres"
const NAMES := ["move", "select", "back", "player_join", "player_leave", "message", "game_start"]
const SILENT_DB := -60.0

var _sounds: Resource
var _cache := {}                 # name -> AudioStream or null
var _players: Array[AudioStreamPlayer] = []
var _next := 0
var _last_start := -100000       # ticks of the last game_start (netplay sends two events)
var played := {}                 # sound name -> times asked for (tests)


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	for i in 6:
		var p := AudioStreamPlayer.new()
		add_child(p)
		_players.append(p)
	reload()
	Dolphin.event.connect(_on_dolphin_event)


## Re-reads menu_sounds.tres and the sound folders (F9).
func reload() -> void:
	_sounds = ResourceLoader.load(SOUNDS_PATH, "", ResourceLoader.CACHE_MODE_REPLACE)
	_cache.clear()


func volume_db() -> float:
	var v := float(Settings.get_value("options", "sfx_volume")) / 10.0
	var extra: float = _sounds.volume_db if _sounds else 0.0
	return SILENT_DB if v <= 0.0 else linear_to_db(v) + extra


func play(name: String) -> void:
	played[name] = int(played.get(name, 0)) + 1
	var stream := stream_for(name)
	if stream == null or float(Settings.get_value("options", "sfx_volume")) <= 0.0:
		return
	var p := _players[_next]
	_next = (_next + 1) % _players.size()
	p.stream = stream
	p.volume_db = volume_db()
	p.play()


func stream_for(name: String) -> AudioStream:
	if _cache.has(name):
		return _cache[name]
	var stream: AudioStream = _load_file(Settings.data_path("sounds").path_join(name))
	if stream == null:
		for ext in ["wav", "ogg", "mp3"]:
			var path := "res://sounds/%s.%s" % [name, ext]
			if ResourceLoader.exists(path):
				stream = load(path)
				break
	if stream == null and _sounds and name in _sounds:
		stream = _sounds.get(name)
	if Settings.data_dir() != "":   # don't remember misses before the data folder is known
		_cache[name] = stream
	return stream


func _load_file(base: String) -> AudioStream:
	if FileAccess.file_exists(base + ".wav"):
		return AudioStreamWAV.load_from_file(base + ".wav")
	if FileAccess.file_exists(base + ".ogg"):
		return AudioStreamOggVorbis.load_from_file(base + ".ogg")
	if FileAccess.file_exists(base + ".mp3"):
		var mp3 := AudioStreamMP3.new()
		mp3.data = FileAccess.get_file_as_bytes(base + ".mp3")
		return mp3
	return null


func _on_dolphin_event(name: String, _data: Dictionary) -> void:
	# Netplay: game_starting when the host presses Start (everyone), then game_booting.
	# Offline: only game_booting.
	if name == "game_starting" or name == "game_booting":
		var now := Time.get_ticks_msec()
		if now - _last_start > 15000:
			play("game_start")
		_last_start = now
	elif name == "game_stopped" or name == "process_exited" or name == "game_start_aborted":
		_last_start = -100000
