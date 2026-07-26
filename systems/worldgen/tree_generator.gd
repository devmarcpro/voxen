class_name TreeGenerator
extends RefCounted
## Générateur procédural d'arbres en code pur — aucun modèle externe (.vox/
## Blender/Blockbench), piloté par les données `data/trees/*.json`.
## Déterministe : mêmes coordonnées + même graine monde → même arbre, à
## chaque appel, sur toute machine (nécessaire au streaming de chunks, G.1).
## Échelle : 1 bloc = 1 mètre (le joueur fait 2 blocs de haut) — les hauteurs
## de tronc de chaque essence (data/trees/*.json) sont calibrées sur cette
## échelle plutôt que sur la taille réelle exacte de l'arbre (un vrai séquoia
## ferait 80+ blocs : hors de propos pour le gameplay).
## Silhouettes fines (palmier, sapin) obtenues par la FORME (tronc à un seul
## bloc, canopée qui s'effile), pas par la résolution du bloc — sauf pour la
## rondeur du tronc, voir SUBDIVIDE_TRUNK juste en dessous.
##
## EXPÉRIMENTAL, RÉVERSIBLE (2026-07-20, demande explicite « rajouter un peu
## de subdivision pour les arbres, essayer, et rendre ça réversible ») : les
## troncs fins (trunk_radius == 1, la majorité des essences) peuvent être
## arrondis en sous-voxels (SubdivGrid 8×8×8/4px, 4.1 — le système DÉJÀ EN
## PLACE, pas un second système parallèle) plutôt que rester des cubes
## parfaits. Mettre SUBDIVIDE_TRUNK à false pour revenir EXACTEMENT au
## comportement précédent (aucun autre changement de code nécessaire — c'est
## tout l'intérêt du flag). Coût : les blocs subdivisés ont un meshing plus
## cher (problème de perf DÉJÀ CONNU et mesuré, voir mémoire projet) ; avec
## potentiellement des dizaines d'arbres à l'écran, ce coût peut s'additionner
## — À VALIDER AU BENCH avant de considérer ce réglage acquis.
const SUBDIVIDE_TRUNK := false  # Désactivé (retour utilisateur 2026-07-20 : pas voulu). Flag laissé en place, réversible.


## Génère un arbre à `base` (position du premier bloc de tronc, au sol).
## Retourne { "blocks": Dictionary[Vector3i,int], "wood_positions": Array[Vector3i],
##            "base": Vector3i, "species_id": String, "special_tags": Array }.
## `blocks` est un survol SPARSE (positions monde → id matériau runtime) ;
## ne contient QUE les voxels de l'arbre (jamais le sol/l'air alentour).
static func generate(base: Vector3i, world_seed: int, species: Dictionary) -> Dictionary:
	var rng := RandomNumberGenerator.new()
	rng.seed = _seed_for(world_seed, base)

	var wood_id: int = GameData.material_runtime_ids.get(species["wood_material"], 0)
	var leaf_id: int = GameData.material_runtime_ids.get(species["leaf_material"], 0)
	var height_range: Array = species["height_range"]
	var height := rng.randi_range(int(height_range[0]), int(height_range[1]))
	var trunk_radius := int(species["trunk_radius"])
	var lean := bool(species.get("trunk_lean", false))

	var blocks := {}
	var wood_positions: Array[Vector3i] = []
	# Sous-grilles de tronc arrondi (SUBDIVIDE_TRUNK, expérimental/réversible).
	var trunk_subdivs := {}
	# Ligne centrale du tronc (pour l'attache des branches) — un point par y.
	var centerline: Array[Vector3i] = []

	# --- 1. Tronc, avec courbure organique (bruit 1D via le rng seedé) ---
	var lean_dir := Vector2(rng.randf_range(-1.0, 1.0), rng.randf_range(-1.0, 1.0))
	lean_dir = lean_dir.normalized() if lean_dir.length() > 0.01 else Vector2.RIGHT
	var offset := Vector2.ZERO
	for y in height:
		if y > 0 and y % 3 == 0:
			# Décalage ±1 bloc tous les ~3 blocs (4.1 : toujours sur grille).
			offset += (lean_dir * 0.9) if lean else Vector2(rng.randf_range(-0.6, 0.6), rng.randf_range(-0.6, 0.6))
		var center := Vector3i(base.x + roundi(offset.x), base.y + y, base.z + roundi(offset.y))
		centerline.append(center)
		# Profil du tronc (baobab : renflement au premier tiers, silhouette
		# "bouteille" caractéristique plutôt qu'un simple cylindre droit).
		var radius := trunk_radius
		if trunk_radius > 1:
			var t := float(y) / maxf(height - 1, 1)
			var bulge := 1.0 + 0.5 * sin(clampf(t, 0.0, 0.6) / 0.6 * PI)
			radius = maxi(1, roundi(trunk_radius * bulge))
		_place_disc(blocks, wood_positions, center, radius, wood_id, trunk_subdivs)

	# --- 2. Branches (Bresenham 3D discret) ---
	var bp: Dictionary = species["branch_parameters"]
	var count_range: Array = bp["count_range"]
	var count := rng.randi_range(int(count_range[0]), int(count_range[1]))
	var branch_ends: Array[Vector3i] = []
	if count > 0:
		var start_y := clampi(int(height * float(bp["start_fraction"])), 0, height - 1)
		var length_range: Array = bp["length_range"]
		var angle_rad := deg_to_rad(float(bp["angle_deg"]))
		for i in count:
			var along_y := start_y if count == 1 else start_y + int(float(i) / (count - 1) * (height - 1 - start_y))
			var from_pos := centerline[clampi(along_y, 0, centerline.size() - 1)]
			var yaw := (TAU / count) * i + rng.randf_range(-0.35, 0.35)
			var dir := Vector3(cos(yaw) * cos(angle_rad), sin(angle_rad), sin(yaw) * cos(angle_rad)).normalized()
			var length := rng.randi_range(int(length_range[0]), int(length_range[1]))
			branch_ends.append(_trace_branch(blocks, wood_positions, from_pos, dir, length, wood_id))
	else:
		# Pas de branches (conifères) : la canopée s'enroule autour du sommet.
		branch_ends.append(centerline[centerline.size() - 1])

	# --- 3. Canopée (feuillage) ---
	match String(species["canopy_shape"]):
		"conical":
			_canopy_conical(blocks, centerline, species, rng, leaf_id)
		"spherical":
			for tip in branch_ends:
				_canopy_ellipsoid(blocks, tip, species, rng, leaf_id)
		"flat":
			for tip in branch_ends:
				_canopy_flat(blocks, tip, species, rng, leaf_id)
		"weeping":
			for tip in branch_ends:
				_canopy_weeping(blocks, tip, species, rng, leaf_id)

	return {
		"blocks": blocks, "wood_positions": wood_positions, "base": base,
		"species_id": String(species["id"]), "special_tags": species.get("special_tags", []),
		"trunk_subdivs": trunk_subdivs,
	}


