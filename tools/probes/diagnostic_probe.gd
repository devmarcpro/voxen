extends Probe
## Sonde `--probe` — extraite de main.gd le 2026-07-28 (audit architectural).
## Logique inchangée : seuls les accès à la scène ont été réécrits
## ($Player -> player, get_tree() -> main.get_tree(), etc.).


func run() -> void:
	var g := WorldManager.generator
	for col: Vector2i in [Vector2i(0, 0), Vector2i(0, -30), Vector2i(0, -60), Vector2i(0, -120)]:
		var ctx := g.prepare_context(col)
		var rng := g.cy_range(col)
		print("[PROBE] col=%s hmin=%d hmax=%d plage_approx=%s" % [col, ctx["hmin"], ctx["hmax"], rng])
		for cy in range(rng.x, rng.y + 1):
			var key := Vector3i(col.x, cy, col.y)
			var data := g.generate_chunk(key, ctx)
			var uniform := data.is_uniform()
			var arrays: Array = []
			if not (uniform and data.uniform_id == 0):
				arrays = ChunkMesher.mesh_chunk(key, data, g, ctx)
			var vertex_count: int = 0 if arrays.is_empty() else (arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array).size()
			print("[PROBE]   cy=%d uniforme=%s id_u=%d sommets=%d" % [cy, uniform, data.uniform_id, vertex_count])
	var h0 := g.height_at(0, 0)
	print("[PROBE] hauteur(0,0)=%d bloc(0,h,0)=%d bloc(0,h+1,0)=%d bloc(0,h-5,0)=%d" % [
		h0, g.block_at(0, h0, 0), g.block_at(0, h0 + 1, 0), g.block_at(0, h0 - 5, 0)])
	# Test de mutation bout-en-bout (set_block → diff → remesh urgent).
	var target := Vector3i(0, h0, 0)
	var before := WorldManager.block_at_world(target)
	var ok := WorldManager.set_block(target, 0)
	var after := WorldManager.block_at_world(target)
	print("[PROBE] mutation : avant=%d ok=%s après=%d (attendu 0)" % [before, ok, after])
	# Relevé du relief et des biomes sur ±6400 blocs.
	var peak := 0
	var peak_pos := Vector2i.ZERO
	var counts := {}
	for gz in range(-100, 101, 4):
		for gx in range(-100, 101, 4):
			var hh := g.height_at(gx * 64, gz * 64)
			if hh > peak:
				peak = hh
				peak_pos = Vector2i(gx * 64, gz * 64)
			var b := g.biome_at(gx * 64, gz * 64)
			var biome_id: String = b.get("id", "?")
			counts[biome_id] = int(counts.get(biome_id, 0)) + 1
	print("[PROBE] pic=%d à %s ; répartition biomes (échantillon 2601 colonnes) : %s" % [peak, peak_pos, counts])

	# Vérification DÉDIÉE de la calotte glaciaire (2026-07-21, retour
	# utilisateur : « pas de biome glaciaire trouvé ») : le scan ±6400 blocs
	# ci-dessus ne peut JAMAIS l'atteindre (elle n'existe qu'au voisinage des
	# "pôles" climatiques, à ±LATITUDE_HALF_PERIOD=12000 blocs de l'équateur,
	# NoiseGenerator) — ce test balaie explicitement une pleine période de
	# latitude pour confirmer qu'elle est bien GÉNÉRÉE au moins quelque part,
	# indépendamment du rayon de recherche du menu de triche (question
	# distincte : la génération existe-t-elle, ou seulement la recherche
	# était-elle trop courte ?).
	var icecap_found := false
	var icecap_pos := Vector2i.ZERO
	for gz2 in range(-13000, 13001, 200):
		if icecap_found:
			break
		for gx2 in range(-2000, 2001, 200):
			if g.biome_at(gx2, gz2).get("id", "") == "calotte_glaciaire":
				icecap_found = true
				icecap_pos = Vector2i(gx2, gz2)
				break
	print("[PROBE] calotte glaciaire générée quelque part sur une période de latitude : %s à %s" % [icecap_found, icecap_pos])

	# Vérification du placement de POI (E.2) : compte les types trouvés sur un
	# échantillon de cellules (128 blocs chacune), doit rester proche des
	# poi_weights par défaut du GDD (village 4 %, donjon 6 %, camp 8 %,
	# sanctuaire 3 %, filon_majeur 6 % — modulés par la disponibilité de
	# poi_weights par biome, tous n'en ont pas forcément).
	var poi_counts := {}
	var poi_cells := 0
	for pcz in range(-50, 51):
		for pcx in range(-50, 51):
			var cell := Vector2i(pcx, pcz)
			var center := POIGenerator.cell_center_world(cell)
			var pb := g.biome_at(center.x, center.y)
			if pb.is_empty():
				continue
			var pois := POIGenerator.pois_at_cell(cell, WorldManager.world_seed, pb)
			poi_cells += 1
			for p in pois:
				poi_counts[p] = int(poi_counts.get(p, 0)) + 1
	print("[PROBE] POI (échantillon %d cellules) : %s" % [poi_cells, poi_counts])

	# Vérification des arbres : cherche d'abord une colonne en forêt tempérée
	# (densité 0.05), puis balaye alentour pour trouver quelques arbres et
	# affiche les matériaux de tronc/canopée par nom.
	var forest_pos := Vector2i.ZERO
	var forest_found := false
	for gz2 in range(-150, 151, 3):
		if forest_found:
			break
		for gx2 in range(-150, 151, 3):
			var b0: Dictionary = g.biome_at(gx2 * 16, gz2 * 16)
			if b0.get("id", "") == "foret_temperee":
				forest_pos = Vector2i(gx2 * 16, gz2 * 16)
				forest_found = true
				break
	print("[PROBE] forêt tempérée trouvée à %s : %s" % [forest_pos, forest_found])
	var found := 0
	if forest_found:
		for dz in range(-64, 64):
			if found >= 3:
				break
			var wz := forest_pos.y + dz
			for dx in range(-64, 64):
				if found >= 3:
					break
				var wx := forest_pos.x + dx
				var h := g.height_at(wx, wz)
				var trunk_id := g.block_at(wx, h + 1, wz)
				if trunk_id == 0:
					continue
				var top_id := g.block_at(wx, h + 4, wz)
				var trunk_name: String = GameData.material_by_runtime[trunk_id] if trunk_id < GameData.material_by_runtime.size() else "?"
				var top_name: String = GameData.material_by_runtime[top_id] if top_id > 0 and top_id < GameData.material_by_runtime.size() else "air"
				print("[PROBE] arbre à x=%d z=%d h=%d : tronc(h+1)=%s canopée(h+4)=%s" % [wx, wz, h, trunk_name, top_name])
				found += 1
	print("[PROBE] arbres trouvés dans le balayage : %d" % found)

	# Localise un représentant de chaque essence pour les captures de contrôle
	# (scan par cellule, cohérent avec le système de placement — G.4/E.2).
	for species_id in ["sapin", "palmier", "baobab"]:
		var pos := Vector3i.ZERO
		var species_found := false
		for cx in range(-800, 801):
			if species_found:
				break
			for cz in range(-800, 801):
				var cand: Dictionary = g._tree_candidate_in_cell(cx, cz)
				if not cand.is_empty() and cand["species_id"] == species_id:
					pos = cand["base"]
					species_found = true
					break
		print("[PROBE] essence=%s trouvée=%s pos=%s" % [species_id, species_found, pos])
		if species_found:
			var tree := g.tree_at_base(pos.x, pos.y, pos.z)
			var by_y := {}
			for p: Vector3i in (tree["blocks"] as Dictionary):
				var r := (Vector2(p.x - pos.x, p.z - pos.z)).length()
				by_y[p.y] = maxf(by_y.get(p.y, 0.0), r)
			var ys: Array = by_y.keys()
			ys.sort()
			var profile := []
			for y in ys:
				profile.append("%d:%.1f" % [y, by_y[y]])
			print("[PROBE]   profil rayon par hauteur : %s" % " ".join(profile))
			print("[PROBE]   total blocs=%d bois=%d" % [(tree["blocks"] as Dictionary).size(), (tree["wood_positions"] as Array).size()])
			if species_id == "baobab":
				# Simule l'abattage complet (WorldManager.set_block par bloc)
				# + la libération d'eau (tag contient_liquide).
				for p: Vector3i in (tree["blocks"] as Dictionary):
					WorldManager.set_block(p, 0)
				var water_id: int = GameData.material_runtime_ids.get("eau", 0)
				WorldManager.set_block(pos, water_id)
				var remaining := 0
				for p: Vector3i in (tree["blocks"] as Dictionary):
					if p != pos and WorldManager.block_at_world(p) != 0:
						remaining += 1
				print("[PROBE]   abattage : blocs résiduels non-air=%d (attendu 0) eau à la base=%s (attendu true)" % [
					remaining, WorldManager.block_at_world(pos) == water_id])
	main.get_tree().quit(0)
