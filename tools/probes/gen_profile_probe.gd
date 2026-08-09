extends Probe
## Sonde `--probe-gen` (2026-08-09) — répartition du temps de GÉNÉRATION.
##
## Le maillage est passé en natif (1,61 ms/chunk) : le plafond du bench de vol
## est désormais la génération (~11 ms/chunk d'après --probe-mesh, sans
## détail). Cette sonde décompose prepare_context et generate_chunk par phase
## — le portage C++ se décidera sur CES chiffres (règle G).
##
## MESURE SUR COLONNES VIERGES, loin du spawn : les caches d'arbres/villes du
## générateur sont déjà chauds autour du spawn après le boot, et un témoin
## réchauffé ment (leçon du 2026-08-04, voir la mémoire des pièges de mesure).
## La zone est décalée à +40 colonnes (640 blocs) : jamais streamée au boot.

const TAG := "GENPROFILE"
const BASE_COL := Vector2i(40, 40)
const SPAN := 7  # 7×7 colonnes = 49 contextes, ~300 chunks


func run() -> void:
	await wait_frame()
	var gen := WorldManager.generator
	if gen == null:
		print("[%s] aucun générateur." % TAG)
		main.get_tree().quit(1)
		return

	NoiseGenerator.reset_profile()
	NoiseGenerator.profiling = true
	var t_ctx_total := 0
	var t_chunk_total := 0
	var chunks := 0
	for dx in SPAN:
		for dz in SPAN:
			var col := BASE_COL + Vector2i(dx, dz)
			var t0 := Time.get_ticks_usec()
			var ctx: Dictionary = gen.prepare_context(col)
			t_ctx_total += Time.get_ticks_usec() - t0
			# La même bande verticale que le streaming réel : de hmin-1 à hmax+1.
			var cy_lo := floori(float(int(ctx["hmin"]) - 1) / 16.0)
			var cy_hi := floori(float(int(ctx["hmax"]) + 1) / 16.0)
			for cy in range(cy_lo, cy_hi + 1):
				t0 = Time.get_ticks_usec()
				gen.generate_chunk(Vector3i(col.x, cy, col.y), ctx)
				t_chunk_total += Time.get_ticks_usec() - t0
				chunks += 1
	NoiseGenerator.profiling = false

	var cols := SPAN * SPAN
	print("[%s] %d colonnes, %d chunks — contexte %.2f ms/colonne, chunk %.2f ms/chunk" % [
			TAG, cols, chunks,
			float(t_ctx_total) / float(cols) / 1000.0,
			float(t_chunk_total) / float(chunks) / 1000.0])
	# La somme des phases doit retomber sur les totaux — sinon la mesure ment
	# (leçon --probe-mesh : 30 % seulement du total étaient expliqués).
	var somme := 0
	for key: String in NoiseGenerator.phase_us:
		somme += int(NoiseGenerator.phase_us[key])
	print("[%s] somme des phases %.2f ms — contexte+chunks %.2f ms" % [
			TAG, float(somme) / 1000.0, float(t_ctx_total + t_chunk_total) / 1000.0])
	var keys: Array = NoiseGenerator.phase_us.keys()
	keys.sort_custom(func(a: String, b: String) -> bool:
		return int(NoiseGenerator.phase_us[a]) > int(NoiseGenerator.phase_us[b]))
	for key: String in keys:
		var us := int(NoiseGenerator.phase_us[key])
		print("[%s]   %-14s %9.2f ms total  %6.3f ms/colonne  %5.1f %%" % [
				TAG, key, float(us) / 1000.0, float(us) / float(cols) / 1000.0,
				100.0 * float(us) / maxf(1.0, float(somme))])
	# La sonde MESURE, elle ne juge pas (même contrat que --probe-mesh).
	main.get_tree().quit(0)
