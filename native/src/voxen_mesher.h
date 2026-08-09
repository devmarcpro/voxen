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

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>
#include <godot_cpp/variant/packed_int32_array.hpp>

namespace godot {

class VoxenNative : public RefCounted {
	GDCLASS(VoxenNative, RefCounted)

protected:
	static void _bind_methods();

public:
	// Retourne un Array de 8 éléments :
	//   [0] PackedVector3Array vertices   [1] PackedVector3Array normals
	//   [2] PackedVector2Array uvs        [3] PackedColorArray colors
	//   [4] PackedInt32Array indices      [5] PackedInt32Array plants (x,y,z,id)*
	//   [6] PackedByteArray light (18³, vide si aucune source)
	//   [7] PackedInt64Array phase_us [interieur, greedy, subdiv] (si profiling)
	// `pad` arrive avec la coquille déjà remplie (fill_shell GDScript) ; les
	// blocs intérieurs sont posés ici.
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
			bool profiling);
};

} // namespace godot
