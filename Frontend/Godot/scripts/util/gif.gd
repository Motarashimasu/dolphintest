extends RefCounted
## Minimal animated GIF decoder (Godot has no GIF support). Handles global/local palettes,
## transparency, interlacing and the three disposal methods. Safe to run on a worker thread.
##
##   var anim := Gif.decode(bytes, Vector2i(480, 360))
##   anim.frames  -> Array of Image (RGBA8, scaled to fit max_size, aspect kept)
##   anim.delays  -> PackedFloat32Array, seconds per frame
##   anim.error   -> "" or a reason
## `on_frame(image, delay)` is called for every frame as soon as it's ready.

const MIN_DELAY := 0.02   # browsers treat 0-1 cs delays as 0.1 s; we keep them short but sane


static func decode(data: PackedByteArray, max_size := Vector2i(0, 0), max_frames := 400,
		on_frame := Callable()) -> Dictionary:
	var out := {"frames": [], "delays": PackedFloat32Array(), "error": "", "size": Vector2i.ZERO}
	if data.size() < 13 or data.slice(0, 3).get_string_from_ascii() != "GIF":
		out.error = "not a GIF"
		return out
	var w := data[6] | (data[7] << 8)
	var h := data[8] | (data[9] << 8)
	out.size = Vector2i(w, h)
	if w <= 0 or h <= 0 or w > 4096 or h > 4096:
		out.error = "bad size"
		return out
	var flags := data[10]
	var bg_index := data[11]
	var pos := 13
	var global_pal := PackedByteArray()
	if flags & 0x80:
		var n := 3 * (1 << ((flags & 7) + 1))
		global_pal = data.slice(pos, pos + n)
		pos += n

	# Frames are composed straight at the display size (nearest sample): much less work than
	# composing at full size and scaling down.
	var target := _fit(Vector2i(w, h), max_size)
	var tw := target.x
	var th := target.y
	var sx_map := PackedInt32Array()
	sx_map.resize(tw)
	for x in tw:
		sx_map[x] = mini(int((x + 0.5) * w / tw), w - 1)
	var sy_map := PackedInt32Array()
	sy_map.resize(th)
	for y in th:
		sy_map[y] = mini(int((y + 0.5) * h / th), h - 1)
	var canvas := PackedByteArray()
	canvas.resize(tw * th * 4)   # transparent black
	var previous := PackedByteArray()

	var delay := 0.1
	var transparent := -1
	var disposal := 0
	var size := data.size()
	while pos < size:
		var block := data[pos]
		pos += 1
		if block == 0x3B:   # trailer
			break
		elif block == 0x21:   # extension
			if pos >= size:
				break
			var label := data[pos]
			pos += 1
			if label == 0xF9 and pos + 5 < size and data[pos] == 4:
				var gflags := data[pos + 1]
				disposal = (gflags >> 2) & 7
				var cs := data[pos + 2] | (data[pos + 3] << 8)
				delay = maxf(cs / 100.0, MIN_DELAY) if cs > 1 else 0.1
				transparent = data[pos + 4] if gflags & 1 else -1
			pos = _skip_blocks(data, pos)
		elif block == 0x2C:   # image
			if pos + 9 > size:
				break
			var fx := data[pos] | (data[pos + 1] << 8)
			var fy := data[pos + 2] | (data[pos + 3] << 8)
			var fw := data[pos + 4] | (data[pos + 5] << 8)
			var fh := data[pos + 6] | (data[pos + 7] << 8)
			var iflags := data[pos + 8]
			pos += 9
			var pal := global_pal
			if iflags & 0x80:
				var n := 3 * (1 << ((iflags & 7) + 1))
				pal = data.slice(pos, pos + n)
				pos += n
			var interlaced := (iflags & 0x40) != 0
			if pos >= size:
				break
			var min_code := data[pos]
			pos += 1
			var lzw := PackedByteArray()
			while pos < size:
				var n := data[pos]
				pos += 1
				if n == 0:
					break
				lzw.append_array(data.slice(pos, pos + n))
				pos += n
			if disposal == 3:
				previous = canvas.duplicate()
			var indices := _lzw(lzw, min_code, fw * fh)
			_draw(canvas, tw, th, sx_map, sy_map, indices, pal, transparent, fx, fy, fw, fh, interlaced)

			var img := Image.create_from_data(tw, th, false, Image.FORMAT_RGBA8, canvas)
			out.frames.append(img)
			out.delays.append(delay)
			if on_frame.is_valid():   # stream frames as they decode (called on this thread)
				on_frame.call(img, delay)
			if out.frames.size() >= max_frames:
				break

			# Disposal: what the next frame starts from.
			if disposal == 2:
				_clear_rect(canvas, tw, th, sx_map, sy_map, fx, fy, fw, fh)
			elif disposal == 3 and not previous.is_empty():
				canvas = previous
			delay = 0.1
			transparent = -1
			disposal = 0
		else:
			break   # unknown block: stop with what we have
	if out.frames.is_empty() and out.error == "":
		out.error = "no frames"
	return out


