extends "res://scripts/screens/screen.gd"
## A settings-style screen: one dark panel holding an OptionList. Subclasses override
## build_rows(), on_value(key, value) and on_press(key). The focused row's `desc` goes to the
## description bar.

const OptionList := preload("res://scripts/ui/option_list.gd")

var list: Control
var _dialog_open := false


func build_rows() -> Array:
	return []


func on_value(_key: String, _value: Variant) -> void:
	pass


func on_press(key: String) -> void:
	if key == "back":
		on_back()


## Where the list sits; override for a different layout.
func list_rect() -> Rect2:
	return Rect2(70, 136, 1140, 352)


func on_enter() -> void:
	var r := list_rect()
	add_form_panel(r.position.x - 30, r.position.y - 24, r.size.x + 60, r.size.y + 48)
	list = OptionList.new()
	Style.place(list, r.position.x, r.position.y, r.size.x, r.size.y)
	add_child(list)
	list.focused.connect(_on_focused)
	list.value_changed.connect(on_value)
	list.pressed.connect(on_press)
	list.set_rows(build_rows())


func on_resume() -> void:
	list.set_rows(build_rows())
	_on_focused(list.row(list.current_key()))


func on_input(event: InputEvent) -> bool:
	if _dialog_open:
		return true
	return list.handle_input(event)


func _on_focused(row: Dictionary) -> void:
	if app:
		app.set_desc(current_desc())


## What the description bar shows: the selected row's text, else the screen's.
func current_desc() -> String:
	var d := String(list.row(list.current_key()).get("desc", "")) if list else ""
	return d if d != "" else screen_desc()


## Opens a file/folder picker; `done.call(path)` on success. However the picker closes (a file
## picked, Cancel, Esc, its X, clicked away) the menus take input again: while it's open they
## ignore it (so the pad doesn't move the menu behind it).
func pick_path(folder: bool, filters: PackedStringArray, current: String, title: String,
		done: Callable) -> void:
	if _dialog_open:
		return
	_dialog_open = true
	var finish := func(path: String) -> void:
		_dialog_open = false
		if path != "" and is_inside_tree():
			done.call(path)
	# The system's own picker (Windows, Linux portals): its callback always comes, with
	# status false when it was closed without a pick.
	if DisplayServer.has_feature(DisplayServer.FEATURE_NATIVE_DIALOG_FILE):
		var dir := current if folder else current.get_base_dir()
		var err := DisplayServer.file_dialog_show(title, dir, "" if folder else current.get_file(), false,
				DisplayServer.FILE_DIALOG_MODE_OPEN_DIR if folder else DisplayServer.FILE_DIALOG_MODE_OPEN_FILE,
				filters, func(status: bool, paths: PackedStringArray, _filter: int) -> void:
					finish.call_deferred(paths[0] if status and paths.size() > 0 else ""))
		if err == OK:
			return
	# Godot's own picker: every way it can close ends the wait.
	var dlg := FileDialog.new()
	dlg.access = FileDialog.ACCESS_FILESYSTEM
	dlg.file_mode = FileDialog.FILE_MODE_OPEN_DIR if folder else FileDialog.FILE_MODE_OPEN_FILE
	dlg.filters = filters
	dlg.title = title
	dlg.use_native_dialog = false
	if current != "":
		if folder:
			dlg.current_dir = current
		else:
			dlg.current_path = current
	var state := {"done": false}
	var close := func(path: String) -> void:
		if state["done"]:
			return
		state["done"] = true
		dlg.queue_free()
		finish.call(path)
	dlg.dir_selected.connect(func(p): close.call(p))
	dlg.file_selected.connect(func(p): close.call(p))
	dlg.canceled.connect(func(): close.call(""))
	dlg.close_requested.connect(func(): close.call(""))
	dlg.visibility_changed.connect(func():
		if not dlg.visible:
			close.call_deferred(""))   # (after a pick's own signal, which comes first)
	add_child(dlg)
	dlg.popup_centered_ratio(0.7)


## Tests: the picker is waiting.
func picking() -> bool:
	return _dialog_open
