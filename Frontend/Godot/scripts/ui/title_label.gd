extends Label
## A screen title (Style.title_label): keeps the letters' gradient (look/title_gradient.gdshader)
## running from the top of the capitals to the baseline wherever the text sits in the label.

## Capital-letter height as a share of the font size (Nunito: 0.705).
const CAP_HEIGHT := 0.72


func _notification(what: int) -> void:
	if what == NOTIFICATION_RESIZED or what == NOTIFICATION_READY:
		place_gradient()


func place_gradient() -> void:
	var s := label_settings
	var m := material as ShaderMaterial
	if s == null or s.font == null or m == null:
		return
	var line_h := s.font.get_height(s.font_size)
	var top := 0.0
	if vertical_alignment == VERTICAL_ALIGNMENT_CENTER:
		top = (size.y - line_h) / 2.0
	elif vertical_alignment == VERTICAL_ALIGNMENT_BOTTOM:
		top = size.y - line_h
	var baseline := top + s.font.get_ascent(s.font_size)
	m.set_shader_parameter("y_top", baseline - s.font_size * CAP_HEIGHT)
	m.set_shader_parameter("y_bottom", baseline)
