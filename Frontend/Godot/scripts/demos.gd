extends Node
## Tenkaichi Terminology demo GIFs: downloaded once from the community Google Doc (its public
## "mobilebasic" page: one table per category, rows of term | definition | GIF) into
## <SparkingData>/terminology/, then played from there. A GIF you put in that folder yourself,
## named like the term ("dragon-dash.gif", "blast-2-boost_2.gif" for a second one), is used as-is.
## Also decodes GIFs on worker threads for the screens (see Job).

signal status_changed(text: String)
signal demo_ready(slug: String)

const Gif := preload("res://scripts/util/gif.gd")
const INDEX_FILE := "index.json"
const UA := "Mozilla/5.0 (Windows NT 10.0; Win64; x64) DragonBallSparkingCollection/1.0"

var status := ""
var _index := {}          # slug -> [image urls]
var _index_state := ""    # "", loading, ready, failed
var _queue: Array = []    # [slug, file stem, candidate urls] waiting to download
var _pending: Array = []  # [slug, urgent] asked for before the index was loaded
var _busy := false
var _page: HTTPRequest
var _img: HTTPRequest
var _jobs := {}           # path -> Job
var _job_order: Array = []
var _tasks := {}          # path -> WorkerThreadPool task id, until collected


## Decoded frames of one GIF, filled by a worker thread; read on the main thread.
class Job:
	extends RefCounted
	var path := ""
	var mutex := Mutex.new()
	var images: Array = []
	var delays: Array = []
	var textures: Array = []   # main thread only
	var done := false
	var error := ""

	func run(max_size: Vector2i) -> void:
		var bytes := FileAccess.get_file_as_bytes(path)
		if bytes.size() >= 4 and bytes.slice(0, 3).get_string_from_ascii() == "GIF":
			var res := Gif.decode(bytes, max_size, 400, _add)
			mutex.lock()
			error = res.error
			done = true
			mutex.unlock()
			return
		# Not a GIF (the doc served a still image): show it as one frame.
		var img := Image.new()
		var err := img.load_png_from_buffer(bytes)
		if err != OK:
			err = img.load_jpg_from_buffer(bytes)
		if err != OK:
			err = img.load_webp_from_buffer(bytes)
		if err == OK:
			var s := minf(float(max_size.x) / img.get_width(), float(max_size.y) / img.get_height())
			if s < 1.0:
				img.resize(int(img.get_width() * s), int(img.get_height() * s), Image.INTERPOLATE_BILINEAR)
			_add(img, 3600.0)
		mutex.lock()
		error = "" if err == OK else "unreadable image"
		done = true
		mutex.unlock()

	func _add(img: Image, delay: float) -> void:
		mutex.lock()
		images.append(img)
		delays.append(delay)
		mutex.unlock()

	## Turns newly decoded frames into textures (main thread). Returns the frame count.
	func sync() -> int:
		mutex.lock()
		var have := textures.size()
		var todo := images.slice(have)
		mutex.unlock()
		for img in todo:
			textures.append(ImageTexture.create_from_image(img))
		return textures.size()

	func is_done() -> bool:
		mutex.lock()
		var d := done
		mutex.unlock()
		return d


func _ready() -> void:
	_page = HTTPRequest.new()
	_page.timeout = 30
	_page.request_completed.connect(_on_page)
	add_child(_page)
	_img = HTTPRequest.new()
	_img.timeout = 60
	_img.request_completed.connect(_on_image)
	add_child(_img)


func cache_dir() -> String:
	return Settings.data_path("terminology")


static func slug(term: String) -> String:
	var s := term.to_lower().replace("(tutorial)", "")
	var out := ""
	for c in s:
		out += c if (c >= "a" and c <= "z") or (c >= "0" and c <= "9") else "-"
	while "--" in out:
		out = out.replace("--", "-")
	return out.strip_edges().trim_prefix("-").trim_suffix("-")


