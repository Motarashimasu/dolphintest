extends Node
## Automatic updates (Docs/UPDATES.md). The release script (Tools/sparking_release.py) uploads a
## build to Cloudflare R2: every file under its SHA-256, and a signed list of the build's files
## (the manifest). Here:
##   1. the ranked server's update.php gives logged-in DRAGON NET players a short-lived link to
##      the manifest; its signature is checked against data/update_key.pem (the release key's
##      public half), so only builds you signed are ever installed;
##   2. the files that differ from this install are downloaded (links from update.php again)
##      into SparkingData/update/download and each one's SHA-256 is checked;
##   3. they're put in place. The launcher's own files (its .exe, its .pck) can't be replaced
##      while it runs: a small PowerShell script waits for the launcher to close, moves them in
##      and starts it again.
## Only files listed in a manifest are touched: saves, settings, controller profiles, replays...
## are never in one. A file the previous update installed that the new one no longer lists is
## deleted. SparkingData/update/installed.json remembers each managed file's size, time and
## hash; SparkingData/update/hashes.json caches every managed file's hash by size and time, so
## unchanged files aren't hashed again on every start.

signal changed   # state / progress
signal found     # a newer build is available (check() found one): Main opens the update screen

const HttpWait := preload("res://scripts/util/http_wait.gd")
const KEY_PATH := "res://data/update_key.pem"   # the release key's public half (keygen)
const BATCH := 400             # links per update.php call
const STALL_SECONDS := 30.0    # a download that gets nothing for this long has failed

## idle, checking, available, up_to_date, downloading, applying, restarting, failed, no_login, off
var state := "idle"
var error := ""                # what went wrong (failed), in English: shown through tr()
var detail := ""               # ...and the server's answer (error code, HTTP status), for reports
var version := ""              # the newest build's version (once known)
var notes := ""
var done_bytes := 0
var total_bytes := 0
var file_count := 0
var cancelled := false
## Tests: called instead of starting the restart script and quitting (the test runs the script).
var restart_hook: Callable

var _manifest := {}
var _need: Array = []
## Tests: the launcher's own files (relative paths), instead of the running .exe / .pck.
var own_files_override: Array = []
var _checked := false          # checked once this session (start, or right after a login)


func _ready() -> void:
	# Logged in for the first time this session: check then (the start-up check needed a login).
	Ranked.changed.connect(func():
		if Ranked.logged_in() and not _checked and enabled() and not busy():
			check(false))


## Updates work in the exported launcher (or with [update] root set, for tests) once the
## release key is in data/update_key.pem.
func enabled() -> bool:
	return FileAccess.file_exists(key_path()) and (root() != "")


## Which build this launcher takes: each platform has its own signed list on the server.
## ([update] platform: tests only.)
func platform() -> String:
	var forced := String(Settings.get_value("update", "platform"))
	if forced != "":
		return forced
	return "linux" if OS.get_name() in ["Linux", "FreeBSD", "NetBSD", "OpenBSD", "BSD"] else "windows"


## Linux: files that must be runnable (the launcher, Dolphin's programs). Windows doesn't keep
## Linux's "executable" mark, so it's set here after every update by name.
static func is_executable(rel: String) -> bool:
	return rel.ends_with(".x86_64") or rel.ends_with(".sh") \
			or (rel.begins_with("Dolphin/") and rel.count("/") == 1 and not "." in rel.get_file())


func _make_executable(rel: String) -> void:
	if platform() == "linux" and is_executable(rel) and FileAccess.file_exists(root().path_join(rel)):
		FileAccess.set_unix_permissions(root().path_join(rel), 493)   # rwxr-xr-x


## The public key ([update] key: tests only, never a shipped build's).
func key_path() -> String:
	var forced := String(Settings.get_value("update", "key"))
	return forced if forced != "" else KEY_PATH


## The install folder: the launcher's own (or [update] root).
func root() -> String:
	var forced := String(Settings.get_value("update", "root"))
	if forced != "":
		return forced
	if OS.has_feature("template") and not OS.has_feature("editor"):
		return OS.get_executable_path().get_base_dir()
	return ""