static func _fit(size: Vector2i, max_size: Vector2i) -> Vector2i:
	if max_size.x <= 0 or max_size.y <= 0:
		return size
	var s := minf(float(max_size.x) / size.x, float(max_size.y) / size.y)
	if s >= 1.0:
		return size
	return Vector2i(maxi(1, int(size.x * s)), maxi(1, int(size.y * s)))


static func _skip_blocks(data: PackedByteArray, pos: int) -> int:
	while pos < data.size():
		var n := data[pos]
		pos += 1
		if n == 0:
			break
		pos += n
	return pos


static func _lzw(data: PackedByteArray, min_code: int, npix: int) -> PackedByteArray:
	var out := PackedByteArray()
	out.resize(npix)
	if min_code < 2 or min_code > 11:
		return out
	var clear := 1 << min_code
	var eoi := clear + 1
	var prefix := PackedInt32Array()
	prefix.resize(4096)
	var suffix := PackedByteArray()
	suffix.resize(4096)
	var stack := PackedByteArray()
	stack.resize(4097)
	for i in clear:
		suffix[i] = i
	var code_size := min_code + 1
	var mask := (1 << code_size) - 1
	var next := eoi + 1
	var old := -1
	var first := 0
	var bits := 0
	var nbits := 0
	var pos := 0
	var n := data.size()
	var o := 0
	while o < npix:
		while nbits < code_size:
			if pos >= n:
				return out
			bits |= data[pos] << nbits
			pos += 1
			nbits += 8
		var code := bits & mask
		bits >>= code_size
		nbits -= code_size
		if code == clear:
			code_size = min_code + 1
			mask = (1 << code_size) - 1
			next = eoi + 1
			old = -1
			continue
		if code == eoi:
			break
		if old == -1:
			if code >= clear:
				break   # corrupt
			out[o] = code
			o += 1
			old = code
			first = code
			continue
		var in_code := code
		var sp := 0
		if code >= next:
			stack[sp] = first
			sp += 1
			code = old
		while code >= clear:
			stack[sp] = suffix[code]
			sp += 1
			code = prefix[code]
		first = suffix[code]
		stack[sp] = first
		sp += 1
		if next < 4096:
			prefix[next] = old
			suffix[next] = first
			next += 1
			if next > mask and code_size < 12:
				code_size += 1
				mask = (1 << code_size) - 1
		while sp > 0 and o < npix:
			sp -= 1
			out[o] = stack[sp]
			o += 1
		old = in_code
	return out


## Target pixels (tx, ty) whose source pixel (sx_map[tx], sy_map[ty]) is inside the frame.
static func _span(map: PackedInt32Array, lo: int, hi: int) -> Vector2i:
	var a := -1
	var b := -1
	for i in map.size():
		if map[i] >= lo and map[i] < hi:
			if a < 0:
				a = i
			b = i
	return Vector2i(a, b + 1) if a >= 0 else Vector2i(0, 0)


static func _draw(canvas: PackedByteArray, tw: int, th: int, sx_map: PackedInt32Array,
		sy_map: PackedInt32Array, indices: PackedByteArray, pal: PackedByteArray, transparent: int,
		fx: int, fy: int, fw: int, fh: int, interlaced: bool) -> void:
	var ncolors := pal.size() / 3
	# Where each frame row starts in the (possibly interlaced) index stream.
	var row_start := PackedInt32Array()
	row_start.resize(fh)
	if interlaced:
		var r := 0
		for pass_ in [[0, 8], [4, 8], [2, 4], [1, 2]]:
			var y: int = pass_[0]
			while y < fh:
				row_start[y] = r * fw
				r += 1
				y += pass_[1]
	else:
		for y in fh:
			row_start[y] = y * fw
	var xs := _span(sx_map, fx, fx + fw)
	var ys := _span(sy_map, fy, fy + fh)
	var n := indices.size()
	for ty in range(ys.x, ys.y):
		var base := row_start[sy_map[ty] - fy] - fx
		var dst := (ty * tw + xs.x) * 4
		for tx in range(xs.x, xs.y):
			var i := base + sx_map[tx]
			var idx := indices[i] if i < n else 0
			if idx != transparent and idx < ncolors:
				var p := idx * 3
				canvas[dst] = pal[p]
				canvas[dst + 1] = pal[p + 1]
				canvas[dst + 2] = pal[p + 2]
				canvas[dst + 3] = 255
			dst += 4


static func _clear_rect(canvas: PackedByteArray, tw: int, th: int, sx_map: PackedInt32Array,
		sy_map: PackedInt32Array, fx: int, fy: int, fw: int, fh: int) -> void:
	var xs := _span(sx_map, fx, fx + fw)
	var ys := _span(sy_map, fy, fy + fh)
	for ty in range(ys.x, ys.y):
		var start := (ty * tw + xs.x) * 4
		var end := (ty * tw + xs.y) * 4
		for i in range(start, end):
			canvas[i] = 0