## Local demo files for a term, in order (term.gif, term_2.gif, ...). Any image extension.
func files_for(term: String) -> PackedStringArray:
	var out := PackedStringArray()
	var base := cache_dir().path_join(slug(term))
	for n in range(1, 10):
		var stem := base if n == 1 else "%s_%d" % [base, n]
		var found := ""
		for ext in ["gif", "png", "jpg", "webp"]:
			if FileAccess.file_exists(stem + "." + ext):
				found = stem + "." + ext
				break
		if found == "":
			break
		out.append(found)
	return out


## The screen shows `term`: make sure its demo is downloaded (first in line).
func want(term: String) -> void:
	_ask([slug(term)], true)


## A category was opened: fetch its demos in the background.
func prefetch(terms: Array) -> void:
	var slugs: Array = []
	for t in terms:
		slugs.append(slug(String(t)))
	_ask(slugs, false)


func _ask(slugs: Array, urgent: bool) -> void:
	if _index_state == "ready":
		for s in slugs:
			_enqueue(s, urgent)
		return
	for s in slugs:
		_pending.append([s, urgent])
	if _index_state == "" or _index_state == "failed":
		_load_index()


## Does the doc have a demo for this term?
func listed(term: String) -> bool:
	return _index.has(slug(term))


func has_source() -> bool:
	return _index_state == "ready" and not _index.is_empty()


func index_state() -> String:
	return _index_state


func _set_status(text: String) -> void:
	status = text
	status_changed.emit(text)


func _load_index() -> void:
	var path := cache_dir().path_join(INDEX_FILE)
	if FileAccess.file_exists(path):
		var data = JSON.parse_string(FileAccess.get_file_as_string(path))
		if data is Dictionary and data.get("terms") is Dictionary and not data["terms"].is_empty() \
				and data.get("source", "") == Settings.get_value("terminology", "source"):
			_index = data["terms"]
			_index_state = "ready"
			_flush_pending()
			return
	_index_state = "loading"
	_set_status("Getting the demo list...")
	if _page.request(Settings.get_value("terminology", "source"), ["User-Agent: " + UA]) != OK:
		_index_state = "failed"
		_set_status("Couldn't reach the Terminology doc.")