func busy() -> bool:
	return state in ["checking", "downloading", "applying", "restarting"]


func _to_state(s: String, err := "") -> void:
	state = s
	error = err
	if err == "":
		detail = ""
	else:
		print("Updater: ", err, " (", detail, ")")
	changed.emit()


## Checks for a newer build and, when there is one, downloads and installs it. Returns the final
## state. `apply` false: only find out whether there's one (state "available").
func check(apply := true) -> String:
	if busy():
		return state
	_checked = true
	cancelled = false
	if not enabled():
		_to_state("off")
		return state
	if not Ranked.logged_in():
		_to_state("no_login")
		return state
	_to_state("checking")
	var r: Dictionary = await Ranked.api("update.php", {"action": "check", "platform": platform()})
	if not r.get("ok", false):
		if r.get("error") == "login_required":   # the login expired (Ranked forgot it): log in again
			_to_state("no_login")
			return state
		detail = _detail(r)
		_to_state("failed", "updates_not_set_up" if r.get("error") == "updates_not_set_up" else "Couldn't reach the update server.")
		return state
	var got := await _get_bytes(String(r["manifest_url"]))
	if got.is_empty():
		_to_state("failed", "Couldn't download the update list.")
		return state
	var m := _verified(got)
	if m.is_empty():
		_to_state("failed", "The update list isn't signed by the release key: not installed.")
		return state
	if String(m.get("platform", "windows")) != platform():
		_to_state("failed", "The update list is for another system: not installed.")
		return state
	# Never back to an older build than the one installed (an old signed list put back).
	if int(m.get("build", 0)) < int(_installed().get("build", 0)):
		version = String(_installed().get("version", ""))
		_to_state("up_to_date")
		return state
	_manifest = m
	version = String(m.get("version", ""))
	notes = String(m.get("notes", ""))
	var need: Array = await _outdated(m)
	if need.is_empty() and _removed(m).is_empty():
		_save_installed(m, {})
		_clear_restart_mark()
		_to_state("up_to_date")
		return state
	_need = need
	file_count = need.size()
	total_bytes = 0
	for f in need:
		total_bytes += int(f["size"])
	done_bytes = 0
	_to_state("available")
	if apply:
		return await install()
	found.emit()
	return state


## Downloads and installs what check() found ("available").
func install() -> String:
	if state != "available" or Dolphin.is_running():
		return state   # (a running game holds Dolphin's files: after it closes)
	cancelled = false
	return await _install(_manifest, _need)


func cancel() -> void:
	cancelled = true


# --- Manifest ---------------------------------------------------------------------------------

## The manifest, if its signature is the release key's ({} otherwise).
func _verified(envelope_bytes: PackedByteArray) -> Dictionary:
	var env = JSON.parse_string(envelope_bytes.get_string_from_utf8())
	if not env is Dictionary or not env.has("manifest") or not env.has("signature"):
		return {}
	var data := Marshalls.base64_to_raw(String(env["manifest"]))
	var sig := Marshalls.base64_to_raw(String(env["signature"]))
	var key := CryptoKey.new()
	if key.load_from_string(FileAccess.get_file_as_string(key_path()), true) != OK:
		push_warning("Updater: data/update_key.pem isn't a public key")
		return {}
	var hc := HashingContext.new()
	hc.start(HashingContext.HASH_SHA256)
	hc.update(data)
	if not Crypto.new().verify(HashingContext.HASH_SHA256, hc.finish(), sig, key):
		return {}
	var m = JSON.parse_string(data.get_string_from_utf8())
	if not m is Dictionary or int(m.get("format", 0)) != 1 or not m.get("files") is Array:
		return {}
	for f in m["files"]:
		var p := String(f.get("path", ""))
		# Paths stay inside the install folder.
		if p == "" or p.begins_with("/") or ":" in p or ".." in p.split("/") or "\\" in p \
				or not RegEx.create_from_string("^[0-9a-f]{64}$").search(String(f.get("sha256", ""))):
			return {}
	return m


