shader_type canvas_item;
// Rounded-corner mask for the menu image buttons, plus an inner border that
// main_menu.gd tweens in on hover.
//
// The button fills its (wide) grid cell with KEEP_ASPECT_COVERED, so the
// shader's UV spans the *cropped* source region, not 0..1 across the node.
// main_menu.gd feeds the crop back in as uv_min/uv_max (and the node aspect)
// on every resize, so the corners are round in real pixels at any cell size.

uniform vec2 uv_min = vec2(0.0);
uniform vec2 uv_max = vec2(1.0);
uniform float node_aspect = 2.0;            // node width / node height
uniform float corner_radius : hint_range(0.0, 0.5) = 0.09;   // fraction of node height
uniform float border_width : hint_range(0.0, 0.1) = 0.0;     // fraction of node height
uniform vec4 border_color : source_color = vec4(1.0, 0.86, 0.55, 1.0);

float rounded_box(vec2 p, vec2 half_size, float r) {
	vec2 q = abs(p) - half_size + vec2(r);
	return min(max(q.x, q.y), 0.0) + length(max(q, vec2(0.0))) - r;
}

void fragment() {
	// UV -> 0..1 across the node, then into a space where 1 unit = node height.
	vec2 nuv = (UV - uv_min) / max(uv_max - uv_min, vec2(0.0001));
	vec2 half_size = vec2(node_aspect, 1.0) * 0.5;
	vec2 p = (nuv - vec2(0.5)) * vec2(node_aspect, 1.0);

	float r = min(corner_radius, min(half_size.x, half_size.y));
	float d = rounded_box(p, half_size, r);
	float aa = fwidth(d) + 0.0001;

	COLOR.a *= 1.0 - smoothstep(-aa, aa, d);

	if (border_width > 0.0005) {
		float inside = -d;
		float band = (1.0 - smoothstep(border_width, border_width + aa * 2.0, inside)) * step(0.0, inside);
		band *= 1.0 - smoothstep(-aa, aa, d);
		COLOR.rgb = mix(COLOR.rgb, border_color.rgb, band * border_color.a);
		COLOR.a = max(COLOR.a, band * border_color.a);
	}
}
