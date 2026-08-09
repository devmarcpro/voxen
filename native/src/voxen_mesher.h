#pragma once

// VoxenNative — cœur du mesher en C++ (GDExtension), port fidèle de
// systems/voxel/chunk_mesher.gd (phases intérieur / plantes / lumière /
// greedy / subdiv). La phase « coquille » (bruit du générateur) et la
// géométrie des plantes restent en GDScript : la première dépend de tout le
// worldgen, la seconde est rare et vit déjà dans PlantMesh.
//
// POURQUOI (mesures du 2026-08-09, sondes --probe-mesh et bench de vol) :
// le meshing GDScript coûte 17 ms/chunk seul et 36-58 ms en contention de
// threads — les workers saturent les cœurs ET le verrou de la VM GDScript,
// ce qui affame le thread principal (8 fps en vol). Les mêmes boucles en
// C++ visent ~1-2 ms et ne prennent aucun verrou de VM.
//
// THREAD-SAFETY : appelé depuis plusieurs workers en parallèle. Aucun état
// membre ; le cache de quads de sous-grilles est thread_local (dupliqué par
// worker, gelé une fois plein — même politique que la version GDScript).

#include <godot_cpp/classes/fast_noise_lite.hpp>
#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>
#include <godot_cpp/variant/packed_int32_array.hpp>

#include <vector>

namespace godot {

class VoxenNative : public RefCounted {
	GDCLASS(VoxenNative, RefCounted)

protected:
	static void _bind_methods();

	// Configuration de la COQUILLE (fill_shell_terrain), posée UNE fois par
	// générateur depuis NoiseGenerator._init — le thread principal — puis lue
	// seule par les workers. TOUTES les valeurs viennent du GDScript (source
	// unique : les constantes de noise_generator.gd), rien n'est recopié en
	// dur ici — une dérive de constante serait invisible à la relecture et se
	// paierait en parois fantômes.
	struct ShellConfig {
		bool configured = false;
		bool is_overworld = true;
		int water_id = 0;
		int subsurface_thickness = 3;
		int dim_crust = 0;
		int64_t world_seed = 0;
		// Strates par profondeur.
		std::vector<int32_t> strata_ids, strata_end, strata_trans;
		// Cavernes de l'overworld.
		bool p_caves = true;
		int cave_min_depth = 22, cave_max_depth = 100;
		int world_floor = -512, cave_max_depth_from_floor = 24;
		int cave_cell_shift = 4;
		double cave_cell_accept = 0.4;
		int64_t seed_cave_cell = 9116;
		double cave_tunnel_threshold = 0.05, cave_cavern_threshold = 0.74;
		// Cavernes et filons d'une dimension.
		int dim_cave_cell_shift = 4, dim_ore_cell_shift = 3;
		double dim_cave_cell_accept = 0.55, dim_ore_cell_accept = 0.16;
		int64_t seed_dim_cave_cell = 9162, seed_dim_ore_cell = 9163;
		double dim_cave_threshold = 0.42, dim_ore_vein_threshold = 0.42;
		Ref<FastNoiseLite> cave_a, cave_b, cavern, dim_cave, dim_ore;
	};
	ShellConfig shell;

	bool is_cave_at(int wx, int wy, int wz, int h) const;
	bool dim_is_cave_at(int wx, int wy, int wz, int h) const;
	bool dim_is_ore_at(int wx, int wy, int wz) const;
	int32_t deep_block(int depth, int32_t subsurface, int32_t trans,
			int32_t accent, int wx, int wy, int wz, int h) const;

public:
	// Configure la coquille pour CE générateur (une instance VoxenNative par
	// NoiseGenerator — le mesher, lui, passe par l'instance partagée de
	// ChunkMesher, qui n'a aucun état).
	void configure_shell(const Dictionary &cfg);

	// Remplit les 6 dalles de TERRAIN de la coquille (port de la première
	// moitié de NoiseGenerator.fill_shell — surface/sous-surface/strates/
	// cavernes). Les SURCOUCHES (arbres, plantes, features de dimension,
	// bâtiments de ville) restent en GDScript, appliquées par l'appelant sur
	// le pad retourné. Retourne [pad rempli, air: bool] — le pad ne peut pas
	// être muté en place à travers la frontière (copie-sur-écriture).
	Array fill_shell_terrain(const Vector3i &cpos,
			const PackedInt32Array &heights,
			const PackedInt32Array &surfaces,
			const PackedInt32Array &subsurfaces,
			const PackedInt32Array &transitions,
			const PackedInt32Array &local_water,
			const PackedInt32Array &accents) const;
	// Retourne un Array de 8 éléments :
	//   [0] PackedVector3Array vertices   [1] PackedVector3Array normals
	//   [2] PackedVector2Array uvs        [3] PackedColorArray colors
	//   [4] PackedInt32Array indices      [5] PackedInt32Array plants (x,y,z,id)*
	//   [6] PackedByteArray light (18³, vide si aucune source)
	//   [7] PackedInt64Array phase_us [interieur, greedy, subdiv] (si profiling)
	// `pad` arrive avec la coquille déjà remplie (fill_shell GDScript) ; les
	// blocs intérieurs sont posés ici.
	// `tint9` : teinte d'herbe du biome, 9 échantillons (grille 3×3 de la
	// colonne, ctx["tint"]) — cuite PAR SOMMET dans COLOR.gba (2026-08-09, ce
	// qui a permis le matériau partagé). Vide = blanc (dimensions/donjons).
	Array mesh_core(const PackedInt32Array &pad_in,
			const PackedByteArray &blocks,
			bool uniform, int uniform_id, bool fine,
			const Dictionary &subdivs,
			const Dictionary &block_host,
			const PackedByteArray &cross_mask,
			const PackedByteArray &hidden_mask,
			const PackedByteArray &liquid_mask,
			const PackedByteArray &emission,
			const PackedByteArray &transmits,
			const PackedColorArray &tint9,
			bool profiling);
};

} // namespace godot
