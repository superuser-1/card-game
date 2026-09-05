shader_type canvas_item;
// Card frame art is generated with a pure-white square punched in the middle
// for the avatar to show through. Drawn ON TOP of the avatar layer, so key
// out near-white pixels (the center hole, and stray white highlights in the
// border art) instead of letting them opaquely cover the avatar underneath.
uniform float white_threshold : hint_range(0.0, 1.0) = 0.90;

void fragment() {
	vec4 tex = texture(TEXTURE, UV);
	float darkest_channel = min(tex.r, min(tex.g, tex.b));
	if (darkest_channel > white_threshold) {
		tex.a = 0.0;
	}
	COLOR = tex;
}