static func _seed_for(world_seed: int, base: Vector3i) -> int:
	var v := (world_seed * 747796405 + 2891336453) ^ (base.x * 2654435761) ^ (base.z * 1597334677)
	v = (v ^ (v >> 15)) * 0x85EBCA6B
	return (v ^ (v >> 13)) & 0x7FFFFFFF


static func _place_block(blocks: Dictionary, wood_positions: Array[Vector3i], pos: Vector3i, material_id: int) -> void:
	if not blocks.has(pos):
		blocks[pos] = material_id
		wood_positions.append(pos)


## Disque plein horizontal (tronc, coupe à une hauteur donnée). `trunk_subdivs`
## (optionnel) reçoit une sous-grille arrondie pour les troncs fins
## (radius == 1) quand SUBDIVIDE_TRUNK est actif — voir en-tête de fichier.
static func _place_disc(blocks: Dictionary, wood_positions: Array[Vector3i], center: Vector3i, radius: int, material_id: int, trunk_subdivs: Dictionary = {}) -> void:
	if radius <= 1:
		_place_block(blocks, wood_positions, center, material_id)
		if SUBDIVIDE_TRUNK:
			trunk_subdivs[center] = _round_trunk_grid(material_id)
		return
	for dx in range(-radius, radius + 1):
		for dz in range(-radius, radius + 1):
			if dx * dx + dz * dz <= radius * radius:
				_place_block(blocks, wood_positions, center + Vector3i(dx, 0, dz), material_id)


## Section circulaire d'un tronc fin en sous-voxels (SubdivGrid 8×8×8/4px,
## système déjà en place — 4.1) : coupe les coins du cube pour approximer un
## cylindre, répliquée sur toute la hauteur du bloc (8 tranches Y).
static func _round_trunk_grid(material_id: int) -> PackedInt32Array:
	var grid := SubdivGrid.create_empty()
	var c := 3.5   # Centre de la grille 8×8 (indices de cellule 0..7).
	var r := 3.6   # Rayon en cellules — juste sous 4 pour rester dans le bloc.
	for x in SubdivGrid.SIZE:
		for z in SubdivGrid.SIZE:
			var dx := float(x) - c
			var dz := float(z) - c
			if dx * dx + dz * dz > r * r:
				continue
			for y in SubdivGrid.SIZE:
				grid[SubdivGrid.cell_index(x, y, z)] = material_id
	return grid


## Tracé discret d'une branche (Bresenham 3D simplifié : pas unitaires le
## long du vecteur directeur le plus significatif). Retourne la position finale.
static func _trace_branch(blocks: Dictionary, wood_positions: Array[Vector3i], from_pos: Vector3i, dir: Vector3, length: int, material_id: int) -> Vector3i:
	var pos := Vector3(from_pos)
	var current := from_pos
	for i in length:
		pos += dir
		current = Vector3i(roundi(pos.x), roundi(pos.y), roundi(pos.z))
		_place_block(blocks, wood_positions, current, material_id)
	return current


