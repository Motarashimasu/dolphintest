extends Control
## Plays one or more GIFs in a row (each once, then the next, looping), decoding on a worker
## thread through Demos.job() and starting as soon as the first frame is ready.

var _paths := PackedStringArray()
var _which := 0
var _job = null       # Demos.Job
var _frame := -1
var _time := 0.0
var _rect: TextureRect


func _init() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE


func _ready() -> void:
	_rect = TextureRect.new()
	_rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_rect.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
	_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_rect.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(_rect)


func play(paths: PackedStringArray) -> void:
	if paths == _paths and _job != null:
		return
	_paths = paths
	_which = 0
	_start()


func stop() -> void:
	_paths = PackedStringArray()
	_job = null
	if _rect:
		_rect.texture = null


func is_showing() -> bool:
	return _rect != null and _rect.texture != null


func _start() -> void:
	_frame = -1
	_time = 0.0
	if _paths.is_empty():
		_job = null
		_rect.texture = null
		return
	_job = Demos.job(_paths[_which], Vector2i(size))


func _process(delta: float) -> void:
	if _job == null:
		return
	var count: int = _job.sync()
	if count == 0:
		return
	if _frame < 0:
		_frame = 0
		_time = 0.0
		_rect.texture = _job.textures[0]
		return
	_time += delta
	var delay: float = _job.delays[_frame]
	if _time < delay:
		return
	_time -= delay
	if _time > 1.0:
		_time = 0.0   # hitch (window was hidden): don't fast-forward
	var next := _frame + 1
	if next >= count:
		if not _job.is_done():
			_time = 0.0   # decoder still behind: hold this frame
			return
		if _paths.size() > 1:
			_which = (_which + 1) % _paths.size()
			_start()
			return
		next = 0
	_frame = next
	_rect.texture = _job.textures[_frame]
