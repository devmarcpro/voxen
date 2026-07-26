class_name PlantGenerator
extends RefCounted
## Génère la structure sub-voxel d'une plante non-arborescente (fleurs,
## buissons, cultures, champignons — demande explicite 2026-07-20) : classe
## STATIQUE PURE, comme TreeGenerator. Réutilise le système de subdivision
## DÉJÀ EN PLACE (SubdivGrid, 4.1/G.2 — grille 8×8×8 de cellules 4px par
## bloc standard 32px) plutôt que d'introduire un second système de sous-
## voxels parallèle et incompatible : le champ `resolution` des données
## (8/4/2, cahier des charges) est réinterprété comme un contrôle de FINESSE
## (épaisseur de tige/taille de motif en cellules SubdivGrid), pas une
## grille séparée — cohérent avec l'architecture existante (set_sub_region,
## ChunkMesher, budget 512 blocs subdivisés/chunk déjà mesurés au bench).
##
## INDIVISIBILITÉ (contrainte mécanique majeure, demande explicite) : une
## plante qui tient dans UN SEUL bloc est déjà indivisible gratuitement —
## casser un bloc plein efface toute sa sous-grille d'un coup
## (ChunkData.set_block_by_index, voir commentaire dans ce fichier). Seules
## les plantes à RACINE (extension dans le bloc du dessous, ex. pomme de
## terre, mandragore) ont besoin d'un couplage explicite : voir
## WorldManager._plant_root_links, alimenté par NoiseGenerator au moment du
## placement.
##
## SIMPLIFICATION ASSUMÉE ET DISCLOSED : les plantes GRIMPANTES (vanille)
## n'ont pas de vraie détection d'adjacence à un mur/tronc pendant la
## génération procédurale du monde (coûterait une requête de bloc voisin
## par candidat, sur un chemin déjà optimisé par rejet bon marché) — elles
## génèrent une tige fine décalée vers un bord du bloc, décorative plutôt
## que fonctionnellement accrochée. Les stades de croissance dans le temps
## (7.4, agriculture) ne sont PAS simulés ici : `stage` est un paramètre
## déterministe (mature par défaut au monde ouvert), pas une horloge —
## l'intégration avec le tick d'agriculture reste à faire séparément.

const N := SubdivGrid.SIZE  # 8 cellules par bloc (4px chacune).


## Hachage entier déterministe (même PCG que NoiseGenerator._pcg_hash — pas
## de dépendance croisée, la formule est dupliquée volontairement, minuscule
## et sans état).
static func _pcg_hash(a: int, b: int, c: int) -> int:
	var v := (a * 747796405 + 2891336453) ^ (b * 2654435761) ^ (c * 1597334677)
	v = (v ^ (v >> 15)) * 0x85EBCA6B
	v = (v ^ (v >> 13)) * 0xC2B2AE35
	return (v ^ (v >> 16)) & 0x7FFFFFFF


static func _rand(seed_value: int, a: int, b: int, c: int) -> float:
	return _pcg_hash(a + seed_value, b, c) / float(1 << 31)


## Génère la sous-grille d'une plante à (base, seed_value, species, stage).
## Retourne { "grid": PackedInt32Array (512), "root_grid": PackedInt32Array
## ou vide, "loot": {material_id: count} }. `root_grid`, si non vide, doit
## être écrit dans le bloc `base + Vector3i(0,-1,0)` (racines).
static func generate(base: Vector3i, seed_value: int, species: Dictionary, stage: int) -> Dictionary:
	var morph: Dictionary = species.get("morphology", {})
	var materials: Dictionary = species.get("materials", {})
	var tags: Array = species.get("special_tags", [])
	var resolution := int(species.get("resolution", 4))
	var stem_width := clampi(int(round(4.0 / maxf(float(resolution), 1.0))), 1, 3)

	var agri: Dictionary = species.get("agriculture", {})
	var stage_count: int = maxi(int(agri.get("stages", 1)), 1)
	var stage_clamped := clampi(stage, 0, stage_count - 1)
	var stage_ratio := float(stage_clamped + 1) / float(stage_count)
	var mature := stage_clamped == stage_count - 1

	var stem_id: int = GameData.material_runtime_ids.get(String(materials.get("stem_material", "")), 0)
	var leaf_id: int = GameData.material_runtime_ids.get(String(materials.get("leaf_material", "")), stem_id)
	var flower_id: int = GameData.material_runtime_ids.get(String(materials.get("flower_material", "")), 0)
	var root_id: int = GameData.material_runtime_ids.get(String(materials.get("root_material", "")), 0)

	var grid := SubdivGrid.create_empty()
	var root_grid := PackedInt32Array()
	var loot := {}

	if "aquatique" in tags:
		_generate_aquatic(grid, base, seed_value, stem_id, stage_ratio)
		return {"grid": grid, "root_grid": root_grid, "loot": loot}

	var max_height: int = clampi(int(morph.get("max_height_subvoxels", 5)), 1, N)
	var height := maxi(1, int(round(max_height * stage_ratio)))
	var spread: float = morph.get("spread_radius", 0.0)
	var pattern: String = String(morph.get("leaf_pattern", "alternate"))
	var branching: float = morph.get("branching_factor", 0.0)

	var stem_cells: Array[Vector3i] = []
	if pattern == "clump":
		# Touffe basse (E.5) : pas de tige centrale unique, un dôme dense
		# de cellules autour de la base — pomme de terre, riz, dionée.
		stem_cells = _generate_clump(grid, seed_value, base, height, spread, leaf_id if leaf_id != 0 else stem_id)
	else:
		# Marche aléatoire dirigée VERS LE HAUT (demande explicite) : la tige
		# dévie latéralement dans les limites de spread_radius.
		stem_cells = _generate_stem(grid, seed_value, base, height, stem_width, spread, stem_id, branching)
		_apply_phyllotaxis(grid, seed_value, base, stem_cells, pattern, leaf_id if leaf_id != 0 else stem_id)

	if mature and flower_id != 0 and not stem_cells.is_empty():
		_place_flowers_or_fruit(grid, seed_value, base, stem_cells, flower_id, tags)
		loot[String(materials.get("flower_material", ""))] = 1 + int(_rand(seed_value, base.x, base.z, 99) * 2.0)

	if root_id != 0 and mature:
		root_grid = _generate_roots(seed_value, base, root_id)
		loot[String(materials.get("root_material", ""))] = 1

	return {"grid": grid, "root_grid": root_grid, "loot": loot}