func _installed_path() -> String:
	return root().path_join("SparkingData/update/installed.json")


func _installed() -> Dictionary:
	var d = JSON.parse_string(FileAccess.get_file_as_string(_installed_path())) \
			if FileAccess.file_exists(_installed_path()) else null
	return d if d is Dictionary else {"files": {}}


## The local file's SHA-256: from the cache (hashes.json) while its size and time haven't
## changed, else hashed again, in pieces, giving the menus a frame now and then (the first check
## of a 1.6 GB texture pack must not freeze them).
func _local_sha(rel: String, cache: Dictionary) -> String:
	var path := root().path_join(rel)
	if not FileAccess.file_exists(path):
		cache.erase(rel)
		return ""
	var size := _size(path)
	var mtime := FileAccess.get_modified_time(path)
	var k: Dictionary = cache.get(rel, {})
	if int(k.get("size", -1)) == size and int(k.get("mtime", -1)) == mtime and String(k.get("sha256", "")) != "":
		return String(k["sha256"])
	var sha: String = await _hash_file(path)
	cache[rel] = {"size": size, "mtime": mtime, "sha256": sha}
	return sha


var _frame_start := 0

## SHA-256 of a file, 1 MB at a time, letting a frame through every ~12 ms of work.
func _hash_file(path: String) -> String:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return ""
	var hc := HashingContext.new()
	hc.start(HashingContext.HASH_SHA256)
	while f.get_position() < f.get_length():
		hc.update(f.get_buffer(1048576))
		if Time.get_ticks_msec() - _frame_start > 12:
			await get_tree().process_frame
			_frame_start = Time.get_ticks_msec()
	return hc.finish().hex_encode()


static func _size(path: String) -> int:
	var f := FileAccess.open(path, FileAccess.READ)
	return f.get_length() if f else -1


func _hashes_path() -> String:
	return root().path_join("SparkingData/update/hashes.json")


func _load_hashes() -> Dictionary:
	var d = JSON.parse_string(FileAccess.get_file_as_string(_hashes_path())) \
			if FileAccess.file_exists(_hashes_path()) else null
	return d if d is Dictionary else {}


func _save_hashes(cache: Dictionary) -> void:
	DirAccess.make_dir_recursive_absolute(_hashes_path().get_base_dir())
	var out := FileAccess.open(_hashes_path(), FileAccess.WRITE)
	if out:
		out.store_string(JSON.stringify(cache))


func _outdated(m: Dictionary) -> Array:
	var cache := _load_hashes()
	_frame_start = Time.get_ticks_msec()
	var out := []
	for f in m["files"]:
		if await _local_sha(String(f["path"]), cache) != String(f["sha256"]):
			out.append(f)
	_save_hashes(cache)   # (a "Later" doesn't hash it all again next start)
	return out


## Files the previous update installed that this one no longer has.
func _removed(m: Dictionary) -> Array:
	var now := {}
	for f in m["files"]:
		now[String(f["path"])] = true
	var out := []
	for rel in _installed().get("files", {}):
		if not now.has(rel) and FileAccess.file_exists(root().path_join(rel)):
			out.append(rel)
	return out


func _save_installed(m: Dictionary, pending: Dictionary) -> void:
	var files := {}
	for f in m["files"]:
		var rel := String(f["path"])
		var path := root().path_join(rel)
		# A file still waiting for the restart script: hashed again next time.
		files[rel] = {"sha256": String(f["sha256"]), "size": int(f["size"]),
			"mtime": -1 if pending.has(rel) else FileAccess.get_modified_time(path)}
	var cache := _load_hashes()
	for rel in files:
		cache[rel] = files[rel]
	_save_hashes(cache)
	DirAccess.make_dir_recursive_absolute(_installed_path().get_base_dir())
	var out := FileAccess.open(_installed_path(), FileAccess.WRITE)
	if out:
		out.store_string(JSON.stringify({"version": m.get("version", ""), "build": m.get("build", 0),
			"files": files}, " "))


