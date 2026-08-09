// Port fidèle de l'échantillonnage de colonnes de noise_generator.gd —
// _terrain (continents, warp, collines, cordillères, canyons, mesas, fjords,
// volcans), _temperature_at/_humidity_at/_mana_at, _biome_index_at,
// _blended_surface (dither de frontière), _coastal_override — pour l'OVERWORLD
// et le monde plat. Mesuré avant de porter (--probe-gen du 2026-08-09) : les
// 324 _sample_column pesaient 41,4 % de la génération (14,5 ms/colonne).
//
// MÊMES RÈGLES QUE LES AUTRES MIROIRS DE CE MODULE : chaque fonction suit sa
// jumelle GDScript ligne à ligne, le hachage travaille en int64 signé (les
// débordements GDScript font partie du résultat), et TOUTE constante vient de
// configure_columns — rien n'est recopié en dur. La parité est verrouillée
// par --probe-mesh-parite (les hauteurs/matériaux divergents casseraient les
// meshes comparés) et par le témoin GDScript conservé dans prepare_context.

#include "voxen_mesher.h"

#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/packed_float32_array.hpp>

#include <cmath>
#include <cstdint>

namespace godot {

namespace {

// Miroir de _pcg_hash (voir voxen_mesher.cpp — dupliqué ici car interne à
// l'unité ; les DEUX doivent rester identiques à la version GDScript).
inline int64_t pcg_hash64c(int64_t a, int64_t b, int64_t c) {
	uint64_t v = ((uint64_t)a * 747796405ULL + 2891336453ULL) ^
			((uint64_t)b * 2654435761ULL) ^ ((uint64_t)c * 1597334677ULL);
	v = (v ^ (uint64_t)((int64_t)v >> 15)) * 0x85EBCA6BULL;
	v = (v ^ (uint64_t)((int64_t)v >> 13)) * 0xC2B2AE35ULL;
	return (int64_t)((v ^ (uint64_t)((int64_t)v >> 16)) & 0x7FFFFFFFULL);
}

// Le PI de GDScript, à l'identique (pas de dépendance à M_PI/Math_PI).
constexpr double PI_D = 3.14159265358979323846;

inline double smoothstep_d(double from, double to, double x) {
	// Miroir du smoothstep Godot (dont le cas dégénéré from == to).
	if (from == to) {
		return x < from ? 0.0 : 1.0;
	}
	double s = (x - from) / (to - from);
	if (s < 0.0) s = 0.0;
	if (s > 1.0) s = 1.0;
	return s * s * (3.0 - 2.0 * s);
}

inline double clamp_d(double v, double lo, double hi) {
	return v < lo ? lo : (v > hi ? hi : v);
}

inline double lerp_d(double a, double b, double t) {
	return a + (b - a) * t;
}

// Précipitations zonales (miroir de _zonal_precip).
inline double zonal_precip(double lat) {
	if (lat < 0.33) {
		return lerp_d(0.95, 0.12, smoothstep_d(0.0, 0.33, lat));
	} else if (lat < 0.60) {
		return lerp_d(0.12, 0.80, smoothstep_d(0.33, 0.60, lat));
	}
	return lerp_d(0.80, 0.22, smoothstep_d(0.60, 1.0, lat));
}

} // namespace

void VoxenNative::configure_columns(const Dictionary &cfg) {
	cols.world_seed = (int64_t)cfg["world_seed"];
	cols.p_flat = (bool)cfg["p_flat"];
	cols.flat_height = (double)cfg["flat_height"];
	cols.p_relief = (double)cfg["p_relief"];
	cols.p_temp_offset = (double)cfg["p_temp_offset"];
	cols.p_hum_offset = (double)cfg["p_hum_offset"];
	cols.warp_amplitude = (double)cfg["warp_amplitude"];
	cols.cont_warp_amp = (double)cfg["cont_warp_amp"];
	cols.cont_detail_weight = (double)cfg["cont_detail_weight"];
	cols.land_radius = (double)cfg["land_radius"];
	cols.world_radius = (double)cfg["world_radius"];
	cols.lat_period = (double)cfg["lat_period"];
	cols.coast_cont = (double)cfg["coast_cont"];
	cols.ocean_gain = (double)cfg["ocean_gain"];
	cols.land_gain = (double)cfg["land_gain"];
	cols.hill_amp = (double)cfg["hill_amp"];
	cols.mtn_amp = (double)cfg["mtn_amp"];
	cols.canyon_depth = (double)cfg["canyon_depth"];
	cols.seismic_threshold = (double)cfg["seismic_threshold"];
	cols.terrace_step = (double)cfg["terrace_step"];
	cols.mesa_dry_bonus = (double)cfg["mesa_dry_bonus"];
	cols.fjord_depth = (double)cfg["fjord_depth"];
	cols.elev_ref = (double)cfg["elev_ref"];
	cols.volcano_cell = (int)cfg["volcano_cell"];
	cols.volcano_chance = (double)cfg["volcano_chance"];
	cols.volcano_radius = (double)cfg["volcano_radius"];
	cols.volcano_height = (double)cfg["volcano_height"];
	cols.seed_volcano = (int64_t)cfg["seed_volcano"];
	cols.seed_biome_dither = (int64_t)cfg["seed_biome_dither"];
	cols.lapse_ref_height = (double)cfg["lapse_ref_height"];
	cols.lapse_rate = (double)cfg["lapse_rate"];
	cols.rain_shadow_upwind = (double)cfg["rain_shadow_upwind"];
	cols.rain_shadow_threshold = (double)cfg["rain_shadow_threshold"];
	cols.rain_shadow_strength = (double)cfg["rain_shadow_strength"];
	cols.orogeny_gradient_sample = (double)cfg["orogeny_gradient_sample"];
	cols.biome_transition_margin = (double)cfg["biome_transition_margin"];
	cols.water_level = (double)cfg["water_level"];
	cols.water_id = (int)cfg["water_id"];
	cols.marsh_id = (int)cfg["marsh_id"];
	cols.marsh_sub_id = (int)cfg["marsh_sub_id"];
	cols.sand_id = (int)cfg["sand_id"];
	cols.gravel_id = (int)cfg["gravel_id"];
	cols.cliff_id = (int)cfg["cliff_id"];
	cols.biome_count = (int)cfg["biome_count"];
	cols.forced_biome = (int)cfg["forced_biome"];
	const PackedFloat32Array bmin = cfg["biome_min"];
	const PackedFloat32Array bmax = cfg["biome_max"];
	const PackedInt32Array bsurf = cfg["biome_surface"];
	const PackedInt32Array bsub = cfg["biome_subsurface"];
	cols.biome_min.assign(bmin.ptr(), bmin.ptr() + bmin.size());
	cols.biome_max.assign(bmax.ptr(), bmax.ptr() + bmax.size());
	cols.biome_surface.assign(bsurf.ptr(), bsurf.ptr() + bsurf.size());
	cols.biome_subsurface.assign(bsub.ptr(), bsub.ptr() + bsub.size());
	cols.warp_x = cfg["warp_x"];
	cols.warp_z = cfg["warp_z"];
	cols.cont_warp_x = cfg["cont_warp_x"];
	cols.cont_warp_z = cfg["cont_warp_z"];
	cols.continent = cfg["continent"];
	cols.altitude = cfg["altitude"];
	cols.hills = cfg["hills"];
	cols.ridged = cfg["ridged"];
	cols.canyon = cfg["canyon"];
	cols.fjord = cfg["fjord"];
	cols.seismic = cfg["seismic"];
	cols.temperature = cfg["temperature"];
	cols.humidity = cfg["humidity"];
	cols.mana = cfg["mana"];
	cols.transition = cfg["transition"];
	cols.configured = true;
}

double VoxenNative::volcano_add(double fx, double fz) const {
	const int cs = cols.volcano_cell;
	const int ccx = (int)std::floor(fx / (double)cs);
	const int ccz = (int)std::floor(fz / (double)cs);
	double best = 0.0;
	for (int dx = -1; dx <= 1; dx++) {
		for (int dz = -1; dz <= 1; dz++) {
			const int cx = ccx + dx;
			const int cz = ccz + dz;
			if ((double)pcg_hash64c(cx, cz, cols.world_seed + cols.seed_volcano) /
							2147483648.0 >= cols.volcano_chance) {
				continue;
			}
			const int64_t jx = pcg_hash64c(cx, cz, cols.world_seed + cols.seed_volcano + 1) % cs;
			const int64_t jz = pcg_hash64c(cx, cz, cols.world_seed + cols.seed_volcano + 2) % cs;
			const double vx = (double)((int64_t)cx * cs + jx);
			const double vz = (double)((int64_t)cz * cs + jz);
			const double d = std::sqrt((fx - vx) * (fx - vx) + (fz - vz) * (fz - vz));
			const double t = d / cols.volcano_radius;
			if (t >= 1.0) {
				continue;
			}
			double cone = std::pow(1.0 - t, 1.3) * cols.volcano_height;
			if (t < 0.16) {
				cone -= (1.0 - t / 0.16) * cols.volcano_height * 0.38; // cratère
			}
			if (cone > best) {
				best = cone;
			}
		}
	}
	return best;
}

VoxenNative::TerrainSample VoxenNative::terrain_at(double fx, double fz) const {
	if (cols.p_flat) {
		return { cols.flat_height, 0.5, 0.0 };
	}
	// Domain warping fin (détail).
	const double wx = fx + (double)cols.warp_x->get_noise_2d(fx, fz) * cols.warp_amplitude;
	const double wz = fz + (double)cols.warp_z->get_noise_2d(fx, fz) * cols.warp_amplitude;
	// Structure continentale.
	const double cwx = fx + (double)cols.cont_warp_x->get_noise_2d(fx, fz) * cols.cont_warp_amp;
	const double cwz = fz + (double)cols.cont_warp_z->get_noise_2d(fx, fz) * cols.cont_warp_amp;
	const double macro_v = (double)cols.continent->get_noise_2d(cwx, cwz);
	const double detail = (double)cols.altitude->get_noise_2d(wx, wz);
	const double continent = macro_v + detail * cols.cont_detail_weight;
	// Monde fini : dégradé radial vers l'océan de bordure.
	const double radius = std::sqrt(fx * fx + fz * fz);
	const double edge = smoothstep_d(cols.land_radius, cols.world_radius, radius);
	const double cont = clamp_d(continent * 0.5 + 0.5 - edge * 1.3, -1.0, 1.0);
	// Gradient local (littoraux).
	const double c_dx = (double)cols.altitude->get_noise_2d(wx + cols.orogeny_gradient_sample, wz) - detail;
	const double c_dz = (double)cols.altitude->get_noise_2d(wx, wz + cols.orogeny_gradient_sample) - detail;
	const double gradient_mag = std::sqrt(c_dx * c_dx + c_dz * c_dz);
	// Composition d'altitude biaisée plaines.
	const double e = cont - cols.coast_cont;
	const double lat = clamp_d(std::abs(fz) / cols.lat_period, 0.0, 1.0);
	const double dryness = 1.0 - zonal_precip(lat);
	const double coast_fade = smoothstep_d(0.0, 0.05, e);
	double h;
	if (e < 0.0) {
		h = cols.water_level + e * cols.ocean_gain;
	} else {
		h = cols.water_level + e * cols.land_gain;
		h += (double)cols.hills->get_noise_2d(wx, wz) * cols.hill_amp * coast_fade;
		const double inland = smoothstep_d(cols.coast_cont + 0.03, cols.coast_cont + 0.22, cont);
		const double ridge = (double)cols.ridged->get_noise_2d(wx, wz) * 0.5 + 0.5;
		const double range_mask = smoothstep_d(0.55, 0.9, ridge) * inland;
		h += range_mask * cols.mtn_amp * coast_fade;
		const double canyon_field = (double)cols.canyon->get_noise_2d(wx, wz) * 0.5 + 0.5;
		const double canyon = smoothstep_d(0.80, 0.93, canyon_field) * smoothstep_d(0.45, 0.75, dryness);
		h -= canyon * cols.canyon_depth * coast_fade;
	}
	// Mesas/terrasses en zone aride, terre émergée seulement.
	if (e > 0.0) {
		const double seismic = (double)cols.seismic->get_noise_2d(fx, fz) * 0.5 + 0.5;
		if (seismic > cols.seismic_threshold) {
			const double step = std::floor(h / cols.terrace_step) * cols.terrace_step;
			const double frac = (h - step) / cols.terrace_step;
			double strength = clamp_d((seismic - cols.seismic_threshold) / 0.25, 0.0, 1.0);
			strength = clamp_d(strength * (1.0 + dryness * cols.mesa_dry_bonus), 0.0, 1.0);
			h = lerp_d(h, step + smoothstep_d(0.35, 0.65, frac) * cols.terrace_step, strength);
		}
	}
	// Fjords aux latitudes froides, près des côtes.
	if (lat > 0.6 && e > -0.05 && e < 0.14) {
		const double fjord_field = (double)cols.fjord->get_noise_2d(fx, fz) * 0.5 + 0.5;
		const double fjord = smoothstep_d(0.78, 0.92, fjord_field) * smoothstep_d(0.6, 0.82, lat);
		h -= fjord * cols.fjord_depth;
	}
	h += volcano_add(fx, fz);
	if (cols.p_relief != 1.0) {
		h = cols.water_level + (h - cols.water_level) * cols.p_relief;
	}
	const double elev_n = clamp_d((h - cols.water_level) / cols.elev_ref, 0.0, 1.0);
	return { h, elev_n, gradient_mag };
}

double VoxenNative::temperature_at(double fx, double fz, double h) const {
	const double lat_n = std::cos((fz / cols.lat_period) * PI_D) * 0.5 + 0.5;
	const double pert = (double)cols.temperature->get_noise_2d(fx, fz) * 0.18;
	const double lapse = clamp_d(h, 0.0, cols.lapse_ref_height) / cols.lapse_ref_height * cols.lapse_rate;
	return clamp_d(lat_n + pert - lapse + cols.p_temp_offset, 0.0, 1.0);
}

double VoxenNative::humidity_at(double fx, double fz) const {
	const double lat = clamp_d(std::abs(fz) / cols.lat_period, 0.0, 1.0);
	const double zonal = zonal_precip(lat);
	const double noise = (double)cols.humidity->get_noise_2d(fx, fz) * 0.5 + 0.5;
	const double base = zonal * 0.65 + noise * 0.35;
	const double upwind = (double)cols.altitude->get_noise_2d(fx - cols.rain_shadow_upwind, fz) * 0.5 + 0.5;
	const double shadow = clamp_d(upwind - cols.rain_shadow_threshold, 0.0, 1.0) * cols.rain_shadow_strength;
	const double cont = (double)cols.altitude->get_noise_2d(fx, fz) * 0.5 + 0.5;
	const double interior = clamp_d((cont - 0.60) / 0.40, 0.0, 1.0) * 0.22;
	return clamp_d(base - shadow - interior + cols.p_hum_offset, 0.0, 1.0);
}

int VoxenNative::biome_index_at(double alt_n, double temp_n, double hum_n,
		double mana_n) const {
	if (cols.forced_biome >= 0) {
		return cols.forced_biome;
	}
	for (int b = 0; b < cols.biome_count; b++) {
		const int o = b * 4; // _CONDITION_COUNT
		if (alt_n >= (double)cols.biome_min[o] && alt_n <= (double)cols.biome_max[o] &&
				temp_n >= (double)cols.biome_min[o + 1] && temp_n <= (double)cols.biome_max[o + 1] &&
				hum_n >= (double)cols.biome_min[o + 2] && hum_n <= (double)cols.biome_max[o + 2] &&
				mana_n >= (double)cols.biome_min[o + 3] && mana_n <= (double)cols.biome_max[o + 3]) {
			return b;
		}
	}
	return -1;
}

void VoxenNative::blended_surface(double fx, double fz, double alt_n,
		double temp_n, double hum_n, double mana_n, int32_t &out_surf,
		int32_t &out_sub) const {
	const int b0 = biome_index_at(alt_n, temp_n, hum_n, mana_n);
	if (b0 < 0) {
		out_surf = 0;
		out_sub = 0;
		return;
	}
	// Miroir de _biome_clearance : distance au bord sur les axes contraints.
	const int o = b0 * 4;
	double clearance = 1.0;
	int axis = -1;
	const double values[3] = { alt_n, temp_n, hum_n };
	for (int a = 0; a < 3; a++) {
		const double lo = (double)cols.biome_min[o + a];
		const double hi = (double)cols.biome_max[o + a];
		if (hi - lo >= 0.999) {
			continue;
		}
		const double d = std::min(values[a] - lo, hi - values[a]);
		if (d < clearance) {
			clearance = d;
			axis = a;
		}
	}
	if (clearance >= cols.biome_transition_margin || axis < 0) {
		out_surf = cols.biome_surface[b0];
		out_sub = cols.biome_subsurface[b0];
		return;
	}
	double pushed[3] = { alt_n, temp_n, hum_n };
	const double lo = (double)cols.biome_min[o + axis];
	const double hi = (double)cols.biome_max[o + axis];
	const double push = cols.biome_transition_margin * 2.0;
	pushed[axis] = (pushed[axis] - lo) < (hi - pushed[axis]) ? (lo - push) : (hi + push);
	const int b1 = biome_index_at(pushed[0], pushed[1], pushed[2], mana_n);
	if (b1 < 0 || b1 == b0) {
		out_surf = cols.biome_surface[b0];
		out_sub = cols.biome_subsurface[b0];
		return;
	}
	const double roll = (double)pcg_hash64c((int64_t)fx, (int64_t)fz,
									cols.world_seed + cols.seed_biome_dither) /
			2147483648.0;
	const double b1_chance = clamp_d(1.0 - clearance / cols.biome_transition_margin, 0.0, 1.0);
	const int chosen = roll < b1_chance ? b1 : b0;
	out_surf = cols.biome_surface[chosen];
	out_sub = cols.biome_subsurface[chosen];
}

Array VoxenNative::sample_columns(const Vector2i &col) const {
	PackedInt32Array heights, surfaces, subsurfaces, transitions;
	heights.resize(324);
	surfaces.resize(324);
	subsurfaces.resize(324);
	transitions.resize(324);
	Array result;
	result.resize(6);
	if (!cols.configured) {
		result[0] = heights;
		result[1] = surfaces;
		result[2] = subsurfaces;
		result[3] = transitions;
		result[4] = 0;
		result[5] = 0;
		return result;
	}
	int32_t *hp = heights.ptrw();
	int32_t *sp = surfaces.ptrw();
	int32_t *bp = subsurfaces.ptrw();
	int32_t *tp = transitions.ptrw();
	const int bx = col.x * 16 - 1; // ChunkData.SIZE
	const int bz = col.y * 16 - 1;
	int32_t h_min = INT32_MAX;
	int32_t h_max = INT32_MIN;
	int i = 0;
	for (int z = 0; z < 18; z++) {
		for (int x = 0; x < 18; x++) {
			const double fx = (double)(bx + x);
			const double fz = (double)(bz + z);
			const TerrainSample t = terrain_at(fx, fz);
			const int32_t h = (int32_t)std::floor(t.h);
			const double temp_n = temperature_at(fx, fz, t.h);
			const double hum_n = humidity_at(fx, fz);
			const double mana_n = (double)cols.mana->get_noise_2d(fx, fz) * 0.5 + 0.5;
			int32_t surf = 0, sub = 0;
			blended_surface(fx, fz, t.elev_n, temp_n, hum_n, mana_n, surf, sub);
			// Littoral (miroir de _coastal_override, overworld toujours).
			if (h >= (int32_t)cols.water_level && h <= (int32_t)cols.water_level + 3) {
				const double slope = clamp_d(t.gradient_mag * 10.0, 0.0, 1.0);
				if (slope < 0.15 && hum_n > 0.6 && cols.marsh_id != 0) {
					surf = cols.marsh_id;
					sub = cols.marsh_sub_id;
				} else if (slope < 0.35 && cols.sand_id != 0) {
					surf = cols.sand_id;
					sub = cols.sand_id;
				} else if (slope < 0.6 && cols.gravel_id != 0) {
					surf = cols.gravel_id;
					sub = cols.gravel_id;
				} else if (cols.cliff_id != 0) {
					surf = cols.cliff_id;
					sub = cols.cliff_id;
				}
			}
			hp[i] = h;
			sp[i] = surf;
			bp[i] = sub;
			tp[i] = (int32_t)((double)cols.transition->get_noise_2d(fx, fz) * 1000.0);
			if (h < h_min) h_min = h;
			if (h > h_max) h_max = h;
			i++;
		}
	}
	result[0] = heights;
	result[1] = surfaces;
	result[2] = subsurfaces;
	result[3] = transitions;
	result[4] = h_min;
	result[5] = h_max;
	return result;
}

} // namespace godot
