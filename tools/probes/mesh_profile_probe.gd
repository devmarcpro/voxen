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
	# LE CHRONOMÈTRE NE COUVRE QUE LE MESHING. Il englobait aussi
	# `_get_chunk_sync`, c'est-à-dire la GÉNÉRATION du chunk : la sonde
	# annonçait 23 ms/chunk « de meshing » contre un budget de 4 ms alors que
	# les phases mesurées n'en totalisaient que 6,8. Les deux tiers du temps
	# accusé n'étaient pas du meshing du tout, et la somme des phases qui ne
	# tombait pas juste était le seul indice que le compte était faux.
	var total_us := 0
	var gen_us := 0
	var chunks := 0
	var vides := 0
	for cx in range(-4, 5):
		for cz in range(-4, 5):
			var col := Vector2i(cx, cz)
			var ctx: Dictionary = gen.prepare_context(col)
			for cy in range(-2, 4):
				var ck := Vector3i(cx, cy, cz)
				var t_gen := Time.get_ticks_usec()
				var data: ChunkData = WorldManager._get_chunk_sync(ck)
				gen_us += Time.get_ticks_usec() - t_gen
				if data == null:
					continue
				var t_mesh := Time.get_ticks_usec()
				var arrays := ChunkMesher.mesh_chunk(ck, data, gen, ctx)
				total_us += Time.get_ticks_usec() - t_mesh
				chunks += 1
				if arrays.is_empty():
					vides += 1
	ChunkMesher.profiling = false

	if chunks == 0:
		print("[MESH] aucun chunk maillé — sonde inexploitable.")
		main.get_tree().quit(1)
		return

	var moyen_ms := float(total_us) / float(chunks) / 1000.0
	print("[MESH] %d chunks maillés (%d vides) — moyenne %.2f ms/chunk (budget E.14 : %.1f ms)" % [
			chunks, vides, moyen_ms, budget_ms])
	# La génération est imprimée à part : elle est réelle et coûteuse, mais elle
	# ne relève pas du budget de meshing et la mélanger rendait les deux
	# chiffres inexploitables.
	print("[MESH] génération des mêmes chunks : %.2f ms/chunk (hors budget meshing)" % [
			float(gen_us) / float(chunks) / 1000.0])
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
