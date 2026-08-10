// Port fidèle de systems/worldgen/tree_generator.gd — TreeGenerator.generate.
// Mesuré avant de porter (--probe-gen, 2026-08-10) : la génération des FORMES
// pesait 13,7 ms/colonne (36,5 % de la génération totale), les candidats 2,3.
//
// LES TROIS CONTRAINTES DE PARITÉ, en plus des règles habituelles du module
// (miroir ligne à ligne, scalaires en double, Vector3 en float32, hachages en
// int64 signé aux débordements identiques) :
//
// 1. LE RNG EST LE MÊME OBJET GODOT (RandomNumberGenerator via godot-cpp) et
//    l'ORDRE DES APPELS est celui du GDScript, à l'appel près — intercaler ou
//    réordonner un seul randf() désynchronise toute la suite de l'arbre.
// 2. L'ORDRE D'INSERTION DES DICTIONNAIRES EST PRÉSERVÉ (OrderedMap maison) :
//    l'ordre des sous-grilles décide de l'ordre des sommets du mesh, et la
//    sonde de parité compare les tableaux exactement.
// 3. La sonde de parité doit VIDER le cache d'arbres entre ses deux passes
//    (sinon la passe native relit les arbres GDScript du cache).

#include "voxen_mesher.h"

#include <godot_cpp/classes/random_number_generator.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/string.hpp>
#include <godot_cpp/variant/vector3.hpp>
#include <godot_cpp/variant/vector3i.hpp>

#include <cmath>
#include <cstdint>
#include <unordered_map>
#include <vector>

namespace godot {

namespace {

constexpr double PI_D = 3.14159265358979323846;
constexpr double TAU_D = 6.28318530717958647692;
constexpr double PHYLLOTAXIS = 2.39996;
constexpr double TIP_RADIUS = 0.28;
constexpr int MAX_TIPS = 96;
constexpr double CROWN_FILL = 1.0;
constexpr int FINE_STEP = 4;      // SubdivGrid : 4 = 16 px.
constexpr int FINE_PER_BLOCK = 2;
constexpr int FINE_SHIFT = 1;
constexpr int FINE_MASK = FINE_PER_BLOCK - 1;
constexpr double LEAF_ERODE_RADIUS = 2.1;

const Vector3i FACE_DIRS[6] = {
	Vector3i(1, 0, 0), Vector3i(-1, 0, 0),
	Vector3i(0, 1, 0), Vector3i(0, -1, 0),
	Vector3i(0, 0, 1), Vector3i(0, 0, -1),
};

inline double clamp_d(double v, double lo, double hi) {
	return v < lo ? lo : (v > hi ? hi : v);
}
inline double lerp_d(double a, double b, double t) { return a + (b - a) * t; }
inline double deg2rad(double d) { return d * (PI_D / 180.0); }

// --- Table ORDONNÉE Vector3i → valeur -------------------------------------
// Les Dictionary Godot préservent l'ordre d'insertion, et le mesher en dépend
// (ordre des sommets). std::unordered_map ne le préserve pas : on garde donc
// la liste des clés dans l'ordre de PREMIÈRE insertion, et l'effacement
// (utilisé par _hollow) marque la table — l'itération saute les clés mortes.
inline int64_t pack_v3i(const Vector3i &v) {
	return ((int64_t)(v.x + (1 << 20)) << 42) | ((int64_t)(v.y + (1 << 20)) << 21) |
			(int64_t)(v.z + (1 << 20));
}
inline Vector3i unpack_v3i(int64_t k) {
	return Vector3i((int32_t)((k >> 42) & 0x1FFFFF) - (1 << 20),
			(int32_t)((k >> 21) & 0x1FFFFF) - (1 << 20),
			(int32_t)(k & 0x1FFFFF) - (1 << 20));
}

struct OrderedBlocks {
	std::unordered_map<int64_t, int32_t> map;
	std::vector<int64_t> order;

