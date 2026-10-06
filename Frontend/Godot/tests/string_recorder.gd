extends Translation
## Test helper: records every text the UI asks to translate (English run), so the tour can check
## that each one has a Spanish and Italian entry.

var seen := {}


func _get_message(src_message: StringName, _context: StringName) -> StringName:
	seen[String(src_message)] = true
	return src_message
