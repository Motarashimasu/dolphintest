extends RefCounted
## DRAGON NET profile pictures (Server/ranked: account.php > picture, pic.php): downloaded once
## per address, then shared by every screen. A new picture has a new address (?v=...), so a
## cached one is never stale.
##   Pictures.Box     a square showing a player's picture, or their initial until it's there
##   Pictures.apply(texture_rect, url)

const SIZE := 128   # what the server takes: SIZE x SIZE (the crop screen makes it)

static var _cache := {}     # url -> Texture2D (null while downloading)
static var _waiting := {}   # url -> [WeakRef of TextureRect]


## Shows the picture at `url` in `rect` (nothing while it downloads, or if there's none).
static func apply(rect: TextureRect, url: String) -> void:
	rect.set_meta("pic_url", url)
	if url == "":
		rect.texture = null
		return
	var have = _cache.get(url)
	if have is Texture2D:
		rect.texture = have
		return
	rect.texture = null
	if not _waiting.has(url):
		_waiting[url] = []
	_waiting[url].append(weakref(rect))
	if _cache.has(url):
		return   # already downloading
	_cache[url] = null
	var req := HTTPRequest.new()
	req.timeout = 20.0
	Ranked.add_child(req)
	req.request_completed.connect(func(result: int, code: int, _h: PackedStringArray, body: PackedByteArray):
		req.queue_free()
		var tex: Texture2D = null
		if result == HTTPRequest.RESULT_SUCCESS and code == 200:
			tex = texture_from(body)
		if tex:
			_cache[url] = tex
		else:
			_cache.erase(url)   # try again next time
		for w in _waiting.get(url, []):
			var r = w.get_ref()
			if r and is_instance_valid(r) and String(r.get_meta("pic_url", "")) == url:
				r.texture = tex
		_waiting.erase(url))
	if req.request(url) != OK:
		req.queue_free()
		_cache.erase(url)
		_waiting.erase(url)


static func texture_from(bytes: PackedByteArray) -> Texture2D:
	var img := Image.new()
	if img.load_png_from_buffer(bytes) != OK and img.load_jpg_from_buffer(bytes) != OK \
			and img.load_webp_from_buffer(bytes) != OK:
		return null
	return ImageTexture.create_from_image(img)


## A just-uploaded picture: no need to download it again.
static func remember(url: String, img: Image) -> void:
	if url != "" and img:
		_cache[url] = ImageTexture.create_from_image(img)


## A square picture box: a rounded dark plate, the player's initial, and the picture over it.
class Box extends Control:
	var _bg: Panel
	var _initial: Label
	var _pic: TextureRect

	func _init() -> void:
		mouse_filter = Control.MOUSE_FILTER_IGNORE
		_bg = Panel.new()
		var sb := StyleBoxFlat.new()
		sb.bg_color = Color(0.04, 0.12, 0.17, 0.85)
		sb.border_color = Color(1, 1, 1, 0.55)
		sb.set_border_width_all(2)
		sb.set_corner_radius_all(6)
		_bg.add_theme_stylebox_override("panel", sb)
		_bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
		add_child(_bg)
		_initial = Label.new()
		_initial.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		_initial.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		_initial.add_theme_color_override("font_color", Color(1, 1, 1, 0.8))
		_initial.auto_translate_mode = Node.AUTO_TRANSLATE_MODE_DISABLED
		add_child(_initial)
		_pic = TextureRect.new()
		_pic.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		_pic.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		_pic.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
		_pic.mouse_filter = Control.MOUSE_FILTER_IGNORE
		add_child(_pic)
		resized.connect(_layout)

	## `url` = the picture ("" = none: the initial of `name`).
	func show_player(url: String, name: String) -> void:
		_initial.text = name.left(1).to_upper()
		Pictures_apply(_pic, url)

	func show_image(img: Image) -> void:
		_pic.texture = ImageTexture.create_from_image(img) if img else null

	func _layout() -> void:
		for c in [_bg, _initial, _pic]:
			c.position = Vector2.ZERO
			c.size = size
		_pic.position = Vector2(2, 2)
		_pic.size = size - Vector2(4, 4)
		_initial.add_theme_font_size_override("font_size", int(size.y * 0.55))

	static func Pictures_apply(rect: TextureRect, url: String) -> void:
		load("res://scripts/pictures.gd").apply(rect, url)
