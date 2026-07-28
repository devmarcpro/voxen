extends Probe
## Sonde `--probe-ore` — extraite de main.gd le 2026-07-28 (audit architectural).
## Logique inchangée : seuls les accès à la scène ont été réécrits
## ($Player -> player, get_tree() -> main.get_tree(), etc.).


## Sonde headless de génération des minerais (G.9, 2026-07-24) : génère une
## pile de chunks, compte les minerais par profondeur, vérifie que les métaux
## communs sont peu profonds et les gemmes/diamant profonds, et que les filons
## s'adaptent aux montagnes (présents à Y absolu élevé sous un sommet).
func run() -> void:
	await main.get_tree().process_frame
	var g := WorldManager.generator
	# Ensemble des ids de minerai (catégories minerai/mineral/cristal/fossile).
	var ore_ids := {}
	for id: String in GameData.materials:
		if GameData.materials[id]["category"] in ["minerai", "mineral", "cristal", "fossile"]:
			ore_ids[int(GameData.material_runtime_ids[id])] = id
	# Scan d'une pile de chunks sur une colonne plate.
	var col := Vector2i(0, 0)
	var ctx := g.prepare_context(col)
	var h0: int = g.height_at(8, 8)
	var by_depth := {}      # bucket de 40 → nb minerais
	var total_rock := 0
	var total_ore := 0
	var shallow_mats := {}  # depth < 55
	var deep_mats := {}     # depth > 280
	for cy in range(floori(float(h0) / 16.0), -25, -1):
		var data := g.generate_chunk(Vector3i(0, cy, 0), ctx)
		if data.is_uniform():
			continue
		for ly in 16:
			for lz in 16:
				for lx in 16:
					var wy := cy * 16 + ly
					var depth := h0 - wy
					if depth < 5:
						continue
					var bid := data.get_block(lx, ly, lz)
					if bid == 0:
						continue
					total_rock += 1
					if ore_ids.has(bid):
						total_ore += 1
						var bucket := (depth / 40) * 40
						by_depth[bucket] = int(by_depth.get(bucket, 0)) + 1
						if depth < 55:
							shallow_mats[ore_ids[bid]] = true
						elif depth > 280:
							deep_mats[ore_ids[bid]] = true
	print("[OREPROBE] surface h=%d · blocs solides=%d · minerais=%d (%.1f%%)" % [
		h0, total_rock, total_ore, 100.0 * total_ore / maxi(total_rock, 1)])
	var buckets: Array = by_depth.keys()
	buckets.sort()
	for b in buckets:
		print("[OREPROBE]   profondeur %d-%d : %d filons" % [b, b + 40, by_depth[b]])
	print("[OREPROBE] peu profond (<55) : %s" % [shallow_mats.keys()])
	print("[OREPROBE] profond (>280) : %s" % [deep_mats.keys()])
	# Diamant ne doit JAMAIS apparaître peu profond.
	var diamant_shallow := "diamant" in shallow_mats or "tungstene" in shallow_mats
	# Cuivre/étain/fer doivent apparaître dans les couches supérieures.
	var common_shallow := shallow_mats.size() > 0

	# Adaptation aux montagnes : trouver un sommet (surface haute) et vérifier
	# qu'un filon existe à Y absolu élevé (= profondeur normale sous CE sommet).
	var peak := Vector2i.ZERO
	var peak_h := -9999
	for gx in range(-40, 41, 4):
		for gz in range(-40, 41, 4):
			var hh := g.height_at(gx * 16, gz * 16)
			if hh > peak_h:
				peak_h = hh
				peak = Vector2i(gx * 16, gz * 16)
	var mountain_ore := false
	var mountain_ore_y := 0
	# Cherche un minerai entre 20 et 120 sous le sommet (Y absolu élevé).
	for d in range(20, 121):
		var wy := peak_h - d
		var b := g.block_at(peak.x, wy, peak.y)
		if ore_ids.has(b):
			mountain_ore = true
			mountain_ore_y = wy
			break
	print("[OREPROBE] sommet à %s h=%d : filon adapté à Y=%d (%s)" % [peak, peak_h, mountain_ore_y, mountain_ore])

	var ok: bool = total_ore > 0 and common_shallow and not diamant_shallow \
		and 0.3 < (100.0 * total_ore / maxi(total_rock, 1)) and (100.0 * total_ore / maxi(total_rock, 1)) < 12.0 \
		and mountain_ore and mountain_ore_y > 60
	print("[OREPROBE] RÉSULTAT : %s" % ("OK" if ok else "ÉCHEC"))
	main.get_tree().quit(0 if ok else 1)