	bool has(const Vector3i &p) const { return map.count(pack_v3i(p)) != 0; }
	int32_t get(const Vector3i &p) const { return map.at(pack_v3i(p)); }
	void set(const Vector3i &p, int32_t id) {
		const int64_t k = pack_v3i(p);
		auto it = map.find(k);
		if (it == map.end()) {
			map.emplace(k, id);
			order.push_back(k);
		} else {
			it->second = id;
		}
	}
	void erase(const Vector3i &p) { map.erase(pack_v3i(p)); }
};

// --- Architecture (miroir de _architecture) --------------------------------
struct Arch {
	String form = "decurrent";
	String foliage = "mass";
	double base_radius = 0, fork = 0.45, children = 3, subdivide = 2;
	double spread_deg = 45.0, droop = 0.0, depth = 3, length_ratio = 0.62;
	double radius_ratio = 0.58, curve = 0.16, lean = 0.05, whorls = 10;
	double leaf_radius = 0, leaf_flatten = 1.0, leaf_density = 0.88, roots = 5;
	double height = 0, crown_reach = 0, whorl_spacing = 0;
};

// Le contexte qui voyage dans la récursion (miroir du ctx GDScript).
struct GrowCtx {
	OrderedBlocks fine;
	std::vector<Vector3> tips;
	Arch arch;
	Ref<RandomNumberGenerator> rng;
	int32_t wood_id = 0;
};

int64_t seed_for(int64_t world_seed, const Vector3i &base) {
	uint64_t v = ((uint64_t)world_seed * 747796405ULL + 2891336453ULL) ^
			((uint64_t)(int64_t)base.x * 2654435761ULL) ^
			((uint64_t)(int64_t)base.z * 1597334677ULL);
	v = (v ^ (uint64_t)((int64_t)v >> 15)) * 0x85EBCA6BULL;
	return (int64_t)((v ^ (uint64_t)((int64_t)v >> 13)) & 0x7FFFFFFFULL);
}

void apply_arch_override(Arch &a, const String &key, const Variant &value) {
	if (key == String("form")) { a.form = value; return; }
	if (key == String("foliage")) { a.foliage = value; return; }
	const double d = (double)value;
	if (key == String("base_radius")) a.base_radius = d;
	else if (key == String("fork")) a.fork = d;
	else if (key == String("children")) a.children = d;
	else if (key == String("subdivide")) a.subdivide = d;
	else if (key == String("spread_deg")) a.spread_deg = d;
	else if (key == String("droop")) a.droop = d;
	else if (key == String("depth")) a.depth = d;
	else if (key == String("length_ratio")) a.length_ratio = d;
	else if (key == String("radius_ratio")) a.radius_ratio = d;
	else if (key == String("curve")) a.curve = d;
	else if (key == String("lean")) a.lean = d;
	else if (key == String("whorls")) a.whorls = d;
	else if (key == String("leaf_radius")) a.leaf_radius = d;
	else if (key == String("leaf_flatten")) a.leaf_flatten = d;
	else if (key == String("leaf_density")) a.leaf_density = d;
	else if (key == String("roots")) a.roots = d;
}

Arch architecture(const Dictionary &species, const Ref<RandomNumberGenerator> &rng) {
	const String shape = species["canopy_shape"];
	const Array height_range = species["height_range"];
	const double height = (double)rng->randi_range((int)height_range[0], (int)height_range[1]);
	const Array canopy_range = species["canopy_radius_range"];
	const double canopy_radius = (double)rng->randi_range((int)canopy_range[0], (int)canopy_range[1]);
	const double trunk_radius = (double)species["trunk_radius"];

	Arch a;
	a.base_radius = std::max(2.2, trunk_radius * 2.2);
	a.leaf_radius = canopy_radius;

	if (shape == String("spirale")) {
		a.form = "excurrent"; a.fork = 0.10; a.spread_deg = 62.0; a.droop = 0.30;
		a.depth = 2; a.children = 3; a.length_ratio = 0.40; a.whorls = 12;
		a.curve = 1.10; a.leaf_flatten = 0.9;
	} else if (shape == String("bulle")) {
		a.form = "excurrent"; a.fork = 0.94; a.spread_deg = 18.0; a.droop = 0.75;
		a.depth = 1; a.children = 2; a.length_ratio = 0.18; a.whorls = 1;
		a.curve = 0.14; a.leaf_flatten = 1.0;
	} else if (shape == String("corolle")) {
		a.form = "palm"; a.fork = 0.97; a.spread_deg = 86.0; a.droop = 0.10;
		a.depth = 1; a.children = 7; a.length_ratio = 0.30; a.curve = 0.16;
		a.leaf_flatten = 0.20;
	} else if (shape == String("voute")) {
		a.form = "decurrent"; a.fork = 0.32; a.spread_deg = 44.0; a.droop = -0.62;
		a.depth = 3; a.children = 5; a.length_ratio = 0.86; a.curve = 0.30;
		a.leaf_flatten = 0.75;
	} else if (shape == String("conical")) {
		a.form = "excurrent"; a.fork = 0.12; a.spread_deg = 78.0; a.droop = -0.18;
		a.depth = 2; a.children = 4; a.length_ratio = 0.34; a.whorls = 14;
		a.curve = 0.07; a.foliage = "needle"; a.leaf_flatten = 0.55;
	} else if (shape == String("columnar")) {
		a.form = "excurrent"; a.fork = 0.15; a.spread_deg = 22.0; a.droop = 0.55;
		a.depth = 2; a.children = 3; a.length_ratio = 0.22; a.whorls = 12;
		a.curve = 0.06; a.foliage = "mass"; a.leaf_flatten = 1.3; a.lean = 0.02;
	} else if (shape == String("tiered")) {
		a.form = "excurrent"; a.fork = 0.45; a.spread_deg = 86.0; a.droop = -0.05;
		a.depth = 2; a.children = 5; a.length_ratio = 0.5; a.whorls = 5;
		a.foliage = "tiered"; a.leaf_flatten = 0.32;
	} else if (shape == String("vase")) {
		a.fork = 0.34; a.spread_deg = 26.0; a.droop = 0.62; a.children = 4;
		a.depth = 3; a.length_ratio = 0.72; a.leaf_flatten = 0.8;
	} else if (shape == String("broad")) {
		a.fork = 0.42; a.spread_deg = 55.0; a.droop = -0.05; a.children = 4;
		a.depth = 3; a.length_ratio = 0.66; a.curve = 0.24; a.leaf_flatten = 0.85;
	} else if (shape == String("oval")) {
		a.fork = 0.5; a.spread_deg = 34.0; a.droop = 0.28; a.children = 3;
		a.depth = 3; a.length_ratio = 0.6; a.foliage = "airy"; a.leaf_flatten = 1.25;
	} else if (shape == String("umbrella")) {
		a.fork = 0.55; a.spread_deg = 58.0; a.droop = 0.45; a.children = 4;
		a.depth = 3; a.length_ratio = 0.78; a.leaf_flatten = 0.3;
	} else if (shape == String("weeping")) {
		a.fork = 0.45; a.spread_deg = 48.0; a.droop = -0.75; a.children = 4;
		a.depth = 3; a.length_ratio = 0.7; a.foliage = "curtain"; a.leaf_flatten = 0.7;
	} else if (shape == String("flat")) {
		a.form = "palm"; a.foliage = "frond";
	} else if (shape == String("spherical")) {
		a.fork = 0.4; a.spread_deg = 48.0; a.droop = 0.15; a.children = 4;
		a.depth = 3; a.length_ratio = 0.62; a.curve = 0.22;
	}

	const Dictionary overrides = species.get("architecture", Dictionary());
	const Array keys = overrides.keys();
	for (int64_t i = 0; i < keys.size(); i++) {
		apply_arch_override(a, keys[i], overrides[keys[i]]);
	}
	a.height = height * FINE_PER_BLOCK;
	a.crown_reach = canopy_radius * FINE_PER_BLOCK;
	const double leafy = a.height * (1.0 - a.fork);
	a.whorl_spacing = std::max(1.5, leafy / std::max(1.0, a.whorls));
	return a;
}

// --- Squelette --------------------------------------------------------------

void ball(GrowCtx &ctx, const Vector3 &center, double radius) {
	const Vector3i origin((int)std::round((double)center.x),
			(int)std::round((double)center.y), (int)std::round((double)center.z));
	if (radius <= 0.5) {
		ctx.fine.set(origin, ctx.wood_id);
		return;
	}
	const int reach = (int)std::ceil(radius);
	for (int dx = -reach; dx <= reach; dx++) {
		for (int dy = -reach; dy <= reach; dy++) {
			for (int dz = -reach; dz <= reach; dz++) {
				const Vector3i cell = origin + Vector3i(dx, dy, dz);
				// distance_squared_to en float32, comme Vector3 GDScript.
				if ((double)Vector3(cell).distance_squared_to(center) <= radius * radius) {
					ctx.fine.set(cell, ctx.wood_id);
				}
			}
		}
	}
}

void stroke(GrowCtx &ctx, const Vector3 &a, const Vector3 &b, double ra, double rb) {
	const Vector3 span = b - a;
	const double distance = (double)span.length();
	const int steps = std::max(1, (int)std::ceil(distance / 0.85));
	for (int i = 0; i <= steps; i++) {
		const double t = (double)i / steps;
		ball(ctx, a + span * (real_t)t, lerp_d(ra, rb, t));
	}
}

Vector3 spread(const Vector3 &dir, double yaw, double angle) {
	const Vector3 reference =
			std::abs((double)dir.dot(Vector3(0, 1, 0))) < 0.95 ? Vector3(0, 1, 0) : Vector3(1, 0, 0);
	const Vector3 side = dir.cross(reference).normalized();
	const Vector3 other = dir.cross(side).normalized();
	const Vector3 radial = (side * (real_t)std::cos(yaw) + other * (real_t)std::sin(yaw)).normalized();
	return (dir * (real_t)std::cos(angle) + radial * (real_t)std::sin(angle)).normalized();
}

void grow(GrowCtx &ctx, const Vector3 &from, const Vector3 &dir, double length,
		double radius, int depth, bool leader) {
	const Arch &arch = ctx.arch;
	const Ref<RandomNumberGenerator> &rng = ctx.rng;
	const bool excurrent = arch.form == String("excurrent");
	const double fork = arch.fork;
	const double droop = arch.droop;
	const double curve = arch.curve;

	const double run = (excurrent || !leader) ? length : length * fork;
	const int steps = std::max(2, (int)std::round(run * 0.5));
	const double seg = run / steps;

	Vector3 pos = from;
	Vector3 heading = dir;
	double travelled = 0.0;
	double next_whorl = arch.whorl_spacing * (leader ? fork * 4.0 : 0.0);

	int per_whorl = (int)arch.children;
	if (excurrent && leader) {
		const double spacing = std::max(arch.whorl_spacing, 0.5);
		const double expected = std::max(1.0, run / spacing);
		// clampi GDScript = min(max(v, lo), hi) — l'ordre compte si hi < lo.
		per_whorl = std::min(std::max((int)((double)MAX_TIPS * 0.85 / expected), 2),
				(int)arch.children);
	}

	for (int i = 0; i < steps; i++) {
		const double t0 = (double)i / steps;
		const double t1 = (double)(i + 1) / steps;
		// TIRAGES HISSÉS EN VARIABLES, DANS L'ORDRE DU GDSCRIPT : l'ordre
		// d'évaluation des arguments C++ n'est pas spécifié (GCC va de droite
		// à gauche), et des tirages inline sortiraient du RNG dans le mauvais
		// ordre — mêmes nombres, mauvaises places, arbres en miroir. C'est le
		// premier écart qu'a montré la sonde de parité.
		const real_t wob_x = (real_t)rng->randf_range(-1.0f, 1.0f);
		const real_t wob_y = (real_t)rng->randf_range(-0.35f, 0.35f);
		const real_t wob_z = (real_t)rng->randf_range(-1.0f, 1.0f);
		const Vector3 wobble = Vector3(wob_x, wob_y, wob_z) * (real_t)curve;
		// MÊME CHAÎNE DE MULTIPLICATIONS que le GDScript : chaque produit
		// Vector3×scalaire arrondit en float32, donc (UP × droop) × 0.22 n'est
		// PAS UP × (droop × 0.22) — l'écart d'un ulp dériverait tout l'arbre.
		heading = (heading + wobble + dir * (real_t)0.35 +
						  Vector3(0, 1, 0) * (real_t)droop * (real_t)0.22)
						  .normalized();
		const Vector3 next = pos + heading * (real_t)seg;
		stroke(ctx, pos, next, lerp_d(radius, radius * 0.72, t0), lerp_d(radius, radius * 0.72, t1));
		pos = next;
		travelled += seg;

		if (excurrent && depth > 0 && leader && travelled >= next_whorl && t1 < 0.97) {
			next_whorl = travelled + arch.whorl_spacing;
			const double profile = lerp_d(1.0, 0.18, t1);
			const double lateral_len = arch.crown_reach * profile * 0.95;
			const double lateral_r = radius * arch.radius_ratio * lerp_d(1.0, 0.4, t1);
			const int whorl = per_whorl;
			for (int k = 0; k < whorl; k++) {
				const double yaw = PHYLLOTAXIS * (double)(i * whorl + k) +
						(double)rng->randf_range(-0.25f, 0.25f);
				const Vector3 lateral = spread(heading, yaw,
						deg2rad(arch.spread_deg + (double)rng->randf_range(-8.0f, 8.0f)));
				grow(ctx, pos, lateral, lateral_len, std::max(lateral_r, TIP_RADIUS), depth - 1, false);
			}
		}
	}

	if (depth <= 0 || radius <= TIP_RADIUS) {
		ctx.tips.push_back(pos);
		return;
	}
	if (excurrent && leader) {
		ctx.tips.push_back(pos);
		return;
	}

	const int n = leader ? (int)arch.children : (int)arch.subdivide;
	if ((int)ctx.tips.size() >= MAX_TIPS) {
		ctx.tips.push_back(pos);
		return;
	}
	const double base_yaw = (double)rng->randf() * TAU_D;
	for (int k = 0; k < n; k++) {
		const double yaw = base_yaw + PHYLLOTAXIS * k + (double)rng->randf_range(-0.3f, 0.3f);
		const double angle = deg2rad(arch.spread_deg + (double)rng->randf_range(-10.0f, 10.0f));
		const Vector3 child_dir = spread(heading, yaw, angle);
		double child_len = length * arch.length_ratio;
		if (leader) {
			child_len = arch.crown_reach / std::max(std::sin(angle), 0.4) * 0.6;
		}
		child_len *= (double)rng->randf_range(0.85f, 1.15f);
		const double child_r = radius * arch.radius_ratio;
		grow(ctx, pos, child_dir, child_len, std::max(child_r, TIP_RADIUS), depth - 1, false);
	}
}

void grow_palm(GrowCtx &ctx, const Vector3 &foot) {
	const Arch &arch = ctx.arch;
	const Ref<RandomNumberGenerator> &rng = ctx.rng;
	const double height = arch.height;
	const int steps = std::max(4, (int)std::round(height));
	const double seg = height / steps;
	// Tirages hissés (ordre d'évaluation C++ non spécifié — voir grow()).
	const real_t lean_x = (real_t)rng->randf_range(-1.0f, 1.0f);
	const real_t lean_z = (real_t)rng->randf_range(-1.0f, 1.0f);
	const Vector3 lean = Vector3(lean_x, 0, lean_z).normalized();
	Vector3 pos = foot;
	const double base_radius = arch.base_radius;
	for (int i = 0; i < steps; i++) {
		const double t = (double)i / steps;
		const Vector3 heading = (Vector3(0, 1, 0) + lean * (real_t)(0.10 + 0.22 * t)).normalized();
		const Vector3 next = pos + heading * (real_t)seg;
		stroke(ctx, pos, next, lerp_d(base_radius, 1.1, t), lerp_d(base_radius, 1.1, t + 1.0 / steps));
		pos = next;
	}
	ctx.tips.push_back(pos);
}

void grow_roots(GrowCtx &ctx, const Vector3 &foot) {
	const Arch &arch = ctx.arch;
	const Ref<RandomNumberGenerator> &rng = ctx.rng;
	const int count = (int)arch.roots;
	if (count <= 0) {
		return;
	}
	const double radius = arch.base_radius;
	const double start_yaw = (double)rng->randf() * TAU_D;
	for (int i = 0; i < count; i++) {
		const double yaw = start_yaw + TAU_D * i / count + (double)rng->randf_range(-0.25f, 0.25f);
		const Vector3 dir((real_t)std::cos(yaw), 0, (real_t)std::sin(yaw));
		const double length = radius * (double)rng->randf_range(1.6f, 2.6f);
		const Vector3 start = foot + Vector3(0, (real_t)(radius * 0.8), 0);
		const Vector3 end = foot + dir * (real_t)length + Vector3(0, (real_t)-0.4, 0);
		stroke(ctx, start, end, radius * 0.85, 0.6);
	}
}

// --- Rastérisation ----------------------------------------------------------

void set_grid_region(PackedInt32Array &grid, const Vector3i &cell_min, int size, int32_t id) {
	int32_t *g = grid.ptrw();
	for (int y = cell_min.y; y < cell_min.y + size; y++) {
		for (int z = cell_min.z; z < cell_min.z + size; z++) {
			const int row = (z << 3) | (y << 6);
			for (int x = cell_min.x; x < cell_min.x + size; x++) {
				g[row | x] = id;
			}
		}
	}
}

double rasterize(const OrderedBlocks &fine, OrderedBlocks &blocks,
		Dictionary &subdivs, Array &wood_positions) {
	// per_block : groupement des cellules fines PAR BLOC, ordre de première
	// rencontre (miroir de l'itération du Dictionary GDScript).
	std::unordered_map<int64_t, std::vector<int64_t>> per_block;
	std::vector<int64_t> block_order;
	for (const int64_t cell_key : fine.order) {
		auto fit = fine.map.find(cell_key);
		if (fit == fine.map.end()) {
			continue;
		}
		const Vector3i cell = unpack_v3i(cell_key);
		const Vector3i block(cell.x >> FINE_SHIFT, cell.y >> FINE_SHIFT, cell.z >> FINE_SHIFT);
		const int64_t bk = pack_v3i(block);
		auto it = per_block.find(bk);
		if (it == per_block.end()) {
			per_block.emplace(bk, std::vector<int64_t>{ cell_key });
			block_order.push_back(bk);
		} else {
			it->second.push_back(cell_key);
		}
	}

	const int full = FINE_PER_BLOCK * FINE_PER_BLOCK * FINE_PER_BLOCK;
	double volume = 0.0;
	for (const int64_t bk : block_order) {
		const std::vector<int64_t> &cells = per_block[bk];
		const Vector3i block = unpack_v3i(bk);
		const int32_t material_id = fine.map.at(cells[0]);
		blocks.set(block, material_id);
		wood_positions.push_back(block);
		volume += (double)cells.size() / (double)full;
		if ((int)cells.size() >= full) {
			continue;
		}
		PackedInt32Array grid;
		grid.resize(512);
		for (const int64_t ck : cells) {
			const Vector3i cell = unpack_v3i(ck);
			const Vector3i q(cell.x & FINE_MASK, cell.y & FINE_MASK, cell.z & FINE_MASK);
			set_grid_region(grid, q * FINE_STEP, FINE_STEP, material_id);
		}
		subdivs[block] = grid;
	}
	return volume;
}

// --- Feuillage --------------------------------------------------------------

bool keep_leaf(const Vector3i &pos, int64_t seed_value, double keep_chance) {
	uint64_t v = ((uint64_t)(int64_t)pos.x * 668265263ULL) ^
			((uint64_t)(int64_t)pos.y * 374761393ULL) ^
			((uint64_t)(int64_t)pos.z * 2246822519ULL) ^ (uint64_t)seed_value;
	v = (v ^ (uint64_t)((int64_t)v >> 13)) * 1274126177ULL;
	const double f = (double)(v & 0xFFFFFF) / (double)0xFFFFFF;
	return f < keep_chance;
}

void blob(OrderedBlocks &blocks, const Vector3 &tip_fine, double radius,
		double flatten, double density, int32_t leaf_id) {
	const Vector3 center = tip_fine / (real_t)FINE_PER_BLOCK;
	const Vector3i origin((int)std::round((double)center.x),
			(int)std::round((double)center.y), (int)std::round((double)center.z));
	const int reach = std::max(1, (int)std::ceil(radius));
	const int reach_y = std::max(1, (int)std::ceil(radius * flatten));
	for (int dx = -reach; dx <= reach; dx++) {
		for (int dy = -reach_y; dy <= reach_y; dy++) {
			for (int dz = -reach; dz <= reach; dz++) {
				const Vector3i pos = origin + Vector3i(dx, dy, dz);
				if (blocks.has(pos)) {
					continue;
				}
				const double ry = (double)dy / std::max(flatten, 0.05);
				const double d2 = (double)(dx * dx + dz * dz) + ry * ry;
				if (d2 > radius * radius) {
					continue;
				}
				const double edge = d2 / std::max(radius * radius, 0.01);
				if (keep_leaf(pos, leaf_id, density * lerp_d(1.05, 0.55, edge))) {
					blocks.set(pos, leaf_id);
				}
			}
		}
	}
}

void curtain(OrderedBlocks &blocks, const Vector3 &tip_fine, const Arch &arch,
		const Ref<RandomNumberGenerator> &rng, int32_t leaf_id) {
	const Vector3 center = tip_fine / (real_t)FINE_PER_BLOCK;
	const Vector3i origin((int)std::round((double)center.x),
			(int)std::round((double)center.y), (int)std::round((double)center.z));
	const int strands = rng->randi_range(2, 4);
	for (int s = 0; s < strands; s++) {
		const double yaw = (double)rng->randf() * TAU_D;
		// Tirages hissés (ordre d'évaluation C++ non spécifié — voir grow()).
		const double off_a = (double)rng->randf_range(0.0f, 2.0f);
		const double off_b = (double)rng->randf_range(0.0f, 2.0f);
		const Vector3i offset((int)std::round(std::cos(yaw) * off_a), 0,
				(int)std::round(std::sin(yaw) * off_b));
		const int drop = rng->randi_range(2, std::max(3, (int)(arch.leaf_radius * 1.6)));
		for (int d = 0; d < drop; d++) {
			const Vector3i pos = origin + offset + Vector3i(0, -d, 0);
			if (blocks.has(pos)) {
				continue;
			}
			if (keep_leaf(pos, leaf_id, lerp_d(0.95, 0.42, (double)d / std::max(drop, 1)))) {
				blocks.set(pos, leaf_id);
			}
		}
	}
}

void fronds(OrderedBlocks &blocks, const Vector3 &tip_fine, const Arch &arch,
		const Ref<RandomNumberGenerator> &rng, int32_t leaf_id) {
	const Vector3 center = tip_fine / (real_t)FINE_PER_BLOCK;
	const Vector3i origin((int)std::round((double)center.x),
			(int)std::round((double)center.y), (int)std::round((double)center.z));
	const int count = rng->randi_range(9, 13);
	const int length = std::max(4, (int)(arch.leaf_radius * 1.9));
	const double start_yaw = (double)rng->randf() * TAU_D;
	for (int i = 0; i < count; i++) {
		const double yaw = start_yaw + TAU_D * i / count + (double)rng->randf_range(-0.15f, 0.15f);
		const Vector3 dir((real_t)std::cos(yaw), 0, (real_t)std::sin(yaw));
		for (int step = 1; step <= length; step++) {
			const double t = (double)step / length;
			const double drop = -0.6 * t * t * length;
			const Vector3i pos = origin + Vector3i((int)std::round((double)dir.x * step),
											 (int)std::round(drop + 1.0),
											 (int)std::round((double)dir.z * step));
			blocks.set(pos, leaf_id);
			if (t < 0.7) {
				const Vector3i side((int)std::round((double)-dir.z), 0, (int)std::round((double)dir.x));
				if (!blocks.has(pos + side)) {
					blocks.set(pos + side, leaf_id);
				}
				if (t < 0.4 && !blocks.has(pos - side)) {
					blocks.set(pos - side, leaf_id);
				}
			}
		}
	}
}

void foliage(GrowCtx &ctx, OrderedBlocks &blocks, int32_t leaf_id) {
	const Arch &arch = ctx.arch;
	if (ctx.tips.empty() || leaf_id == 0) {
		return;
	}
	const String style = arch.foliage;
	const double flatten = arch.leaf_flatten;
	const double density = arch.leaf_density;
	const double count = std::max(1.0, (double)ctx.tips.size());
	const double crown = arch.leaf_radius;
	const double per_tip = clamp_d(crown * CROWN_FILL / std::pow(count, 1.0 / 3.0), 1.5, crown * 0.7);

	for (const Vector3 &tip : ctx.tips) {
		if (style == String("frond")) {
			fronds(blocks, tip, arch, ctx.rng, leaf_id);
		} else if (style == String("curtain")) {
			blob(blocks, tip, per_tip, flatten, density, leaf_id);
			curtain(blocks, tip, arch, ctx.rng, leaf_id);
		} else if (style == String("tiered")) {
			blob(blocks, tip, per_tip * 1.35, 0.28, density, leaf_id);
		} else if (style == String("needle")) {
			blob(blocks, tip, per_tip * 1.15, 0.85, std::min(density * 1.25, 1.0), leaf_id);
		} else if (style == String("airy")) {
			blob(blocks, tip, per_tip * 0.9, flatten, density * 0.72, leaf_id);
		} else {
			blob(blocks, tip, per_tip, flatten, density, leaf_id);
		}
	}
}

void hollow(OrderedBlocks &blocks, int32_t leaf_id) {
	std::vector<Vector3i> buried;
	for (const int64_t k : blocks.order) {
		auto it = blocks.map.find(k);
		if (it == blocks.map.end() || it->second != leaf_id) {
			continue;
		}
		const Vector3i pos = unpack_v3i(k);
		bool enclosed = true;
		for (int i = 0; i < 6; i++) {
			if (!blocks.has(pos + FACE_DIRS[i])) {
				enclosed = false;
				break;
			}
		}
		if (enclosed) {
			buried.push_back(pos);
		}
	}
	for (const Vector3i &pos : buried) {
		blocks.erase(pos);
	}
}

// --- Peau du feuillage ------------------------------------------------------

PackedInt32Array eroded_leaf_grid(int32_t material_id, int mask) {
	const int32_t key = (material_id << 8) | mask;
	thread_local std::unordered_map<int32_t, PackedInt32Array> t_cache;
	auto it = t_cache.find(key);
	if (it != t_cache.end()) {
		return it->second;
	}
	PackedInt32Array grid;
	grid.resize(512);
	const double center = (FINE_PER_BLOCK - 1) * 0.5;
	for (int qx = 0; qx < FINE_PER_BLOCK; qx++) {
		for (int qy = 0; qy < FINE_PER_BLOCK; qy++) {
			for (int qz = 0; qz < FINE_PER_BLOCK; qz++) {
				double reach = 0.0;
				for (int i = 0; i < 6; i++) {
					if (!(mask & (1 << i))) {
						continue;
					}
					const Vector3i dir = FACE_DIRS[i];
					const double along = ((double)qx - center) * dir.x +
							((double)qy - center) * dir.y + ((double)qz - center) * dir.z;
					if (along > 0.0) {
						reach += along * along;
					}
				}
				if (reach <= LEAF_ERODE_RADIUS * LEAF_ERODE_RADIUS) {
					set_grid_region(grid, Vector3i(qx, qy, qz) * FINE_STEP, FINE_STEP, material_id);
				}
			}
		}
	}
	t_cache.emplace(key, grid);
	return grid;
}

void erode_leaf_shell(OrderedBlocks &blocks, Dictionary &subdivs, int32_t leaf_id) {
	std::vector<std::pair<Vector3i, int>> shells;
	for (const int64_t k : blocks.order) {
		auto it = blocks.map.find(k);
		if (it == blocks.map.end() || it->second != leaf_id) {
			continue;
		}
		const Vector3i pos = unpack_v3i(k);
		if (subdivs.has(pos)) {
			continue;
		}
		int mask = 0;
		for (int i = 0; i < 6; i++) {
			if (!blocks.has(pos + FACE_DIRS[i])) {
				mask |= 1 << i;
			}
		}
		int free_faces = 0;
		for (int i = 0; i < 6; i++) {
			if (mask & (1 << i)) {
				free_faces++;
			}
		}
		if (free_faces == 3 || free_faces == 4) {
			shells.emplace_back(pos, mask);
		}
	}
	for (const auto &entry : shells) {
		subdivs[entry.first] = eroded_leaf_grid(leaf_id, entry.second);
	}
}

} // namespace

Dictionary VoxenNative::generate_tree(const Vector3i &base, int64_t world_seed,
		const Dictionary &species, int wood_id, int leaf_id) const {
	Ref<RandomNumberGenerator> rng;
	rng.instantiate();
	rng->set_seed(seed_for(world_seed, base));

	GrowCtx ctx;
	ctx.arch = architecture(species, rng);
	ctx.rng = rng;
	ctx.wood_id = wood_id;

	const Vector3 foot((real_t)(base.x * FINE_PER_BLOCK + (FINE_PER_BLOCK - 1) * 0.5),
			(real_t)(base.y * FINE_PER_BLOCK),
			(real_t)(base.z * FINE_PER_BLOCK + (FINE_PER_BLOCK - 1) * 0.5));

	// --- 1. Le squelette ---
	if (ctx.arch.form == String("palm")) {
		grow_palm(ctx, foot);
	} else {
		// Tirages hissés (ordre d'évaluation C++ non spécifié — voir grow()).
		const real_t lean_x = (real_t)rng->randf_range(-1.0f, 1.0f);
		const real_t lean_z = (real_t)rng->randf_range(-1.0f, 1.0f);
		const Vector3 lean(lean_x, 0, lean_z);
		const Vector3 up = (Vector3(0, 1, 0) + lean * (real_t)ctx.arch.lean).normalized();
		grow(ctx, foot, up, ctx.arch.height, ctx.arch.base_radius, (int)ctx.arch.depth, true);
	}

	// --- 2. Les racines ---
	grow_roots(ctx, foot);

	// --- 3. Rastérisation ---
	OrderedBlocks blocks;
	Dictionary subdivs;
	Array wood_positions;
	const double wood_volume = rasterize(ctx.fine, blocks, subdivs, wood_positions);

	// --- 4. Le feuillage ---
	foliage(ctx, blocks, leaf_id);

	// --- 4 bis. Évidage ---
	hollow(blocks, leaf_id); // HOLLOW_CANOPY est vrai côté GDScript.

	// --- 5. Peau du feuillage érodée ---
	erode_leaf_shell(blocks, subdivs, leaf_id);

	// Sortie : les Dictionary Godot sont remplis DANS L'ORDRE D'INSERTION de la
	// table ordonnée — même ordre que le GDScript, donc mêmes meshes.
	Dictionary blocks_out;
	for (const int64_t k : blocks.order) {
		auto it = blocks.map.find(k);
		if (it != blocks.map.end()) {
			blocks_out[unpack_v3i(k)] = it->second;
		}
	}

	Dictionary result;
	result["blocks"] = blocks_out;
	result["wood_positions"] = wood_positions;
	result["base"] = base;
	result["species_id"] = String(species["id"]);
	result["special_tags"] = species.get("special_tags", Array());
	result["trunk_subdivs"] = subdivs;
	result["wood_volume"] = wood_volume;
	return result;
}

} // namespace godot
