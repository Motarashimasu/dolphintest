extends "res://scripts/screens/form_screen.gd"
## Renderer, internal resolution, Smooth Motion (frame interpolation), game window, and Dolphin's
## other picture settings that can't desync an online match (Settings.video_args). Applied at the
## next game launch.


func screen_title() -> String:
	return "Video Settings"


func screen_desc() -> String:
	return "Change your video settings here."


func build_rows() -> Array:
	var windows: Array = Settings.WINDOW_SIZES.duplicate()
	var window_names: Array = []
	for w in windows:
		window_names.append(tr("Window %s") % String(w).replace("x", " x "))
	windows.append("borderless")
	window_names.append("Borderless fullscreen")
	return [
		{"type": "choice", "key": "renderer", "label": "Graphics renderer",
			"values": Settings.renderers(), "names": Settings.renderer_names(),
			"value": Settings.renderer(),
			"desc": ("Vulkan is usually faster with fewer stutters. If it has problems on your PC,\ntry Direct3D 12, Direct3D 11 (older graphics cards) or OpenGL.") if OS.get_name() == "Windows" \
				else "Vulkan is usually faster with fewer stutters.\nTry OpenGL if Vulkan has problems on your PC."},
		{"type": "choice", "key": "resolution", "label": "Resolution",
			"values": Settings.RESOLUTIONS, "names": Settings.RESOLUTION_NAMES,
			"value": Settings.get_value("video", "resolution"),
			"desc": "Internal rendering resolution. 1080p is the default; higher needs a stronger\ngraphics card. 480p (1x) is the Wii's own: for weak PCs and laptops."},
		{"type": "toggle", "key": "smooth_motion", "label": "Smooth Motion",
			"value": Settings.get_value("video", "smooth_motion"), "on_text": "On", "off_text": "Off",
			"desc": "Frame interpolation: in-between frames make 30 fps fights look like 60 fps.\nAdds about one frame of input delay; very fast effects can smear."},
		{"type": "choice", "key": "window", "label": "Game display",
			"values": windows, "names": window_names, "value": Settings.get_value("video", "window"),
			"desc": "Game window size, or borderless fullscreen\n(covers the whole monitor, no frame)."},
		{"type": "choice", "key": "menu_display", "label": "Menu display", "values": ["fullscreen", "window"],
			"names": ["Borderless fullscreen", "Window"], "value": Settings.get_value("video", "menu_display"),
			"desc": "These menus: borderless fullscreen or a 1280 x 720 window.\nChanges right away."},
		_toggle("vsync", "V-Sync", "Waits for your monitor's refresh: no tearing, a little more input delay."),
		{"type": "choice", "key": "antialiasing", "label": "Anti-aliasing",
			"values": Settings.ANTIALIASING, "names": Settings.ANTIALIASING_NAMES,
			"value": Settings.get_value("video", "antialiasing"),
			"desc": "Smooths jagged edges. MSAA is lighter; SSAA is sharper but much heavier.\nOnly your screen: it can't desync an online match."},
		{"type": "choice", "key": "anisotropy", "label": "Anisotropic filtering",
			"values": Settings.ANISOTROPY, "names": Settings.ANISOTROPY_NAMES,
			"value": Settings.get_value("video", "anisotropy"),
			"desc": "Sharper ground and walls seen at an angle.\n16x looks best and costs little on most graphics cards."},
		{"type": "choice", "key": "texture_filtering", "label": "Texture filtering",
			"values": Settings.TEXTURE_FILTERING, "names": Settings.TEXTURE_FILTERING_NAMES,
			"value": Settings.get_value("video", "texture_filtering"),
			"desc": "Default: as the game draws it. Nearest: pixelated. Linear: smoother."},
		{"type": "choice", "key": "output_resampling", "label": "Output resampling",
			"values": Settings.OUTPUT_RESAMPLING, "names": Settings.OUTPUT_RESAMPLING_NAMES,
			"value": Settings.get_value("video", "output_resampling"),
			"desc": "How the picture is scaled to your window or screen.\nArea Sampling is best when the resolution is higher than your screen."},
		{"type": "choice", "key": "shader_compilation", "label": "Shader compilation",
			"values": Settings.SHADER_MODES, "names": Settings.SHADER_MODE_NAMES,
			"value": Settings.get_value("video", "shader_compilation"),
			"desc": "Hybrid Ubershaders: fewer stutters the first time effects appear (needs a\ngood graphics card). Skip Drawing: no stutter, effects can be missing for a moment."},
		_toggle("disable_fog", "Disable fog", "Removes the game's distance fog. Some stages can look different."),
		_toggle("crop", "Crop", "Cuts off the picture's edges to fit the aspect ratio exactly."),
		_toggle("true_color", "Force 24-bit color", "Removes color banding in gradients. Recommended."),
		_toggle("copy_filter_off", "Disable copy filter", "Sharper picture without the game's blur filter. Recommended."),
		_toggle("arbitrary_mipmaps", "Arbitrary mipmap detection", "Makes some textures sharper at a distance.\nCan cause a small stutter when they first load."),
		_toggle("backend_multithreading", "Multithreaded graphics", "Uses more CPU cores for graphics (Vulkan).\nTurn off only if the game crashes or flickers."),
		{"type": "choice", "key": "cc_color_space", "label": "Color correction",
			"values": Settings.CC_COLOR_SPACES, "names": Settings.CC_COLOR_SPACE_NAMES,
			"value": Settings.get_value("video", "cc_color_space"),
			"desc": "Shows the colors as a TV of that region did (the game was made for those).\nPAL for 4.0, NTSC-J for the Japanese versions. Off: as Dolphin draws them."},
		{"type": "choice", "key": "cc_game_gamma", "label": "Game gamma",
			"values": Settings.CC_GAMMAS, "names": Settings.CC_GAMMA_NAMES,
			"value": Settings.get_value("video", "cc_game_gamma"),
			"desc": "Corrects the brightness curve the game was made for (old CRT TVs: 2.35).\nOff: as Dolphin draws it."},
		{"type": "choice", "key": "cc_display_gamma", "label": "Monitor gamma",
			"values": Settings.CC_DISPLAY_GAMMAS, "names": Settings.CC_DISPLAY_GAMMA_NAMES,
			"value": Settings.get_value("video", "cc_display_gamma"),
			"desc": "Your monitor's gamma, for the game gamma correction. sRGB fits most monitors."},
		_toggle("hdr", "HDR output", "For HDR monitors with HDR turned on in Windows (Vulkan or Direct3D).\nLeave it off on other monitors."),
		{"type": "choice", "key": "hdr_paper_white", "label": "HDR paper white",
			"values": Settings.HDR_PAPER_WHITES,
			"names": Settings.HDR_PAPER_WHITES.map(func(n): return tr("%d nits") % n),
			"value": Settings.get_value("video", "hdr_paper_white"),
			"desc": "How bright white is with HDR output. 203 nits is the standard."},
		{"type": "action", "key": "back", "label": "Back", "desc": "Back to the main menu."},
	]


func _toggle(key: String, label: String, desc: String) -> Dictionary:
	return {"type": "toggle", "key": key, "label": label, "value": Settings.get_value("video", key),
		"on_text": "On", "off_text": "Off", "desc": desc}


func on_value(key: String, value: Variant) -> void:
	Settings.set_value("video", key, value)
	if key == "menu_display":
		app.apply_menu_display()