# --- Download and install ---------------------------------------------------------------------

func _staging() -> String:
	return root().path_join("SparkingData/update/download")


func _install(m: Dictionary, need: Array) -> String:
	if DirAccess.make_dir_recursive_absolute(_staging()) != OK or not _writable(root()):
		_to_state("failed", "The game folder is read-only (Program Files?). Move it, or run as administrator.")
		return state
	for n in DirAccess.get_files_at(_staging()):
		if n.ends_with(".part"):   # (left by builds up to 209, which renamed after downloading)
			DirAccess.remove_absolute(_staging().path_join(n))
	_to_state("downloading")
	# Links for the files we don't have staged yet (a cancelled update keeps what it got).
	var todo := {}
	for f in need:
		var staged := _staging().path_join(String(f["sha256"]))
		if FileAccess.file_exists(staged) and FileAccess.get_sha256(staged) == String(f["sha256"]):
			done_bytes += int(f["size"])
			continue
		todo[String(f["sha256"])] = f
	changed.emit()
	var shas: Array = todo.keys()
	for start in range(0, shas.size(), BATCH):
		var batch := shas.slice(start, start + BATCH)
		var r: Dictionary = await Ranked.api("update.php", {"action": "files", "files": batch})
		if not r.get("ok", false):
			detail = _detail(r)
			_to_state("failed", "Couldn't reach the update server.")
			return state
		for sha in batch:
			if cancelled:
				_to_state("idle")
				return state
			var f: Dictionary = todo[sha]
			if not await _download(String(r["urls"][sha]), String(sha), int(f["size"])):
				if cancelled:
					_to_state("idle")
					return state
				_to_state("failed", "A download failed or arrived damaged. Try again later.")
				return state
	_to_state("applying")
	var pending := {}   # rel path -> staged file: for the restart script
	var self_files := _own_files()
	for f in need:
		var rel := String(f["path"])
		var staged := _staging().path_join(String(f["sha256"]))
		if self_files.has(rel) or not _replace(staged, root().path_join(rel)):
			pending[rel] = staged
		else:
			_make_executable(rel)
	for rel in _removed(m):
		if not self_files.has(rel):
			DirAccess.remove_absolute(root().path_join(rel))
	if pending.is_empty():
		_save_installed(m, pending)
		_clear_staging()
		_clear_restart_mark()
		_to_state("up_to_date")
		return state
	# The restart script copies these in after the launcher closes: they must all be there, and
	# a restart that already happened for this build without them getting in must not repeat
	# (it would loop: restart, same update, restart...).
	for rel in pending:
		if not FileAccess.file_exists(pending[rel]):
			_to_state("failed", "A download failed or arrived damaged. Try again later.")
			return state
	if _restarted_for(m):
		_to_state("failed", "The update couldn't replace the launcher's files (in use, or blocked by antivirus?). Close other copies of the launcher and try again, or reinstall.")
		return state
	_save_installed(m, pending)
	_mark_restart(m)
	_to_state("restarting")
	_restart_with(pending, String(m.get("launcher", "")))
	return state


func _restart_mark_path() -> String:
	return root().path_join("SparkingData/update/restarted.json")


## Restarted to install this build less than 10 minutes ago (and it still isn't in).
func _restarted_for(m: Dictionary) -> bool:
	var d = JSON.parse_string(FileAccess.get_file_as_string(_restart_mark_path())) \
			if FileAccess.file_exists(_restart_mark_path()) else null
	return d is Dictionary and int(d.get("build", -1)) == int(m.get("build", 0)) \
			and Time.get_unix_time_from_system() - float(d.get("at", 0)) < 600.0


func _mark_restart(m: Dictionary) -> void:
	var f := FileAccess.open(_restart_mark_path(), FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify({"build": int(m.get("build", 0)), "at": Time.get_unix_time_from_system()}))


func _clear_restart_mark() -> void:
	if FileAccess.file_exists(_restart_mark_path()):
		DirAccess.remove_absolute(_restart_mark_path())


