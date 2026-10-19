extends Node
## DRAGON NET friends and messages (Server/ranked/social.php), for the logged-in account.
## Every POLL_EVERY seconds while logged in: the friends list (who's online), friend requests,
## and the admin's messages not closed yet. Polling is also what keeps this player "online"
## for their friends.
##   friend_online(name)   a friend came online: the server says when each friend came online
##                         (`since`); a newer `since` than the last one seen is announced, so a
##                         missed poll, a slow server or a quick restart doesn't lose it. On the
##                         first poll after logging in, only friends who came online in the last
##                         RECENT seconds (not everyone already online); never a friend just added.
##   message(id, text)     an admin message, once per id until close_message(id)
##   updated               the lists changed (the Friends screen redraws)

signal friend_online(name: String)
signal message(id: int, text: String)
signal updated

const POLL_EVERY := 20.0
const RECENT := 40   # s

var friends: Array = []      # [{id, name, online}]
var incoming: Array = []     # [{id, name}]: asked to be our friend
var outgoing: Array = []     # [{id, name}]: we asked
var polled := false          # the lists are from the server (since logging in)

var _since := {}             # id -> when that friend came online, as last seen (0 = offline)
var _started := false        # told the server this launcher run started
var _known := {}             # id -> true: friends at the last poll
var _first := true           # the next poll is the first for this login
var _told := {}              # message ids already handed out this run
var _timer := 0.0
var _busy := false


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	Ranked.changed.connect(_on_login_changed)


func _on_login_changed() -> void:
	if not Ranked.logged_in():
		friends.clear()
		incoming.clear()
		outgoing.clear()
		_since.clear()
		_known.clear()
		_first = true
		_started = false
		polled = false
		updated.emit()
	elif not polled:
		poll()


func _process(delta: float) -> void:
	if not Ranked.logged_in() or Ranked.needs_account:
		return
	_timer -= delta
	if _timer <= 0.0 and not _busy:
		_timer = POLL_EVERY
		poll()


## Asks the server now (after the poll already running, if any, so the answer is fresh).
func poll() -> void:
	while _busy:
		await get_tree().process_frame
	if not Ranked.logged_in():
		return
	_busy = true
	var res: Dictionary = await Ranked.api("social.php", {"action": "poll", "start": not _started})
	_busy = false
	if not res.get("ok", false):
		return
	_started = true
	friends = res.get("friends", [])
	incoming = res.get("incoming", [])
	outgoing = res.get("outgoing", [])
	var now_since := {}
	var now_known := {}
	var server_now := int(res.get("now", 0))
	for f in friends:
		var id := int(f["id"])
		now_known[id] = true
		var since := int(f.get("since", 0)) if f.get("online", false) else 0
		now_since[id] = since
		if since <= 0 or since <= int(_since.get(id, 0)):
			continue
		if _first:
			if server_now > 0 and server_now - since <= RECENT:
				friend_online.emit(String(f["name"]))
		elif _known.has(id):
			friend_online.emit(String(f["name"]))
	_since = now_since
	_known = now_known
	_first = false
	polled = true
	for m in res.get("messages", []):
		var id := int(m["id"])
		if not _told.has(id):
			_told[id] = true
			message.emit(id, String(m["text"]))
	updated.emit()


## The player closed message `id`: the server won't send it again.
func close_message(id: int) -> void:
	await Ranked.api("social.php", {"action": "ack", "message": id})


## Friends actions: {"ok": ...} like Ranked.api; the lists refresh after each.
func act(action: String, body: Dictionary) -> Dictionary:
	body["action"] = action
	var res: Dictionary = await Ranked.api("social.php", body)
	await poll()
	return res
