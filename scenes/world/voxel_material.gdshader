// Matériau voxel unique — 1 draw call par chunk opaque (G.2).
// TEXTURES PROCÉDURALES 16px/face, GRANULEUSES (2026-07-24). Chaque bloc a un
// grain fin (un pixel = une couleur) + une variation douce ; homogène mais pas
// un aplat. MINERAI et HERBE = MASQUE sur leur bloc HÔTE (roche / terre) passé
// par UV.y : un minerai se fond dans sa roche, l'herbe dans sa terre. Feuilles
// OPAQUES (les trous alpha coûtaient trop cher). Normal mapping procédural sur
// les surfaces STRUCTURÉES seulement (roche, terre, bois, planches, briques,
// minerai). Fondu vers la couleur plate au loin (anti-scintillement).
shader_type spatial;
// Ombrage voxel MAISON (2026-07-25) : unshaded = aucune boucle de lumière ni
// ombre temps réel (le poste le plus lourd sur iGPU). La profondeur vient d'un
// ombrage par FACE cuit dans l'albédo (dessus clair, côtés moyens, dessous
// sombre, façon Minecraft). Le soleil ne projette plus d'ombres.
render_mode cull_back, unshaded;

uniform sampler2D palette : source_color, filter_nearest;
uniform sampler2D noise_params : filter_nearest;
uniform sampler2D style_map : filter_nearest, repeat_disable;
uniform float world_seed = 0.0;
uniform int herbe_id = -1;
uniform int eau_id = -1;
uniform sampler2D grass_tint_map : filter_linear, repeat_disable;
uniform float chunk_size = 16.0;
uniform float bump_strength = 0.35;
// Cycle jour/nuit (E.21/G.3) : le terrain est UNSHADED, il ignore donc
// totalement la lumière directionnelle — changer l'énergie du soleil ne
// noircissait rien du tout. G.3 prescrit exactement ce qui suit : « le cycle
// jour/nuit module en SHADER (uniform global), pas en re-propagation —
// changer l'heure ne coûte rien ». `daylight` va de 0 (minuit) à 1 (midi).
uniform float daylight = 1.0;
uniform vec3 night_tint = vec3(0.42, 0.50, 0.78);
// Plancher de luminosité nocturne : la nuit n'est JAMAIS noire tant que les
// sources de lumière locales (torches, G.3) n'existent pas — sinon le jeu
// deviendrait injouable la nuit au lieu d'être dangereux.
uniform float night_floor = 0.30;
// Origine MONDE du chunk (en blocs, multiple de 16) — permet de calculer la
// texture à partir des coords LOCALES précises (2026-07-26) : à grande distance
// de l'origine, `fract(world_pos)` perdait toute précision → la texture nageait
// (« tout tremble »). `fract(origine_entière + local) == fract(local)`.
uniform vec3 chunk_origin = vec3(0.0);

const float PIXELS = 16.0;
const float DETAIL_NEAR = 26.0;
const float DETAIL_FAR = 68.0;

const int S_BASIC = 0;
const int S_STONE = 1;
const int S_SOIL = 2;
const int S_SAND = 3;
const int S_WOOD = 4;
const int S_PLANKS = 5;
const int S_LEAVES = 6;
const int S_ORE = 7;
const int S_METAL = 8;
const int S_GEM = 9;
const int S_BRICKS = 10;
const int S_WATER = 11;
const int S_SNOW = 12;
const int S_GRASS = 13;

varying vec3 v_world_pos;
varying vec3 v_local;      // Position LOCALE au chunk (0..16), précise.
varying vec3 v_world_normal;
varying flat float v_material;
varying flat float v_host;
varying vec2 v_tint_uv;