## The launcher's own files, relative to the install folder: its .exe and its .pck.
func _own_files() -> Dictionary:
	var out := {}
	for rel in own_files_override:
		out[String(rel)] = true
	if not own_files_override.is_empty():
		return out
	var exe := OS.get_executable_path()
	for p in [exe, exe.get_basename() + ".pck"]:
		if p.begins_with(root() + "/"):
			out[p.substr(root().length() + 1)] = true
	return out


func _writable(dir: String) -> bool:
	var probe := dir.path_join("SparkingData/update/.write_test")
	var f := FileAccess.open(probe, FileAccess.WRITE)
	if f == null:
		return false
	f.close()
	DirAccess.remove_absolute(probe)
	return true


## Moves the staged file into place (the old one out of the way first). false: couldn't (in use).
func _replace(staged: String, target: String) -> bool:
	DirAccess.make_dir_recursive_absolute(target.get_base_dir())
	var old := target + ".old"
	if FileAccess.file_exists(old):
		DirAccess.remove_absolute(old)
	if FileAccess.file_exists(target) and DirAccess.rename_absolute(target, old) != OK:
		return false
	if DirAccess.rename_absolute(staged, target) != OK and DirAccess.copy_absolute(staged, target) != OK:
		if FileAccess.file_exists(old):
			DirAccess.rename_absolute(old, target)   # put the old one back
		return false
	DirAccess.remove_absolute(old)
	if FileAccess.file_exists(staged):
		DirAccess.remove_absolute(staged)
	return true


func _clear_staging() -> void:
	for n in DirAccess.get_files_at(_staging()):
		DirAccess.remove_absolute(_staging().path_join(n))


func _get_bytes(url: String) -> PackedByteArray:
	var req := HTTPRequest.new()
	add_child(req)
	if req.request(url) != OK:
		req.queue_free()
		return PackedByteArray()
	var res: Array = await HttpWait.done(req, 30.0)
	req.queue_free()
	if int(res[0]) != HTTPRequest.RESULT_SUCCESS or int(res[1]) != 200:
		return PackedByteArray()
	return res[3]


## Downloads one file into staging and checks its SHA-256.
func _download(url: String, sha: String, size: int) -> bool:
	# Straight under its final name, no rename afterwards: Windows (Defender scanning a new .exe,
	# for one) can hold a just-written file open, and a rename then fails. A file that's cut off or
	# damaged never passes the SHA-256 check below or the one before it's used.
	var part := _staging().path_join(sha)
	var req := HTTPRequest.new()
	req.download_file = part
	req.download_chunk_size = 262144
	req.timeout = 0.0   # big files: no overall limit (a stall still ends the connection)
	add_child(req)
	var base := done_bytes
	if req.request(url) != OK:
		req.queue_free()
		return false
	var done := {}   # (a lambda can't assign this function's locals: it fills this)
	req.request_completed.connect(func(a, b, _c, _d):
		done["result"] = [a, b])
	# Checked every frame (thousands of small textures: no fixed wait per file). A stall is
	# judged by the real clock, and a hitch of the launcher itself isn't counted as one.
	var last := -1
	var progress_at := Time.get_ticks_msec()
	var frame_at := progress_at
	var shown_at := 0
	while not done.has("result"):
		var now := Time.get_ticks_msec()
		if now - frame_at > 2000:
			progress_at = now   # the launcher itself was stuck: not the download
		frame_at = now
		if cancelled or now - progress_at > int(STALL_SECONDS * 1000.0):
			req.cancel_request()
			break
		var got := req.get_downloaded_bytes()
		if got != last:
			last = got
			progress_at = now
		done_bytes = base + got
		if now - shown_at > 100:
			shown_at = now
			changed.emit()
		await get_tree().process_frame
	req.queue_free()
	var result: Array = done.get("result", [])
	if result.is_empty() or int(result[0]) != HTTPRequest.RESULT_SUCCESS or int(result[1]) != 200:
		DirAccess.remove_absolute(part)
		done_bytes = base
		return false
	_frame_start = Time.get_ticks_msec()
	if await _hash_file(part) != sha:
		DirAccess.remove_absolute(part)
		done_bytes = base
		return false
	done_bytes = base + size
	changed.emit()
	return true