## Bruit soustractif déterministe (silhouette organique, jamais un bloc plein
## parfait) — hachage de la position monde, indépendant de tout autre état.
static func _keep_leaf(pos: Vector3i, seed_value: int, keep_chance: float) -> bool:
	var v := (pos.x * 668265263) ^ (pos.y * 374761393) ^ (pos.z * 2246822519) ^ seed_value
	v = (v ^ (v >> 13)) * 1274126177
	var f := float(v & 0xFFFFFF) / float(0xFFFFFF)
	return f < keep_chance


## Canopée sphérique (feuillus à couronne arrondie — chêne).
static func _canopy_ellipsoid(blocks: Dictionary, tip: Vector3i, species: Dictionary, rng: RandomNumberGenerator, leaf_id: int) -> void:
	var radius_range: Array = species["canopy_radius_range"]
	var r := rng.randi_range(int(radius_range[0]), int(radius_range[1]))
	var seed_value := rng.randi()
	for dx in range(-r, r + 1):
		for dy in range(-r, r + 1):
			for dz in range(-r, r + 1):
				var d2 := dx * dx + dy * dy * 1.2 + dz * dz  # légèrement aplati (réaliste)
				if d2 > r * r + 0.5:
					continue
				var pos := tip + Vector3i(dx, dy, dz)
				# Bord adouci : les voxels proches de la limite ont une chance
				# de manquer, jamais un contour parfaitement sphérique.
				var edge := d2 / maxf(r * r, 1.0)
				var chance := 1.0 if edge < 0.5 else lerpf(0.95, 0.35, (edge - 0.5) / 0.5)
				if _keep_leaf(pos, seed_value, chance):
					blocks[pos] = leaf_id


## Canopée conique (conifères — le feuillage enveloppe le tronc, s'effile
## vers le sommet, silhouette caractéristique du sapin).
static func _canopy_conical(blocks: Dictionary, centerline: Array[Vector3i], species: Dictionary, rng: RandomNumberGenerator, leaf_id: int) -> void:
	var radius_range: Array = species["canopy_radius_range"]
	var max_r := rng.randi_range(int(radius_range[0]), int(radius_range[1]))
	var start_i := clampi(int(centerline.size() * 0.15), 0, centerline.size() - 1)
	var seed_value := rng.randi()
	for i in range(start_i, centerline.size()):
		var t := float(i - start_i) / maxf(centerline.size() - 1 - start_i, 1)
		var r := maxi(0, roundi(lerpf(max_r, 0.3, t)))
		var center := centerline[i]
		for dx in range(-r, r + 1):
			for dz in range(-r, r + 1):
				if dx * dx + dz * dz > r * r:
					continue
				var pos := center + Vector3i(dx, 0, dz)
				if pos == center:
					continue  # Le tronc occupe déjà cette cellule.
				if _keep_leaf(pos, seed_value, 0.85):
					blocks[pos] = leaf_id


## Canopée plate (houppier étalé et clairsemé — palmier, baobab).
static func _canopy_flat(blocks: Dictionary, tip: Vector3i, species: Dictionary, rng: RandomNumberGenerator, leaf_id: int) -> void:
	var radius_range: Array = species["canopy_radius_range"]
	var r := rng.randi_range(int(radius_range[0]), int(radius_range[1]))
	var seed_value := rng.randi()
	for dx in range(-r, r + 1):
		for dz in range(-r, r + 1):
			if dx * dx + dz * dz > r * r:
				continue
			for dy in range(0, 2):
				var pos := tip + Vector3i(dx, dy, dz)
				if _keep_leaf(pos, seed_value, 0.8):
					blocks[pos] = leaf_id


## Canopée pleureuse (branches retombantes — non utilisée par les 4 essences
## de départ, incluse pour compléter le schéma canopy_shape).
static func _canopy_weeping(blocks: Dictionary, tip: Vector3i, species: Dictionary, rng: RandomNumberGenerator, leaf_id: int) -> void:
	var radius_range: Array = species["canopy_radius_range"]
	var r := rng.randi_range(int(radius_range[0]), int(radius_range[1]))
	var seed_value := rng.randi()
	for dx in range(-r, r + 1):
		for dz in range(-r, r + 1):
			if dx * dx + dz * dz > r * r:
				continue
			var pos := tip + Vector3i(dx, 0, dz)
			if _keep_leaf(pos, seed_value, 0.9):
				blocks[pos] = leaf_id
			# Mèches retombantes.
			var strand := rng.randi_range(1, 3)
			for dy in range(1, strand + 1):
				blocks[tip + Vector3i(dx, -dy, dz)] = leaf_id
