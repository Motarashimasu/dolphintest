extends "res://scripts/screens/form_screen.gd"
## Renderer, internal resolution, game window. Applied at the next game launch.


func screen_title() -> String:
	return "Video Settings"


func screen_desc() -> String:
	return "Change your video settings here."


func build_rows() -> Array:
	var windows: Array = Settings.WINDOW_SIZES.duplicate()
	var window_names: Array = []
	for w in windows:
		window_names.append("Window " + String(w).replace("x", " x "))
	windows.append("borderless")
	window_names.append("Borderless fullscreen")
	return [
		{"type": "choice", "key": "renderer", "label": "Graphics renderer",
			"values": Settings.RENDERERS, "names": Settings.RENDERER_NAMES,
			"value": Settings.get_value("video", "renderer"),
			"desc": "Vulkan is usually faster with fewer stutters.\nTry OpenGL if Vulkan has problems on your PC."},
		{"type": "choice", "key": "resolution", "label": "Resolution",
			"values": Settings.RESOLUTIONS, "names": Settings.RESOLUTION_NAMES,
			"value": Settings.get_value("video", "resolution"),
			"desc": "Internal rendering resolution. 1080p is the default;\nhigher needs a stronger graphics card."},
		{"type": "choice", "key": "window", "label": "Game display",
			"values": windows, "names": window_names, "value": Settings.get_value("video", "window"),
			"desc": "Game window size, or borderless fullscreen\n(covers the whole monitor, no frame)."},
		{"type": "choice", "key": "menu_display", "label": "Menu display", "values": ["fullscreen", "window"],
			"names": ["Borderless fullscreen", "Window"], "value": Settings.get_value("video", "menu_display"),
			"desc": "These menus: borderless fullscreen or a 1280 x 720 window.\nChanges right away."},
		{"type": "action", "key": "back", "label": "Back", "desc": "Back to the main menu."},
	]


func on_value(key: String, value: Variant) -> void:
	Settings.set_value("video", key, value)
	if key == "menu_display":
		app.apply_menu_display()