## Marche aléatoire dirigée : à chaque cellule vers le haut, décale (x,z) de
## -1/0/+1 borné par spread_radius (en cellules). Épaisseur `width` (1-3
## cellules) — un blé fin (width=1) vs un maïs épais (width=2-3).
static func _generate_stem(grid: PackedInt32Array, seed_value: int, base: Vector3i, height: int, width: int, spread: float, stem_id: int, branching: float) -> Array[Vector3i]:
	var cells: Array[Vector3i] = []
	if stem_id == 0:
		return cells
	var cx := N / 2
	var cz := N / 2
	var spread_cells := maxi(0, int(round(spread * float(N))))
	for y in height:
		if y > 0:
			var dx := int(round(_rand(seed_value, y, 1, base.x) * 2.0 - 1.0))
			var dz := int(round(_rand(seed_value, y, 2, base.z) * 2.0 - 1.0))
			cx = clampi(cx + dx, N / 2 - spread_cells, N / 2 + spread_cells)
			cz = clampi(cz + dz, N / 2 - spread_cells, N / 2 + spread_cells)
		cx = clampi(cx, 0, N - 1)
		cz = clampi(cz, 0, N - 1)
		for wx in range(-(width / 2), width - width / 2):
			for wz in range(-(width / 2), width - width / 2):
				var px := clampi(cx + wx, 0, N - 1)
				var pz := clampi(cz + wz, 0, N - 1)
				grid[SubdivGrid.cell_index(px, y, pz)] = stem_id
		cells.append(Vector3i(cx, y, cz))
		# Ramification secondaire (branching_factor, ronces notamment) : une
		# petite excroissance latérale à partir de cette cellule de tige.
		if branching > 0.0 and _rand(seed_value, y, 3, base.z) < branching:
			var bdx := 1 if _rand(seed_value, y, 4, base.x) < 0.5 else -1
			var bx := clampi(cx + bdx, 0, N - 1)
			if y + 1 < N:
				grid[SubdivGrid.cell_index(bx, y, cz)] = stem_id
				cells.append(Vector3i(bx, y, cz))
	return cells


## Touffe basse dense (riz, pomme de terre, dionée) : dôme de cellules
## centré sur la base, rayon croissant puis décroissant avec la hauteur.
static func _generate_clump(grid: PackedInt32Array, seed_value: int, base: Vector3i, height: int, spread: float, fill_id: int) -> Array[Vector3i]:
	var cells: Array[Vector3i] = []
	if fill_id == 0:
		return cells
	var radius_cells := clampi(int(round(spread * float(N))), 1, N / 2)
	var cx := N / 2
	var cz := N / 2
	for y in height:
		var shrink := 1.0 - float(y) / float(maxi(height, 1))
		var r := maxi(1, int(round(radius_cells * shrink)))
		for dx in range(-r, r + 1):
			for dz in range(-r, r + 1):
				if dx * dx + dz * dz > r * r:
					continue
				var roll := _rand(seed_value, cx + dx, cz + dz, y + base.x)
				if roll > 0.55:
					continue  # Silhouette organique, pas un disque plein (E.2).
				var px := clampi(cx + dx, 0, N - 1)
				var pz := clampi(cz + dz, 0, N - 1)
				grid[SubdivGrid.cell_index(px, y, pz)] = fill_id
				cells.append(Vector3i(px, y, pz))
	return cells


