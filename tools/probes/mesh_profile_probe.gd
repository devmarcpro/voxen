extends Probe
## Sonde `--probe-mesh` — extraite de main.gd le 2026-07-28 (audit architectural).
## Logique inchangée : seuls les accès à la scène ont été réécrits
## ($Player -> player, get_tree() -> main.get_tree(), etc.).


## Sonde meshing (E.14/G.2) : maille un lot de chunks RÉELS de façon
## synchrone et donne la répartition du temps par phase. Le bench global ne
## dit que le total (« meshing_moyen »), jamais OÙ il part — sans ça on
## optimise à l'aveugle, ce que G interdit (« mesurer avant d'optimiser »).
func run() -> void:
	await main.get_tree().process_frame
	var gen := WorldManager.generator
	var budget_ms := 4.0  # E.14 : « < 4 ms par chunk ».

	ChunkMesher.reset_profile()
	ChunkMesher.profiling = true

	# Colonnes autour du spawn, sur toute la plage verticale utile : on veut
	# le mélange réel (air, surface, sous-sol plein) et pas un cas favorable.
	var t0 := Time.get_ticks_usec()
	var chunks := 0
	var vides := 0
	for cx in range(-4, 5):
		for cz in range(-4, 5):
			var col := Vector2i(cx, cz)
			var ctx: Dictionary = gen.prepare_context(col)
			for cy in range(-2, 4):
				var ck := Vector3i(cx, cy, cz)
				var data: ChunkData = WorldManager._get_chunk_sync(ck)
				if data == null:
					continue
				var arrays := ChunkMesher.mesh_chunk(ck, data, gen, ctx)
				chunks += 1
				if arrays.is_empty():
					vides += 1
	var total_us := Time.get_ticks_usec() - t0
	ChunkMesher.profiling = false

	if chunks == 0:
		print("[MESH] aucun chunk maillé — sonde inexploitable.")
		main.get_tree().quit(1)
		return

	var moyen_ms := float(total_us) / float(chunks) / 1000.0
	print("[MESH] %d chunks maillés (%d vides) — moyenne %.2f ms/chunk (budget E.14 : %.1f ms)" % [
			chunks, vides, moyen_ms, budget_ms])
	var phases: Dictionary = ChunkMesher.phase_us
	var somme := 0
	for key: String in phases:
		somme += int(phases[key])
	for key: String in ["coquille", "interieur", "greedy", "subdiv"]:
		var us := int(phases[key])
		var part := 100.0 * float(us) / maxf(1.0, float(somme))
		print("[MESH]   %-10s %8.2f ms total  %6.3f ms/chunk  %5.1f %%" % [
				key, float(us) / 1000.0, float(us) / float(chunks) / 1000.0, part])
	print("[MESH] verdict : %s le budget E.14" % ("DANS" if moyen_ms <= budget_ms else "AU-DESSUS DE"))
	# La sonde MESURE, elle ne juge pas : elle sort toujours 0 pour rester
	# utilisable comme outil de comparaison avant/après optimisation.
	main.get_tree().quit(0)
