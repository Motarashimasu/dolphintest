extends RefCounted
## Waits for an HTTPRequest by the real clock. HTTPRequest's own `timeout` counts frame time: after
## the launcher hangs for a while (a long load, Windows pausing it), the next frame counts the whole
## hang at once and a request that just started "times out" before the server could answer. That
## made every automatic update from build 206 fail ("Couldn't reach the update server"). Leave
## `req.timeout` at 0 and wait with this instead.
##
##   req.request(...)
##   var res: Array = await HttpWait.done(req, 20.0)   # = request_completed's arguments

static func done(req: HTTPRequest, seconds: float) -> Array:
	var box := {}   # (a lambda can't assign this function's locals: it fills this)
	req.request_completed.connect(func(result, code, headers, body):
		box["res"] = [result, code, headers, body], CONNECT_ONE_SHOT)
	var end := Time.get_ticks_msec() + int(seconds * 1000.0)
	while not box.has("res"):
		if Time.get_ticks_msec() > end:
			req.cancel_request()
			return [HTTPRequest.RESULT_TIMEOUT, 0, PackedStringArray(), PackedByteArray()]
		await req.get_tree().process_frame
	return box["res"]