## The launcher's own files (and any file that was in use): a script waits for this launcher to
## close, moves them in, and starts the launcher again.
func _restart_with(pending: Dictionary, launcher: String) -> void:
	var exe := OS.get_executable_path()
	var start := root().path_join(launcher) if launcher != "" else exe
	var dir := root().path_join("SparkingData/update")
	if OS.get_name() == "Windows":
		var path := dir.path_join("finish_update.ps1")
		var f := FileAccess.open(path, FileAccess.WRITE)
		f.store_buffer(PackedByteArray([0xEF, 0xBB, 0xBF]))   # UTF-8 BOM: Windows PowerShell 5 reads it as UTF-8
		f.store_string(powershell_script(OS.get_process_id(), pending, root(), start))
		f.close()
		if not restart_hook.is_valid():
			OS.create_process("powershell.exe", ["-NoProfile", "-ExecutionPolicy", "Bypass",
				"-WindowStyle", "Hidden", "-File", path.replace("/", "\\")])
	else:
		var sh := shell_script(OS.get_process_id(), pending, root(), start)
		var path := dir.path_join("finish_update.sh")
		var f := FileAccess.open(path, FileAccess.WRITE)
		f.store_string(sh)
		f.close()
		if not restart_hook.is_valid():
			OS.create_process("/bin/sh", [path])
	if restart_hook.is_valid():
		restart_hook.call()
	else:
		get_tree().quit()


## The Windows restart script: waits for this launcher (pid) to close, copies each staged file
## over its target (retrying while Windows still holds it), starts the launcher again, deletes
## itself.
static func powershell_script(pid: int, pending: Dictionary, install: String, start: String) -> String:
	# .NET's file calls, not Copy-Item / Start-Process: those read [ ] in paths as wildcards
	# (texture folders are named like "[GrandpaNiki DDS]"). Everything goes to finish_update.log.
	var log := _ps(install.path_join("SparkingData/update/finish_update.log"))
	var ps := PackedStringArray([
		"# Dolphin-Sparking update: finishes what the launcher couldn't replace while running.",
		"$ErrorActionPreference = 'Continue'",
		"$log = %s" % log,
		"function Log($t) { try { [IO.File]::AppendAllText($log, ((Get-Date).ToString('s') + ' ' + $t + [Environment]::NewLine)) } catch {} }",
		"Log 'waiting for the launcher (pid %d) to close'" % pid,
		"try { Wait-Process -Id %d -Timeout 60 -ErrorAction Stop } catch {}" % pid,
	])
	for rel in pending:
		ps.append("$src = %s; $dst = %s" % [_ps(pending[rel]), _ps(install.path_join(rel))])
		ps.append("if (-not [IO.File]::Exists($src)) { Log ('missing: ' + $src) } else {")
		ps.append("  [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($dst)) | Out-Null")
		ps.append("  $ok = $false; for ($i = 0; $i -lt 30 -and -not $ok; $i++) { try { [IO.File]::Copy($src, $dst, $true); $ok = $true } catch { $err = $_.Exception.Message; Start-Sleep -Seconds 1 } }")
		ps.append("  if ($ok) { Log ('replaced: ' + $dst); try { [IO.File]::Delete($src) } catch {} } else { Log ('FAILED: ' + $dst + ': ' + $err) }")
		ps.append("}")
	ps.append("try { $si = New-Object Diagnostics.ProcessStartInfo %s; $si.WorkingDirectory = %s; $si.UseShellExecute = $true; [Diagnostics.Process]::Start($si) | Out-Null; Log 'launcher started' } catch { Log ('could not start the launcher: ' + $_.Exception.Message) }" % [_ps(start), _ps(install)])
	ps.append("try { [IO.File]::Delete($PSCommandPath) } catch {}")
	return "\r\n".join(ps) + "\r\n"


