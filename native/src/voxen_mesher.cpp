// Port fidèle de systems/voxel/chunk_mesher.gd — voir l'en-tête pour le
// périmètre. CHAQUE bloc de ce fichier correspond à un bloc du GDScript, dans
// le même ordre, avec les mêmes noms : en cas de divergence de rendu, la
// comparaison se fait côte à côte. Ne pas « améliorer » l'algorithme ici sans
// changer le GDScript de référence — les deux chemins doivent rester miroirs
// (la sonde --probe-mesh les compare).

#include "voxen_mesher.h"

#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/color.hpp>
#include <godot_cpp/variant/packed_color_array.hpp>
#include <godot_cpp/variant/packed_int64_array.hpp>
#include <godot_cpp/variant/packed_vector2_array.hpp>
#include <godot_cpp/variant/packed_vector3_array.hpp>
#include <godot_cpp/variant/vector2.hpp>
#include <godot_cpp/variant/vector3.hpp>

#include <chrono>
#include <cstdint>
#include <cstring>
#include <unordered_map>
#include <vector>

namespace godot {

namespace {

constexpr int T = 16;
constexpr int P = 18;
// Strides du tableau paddé : indice = (x+1) + (z+1)*18 + (y+1)*324.
constexpr int SX = 1;
constexpr int SY = 324;
constexpr int SZ = 18;
constexpr int STRIDES[3] = { SX, SY, SZ };       // par axe (0=x, 1=y, 2=z)
constexpr int CHUNK_STRIDES[3] = { 1, 256, 16 }; // tableau 16³ du chunk
constexpr float WATER_DROP = 0.14f;
constexpr int LIGHT_MAX_LEVEL = 15;
constexpr float SUBDIV_CELL_UNIT = 0.125f; // SubdivGrid.CELL_UNIT

inline int64_t now_us() {
	return std::chrono::duration_cast<std::chrono::microseconds>(
			std::chrono::steady_clock::now().time_since_epoch())
			.count();
}

// --- Lumière de bloc (port de LightField.compute_from_pad) ---------------
// Retourne un champ 18³ (vide si aucune source), écrit dans `light`.
void compute_light_from_pad(const int32_t *pad, const PackedByteArray &emission,
		const PackedByteArray &transmits, std::vector<uint8_t> &light) {
	const int64_t emission_size = emission.size();
	if (emission_size == 0) {
		return;
	}
	const uint8_t *em = emission.ptr();
	const uint8_t *tr = transmits.ptr();
	const int64_t transmits_size = transmits.size();

	// 1. Repérage des sources — la boucle sort presque toujours les mains vides.
	std::vector<int32_t> sources;
	std::vector<int32_t> levels;
	for (int index = 0; index < P * P * P; index++) {
		const int32_t id = pad[index];
		if (id <= 0 || id >= emission_size) {
			continue;
		}
		const int level = em[id];
		if (level > 0) {
			sources.push_back(index);
			levels.push_back(level);
		}
	}
	if (sources.empty()) {
		return;
	}

	light.assign(P * P * P, 0);
	for (size_t i = 0; i < sources.size(); i++) {
		if (light[sources[i]] < levels[i]) {
			light[sources[i]] = (uint8_t)levels[i];
		}
	}

	// 2. Propagation en largeur, file à curseur.
	std::vector<int32_t> queue = sources;
	size_t cursor = 0;
	constexpr int OFF[6] = { SX, -SX, SY, -SY, SZ, -SZ };
	constexpr int DDX[6] = { 1, -1, 0, 0, 0, 0 };
	constexpr int DDY[6] = { 0, 0, 1, -1, 0, 0 };
	constexpr int DDZ[6] = { 0, 0, 0, 0, 1, -1 };
	while (cursor < queue.size()) {
		const int32_t index = queue[cursor];
		cursor++;
		const int level = light[index];
		if (level <= 1) {
			continue;
		}
		const int next_level = level - 1;
		const int x = index % P;
		const int y = index / SY;
		const int z = (index / SZ) % P;
		for (int k = 0; k < 6; k++) {
			const int nx = x + DDX[k];
			const int ny = y + DDY[k];
			const int nz = z + DDZ[k];
			if (nx < 0 || ny < 0 || nz < 0 || nx >= P || ny >= P || nz >= P) {
				continue;
			}
			const int neighbour = index + OFF[k];
			if (light[neighbour] >= next_level) {
				continue;
			}
			const int32_t id = pad[neighbour];
			// Un bloc opaque reçoit la lumière mais ne la propage pas.
			const bool opaque = id > 0 && (id >= transmits_size || tr[id] == 0);
			light[neighbour] = (uint8_t)next_level;
			if (!opaque) {
				queue.push_back(neighbour);
			}
		}
	}
}

// --- Cache des quads d'une sous-grille (port de _grid_quads) --------------
// THREAD_LOCAL : un cache par worker, aucun verrou. Même politique que le
// GDScript : borné, et GELÉ une fois plein (on ne vide pas, on ne filtre pas).
constexpr size_t MAX_CACHED_GRIDS = 16384;
thread_local std::unordered_map<uint64_t, std::vector<int32_t>> t_grid_cache;

uint64_t grid_hash(const int32_t *g) {
	uint64_t h = 1469598103934665603ull; // FNV-1a
	const uint8_t *bytes = (const uint8_t *)g;
	for (int i = 0; i < 512 * 4; i++) {
		h ^= bytes[i];
		h *= 1099511628211ull;
	}
	return h;
}

const std::vector<int32_t> &grid_quads(const int32_t *grid) {
	const uint64_t key = grid_hash(grid);
	auto it = t_grid_cache.find(key);
	if (it != t_grid_cache.end()) {
		return it->second;
	}

	std::vector<int32_t> quads;
	int32_t mask[64];
	constexpr int GRID_STRIDES[3] = { 1, 64, 8 };
	for (int d = 0; d < 3; d++) {
		const int u = (d + 1) % 3;
		const int v = (d + 2) % 3;
		const int gd = GRID_STRIDES[d];
		const int gu = GRID_STRIDES[u];
		const int gv = GRID_STRIDES[v];
		for (int cut = -1; cut < 8; cut++) {
			bool visible = false;
			int n = 0;
			for (int j = 0; j < 8; j++) {
				for (int i = 0; i < 8; i++) {
					const int32_t a = cut >= 0 ? grid[cut * gd + i * gu + j * gv] : 0;
					const int32_t b = cut <= 6 ? grid[(cut + 1) * gd + i * gu + j * gv] : 0;
					int32_t value = 0;
					if (a != 0 && b == 0) {
						value = a;
					} else if (b != 0 && a == 0) {
						value = -b;
					}
					mask[n] = value;
					if (value != 0) {
						visible = true;
					}
					n++;
				}
			}
			if (!visible) {
				continue;
			}
			// Fusion gloutonne (identique à la passe bloc, T = 8).
			for (int j = 0; j < 8; j++) {
				int i = 0;
				while (i < 8) {
					const int32_t c = mask[j * 8 + i];
					if (c == 0) {
						i++;
						continue;
					}
					int w = 1;
					while (i + w < 8 && mask[j * 8 + i + w] == c) {
						w++;
					}
					int h = 1;
					bool extendable = true;
					while (j + h < 8 && extendable) {
						for (int k = 0; k < w; k++) {
							if (mask[(j + h) * 8 + i + k] != c) {
								extendable = false;
								break;
							}
						}
						if (extendable) {
							h++;
						}
					}
					quads.push_back(d);
					quads.push_back(cut);
					quads.push_back(i);
					quads.push_back(j);
					quads.push_back(w);
					quads.push_back(h);
					quads.push_back(c);
					for (int jj = 0; jj < h; jj++) {
						for (int kk = 0; kk < w; kk++) {
							mask[(j + jj) * 8 + i + kk] = 0;
						}
					}
					i += w;
				}
			}
		}
	}

	if (t_grid_cache.size() < MAX_CACHED_GRIDS) {
		return t_grid_cache.emplace(key, std::move(quads)).first->second;
	}
	// Cache gelé : la grille unique repart calculée sans être retenue.
	thread_local std::vector<int32_t> t_overflow;
	t_overflow = std::move(quads);
	return t_overflow;
}

// --- Teinte d'herbe par sommet (2026-08-09) --------------------------------
// Réplique EXACTEMENT l'échantillonnage GPU de l'ancienne texture 3×3
// filter_linear/clamp par chunk : uv = clamp(p/16, 0, 1) ; c = clamp(uv*3
// - 0.5, 0, 2) ; interpolation entre les deux texels encadrants. Les points de
// la grille sont partagés entre chunks voisins (offsets monde 0/8/16), donc la
// continuité aux jointures est la même qu'avant. Seule différence assumée :
// l'interpolation est portée par les SOMMETS du quad et non par pixel — sur un
// grand quad traversant le point central, le dégradé perd l'échantillon du
// milieu, invisible à l'échelle où la teinte varie (biomes).
struct TintGrid {
	bool active = false;
	float r[9], g[9], b[9];
};

inline void tint_axis(float p, int &i0, float &f) {
	float uv = p * (1.0f / 16.0f);
	if (uv < 0.0f) uv = 0.0f;
	if (uv > 1.0f) uv = 1.0f;
	float c = uv * 3.0f - 0.5f;
	if (c < 0.0f) c = 0.0f;
	if (c > 2.0f) c = 2.0f;
	i0 = (int)c;
	if (i0 > 1) i0 = 1;
	f = c - (float)i0;
}

// COLOR d'un sommet de terrain : r = lumière de bloc, gba = teinte d'herbe
// interpolée à (x, z) locaux. `set_pixel(gx, gz)` de l'ancienne texture →
// index gz*3+gx, u sur l'axe X.
inline Color tint_color(const TintGrid &t, float light, float x, float z) {
	if (!t.active) {
		return Color(light, 1.0f, 1.0f, 1.0f);
	}
	int ix, iz;
	float fx, fz;
	tint_axis(x, ix, fx);
	tint_axis(z, iz, fz);
	const int i00 = iz * 3 + ix;
	const int i10 = i00 + 1;
	const int i01 = i00 + 3;
	const int i11 = i01 + 1;
	const float rr = (t.r[i00] + (t.r[i10] - t.r[i00]) * fx) * (1.0f - fz) +
			(t.r[i01] + (t.r[i11] - t.r[i01]) * fx) * fz;
	const float gg = (t.g[i00] + (t.g[i10] - t.g[i00]) * fx) * (1.0f - fz) +
			(t.g[i01] + (t.g[i11] - t.g[i01]) * fx) * fz;
	const float bb = (t.b[i00] + (t.b[i10] - t.b[i00]) * fx) * (1.0f - fz) +
			(t.b[i01] + (t.b[i11] - t.b[i01]) * fx) * fz;
	return Color(light, rr, gg, bb);
}

// Sortie à curseurs — jamais d'append par sommet côté Packed*, tout passe par
// des std::vector contigus puis une copie unique en fin de fonction.
struct MeshOut {
	std::vector<Vector3> vertices;
	std::vector<Vector3> normals;
	std::vector<Vector2> uvs;
	std::vector<Color> colors;
	std::vector<int32_t> indices;

