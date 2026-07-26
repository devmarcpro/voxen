// Matériau des modèles .vox (items/outils, 9.1) : l'index de palette arrive
// par UV.x et est résolu via une palette 256 remappée PAR INSTANCE (les
// couleurs stand-in ont été remplacées par les couleurs réelles des
// matériaux du craft). Bruit 2×2 pixels par voxel (9.1), en coordonnées
// LOCALES (l'objet bouge avec la main).
shader_type spatial;
render_mode cull_back;

uniform sampler2D palette : source_color, filter_nearest;
// r = amplitude de bruit, b = seed_offset (0 = pas de bruit, index non remappé).
uniform sampler2D noise_params : filter_nearest;

varying vec3 v_local_pos;
varying vec3 v_local_normal;
varying flat float v_index;

void vertex() {
	v_local_pos = VERTEX;
	v_local_normal = NORMAL;
	v_index = UV.x;
}

uint pcg(uint v) {
	v = v * 747796405u + 2891336453u;
	uint w = ((v >> ((v >> 28u) + 4u)) ^ v) * 277803737u;
	return (w >> 22u) ^ w;
}

float cell_noise(ivec3 cell, uint seed_value) {
	uint h = pcg(uint(cell.x) ^ pcg(uint(cell.y) ^ pcg(uint(cell.z) ^ seed_value)));
	return float(h & 0xFFFFu) / 65535.0;
}

void fragment() {
	int id = int(round(v_index));
	vec4 color = texelFetch(palette, ivec2(id, 0), 0);
	vec4 p = texelFetch(noise_params, ivec2(id, 0), 0);
	if (p.r > 0.0) {
		// Grain 2×2 px par voxel : cellule d'un demi-voxel (1/64 bloc).
		vec3 inside = v_local_pos - normalize(v_local_normal) * 0.001;
		ivec3 cell = ivec3(floor(inside * 64.0));
		float n = cell_noise(cell, uint(p.b));
		color.rgb *= 1.0 + p.r * (n * 2.0 - 1.0);
	}
	ALBEDO = color.rgb;
	ROUGHNESS = 1.0;
}