## The Linux / macOS restart script: waits for this launcher (pid) to close, copies each staged
## file over its target, marks the launcher / Dolphin executable, starts the launcher again
## (detached), deletes itself. Steps go to finish_update.log.
static func shell_script(pid: int, pending: Dictionary, install: String, start: String) -> String:
	var sh := PackedStringArray([
		"#!/bin/sh",
		"# Dolphin-Sparking update: finishes what the launcher couldn't replace while running.",
		"LOG=%s" % _sh(install.path_join("SparkingData/update/finish_update.log")),
		"log() { echo \"$(date +%Y-%m-%dT%H:%M:%S) $1\" >> \"$LOG\" 2>/dev/null; }",
		"log 'waiting for the launcher (pid %d) to close'" % pid,
		"i=0; while kill -0 %d 2>/dev/null && [ $i -lt 600 ]; do sleep 0.1; i=$((i+1)); done" % pid,
	])
	for rel in pending:
		var dst := install.path_join(rel)
		sh.append("SRC=%s; DST=%s" % [_sh(pending[rel]), _sh(dst)])
		sh.append("if [ ! -f \"$SRC\" ]; then log \"missing: $SRC\"; else")
		sh.append("  mkdir -p \"$(dirname \"$DST\")\"; ok=0; i=0")
		sh.append("  while [ $ok = 0 ] && [ $i -lt 30 ]; do if cp -f \"$SRC\" \"$DST.new\" && mv -f \"$DST.new\" \"$DST\"; then ok=1; else i=$((i+1)); sleep 1; fi; done")
		sh.append("  if [ $ok = 1 ]; then log \"replaced: $DST\"; rm -f \"$SRC\"; else log \"FAILED: $DST\"; fi")
		sh.append("fi")
		if is_executable(rel):
			sh.append("chmod 755 %s 2>/dev/null" % _sh(dst))
	sh.append("chmod 755 %s 2>/dev/null" % _sh(start))
	sh.append("cd %s || exit 1" % _sh(install))
	sh.append("if command -v setsid >/dev/null 2>&1; then setsid %s >/dev/null 2>&1 </dev/null & else nohup %s >/dev/null 2>&1 </dev/null & fi" % [_sh(start), _sh(start)])
	sh.append("log 'launcher started'")
	sh.append("rm -f \"$0\"")
	return "\n".join(sh) + "\n"


static func _sh(path: String) -> String:
	return "'" + path.replace("'", "'\\''") + "'"


static func _ps(path: String) -> String:
	return "'" + path.replace("/", "\\").replace("'", "''") + "'"


## The server's answer, short: "login_required", "bad_response, HTTP 404", "unreachable".
static func _detail(r: Dictionary) -> String:
	var d := String(r.get("error", "?"))
	if r.has("http"):
		d += ", HTTP %d" % int(r["http"])
	if r.has("result"):
		d += ", connection error %d" % int(r["result"])
	return d


## A line for Options > Updates.
func summary() -> String:
	match state:
		"up_to_date":
			return tr("Up to date (%s)") % version if version != "" else tr("Up to date")
		"available":
			return tr("Version %s is available.") % version
		"checking":
			return tr("Checking...")
		"downloading", "applying", "restarting":
			return tr("Updating...")
		"no_login":
			return tr("Needs a DRAGON NET login")
		"failed":
			return tr("Failed")
		"off":
			return tr("Not set up")
	return tr("Check now")


## What check() came to, for a toast.
func result_text() -> String:
	match state:
		"up_to_date":
			return tr("Up to date (%s)") % version if version != "" else tr("Up to date")
		"no_login":
			return tr("Log in to DRAGON NET to get updates (Ranked Match > Profile).")
		"off":
			return tr("Updates aren't set up in this build.")
		"failed":
			var t := tr("Updates aren't set up on the server yet.") if error == "updates_not_set_up" else tr(error)
			return t + ("  (%s)" % detail if detail != "" else "")
	return ""
