// Screen titles: the letters' fill as a top-to-bottom gradient (the outlines keep their colors).
// The fill is drawn in the marker color (pure magenta) so it can be told apart from the outlines.
shader_type canvas_item;

uniform vec4 top_color : source_color = vec4(0.988, 0.714, 0.188, 1.0);
uniform vec4 bottom_color : source_color = vec4(0.992, 0.165, 0.141, 1.0);
uniform float y_top = 0.0;      // label-local y where the gradient starts (top of the capitals)
uniform float y_bottom = 64.0;  // ... and ends (the baseline)

varying vec4 vertex_color;
varying float local_y;

void vertex() {
	vertex_color = COLOR;
	local_y = VERTEX.y;
}

void fragment() {
	vec3 c = vertex_color.rgb;
	// Magenta marker (any brightness, so a dimmed menu keeps working): red == blue, no green.
	if (c.r > 0.05 && abs(c.r - c.b) < 0.03 * c.r + 0.01 && c.g < 0.05 * c.r + 0.01) {
		float t = clamp((local_y - y_top) / max(y_bottom - y_top, 1.0), 0.0, 1.0);
		COLOR.rgb = mix(top_color.rgb, bottom_color.rgb, t) * c.r;
	}
}
