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
	var d := String(row.get("desc", ""))
	app.set_desc(d if d != "" else screen_desc())


## Opens a file/folder picker; `done.call(path)` on success.
func pick_path(folder: bool, filters: PackedStringArray, current: String, title: String,
		done: Callable) -> void:
	var dlg := FileDialog.new()
	dlg.access = FileDialog.ACCESS_FILESYSTEM
	dlg.file_mode = FileDialog.FILE_MODE_OPEN_DIR if folder else FileDialog.FILE_MODE_OPEN_FILE
	dlg.filters = filters
	dlg.title = title
	dlg.use_native_dialog = true
	if current != "":
		if folder:
			dlg.current_dir = current
		else:
			dlg.current_path = current
	var close := func():
		_dialog_open = false
		dlg.queue_free()
	dlg.dir_selected.connect(func(p):
		close.call()
		done.call(p))
	dlg.file_selected.connect(func(p):
		close.call()
		done.call(p))
	dlg.canceled.connect(close)
	add_child(dlg)
	_dialog_open = true
	dlg.popup_centered_ratio(0.7)
