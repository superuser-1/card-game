shader_type canvas_item;
// Overlay that turns a full-bleed rectangular image into a rounded card:
// paints the four corner wedges (outside the rounded rect) with `bg_color`
// so the image's square corners are hidden, and strokes a rounded border on
// top. Put it on a full-rect ColorRect above the artwork, mouse-ignored.
//
// `rect_px` must be kept in sync with the node's pixel size from script.

uniform vec2 rect_px = vec2(240.0, 280.0);
uniform float radius_px : hint_range(0.0, 64.0) = 12.0;
uniform float border_px : hint_range(0.0, 8.0) = 2.0;
uniform vec4 border_color : source_color = vec4(1.0, 0.86, 0.55, 0.95);

void fragment() {
	vec2 half_size = rect_px * 0.5;
	vec2 p = abs(UV * rect_px - half_size) - (half_size - vec2(radius_px));
	float d = length(max(p, vec2(0.0))) + min(max(p.x, p.y), 0.0) - radius_px;
	float aa = max(fwidth(d), 0.0001);

	float outside = smoothstep(-aa, aa, d);                                   // 1 in the corner wedge
	float edge_in = (1.0 - outside) * (1.0 - smoothstep(border_px - aa, border_px + aa, -d));

	vec3 rgb = mix(COLOR.rgb, border_color.rgb, edge_in);                     // COLOR.rgb == bg_color
	float a = max(outside, edge_in * border_color.a);
	if (a < 0.003) {
		discard;
	}
	COLOR = vec4(rgb, a);
}
