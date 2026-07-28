extends Probe
## Sonde `--probe-subdiv` — extraite de main.gd le 2026-07-28 (audit architectural).
## Logique inchangée : seuls les accès à la scène ont été réécrits
## ($Player -> player, get_tree() -> main.get_tree(), etc.).


## Critère G.8 étape 4 : une façade de 64 blocs détaillés en 4 px doit se
## mesher en < 4 ms. Deux motifs mesurés : « réaliste » (blocs pleins avec
## relief de surface sculpté) et « pire cas » (damier air/solide en 3D —
## chaque cellule isolée, fusion greedy impossible).
func run() -> void:
	var g := WorldManager.generator
	var col := Vector2i(0, 0)
	var ctx := g.prepare_context(col)
	var key := Vector3i(0, 8, 0)  # Chunk d'air, au-dessus du relief local.
	var id_a: int = GameData.material_runtime_ids["pierre"]
	var id_b: int = GameData.material_runtime_ids["granit"]

	for pattern in ["realiste", "pire_cas"]:
		var data := g.generate_chunk(key, ctx)
		for bx in 8:
			for by in 8:
				var grid := SubdivGrid.create_empty()
				if pattern == "realiste":
					# Bloc plein avec relief : la couche de façade (z = 0)
					# est sculptée une cellule sur trois.
					grid.fill(id_a)
					for cy in 8:
						for cx in 8:
							if (cx + cy * 3) % 3 == 0:
								grid[SubdivGrid.cell_index(cx, cy, 0)] = 0
							elif (cx + cy) % 2 == 0:
								grid[SubdivGrid.cell_index(cx, cy, 0)] = id_b
				else:
					# Damier air/solide 3D : pire cas de fusion greedy.
					for cy in 8:
						for cz in 8:
							for cx in 8:
								if (cx + cy + cz) % 2 == 0:
									grid[SubdivGrid.cell_index(cx, cy, cz)] = id_a
				data.set_subdiv(ChunkData.index_of(bx, by, 0), grid, id_a)
		# Mesure : 20 meshings de la passe fine.
		var total_us := 0
		var max_us := 0
		var vertex_count := 0
		for i in 20:
			var start := Time.get_ticks_usec()
			var arrays := ChunkMesher.mesh_chunk(key, data, g, ctx, {}, true)
			var elapsed := Time.get_ticks_usec() - start
			total_us += elapsed
			max_us = maxi(max_us, elapsed)
			vertex_count = 0 if arrays.is_empty() else (arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array).size()
		print("[SUBDIV] motif=%s : moyen=%.2f ms max=%.2f ms sommets=%d (critère G.8 : < 4 ms)" % [
			pattern, total_us / 20.0 / 1000.0, max_us / 1000.0, vertex_count])
	main.get_tree().quit(0)
