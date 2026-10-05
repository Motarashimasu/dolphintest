extends Control
## Connection icon for netplay players: an Ethernet plug (wired), Wi-Fi waves (wireless), a
## shield (VPN / virtual adapter) or a "?" (unknown). Vector-drawn, any size.

var link := "":
	set(v):
		link = v
		tooltip_text = {"wired": "Wired (Ethernet)", "wireless": "Wi-Fi", "virtual": "VPN"}.get(v, "Unknown connection")
		queue_redraw()
var color := Color.WHITE:
	set(v):
		color = v
		queue_redraw()


func _init() -> void:
	mouse_filter = Control.MOUSE_FILTER_PASS
	custom_minimum_size = Vector2(28, 28)


func _notification(what: int) -> void:
	if what == NOTIFICATION_RESIZED:
		queue_redraw()


func _draw() -> void:
	var s := minf(size.x, size.y)
	var o := (size - Vector2(s, s)) / 2.0
	var shadow := Color(0, 0, 0, 0.45)
	match link:
		"wired":
			_plug(o + Vector2(1, 1.5), s, shadow)
			_plug(o, s, color)
		"wireless":
			_wifi(o + Vector2(1, 1.5), s, shadow)
			_wifi(o, s, color)
		"virtual":
			_shield(o + Vector2(1, 1.5), s, shadow)
			_shield(o, s, color)
		_:
			var f := ThemeDB.fallback_font
			var fs := int(s * 0.8)
			var w := f.get_string_size("?", HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
			draw_string(f, o + Vector2((s - w) / 2, s * 0.8), "?", HORIZONTAL_ALIGNMENT_LEFT, -1, fs,
					Color(color, 0.7))


## RJ45 plug seen from the front: body, latch tab, three contacts, cable.
func _plug(o: Vector2, s: float, c: Color) -> void:
	var lw := maxf(1.5, s * 0.08)
	var body := Rect2(o + Vector2(s * 0.18, s * 0.08), Vector2(s * 0.64, s * 0.5))
	draw_rect(body, c, false, lw)
	draw_rect(Rect2(o + Vector2(s * 0.36, s * 0.58), Vector2(s * 0.28, s * 0.14)), c, true)   # latch
	for i in 3:
		var x := s * (0.33 + i * 0.17)
		draw_line(o + Vector2(x, s * 0.16), o + Vector2(x, s * 0.32), c, lw * 0.9)   # contacts
	draw_line(o + Vector2(s * 0.5, s * 0.72), o + Vector2(s * 0.5, s * 0.94), c, lw * 1.3)   # cable


## Wi-Fi: three arcs over a dot.
func _wifi(o: Vector2, s: float, c: Color) -> void:
	var lw := maxf(1.5, s * 0.09)
	var center := o + Vector2(s * 0.5, s * 0.84)
	for i in 3:
		var r := s * (0.22 + i * 0.22)
		draw_arc(center, r, deg_to_rad(-135), deg_to_rad(-45), 16, c, lw, true)
	draw_circle(center, s * 0.08, c)


## Shield with a check: VPN / virtual network adapter.
func _shield(o: Vector2, s: float, c: Color) -> void:
	var lw := maxf(1.5, s * 0.08)
	var pts := PackedVector2Array([o + Vector2(s * 0.5, s * 0.08), o + Vector2(s * 0.84, s * 0.2),
		o + Vector2(s * 0.8, s * 0.55), o + Vector2(s * 0.5, s * 0.92), o + Vector2(s * 0.2, s * 0.55),
		o + Vector2(s * 0.16, s * 0.2), o + Vector2(s * 0.5, s * 0.08)])
	draw_polyline(pts, c, lw, true)
	draw_polyline(PackedVector2Array([o + Vector2(s * 0.35, s * 0.5), o + Vector2(s * 0.47, s * 0.62),
		o + Vector2(s * 0.66, s * 0.38)]), c, lw, true)