void vertex() {
	v_world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	v_local = VERTEX;
	v_world_normal = (MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz;
	v_material = UV.x;
	v_host = UV.y;
	v_tint_uv = clamp(VERTEX.xz / chunk_size, 0.0, 1.0);
}

uint pcg(uint v) {
	v = v * 747796405u + 2891336453u;
	uint w = ((v >> ((v >> 28u) + 4u)) ^ v) * 277803737u;
	return (w >> 22u) ^ w;
}
float h1(uint s) { return float(pcg(s) & 0xFFFFu) / 65535.0; }

// Ombrage directionnel par face (façon Minecraft) : dessus le plus clair,
// dessous le plus sombre, faces X un peu plus sombres que les faces Z pour
// donner du volume sans aucune lumière temps réel.
float face_shade(vec3 n) {
	if (n.y > 0.5) return 1.0;
	if (n.y < -0.5) return 0.5;
	return (abs(n.x) > abs(n.z)) ? 0.66 : 0.82;
}
float h2(ivec2 i, uint s) { return h1(uint(i.x) * 1973u ^ uint(i.y) * 9277u ^ s); }
// Bruit valeur interpolé (variation DOUCE de plus grande échelle).
float vnoise(vec2 p, uint s) {
	ivec2 i = ivec2(floor(p));
	vec2 f = fract(p);
	vec2 u = f * f * (3.0 - 2.0 * f);
	float a = h2(i, s);
	float b = h2(i + ivec2(1, 0), s);
	float c = h2(i + ivec2(0, 1), s);
	float d = h2(i + ivec2(1, 1), s);
	return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}
// fbm centré ~0 (retourne ~-0.5..0.5).
float fbm(vec2 p, uint s) {
	return (vnoise(p, s) - 0.5) * 0.66 + (vnoise(p * 2.0, s + 131u) - 0.5) * 0.34;
}
// GRAIN fin : bruit blanc PAR PIXEL (±0.5). C'est lui qui donne l'aspect
// granuleux « un pixel = une couleur ».
float grain(vec2 px, uint s) { return h2(ivec2(px), s) - 0.5; }

// --- Styles granuleux ---
vec3 st_stone(vec2 px, vec3 base, uint bs) {
	return base * (1.0 + grain(px, bs) * 0.15 + fbm(px * 0.3, bs) * 0.14);
}
vec3 st_soil(vec2 px, vec3 base, uint bs) {
	vec3 c = base * (1.0 + grain(px, bs + 1u) * 0.17 + fbm(px * 0.4, bs) * 0.12);
	float peb = step(0.88, h2(ivec2(px), bs + 3u));  // petits cailloux clairs
	return mix(c, base * 1.14, peb * 0.5);
}
vec3 st_sand(vec2 px, vec3 base, uint bs) {
	return base * (1.0 + grain(px, bs + 2u) * 0.1 + fbm(px * 0.6, bs) * 0.05);
}
vec3 st_grass(vec2 px, vec2 uv, vec3 dirt_col, vec3 green, uint bs, bool top) {
	// Herbe = masque VERT sur la terre : dessus vert, côtés terre avec une
	// frange verte en haut, façon Minecraft.
	if (top) {
		vec3 c = green * (1.0 + grain(px, bs + 5u) * 0.14 + fbm(px * 0.5, bs) * 0.1);
		float blade = step(0.85, h2(ivec2(px), bs + 7u));  // brins plus foncés
		return c * (1.0 - blade * 0.14);
	}
	vec3 dirt = st_soil(px, dirt_col, bs);
	if (uv.y > 0.82) return green * (1.0 + grain(px, bs + 5u) * 0.14);  // frange verte
	return dirt;
}
vec3 st_wood(vec2 px, vec2 uv, vec3 base, uint bs, bool top, int variant, float mj) {
	// Espacement d'anneaux + ondulation propres à l'ESSENCE (mj continu) : un
	// chêne (anneaux larges) ≠ un pin (serrés) ≠ un bois tropical.
	float ring_freq = 5.0 + mj * 6.0;      // 5..11
	float contrast = 0.10 + mj * 0.08;     // grain plus ou moins marqué
	if (top) {
		vec2 cp = px / PIXELS - 0.5;
		float d = length(cp) * ring_freq + (fbm(px * 0.3, bs) + 0.5) * 1.4;
		float rings = sin(d * 6.2832) * 0.5;
		return base * (1.0 + rings * (contrast + 0.03) + grain(px, bs) * 0.06);
	}
	// Grain vertical ; variante + mj changent l'ondulation (essences distinctes).
	float warp = (variant == 1) ? 11.0 : (variant == 2 ? 3.0 : (variant == 3 ? 8.0 : 6.0));
	warp *= 0.7 + mj * 0.6;
	float g = fbm(vec2(px.x * (0.7 + mj * 0.5), px.y * 0.12), bs);
	float fibers = sin(px.x * (2.0 + mj * 1.6) + (g + 0.5) * warp) * 0.5;
	float knot = (variant == 2) ? step(0.92, vnoise(px * 0.4, bs + 5u)) * 0.15 : 0.0;
	return base * (1.0 + g * contrast + fibers * 0.07 + grain(px, bs) * 0.05 - knot);
}
vec3 st_planks(vec2 px, vec3 base, uint bs) {
	float bh = 4.0;
	uint rs = bs + uint(floor(px.y / bh)) * 13u;
	float sy = fract(px.y / bh);
	float seam = smoothstep(0.0, 0.22, sy) * smoothstep(1.0, 0.78, sy);
	float g = fbm(vec2(px.x * 0.25, px.y) + floor(px.y / bh), rs);
	return base * (1.0 + g * 0.1 + grain(px, rs) * 0.06) * (0.84 + seam * 0.16);
}
vec3 st_leaves(vec2 px, vec3 base, uint bs, int variant, float mj) {
	// variant 3 = CONIFÈRE (aiguilles) : fines stries verticales serrées.
	if (variant == 3) {
		float needles = sin(px.x * 3.14159 + fbm(px * 0.5, bs) * 2.0) * 0.5;
		float v = fbm(vec2(px.x * 0.5, px.y * (1.4 + mj)), bs + 2u);
		vec3 c = base * (1.0 + needles * 0.1 + v * 0.14 + grain(px, bs + 9u) * 0.08);
		return c * (1.0 - smoothstep(-0.05, -0.18, v) * 0.16);
	}
	// Feuillu : touffes d'échelle propre à l'essence (mj continu).
	float sc = 0.28 + mj * 0.4;
	vec3 c = base * (1.0 + fbm(px * sc, bs) * 0.16 + grain(px, bs + 9u) * 0.1);
	float dark = smoothstep(-0.06, -0.16, fbm(px * (0.7 + mj * 0.5), bs + 3u));  // creux d'ombre
	return c * (1.0 - dark * 0.18);
}
vec3 st_ore(vec2 px, vec3 ore_col, vec3 host_col, uint bs, int variant, float mj) {
	// MATRICE = roche hôte ; VEINES du minerai par-dessus — texture PLATE (pas
	// de relief/normal map factice, retiré) mais BIEN DÉFINIES et contrastées :
	// seuil net + minerai saturé → les veines ressortent (retour 2026-07-26).
	vec3 matrix = st_stone(px, host_col, bs);
	if (variant == 3) {
		// CRISTALLIN : éclats anguleux nets et brillants.
		float facet = vnoise(px * 2.3, bs + 13u);
		float spot = smoothstep(0.58, 0.7, facet);
		float spark = smoothstep(0.88, 0.97, vnoise(px * 4.0, bs + 17u)) * spot;
		return mix(matrix, ore_col * 1.08, spot) + spark * 0.32;
	}
	if (variant == 2) {
		// TERNE (charbon) : GROSSES veines sombres bien définies (basse fréquence).
		float vein = fbm(px * 0.22, bs + 11u);
		float spot = smoothstep(-0.02, 0.06, vein);
		vec3 dull = ore_col * (0.85 + grain(px, bs + 4u) * 0.14);
		return mix(matrix, dull, spot);
	}
	// MÉTAUX / minéraux : GROSSES veines bien définies + ÉCLAT (cœur plus clair
	// + reflets ponctuels) → le minerai « brille » et ressort dans la roche.
	float vein = fbm(px * 0.22, bs + 11u);          // basse fréquence = grosses veines
	float spot = smoothstep(-0.02, 0.06, vein);     // bord net
	float core = smoothstep(0.06, 0.24, vein);      // cœur de la veine
	vec3 mineral = ore_col * (1.12 + core * 0.40) * (1.0 + grain(px, bs + 4u) * 0.12);
	float glint = smoothstep(0.86, 0.96, vnoise(px * 3.0, bs + 17u)) * spot;
	return mix(matrix, mineral, spot) + glint * 0.28;
}
vec3 st_metal(vec2 px, vec3 base, uint bs, float mj) {
	// Brossage métallique d'orientation/échelle propre au métal.
	float dir = (mj > 0.5) ? px.x : px.y;
	return base * (1.0 + fbm(px * (0.25 + mj * 0.3), bs) * 0.08
		+ sin(dir * (0.6 + mj)) * 0.03 + grain(px, bs) * 0.03);
}
vec3 st_gem(vec2 px, vec3 base, uint bs, float mj) {
	vec3 c = base * (1.0 + fbm(px * (0.35 + mj * 0.4), bs) * 0.18);
	float spark = smoothstep(0.95, 0.99, vnoise(px * (2.5 + mj * 2.0), bs + 7u));
	return c + spark * 0.3;
}
vec3 st_bricks(vec2 px, vec3 base, uint bs) {
	float bw = 8.0;
	float bh = 4.0;
	vec2 bp = px;
	bp.x += step(1.0, mod(floor(bp.y / bh), 2.0)) * (bw * 0.5);
	vec2 g = fract(bp / vec2(bw, bh));
	float m = smoothstep(0.0, 0.14, g.x) * smoothstep(1.0, 0.86, g.x);
	m = min(m, smoothstep(0.0, 0.28, g.y) * smoothstep(1.0, 0.72, g.y));
	float bv = h2(ivec2(floor(bp / vec2(bw, bh))), bs);
	vec3 brick = base * (0.94 + bv * 0.12 + grain(px, bs) * 0.05);
	vec3 mortar = base * 0.62;
	return mix(mortar, brick, m);
}
vec3 st_water(vec2 px, vec3 base, uint bs, bool animate) {
	float t = animate ? TIME * 0.4 : 0.0;
	float n = fbm(px * 0.3 + vec2(t, 0.0), bs) + fbm(px * 0.6 - vec2(0.0, t * 0.7), bs + 2u) * 0.5;
	return base * (1.0 + n * 0.12);
}
vec3 st_snow(vec2 px, vec3 base, uint bs) {
	vec3 c = base * (1.0 + grain(px, bs) * 0.05);
	float spark = smoothstep(0.96, 0.99, vnoise(px * 3.5, bs + 8u));
	return c + spark * 0.25;
}

// Hauteur pour normal mapping — plate (0.5) sur les styles LISSES, réelle sur
// les STRUCTURÉS (roche/terre/bois/planches/briques/minerai).
float bump_height(vec2 px, uint bs, int style, vec2 uv, bool top) {
	if (style == S_WOOD && !top) {
		float g = fbm(vec2(px.x * 0.9, px.y * 0.12), bs);
		return sin(px.x * 2.6 + (g + 0.5) * 6.0) * 0.5 + 0.5;
	}
	if (style == S_PLANKS) {
		float sy = fract(px.y / 4.0);
		return smoothstep(0.0, 0.22, sy) * smoothstep(1.0, 0.78, sy);
	}
	if (style == S_BRICKS) {
		vec2 bp = px;
		bp.x += step(1.0, mod(floor(bp.y / 4.0), 2.0)) * 4.0;
		vec2 g = fract(bp / vec2(8.0, 4.0));
		float m = smoothstep(0.0, 0.14, g.x) * smoothstep(1.0, 0.86, g.x);
		return min(m, smoothstep(0.0, 0.28, g.y) * smoothstep(1.0, 0.72, g.y));
	}
	if (style == S_ORE) return fbm(px * 0.7, bs + 11u) + 0.5;
	if (style == S_STONE || style == S_SOIL) return fbm(px * 0.35, bs) + 0.5;
	return 0.5;  // lisse : grass/sand/metal/water/snow/gem/leaves
}

void fragment() {
	int id = int(round(v_material));
	int host = int(round(v_host));
	vec3 base = texelFetch(palette, ivec2(id, 0), 0).rgb;
	// Roche HÔTE : la roche encaissante pour un FILON généré (host défini), sinon
	// (bloc solide posé/inventaire, host=0) la couleur du minéral LUI-MÊME → un
	// bloc d'ocre/soufre/sel reste SOLIDE et vif au lieu d'un fond gris terne.
	vec3 host_col = (host > 0) ? texelFetch(palette, ivec2(host, 0), 0).rgb : base;
	vec4 pp = texelFetch(noise_params, ivec2(id, 0), 0);
	int style = int(round(texelFetch(style_map, ivec2(id, 0), 0).r * 255.0));
	// Identité de TEXTURE par MATÉRIAU (2026-07-26) : chaque matériau a son
	// propre look (le fer ≠ le cuivre, le chêne ≠ le pin). `mseed` = graine
	// unique dérivée de l'id → `mvar` (sous-type discret) + `mj` (jitter continu
	// d'échelle/fréquence). `mpat` (canal .a de noise_params) = motif CURÉ
	// optionnel par donnée (0 = auto ; >0 force un sous-type : cristallin, dull,
	// aiguilles…), sinon on retombe sur mvar.
	uint mseed = pcg(uint(id) * 2654435761u + 7654321u);
	float mj = h1(mseed);
	int mpat = int(round(pp.a));
	// Auto-variant CONSCIENT DU STYLE : un minerai métallique reste en pépites
	// (0/1), une feuille reste feuillue (0/1/2) — les sous-types « spéciaux »
	// (cristallin, aiguilles) ne viennent QUE d'un motif curé (mpat). Le bois
	// tolère les 4 variantes.
	int autov = int(mseed % 4u);
	if (style == S_ORE) autov = int(mseed % 2u);
	else if (style == S_LEAVES) autov = int(mseed % 3u);
	int variant = (mpat > 0) ? (mpat - 1) : autov;
	uint ms = uint(world_seed + pp.b);

	vec3 an = abs(v_world_normal);
	vec2 uv;
	vec3 T;
	vec3 B;
	bool top = false;
	// Coords LOCALES au chunk (précises) pour la texture : fract(origine+local)
	// == fract(local) car l'origine du chunk est un entier (multiple de 16).
	if (an.y >= an.x && an.y >= an.z) {
		uv = fract(v_local.xz); top = true;
		T = vec3(1, 0, 0); B = vec3(0, 0, 1);
	} else if (an.x >= an.z) {
		uv = fract(v_local.zy);
		T = vec3(0, 0, 1); B = vec3(0, 1, 0);
	} else {
		uv = fract(v_local.xy);
		T = vec3(1, 0, 0); B = vec3(0, 1, 0);
	}
	vec2 px = floor(uv * PIXELS) + 0.5;

	float dist = length(v_world_pos - CAMERA_POSITION_WORLD);
	float detail = 1.0 - smoothstep(DETAIL_NEAR, DETAIL_FAR, dist);

	vec3 green = base * texture(grass_tint_map, v_tint_uv).rgb;  // herbe : teinte biome

	if (detail < 0.02) {
		ALBEDO = (style == S_GRASS) ? green : base;
	} else {
		// Coordonnée de bloc MONDE = origine entière du chunk + bloc local
		// (précis même très loin de l'origine).
		ivec3 bc = ivec3(round(chunk_origin)) + ivec3(floor(v_local - v_world_normal * 0.5));
		uint bs = ms ^ pcg(uint(bc.x) * 2654435761u ^ pcg(uint(bc.y) * 40503u ^ pcg(uint(bc.z))));

		vec3 c;
		if (style == S_STONE) c = st_stone(px, base, bs);
		else if (style == S_SOIL) c = st_soil(px, base, bs);
		else if (style == S_SAND) c = st_sand(px, base, bs);
		else if (style == S_GRASS) c = st_grass(px, uv, base, green, bs, top);
		else if (style == S_WOOD) c = st_wood(px, uv, base, bs, top, variant, mj);
		else if (style == S_PLANKS) c = st_planks(px, base, bs);
		else if (style == S_LEAVES) c = st_leaves(px, base, bs, variant, mj);
		else if (style == S_ORE) c = st_ore(px, base, host_col, bs, variant, mj);
		else if (style == S_METAL) c = st_metal(px, base, bs, mj);
		else if (style == S_GEM) c = st_gem(px, base, bs, mj);
		else if (style == S_BRICKS) c = st_bricks(px, base, bs);
		else if (style == S_WATER) c = st_water(px, base, bs, id == eau_id && top);
		else if (style == S_SNOW) c = st_snow(px, base, bs);
		else c = base * (1.0 + grain(px, bs) * 0.1);

		ALBEDO = mix((style == S_GRASS) ? green : base, c, detail);
	}

	// Ombrage par FACE (maison, remplace les ombres temps réel) : profondeur
	// gratuite façon Minecraft. Cuit directement dans l'albédo (unshaded).
	ALBEDO *= face_shade(v_world_normal);

	// Jour/nuit : assombrissement + dérive vers une teinte froide la nuit.
	// Une simple multiplication suffit — aucun coût mesurable, et l'heure
	// peut changer à chaque frame sans rien recalculer côté CPU.
	float lum = mix(night_floor, 1.0, daylight);
	vec3 tinted = mix(ALBEDO * night_tint, ALBEDO, daylight);
	ALBEDO = tinted * lum;

	// Lumière de BLOC (G.3), cuite dans la couleur de sommet par le mesher :
	// torches, lave, gemmes. Elle s'AJOUTE au jour plutôt que de le
	// remplacer — une torche en plein midi ne doit rien changer, la même
	// torche en pleine nuit doit tout changer. La teinte est chaude, pour
	// contraster avec le bleu nocturne.
	float block_light = COLOR.r;
	if (block_light > 0.001) {
		vec3 warm = ALBEDO * vec3(1.25, 1.08, 0.82);
		ALBEDO = mix(ALBEDO, warm, block_light * (1.0 - daylight * 0.75));
		ALBEDO *= 1.0 + block_light * (1.0 - daylight) * 1.6;
	}
}
