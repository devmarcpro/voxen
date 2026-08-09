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
			const Color &color) {
		const int32_t vc = (int32_t)vertices.size();
		vertices.push_back(a);
		vertices.push_back(b);
		vertices.push_back(c);
		vertices.push_back(d);
		for (int k = 0; k < 4; k++) {
			normals.push_back(normal);
			uvs.push_back(uv);
			colors.push_back(color);
		}
		indices.push_back(vc);
		indices.push_back(vc + 1);
		indices.push_back(vc + 2);
		indices.push_back(vc);
		indices.push_back(vc + 2);
		indices.push_back(vc + 3);
	}
};

} // namespace

void VoxenNative::_bind_methods() {
	ClassDB::bind_method(D_METHOD("mesh_core", "pad", "blocks", "uniform",
								 "uniform_id", "fine", "subdivs", "block_host",
								 "cross_mask", "hidden_mask", "liquid_mask",
								 "emission", "transmits", "profiling"),
			&VoxenNative::mesh_core);
}

Array VoxenNative::mesh_core(const PackedInt32Array &pad_in,
		const PackedByteArray &blocks, bool uniform, int uniform_id, bool fine,
		const Dictionary &subdivs, const Dictionary &block_host,
		const PackedByteArray &cross_mask, const PackedByteArray &hidden_mask,
		const PackedByteArray &liquid_mask, const PackedByteArray &emission,
		const PackedByteArray &transmits, bool profiling) {
	int64_t t_phase = profiling ? now_us() : 0;
	int64_t us_interieur = 0, us_greedy = 0, us_subdiv = 0;

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
					out.emit_quad(q0, q1, q2, q3, normal, uv,
							Color(level, level, level, 1.0f));
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
			const Color sub_color(sub_level, sub_level, sub_level, 1.0f);
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
				out.emit_quad(origin, origin + du, origin + du + dv, origin + dv,
						normal, Vector2((float)cid, 0.0f), sub_color);
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