## Phyllotaxie (motif de placement des feuilles, demande explicite) : pour
## chaque cellule de tige (sauf la base), place 1-2 cellules de feuille
## selon le motif choisi. "spiral" : angle qui tourne à chaque niveau.
## "opposite" : deux feuilles à 180°, toutes au même angle. "alternate" :
## une feuille par niveau, angle qui alterne 0°/180°.
static func _apply_phyllotaxis(grid: PackedInt32Array, seed_value: int, base: Vector3i, stem_cells: Array[Vector3i], pattern: String, leaf_id: int) -> void:
	if leaf_id == 0:
		return
	var offsets := [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]
	for i in stem_cells.size():
		if i == 0:
			continue  # Pas de feuille à la base (rejoint le sol).
		var c := stem_cells[i]
		var dirs: Array[Vector2i] = []
		match pattern:
			"spiral":
				dirs = [offsets[i % offsets.size()]]
			"opposite":
				dirs = [offsets[0], offsets[1]]
			_:  # "alternate" (défaut).
				dirs = [offsets[i % 2]]
		for d: Vector2i in dirs:
			var lx := clampi(c.x + d.x, 0, N - 1)
			var lz := clampi(c.z + d.y, 0, N - 1)
			if grid[SubdivGrid.cell_index(lx, c.y, lz)] == 0:
				grid[SubdivGrid.cell_index(lx, c.y, lz)] = leaf_id


## Fleurs/fruits (demande explicite) : au bout des branches (les dernières
## cellules de tige atteintes), un petit amas de cellules du matériau de
## fleur/fruit — remplace la cellule de tige terminale et déborde d'une
## cellule autour (silhouette lisible sans dépasser la grille).
static func _place_flowers_or_fruit(grid: PackedInt32Array, seed_value: int, base: Vector3i, stem_cells: Array[Vector3i], flower_id: int, tags: Array) -> void:
	if stem_cells.is_empty():
		return
	# "Grosse fructification au sol" (calebasse/citrouille, E.2) : sphère
	# massive posée à la base plutôt qu'en bout de tige.
	if "fruit_massif_sol" in tags:
		var r := 3
		for dx in range(-r, r + 1):
			for dy in range(0, r + 1):
				for dz in range(-r, r + 1):
					if dx * dx + dy * dy + dz * dz > r * r:
						continue
					var px := clampi(N / 2 + dx, 0, N - 1)
					var py := clampi(dy, 0, N - 1)
					var pz := clampi(N / 2 + dz, 0, N - 1)
					grid[SubdivGrid.cell_index(px, py, pz)] = flower_id
		return
	var tip := stem_cells[stem_cells.size() - 1]
	for dx in range(-1, 2):
		for dz in range(-1, 2):
			var px := clampi(tip.x + dx, 0, N - 1)
			var pz := clampi(tip.z + dz, 0, N - 1)
			var py := clampi(tip.y, 0, N - 1)
			if dx == 0 and dz == 0 or _rand(seed_value, px, pz, py) < 0.6:
				grid[SubdivGrid.cell_index(px, py, pz)] = flower_id


## Racines (pomme de terre/mandragore, demande explicite) : sous-grille
## écrite dans le bloc DU DESSOUS (Y locale = le haut de CETTE grille = juste
## sous le sol) — un petit amas s'enfonçant, silhouette organique.
static func _generate_roots(seed_value: int, base: Vector3i, root_id: int) -> PackedInt32Array:
	var grid := SubdivGrid.create_empty()
	var r := 2
	var cx := N / 2
	var cz := N / 2
	for dx in range(-r, r + 1):
		for dz in range(-r, r + 1):
			for y in range(N - 3, N):  # Juste sous la surface (haut de ce bloc).
				if dx * dx + dz * dz > r * r:
					continue
				if _rand(seed_value, base.x + dx, base.z + dz, y) > 0.5:
					continue
				var px := clampi(cx + dx, 0, N - 1)
				var pz := clampi(cz + dz, 0, N - 1)
				grid[SubdivGrid.cell_index(px, y, pz)] = root_id
	return grid


## Végétation aquatique (algues, demande explicite) : bande verticale
## ondulante, sans gravité visuelle — ne dépend d'aucune tige/feuille,
## juste une colonne sinueuse de la base jusqu'au sommet du bloc.
static func _generate_aquatic(grid: PackedInt32Array, base: Vector3i, seed_value: int, material_id: int, stage_ratio: float) -> void:
	if material_id == 0:
		return
	var height := maxi(1, int(round(N * stage_ratio)))
	var cx := N / 2
	for y in height:
		var wave := int(round(sin(float(y) * 0.9 + float(base.x + base.z)) * 1.5))
		var px := clampi(cx + wave, 0, N - 1)
		grid[SubdivGrid.cell_index(px, y, N / 2)] = material_id