	void emit_quad(const Vector3 &a, const Vector3 &b, const Vector3 &c,
			const Vector3 &d, const Vector3 &normal, const Vector2 &uv,
			const Color &ca, const Color &cb, const Color &cc, const Color &cd) {
		const int32_t vc = (int32_t)vertices.size();
		vertices.push_back(a);
		vertices.push_back(b);
		vertices.push_back(c);
		vertices.push_back(d);
		for (int k = 0; k < 4; k++) {
			normals.push_back(normal);
			uvs.push_back(uv);
		}
		colors.push_back(ca);
		colors.push_back(cb);
		colors.push_back(cc);
		colors.push_back(cd);
		indices.push_back(vc);
		indices.push_back(vc + 1);
		indices.push_back(vc + 2);
		indices.push_back(vc);
		indices.push_back(vc + 2);
		indices.push_back(vc + 3);
	}
};

} // namespace

// --- Coquille : port de la première moitié de NoiseGenerator.fill_shell ----
// CHAQUE fonction ici est le miroir d'une fonction du GDScript, même nom sans
// underscore. Le hachage travaille en ENTIER 64 BITS SIGNÉ comme GDScript
// (les multiplications débordent au-delà de 32 bits AVANT le masque final, et
// ces débordements font partie du résultat) — les produits passent par
// uint64_t parce que le débordement signé est indéfini en C++, les décalages
// par int64_t parce que `>>` GDScript est arithmétique.

namespace {
inline int64_t pcg_hash64(int64_t a, int64_t b, int64_t c) {
	uint64_t v = ((uint64_t)a * 747796405ULL + 2891336453ULL) ^
			((uint64_t)b * 2654435761ULL) ^ ((uint64_t)c * 1597334677ULL);
	v = (v ^ (uint64_t)((int64_t)v >> 15)) * 0x85EBCA6BULL;
	v = (v ^ (uint64_t)((int64_t)v >> 13)) * 0xC2B2AE35ULL;
	return (int64_t)((v ^ (uint64_t)((int64_t)v >> 16)) & 0x7FFFFFFFULL);
}
} // namespace

void VoxenNative::configure_shell(const Dictionary &cfg) {
	shell.is_overworld = (bool)cfg["is_overworld"];
	shell.water_id = (int)cfg["water_id"];
	shell.subsurface_thickness = (int)cfg["subsurface_thickness"];
	shell.dim_crust = (int)cfg["dim_crust"];
	shell.world_seed = (int64_t)cfg["world_seed"];
	const PackedInt32Array ids = cfg["strata_ids"];
	const PackedInt32Array ends = cfg["strata_end"];
	const PackedInt32Array trs = cfg["strata_trans"];
	shell.strata_ids.assign(ids.ptr(), ids.ptr() + ids.size());
	shell.strata_end.assign(ends.ptr(), ends.ptr() + ends.size());
	shell.strata_trans.assign(trs.ptr(), trs.ptr() + trs.size());
	shell.p_caves = (bool)cfg["p_caves"];
	shell.cave_min_depth = (int)cfg["cave_min_depth"];
	shell.cave_max_depth = (int)cfg["cave_max_depth"];
	shell.world_floor = (int)cfg["world_floor"];
	shell.cave_max_depth_from_floor = (int)cfg["cave_max_depth_from_floor"];
	shell.cave_cell_shift = (int)cfg["cave_cell_shift"];
	shell.cave_cell_accept = (double)cfg["cave_cell_accept"];
	shell.seed_cave_cell = (int64_t)cfg["seed_cave_cell"];
	shell.cave_tunnel_threshold = (double)cfg["cave_tunnel_threshold"];
	shell.cave_cavern_threshold = (double)cfg["cave_cavern_threshold"];
	shell.dim_cave_cell_shift = (int)cfg["dim_cave_cell_shift"];
	shell.dim_ore_cell_shift = (int)cfg["dim_ore_cell_shift"];
	shell.dim_cave_cell_accept = (double)cfg["dim_cave_cell_accept"];
	shell.dim_ore_cell_accept = (double)cfg["dim_ore_cell_accept"];
	shell.seed_dim_cave_cell = (int64_t)cfg["seed_dim_cave_cell"];
	shell.seed_dim_ore_cell = (int64_t)cfg["seed_dim_ore_cell"];
	shell.dim_cave_threshold = (double)cfg["dim_cave_threshold"];
	shell.dim_ore_vein_threshold = (double)cfg["dim_ore_vein_threshold"];
	shell.cave_a = cfg["cave_a"];
	shell.cave_b = cfg["cave_b"];
	shell.cavern = cfg["cavern"];
	shell.dim_cave = cfg["dim_cave"];
	shell.dim_ore = cfg["dim_ore"];
	shell.configured = true;
}

bool VoxenNative::is_cave_at(int wx, int wy, int wz, int h) const {
	if (!shell.p_caves) {
		return false;
	}
	if (!shell.is_overworld) {
		return dim_is_cave_at(wx, wy, wz, h);
	}
	const int depth = h - wy;
	if (depth < shell.cave_min_depth || depth > shell.cave_max_depth) {
		return false;
	}
	if (wy < shell.world_floor + shell.cave_max_depth_from_floor) {
		return false;
	}
	const double cell_roll = (double)pcg_hash64(wx >> shell.cave_cell_shift,
			wz >> shell.cave_cell_shift, shell.world_seed + shell.seed_cave_cell) /
			2147483648.0;
	if (cell_roll >= shell.cave_cell_accept) {
		return false;
	}
	const double fx = (double)wx, fy = (double)wy, fz = (double)wz;
	const double cavern =
			(double)shell.cavern->get_noise_3d(fx, fy, fz) * 0.5 + 0.5;
	if (cavern > shell.cave_cavern_threshold) {
		return true; // Grande salle.
	}
	const double a = (double)shell.cave_a->get_noise_3d(fx, fy, fz);
	if (std::abs(a) > shell.cave_tunnel_threshold) {
		return false;
	}
	const double b = (double)shell.cave_b->get_noise_3d(fx, fy, fz);
	return std::abs(b) < shell.cave_tunnel_threshold;
}

bool VoxenNative::dim_is_cave_at(int wx, int wy, int wz, int h) const {
	if (shell.dim_cave.is_null()) {
		return false;
	}
	const int depth = h - wy;
	if (depth < 8) {
		return false;
	}
	if ((double)pcg_hash64(wx >> shell.dim_cave_cell_shift,
			wz >> shell.dim_cave_cell_shift,
			shell.world_seed + shell.seed_dim_cave_cell) / 2147483648.0 >=
			shell.dim_cave_cell_accept) {
		return false;
	}
	const double opening = std::min(std::max(((double)depth - 8.0) / 26.0, 0.0), 1.0);
	return std::abs((double)shell.dim_cave->get_noise_3d(
				   (double)wx, (double)wy * 1.6, (double)wz)) <
			shell.dim_cave_threshold * opening;
}

bool VoxenNative::dim_is_ore_at(int wx, int wy, int wz) const {
	if (shell.dim_ore.is_null()) {
		return false;
	}
	if ((double)pcg_hash64(wx >> shell.dim_ore_cell_shift,
			wz >> shell.dim_ore_cell_shift,
			shell.world_seed + shell.seed_dim_ore_cell) / 2147483648.0 >=
			shell.dim_ore_cell_accept) {
		return false;
	}
	return (double)shell.dim_ore->get_noise_3d((double)wx, (double)wy, (double)wz) >
			shell.dim_ore_vein_threshold;
}

int32_t VoxenNative::deep_block(int depth, int32_t subsurface, int32_t trans,
		int32_t accent, int wx, int wy, int wz, int h) const {
	if (!shell.is_overworld) {
		if (depth > shell.dim_crust) {
			return 0;
		}
		int32_t id = subsurface;
		if (accent != 0 && dim_is_ore_at(wx, wy, wz)) {
			id = accent;
		}
		if (id != 0 && dim_is_cave_at(wx, wy, wz, h)) {
			return 0;
		}
		return id;
	}
	int32_t v = 0;
	const size_t count = shell.strata_ids.size();
	for (size_t st = 0; st < count; st++) {
		// Division ENTIÈRE tronquée vers zéro, comme GDScript.
		if (depth <= shell.strata_end[st] +
						(trans * shell.strata_trans[st]) / 1000) {
			v = shell.strata_ids[st];
			break;
		}
	}
	if (v != 0 && is_cave_at(wx, wy, wz, h)) {
		return 0;
	}
	return v;
}

Array VoxenNative::fill_shell_terrain(const Vector3i &cpos,
		const PackedInt32Array &heights, const PackedInt32Array &surfaces,
		const PackedInt32Array &subsurfaces, const PackedInt32Array &transitions,
		const PackedInt32Array &local_water, const PackedInt32Array &accents) const {
	PackedInt32Array pad_out;
	pad_out.resize(P * P * P);
	int32_t *pad = pad_out.ptrw();
	std::memset(pad, 0, P * P * P * sizeof(int32_t));
	bool air = false;

	Array result;
	result.resize(2);
	if (!shell.configured || heights.size() < 324) {
		result[0] = pad_out;
		result[1] = true; // Pad d'air pur : conservateur (jamais de face manquée).
		return result;
	}
	const int32_t *hs = heights.ptr();
	const int32_t *surf = surfaces.ptr();
	const int32_t *sub = subsurfaces.ptr();
	const int32_t *trs = transitions.ptr();
	const int32_t *lw = local_water.ptr();
	const int32_t *acc = accents.ptr();
	const int t = T;
	const int y0 = cpos.y * t;

	// Dalles X-/X+/Z-/Z+ : pour chaque colonne latérale, 16 y (miroir exact du
	// `match side` GDScript).
	for (int side = 0; side < 4; side++) {
		for (int k = 0; k < t; k++) {
			int icol, pad_base, wx, wz;
			const int pad_step = 324;
			switch (side) {
				case 0: // X- : colonne ctx x=-1
					icol = (k + 1) * 18;
					pad_base = 324 + (k + 1) * 18;
					wx = cpos.x * t - 1;
					wz = cpos.z * t + k;
					break;
				case 1: // X+ : colonne ctx x=16
					icol = (k + 1) * 18 + 17;
					pad_base = 324 + (k + 1) * 18 + t + 1;
					wx = cpos.x * t + t;
					wz = cpos.z * t + k;
					break;
				case 2: // Z- : colonne ctx z=-1
					icol = k + 1;
					pad_base = 324 + k + 1;
					wx = cpos.x * t + k;
					wz = cpos.z * t - 1;
					break;
				default: // Z+ : colonne ctx z=16
					icol = k + 1 + 17 * 18;
					pad_base = 324 + (t + 1) * 18 + k + 1;
					wx = cpos.x * t + k;
					wz = cpos.z * t + t;
					break;
			}
			const int h = hs[icol];
			const int32_t surface = surf[icol];
			const int32_t subsurface = sub[icol];
			const int32_t trans = trs[icol];
			const int32_t accent = acc[icol];
			const int water_level = lw[icol];
			for (int y = 0; y < t; y++) {
				const int wy = y0 + y;
				int32_t v = 0;
				if (wy <= h) {
					const int depth = h - wy;
					if (depth == 0) {
						v = surface;
					} else if (depth <= shell.subsurface_thickness && shell.is_overworld) {
						v = subsurface;
					} else {
						v = deep_block(depth, subsurface, trans, accent, wx, wy, wz, h);
					}
				} else if (wy <= water_level) {
					v = shell.water_id;
				} else {
					air = true;
				}
				pad[pad_base + y * pad_step] = v;
			}
		}
	}

	// Dalles Y- (wy = y0-1) et Y+ (wy = y0+16), colonnes intérieures.
	for (int face = 0; face < 2; face++) {
		const int wy = face == 0 ? y0 - 1 : y0 + t;
		const int off_y = face == 0 ? 0 : (t + 1) * 324;
		for (int z = 0; z < t; z++) {
			const int row = off_y + (z + 1) * 18;
			for (int x = 0; x < t; x++) {
				const int icol = (x + 1) + (z + 1) * 18;
				const int h = hs[icol];
				int32_t v = 0;
				if (wy <= h) {
					const int depth = h - wy;
					if (depth == 0) {
						v = surf[icol];
					} else if (depth <= shell.subsurface_thickness && shell.is_overworld) {
						v = sub[icol];
					} else {
						v = deep_block(depth, sub[icol], trs[icol], acc[icol],
								cpos.x * t + x, wy, cpos.z * t + z, h);
					}
				} else if (wy <= lw[icol]) {
					v = shell.water_id;
				} else {
					air = true;
				}
				pad[row + x + 1] = v;
			}
		}
	}

	result[0] = pad_out;
	result[1] = air;
	return result;
}

void VoxenNative::_bind_methods() {
	ClassDB::bind_method(D_METHOD("configure_shell", "cfg"),
			&VoxenNative::configure_shell);
	ClassDB::bind_method(D_METHOD("fill_shell_terrain", "cpos", "heights",
								 "surfaces", "subsurfaces", "transitions",
								 "local_water", "accents"),
			&VoxenNative::fill_shell_terrain);
	ClassDB::bind_method(D_METHOD("mesh_core", "pad", "blocks", "uniform",
								 "uniform_id", "fine", "subdivs", "block_host",
								 "cross_mask", "hidden_mask", "liquid_mask",
								 "emission", "transmits", "tint9", "profiling"),
			&VoxenNative::mesh_core);
}

Array VoxenNative::mesh_core(const PackedInt32Array &pad_in,
		const PackedByteArray &blocks, bool uniform, int uniform_id, bool fine,
		const Dictionary &subdivs, const Dictionary &block_host,
		const PackedByteArray &cross_mask, const PackedByteArray &hidden_mask,
		const PackedByteArray &liquid_mask, const PackedByteArray &emission,
		const PackedByteArray &transmits, const PackedColorArray &tint9,
		bool profiling) {
	int64_t t_phase = profiling ? now_us() : 0;
	int64_t us_interieur = 0, us_greedy = 0, us_subdiv = 0;

	TintGrid tint;
	if (tint9.size() >= 9) {
		tint.active = true;
		for (int i = 0; i < 9; i++) {
			const Color c = tint9[i];
			tint.r[i] = c.r;
			tint.g[i] = c.g;
			tint.b[i] = c.b;
		}
	}

	// Copie de travail du pad : l'intérieur y est écrit (COW → une copie).
	PackedInt32Array pad_copy = pad_in;
	int32_t *pad = pad_copy.ptrw();

	// --- Intérieur + solides par niveau Y (port de la phase « interieur ») ---
	int level_solid[T] = { 0 };
	const bool has_subdivs = !subdivs.is_empty();
	if (uniform) {
		for (int y = 0; y < T; y++) {
			const int off_y = (y + 1) * SY;
			for (int z = 0; z < T; z++) {
				const int off = off_y + (z + 1) * SZ + 1;
				for (int x = 0; x < T; x++) {
					pad[off + x] = uniform_id;
				}
			}
			level_solid[y] = T * T;
		}
	} else {
		const uint8_t *bl = blocks.ptr();
		// En passe FINE, les blocs subdivisés comptent comme de l'air au
		// niveau bloc ; leur appartenance est dépliée en bitset (une itération
		// du Dictionary, puis des tests O(1) dans la boucle chaude).
		const bool exclude_subdivs = fine && has_subdivs;
		bool subdiv_set[T * T * T] = { false };
		if (exclude_subdivs) {
			const Array keys = subdivs.keys();
			for (int64_t k = 0; k < keys.size(); k++) {
				const int idx = (int)keys[k];
				if (idx >= 0 && idx < T * T * T) {
					subdiv_set[idx] = true;
				}
			}
		}
		int src = 0;
		for (int y = 0; y < T; y++) {
			const int off_y = (y + 1) * SY;
			int count = 0;
			for (int z = 0; z < T; z++) {
				const int off = off_y + (z + 1) * SZ + 1;
				for (int x = 0; x < T; x++) {
					const int id = bl[src * 2] | (bl[src * 2 + 1] << 8);
					if (id != 0 && !(exclude_subdivs && subdiv_set[src])) {
						pad[off + x] = id;
						count++;
					}
					src++;
				}
			}
			level_solid[y] = count;
		}
	}

	// --- Blocs en croix / objets posés : retirés du pad (mêmes règles) ------
	const int64_t cross_count = cross_mask.size();
	const int64_t hidden_count = hidden_mask.size();
	const uint8_t *cross = cross_mask.ptr();
	const uint8_t *hidden = hidden_mask.ptr();
	std::vector<int32_t> plants; // (x, y, z, id) par plante DE CE CHUNK
	if (cross_count > 0) {
		for (int i = 0; i < P * P * P; i++) {
			const int32_t pid = pad[i];
			if (pid > 0 && pid < hidden_count && hidden[pid] == 1) {
				pad[i] = 0;
				continue;
			}
			if (pid > 0 && pid < cross_count && cross[pid] == 1) {
				pad[i] = 0;
				const int py = i / SY;
				const int rest = i % SY;
				const int pz = rest / SZ;
				const int px = rest % SZ;
				if (px >= 1 && px <= T && py >= 1 && py <= T && pz >= 1 && pz <= T) {
					plants.push_back(px - 1);
					plants.push_back(py - 1);
					plants.push_back(pz - 1);
					plants.push_back(pid);
				}
			}
		}
	}

	// --- Lumière de bloc (G.3), calculée depuis le pad ----------------------
	std::vector<uint8_t> light;
	compute_light_from_pad(pad, emission, transmits, light);
	const bool light_empty = light.empty();
	const float inv_light = 1.0f / (float)LIGHT_MAX_LEVEL;

	if (profiling) {
		us_interieur = now_us() - t_phase;
		t_phase = now_us();
	}

	// --- Balayage greedy par axe (port exact) -------------------------------
	MeshOut out;
	out.vertices.reserve(4096);
	out.normals.reserve(4096);
	out.uvs.reserve(4096);
	out.colors.reserve(4096);
	out.indices.reserve(6144);

	// Hôte roche/terre par bloc, déplié du Dictionary une fois (lookups par
	// quad sinon — des dizaines de milliers par chunk dense).
	int32_t host_arr[T * T * T];
	const bool has_host = !block_host.is_empty();
	if (has_host) {
		std::memset(host_arr, 0, sizeof(host_arr));
		const Array keys = block_host.keys();
		for (int64_t k = 0; k < keys.size(); k++) {
			const int idx = (int)keys[k];
			if (idx >= 0 && idx < T * T * T) {
				host_arr[idx] = (int32_t)(int)block_host[keys[k]];
			}
		}
	}
	const int64_t liquid_count = liquid_mask.size();
	const uint8_t *liquid = liquid_mask.ptr();

	int32_t mask[T * T];
	for (int d = 0; d < 3; d++) {
		const int u = (d + 1) % 3;
		const int v = (d + 2) % 3;
		const int sd = STRIDES[d];
		const int su = STRIDES[u];
		const int sv = STRIDES[v];
		Vector3 e_d, e_u, e_v;
		e_d[d] = 1.0f;
		e_u[u] = 1.0f;
		e_v[v] = 1.0f;
		const bool swap_when_positive = e_u.cross(e_v).dot(e_d) > 0.0f;
		const int hd = CHUNK_STRIDES[d];
		const int hu = CHUNK_STRIDES[u];
		const int hv = CHUNK_STRIDES[v];

		for (int cut = -1; cut < T; cut++) {
			if (d == 1) {
				const bool solid_below = cut >= 0 && level_solid[cut] > 0;
				const bool solid_above = cut + 1 <= T - 1 && level_solid[cut + 1] > 0;
				if (!solid_below && !solid_above) {
					continue;
				}
				if (cut >= 0 && cut + 1 <= T - 1 && level_solid[cut] == T * T &&
						level_solid[cut + 1] == T * T) {
					continue;
				}
			}

			const int base_d = (cut + 1) * sd;
			bool visible = false;
			int n = 0;
			for (int j = 0; j < T; j++) {
				if (d == 2 && level_solid[j] == 0 && cut >= 0 && cut + 1 <= T - 1) {
					for (int i = 0; i < T; i++) {
						mask[n] = 0;
						n++;
					}
					continue;
				}
				const int base_j = base_d + (j + 1) * sv + su;
				for (int i = 0; i < T; i++) {
					if (d == 0 && level_solid[i] == 0 && cut >= 0 && cut + 1 <= T - 1) {
						mask[n] = 0;
						n++;
						continue;
					}
					const int idx = base_j + i * su;
					const int32_t a = pad[idx];
					const int32_t b = pad[idx + sd];
					int32_t value = 0;
					if (a != 0 && b == 0 && cut >= 0) {
						value = a;
					} else if (b != 0 && a == 0 && cut + 1 <= T - 1) {
						value = -b;
					}
					mask[n] = value;
					if (value != 0) {
						visible = true;
					}
					n++;
				}
			}
			if (!visible) {
				continue;
			}

			for (int j = 0; j < T; j++) {
				int i = 0;
				while (i < T) {
					const int32_t c = mask[j * T + i];
					if (c == 0) {
						i++;
						continue;
					}
					int w = 1;
					while (i + w < T && mask[j * T + i + w] == c) {
						w++;
					}
					int h = 1;
					bool extendable = true;
					while (j + h < T && extendable) {
						for (int k = 0; k < w; k++) {
							if (mask[(j + h) * T + i + k] != c) {
								extendable = false;
								break;
							}
						}
						if (extendable) {
							h++;
						}
					}
					const bool positive = c > 0;
					const Vector3 normal = positive ? e_d : -e_d;
					const Vector3 origin =
							e_d * (float)(cut + 1) + e_u * (float)i + e_v * (float)j;
					Vector3 du = e_u * (float)w;
					Vector3 dv = e_v * (float)h;
					if (positive == swap_when_positive) {
						const Vector3 tmp = du;
						du = dv;
						dv = tmp;
					}
					Vector3 q0 = origin;
					Vector3 q1 = origin + du;
					Vector3 q2 = origin + du + dv;
					Vector3 q3 = origin + dv;
					// Liquides « moins grands » : abaisse l'arête supérieure.
					const int cid = c > 0 ? c : -c;
					if (cid < liquid_count && liquid[cid] == 1 &&
							!(d == 1 && !positive)) {
						float top_y = q0.y;
						if (q1.y > top_y) top_y = q1.y;
						if (q2.y > top_y) top_y = q2.y;
						if (q3.y > top_y) top_y = q3.y;
						if (q0.y >= top_y - 0.001f) q0.y -= WATER_DROP;
						if (q1.y >= top_y - 0.001f) q1.y -= WATER_DROP;
						if (q2.y >= top_y - 0.001f) q2.y -= WATER_DROP;
						if (q3.y >= top_y - 0.001f) q3.y -= WATER_DROP;
					}
					int32_t host = 0;
					if (has_host) {
						host = host_arr[(positive ? cut : cut + 1) * hd + i * hu + j * hv];
					}
					const Vector2 uv((float)cid, (float)host);
					float level = 0.0f;
					if (!light_empty) {
						int lit_index = (cut + 1) * sd + (i + 1) * su + (j + 1) * sv;
						if (positive) {
							lit_index += sd;
						}
						level = (float)light[lit_index] * inv_light;
					}
					// Teinte évaluée PAR COIN (x, z locaux — la chute d'eau ne
					// touche que y, les coordonnées de teinte sont intactes).
					out.emit_quad(q0, q1, q2, q3, normal, uv,
							tint_color(tint, level, q0.x, q0.z),
							tint_color(tint, level, q1.x, q1.z),
							tint_color(tint, level, q2.x, q2.z),
							tint_color(tint, level, q3.x, q3.z));
					for (int jj = 0; jj < h; jj++) {
						for (int kk = 0; kk < w; kk++) {
							mask[(j + jj) * T + i + kk] = 0;
						}
					}
					i += w;
				}
			}
		}
	}

	if (profiling) {
		us_greedy = now_us() - t_phase;
		t_phase = now_us();
	}

	// --- Passe FINE : sous-grilles des blocs subdivisés (port exact) --------
	if (fine && has_subdivs) {
		const Array keys = subdivs.keys(); // ordre d'insertion, comme GDScript
		for (int64_t k = 0; k < keys.size(); k++) {
			const int block_index = (int)keys[k];
			const PackedInt32Array grid_arr = subdivs[keys[k]];
			if (grid_arr.size() < 512) {
				continue; // grille corrompue : on ne lit pas hors bornes
			}
			const int32_t *grid = grid_arr.ptr();
			const int bx = block_index & 15;
			const int bz = (block_index >> 4) & 15;
			const int by = block_index >> 8;
			const Vector3 block_base((float)bx, (float)by, (float)bz);
			const int pad_center = (bx + 1) * SX + (bz + 1) * SZ + (by + 1) * SY;
			const std::vector<int32_t> &quads = grid_quads(grid);
			float sub_level = 0.0f;
			if (!light_empty) {
				sub_level = (float)light[(bx + 1) * SX + (bz + 1) * SZ + (by + 1) * SY] *
						inv_light;
			}
			size_t q = 0;
			while (q < quads.size()) {
				const int d = quads[q];
				const int cut = quads[q + 1];
				const int i = quads[q + 2];
				const int j = quads[q + 3];
				const int w = quads[q + 4];
				const int h = quads[q + 5];
				const int32_t c = quads[q + 6];
				q += 7;
				if (cut == -1 && pad[pad_center - STRIDES[d]] != 0) {
					continue;
				}
				if (cut == 7 && pad[pad_center + STRIDES[d]] != 0) {
					continue;
				}
				const int u = (d + 1) % 3;
				const int v = (d + 2) % 3;
				Vector3 normal;
				normal[d] = c > 0 ? 1.0f : -1.0f;
				Vector3 origin = block_base;
				origin[d] += (float)(cut + 1) * SUBDIV_CELL_UNIT;
				origin[u] += (float)i * SUBDIV_CELL_UNIT;
				origin[v] += (float)j * SUBDIV_CELL_UNIT;
				Vector3 du;
				du[u] = (float)w * SUBDIV_CELL_UNIT;
				Vector3 dv;
				dv[v] = (float)h * SUBDIV_CELL_UNIT;
				if (du.cross(dv).dot(normal) > 0.0f) {
					const Vector3 tmp = du;
					du = dv;
					dv = tmp;
				}
				const int cid = c > 0 ? c : -c;
				const Vector3 p1 = origin + du;
				const Vector3 p2 = origin + du + dv;
				const Vector3 p3 = origin + dv;
				out.emit_quad(origin, p1, p2, p3,
						normal, Vector2((float)cid, 0.0f),
						tint_color(tint, sub_level, origin.x, origin.z),
						tint_color(tint, sub_level, p1.x, p1.z),
						tint_color(tint, sub_level, p2.x, p2.z),
						tint_color(tint, sub_level, p3.x, p3.z));
			}
		}
	}

	if (profiling) {
		us_subdiv = now_us() - t_phase;
	}

	// --- Sortie : copie unique vers les Packed* -----------------------------
	const int64_t vc = (int64_t)out.vertices.size();
	const int64_t ic = (int64_t)out.indices.size();
	PackedVector3Array vertices;
	PackedVector3Array normals;
	PackedVector2Array uvs;
	PackedColorArray colors;
	PackedInt32Array indices;
	vertices.resize(vc);
	normals.resize(vc);
	uvs.resize(vc);
	colors.resize(vc);
	indices.resize(ic);
	if (vc > 0) {
		std::memcpy(vertices.ptrw(), out.vertices.data(), vc * sizeof(Vector3));
		std::memcpy(normals.ptrw(), out.normals.data(), vc * sizeof(Vector3));
		std::memcpy(uvs.ptrw(), out.uvs.data(), vc * sizeof(Vector2));
		std::memcpy(colors.ptrw(), out.colors.data(), vc * sizeof(Color));
	}
	if (ic > 0) {
		std::memcpy(indices.ptrw(), out.indices.data(), ic * sizeof(int32_t));
	}
	PackedInt32Array plants_out;
	plants_out.resize((int64_t)plants.size());
	if (!plants.empty()) {
		std::memcpy(plants_out.ptrw(), plants.data(), plants.size() * sizeof(int32_t));
	}
	PackedByteArray light_out;
	if (!light_empty) {
		light_out.resize((int64_t)light.size());
		std::memcpy(light_out.ptrw(), light.data(), light.size());
	}

	Array result;
	result.resize(8);
	result[0] = vertices;
	result[1] = normals;
	result[2] = uvs;
	result[3] = colors;
	result[4] = indices;
	result[5] = plants_out;
	result[6] = light_out;
	if (profiling) {
		PackedInt64Array phases;
		phases.resize(3);
		phases[0] = us_interieur;
		phases[1] = us_greedy;
		phases[2] = us_subdiv;
		result[7] = phases;
	}
	return result;
}

} // namespace godot