func _on_page(result: int, code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	if result != HTTPRequest.RESULT_SUCCESS or code != 200:
		_index_state = "failed"
		_set_status("Couldn't download the demo list (offline?).")
		return
	_index = parse_doc(body.get_string_from_utf8())
	if _index.is_empty():
		_index_state = "failed"
		_set_status("The Terminology doc had no demos.")
		return
	_index_state = "ready"
	DirAccess.make_dir_recursive_absolute(cache_dir())
	var f := FileAccess.open(cache_dir().path_join(INDEX_FILE), FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify({"source": Settings.get_value("terminology", "source"),
			"fetched": Time.get_datetime_string_from_system(), "terms": _index}, " "))
	_set_status("")
	_flush_pending()


func _flush_pending() -> void:
	var p := _pending
	_pending = []
	# Urgent ones last so they end up first in the queue.
	for item in p:
		if not item[1]:
			_enqueue(item[0], false)
	for item in p:
		if item[1]:
			_enqueue(item[0], true)


## {slug: [image urls]} from the doc's HTML: every table row with images, keyed by its first cell.
static func parse_doc(html: String) -> Dictionary:
	var out := {}
	var cell_re := RegEx.create_from_string("(?s)<td[^>]*>(.*?)</td>")
	var img_re := RegEx.create_from_string("<img[^>]*?\\ssrc=\"([^\"]+)\"")
	var tag_re := RegEx.create_from_string("<[^>]+>")
	for row in html.split("<tr"):
		var cells := cell_re.search_all(row)
		if cells.size() < 2:
			continue
		var term := _unescape(tag_re.sub(cells[0].get_string(1), " ", true)).strip_edges()
		var urls: Array = []
		for m in img_re.search_all(row):
			urls.append(_unescape(m.get_string(1)))
		if term == "" or urls.is_empty():
			continue
		out[slug(term)] = urls
	return out


static func _unescape(s: String) -> String:
	s = s.replace("&nbsp;", " ").replace("&quot;", "\"").replace("&#39;", "'").replace("&lt;", "<") \
		.replace("&gt;", ">")
	var num := RegEx.create_from_string("&#(x?)([0-9a-fA-F]+);")
	for m in num.search_all(s):
		var code := m.get_string(2).hex_to_int() if m.get_string(1) == "x" else m.get_string(2).to_int()
		s = s.replace(m.get_string(0), String.chr(code))
	return s.replace("&amp;", "&")


func _enqueue(s: String, urgent: bool) -> void:
	if not _index.has(s):
		return
	var urls: Array = _index[s]
	for i in urls.size():
		var target := cache_dir().path_join(s if i == 0 else "%s_%d" % [s, i + 1])
		if _exists_any(target) or (_busy and _current[1] == target):
			continue
		var item := [s, target, _candidates(String(urls[i]))]
		for q in _queue:
			if q[1] == target:
				if urgent:
					_queue.erase(q)
				else:
					item = []
				break
		if item.is_empty():
			continue
		if urgent:
			_queue.push_front(item)
		else:
			_queue.append(item)
	_next()


func _exists_any(stem: String) -> bool:
	for ext in ["gif", "png", "jpg", "webp"]:
		if FileAccess.file_exists(stem + "." + ext):
			return true
	return false


## The doc links a resized copy (".../xyz=s650"): ask for the original first.
static func _candidates(url: String) -> Array:
	var eq := url.rfind("=")
	var slash := url.rfind("/")
	if eq > slash and eq > 0:
		return [url.substr(0, eq) + "=s0", url]
	return [url]


var _current: Array = []


func _next() -> void:
	if _busy or _queue.is_empty():
		return
	_current = _queue.pop_front()
	_busy = true
	_request_current()


func _request_current() -> void:
	var urls: Array = _current[2]
	if urls.is_empty():
		_busy = false
		_next()
		return
	var url: String = urls.pop_front()
	if _img.request(url, ["User-Agent: " + UA]) != OK:
		_request_current()


func _on_image(result: int, code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	var ext := _sniff(body)
	if result != HTTPRequest.RESULT_SUCCESS or code != 200 or ext == "":
		_request_current()   # next candidate URL, or give up on this one
		return
	DirAccess.make_dir_recursive_absolute(cache_dir())
	var path: String = _current[1] + "." + ext
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f:
		f.store_buffer(body)
		f.close()
		demo_ready.emit(_current[0])
	_busy = false
	var left := _queue.size()
	_set_status("" if left == 0 else "Downloading demos: %d left" % left)
	_next()


static func _sniff(b: PackedByteArray) -> String:
	if b.size() < 8:
		return ""
	if b[0] == 0x47 and b[1] == 0x49 and b[2] == 0x46:
		return "gif"
	if b[0] == 0x89 and b[1] == 0x50:
		return "png"
	if b[0] == 0xFF and b[1] == 0xD8:
		return "jpg"
	if b.size() > 11 and b[0] == 0x52 and b[1] == 0x49 and b[8] == 0x57 and b[9] == 0x45:
		return "webp"
	return ""


# --- decoding --------------------------------------------------------------------------

## Decoded frames for a file (shared; the last few stay in memory).
func job(path: String, max_size: Vector2i) -> Job:
	if _jobs.has(path):
		_job_order.erase(path)
		_job_order.append(path)
		return _jobs[path]
	var j := Job.new()
	j.path = path
	_jobs[path] = j
	_job_order.append(path)
	_tasks[path] = WorkerThreadPool.add_task(j.run.bind(max_size), false, "gif " + path.get_file())
	# Keep memory bounded: forget the oldest finished decodes.
	while _job_order.size() > 8:
		var old: String = _job_order[0]
		if not _jobs[old].is_done():
			break
		_job_order.pop_front()
		_jobs.erase(old)
	return j


func _process(_delta: float) -> void:
	# Collect finished decode tasks (WorkerThreadPool wants every task waited on).
	for path in _tasks.keys():
		if WorkerThreadPool.is_task_completed(_tasks[path]):
			WorkerThreadPool.wait_for_task_completion(_tasks[path])
			_tasks.erase(path)


func _exit_tree() -> void:
	for path in _tasks:
		WorkerThreadPool.wait_for_task_completion(_tasks[path])
	_tasks.clear()
