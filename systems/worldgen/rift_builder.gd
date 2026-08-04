class_name RiftBuilder
extends RefCounted
## FAILLE DE MANA (2026-08-03) — la seconde dimension, et la preuve que le
## système de dimensions est vraiment générique.
##
## POURQUOI ELLE EXISTE. Généraliser un système sur un seul cas ne prouve rien :
## tant que `donjon` était la seule dimension, rien ne distinguait une vraie
## abstraction d'un renommage. Cette faille n'a AUCUN code dans le moteur — pas
## de backend, pas de branche dans WorldManager, pas d'ambiance codée en dur.
## Elle est un fichier de données et ce constructeur, qui écrit des blocs par
## `DimensionManager.set_block_in` comme n'importe qui d'autre pourrait le faire.
##
## Ce qu'elle est, dans le jeu : des îlots d'améthyste flottant dans le vide,
## éclairés par des veines de scorie, sans sol ni ciel. On y entre, on y tombe
## si on rate son saut, on en sort. C'est peu de contenu, et c'est assumé — le
## sujet de cette passe était l'architecture, pas le level design.

## Coordonnées de la faille. Loin de l'origine mais TRÈS EN DEÇÀ de la limite
## où float32 commence à trembler (le donjon a appris ça à ses dépens à ~4
## millions) : quelques milliers de blocs suffisent à ne croiser personne.
const ORIGIN := Vector3i(0, 0, 0)


## Construit la faille et retourne le point d'arrivée du joueur.
##
## Le maillage est fait UNE FOIS à la fin (`remesh_all`) : remailler à chaque
## bloc coûterait des milliers de maillages pour un seul résultat, et c'est
## exactement la raison d'être du paramètre `remesh` de `set_block_in`.
static func build(dimension: StringName, declaration: Dictionary, world_seed: int) -> Vector3:
	var rng := RandomNumberGenerator.new()
	rng.seed = world_seed ^ 0x5EED_FA11

	var islands: Dictionary = declaration.get("islands", {})
	var materials: Dictionary = declaration.get("materials", {})
	var ground: int = GameData.material_runtime_ids.get(String(materials.get("sol", "amethyste")), 0)
	var rock: int = GameData.material_runtime_ids.get(String(materials.get("roche", "obsidienne")), 0)
	var glow: int = GameData.material_runtime_ids.get(String(materials.get("lumiere", "scorie_ardente")), 0)
	if ground == 0 or rock == 0:
		push_warning("RiftBuilder : matériaux de faille introuvables.")
		return Vector3.ZERO

	var count := int(islands.get("count", 12))
	var radius_range: Array = islands.get("radius", [5, 12])
	var thickness_range: Array = islands.get("thickness", [3, 7])
	var spread := float(islands.get("spread", 70))

	var arrival := Vector3.ZERO
	for i in count:
		# LE PREMIER ÎLOT EST TOUJOURS À L'ORIGINE, et large : c'est là qu'on
		# arrive, et arriver dans le vide serait une chute immédiate.
		var center := ORIGIN
		var radius := int(radius_range[1])
		if i > 0:
			center = ORIGIN + Vector3i(
					roundi(rng.randf_range(-spread, spread)),
					roundi(rng.randf_range(-24.0, 24.0)),
					roundi(rng.randf_range(-spread, spread)))
			radius = rng.randi_range(int(radius_range[0]), int(radius_range[1]))
		var thickness := rng.randi_range(int(thickness_range[0]), int(thickness_range[1]))
		_carve_island(dimension, center, radius, thickness, ground, rock, glow, rng)
		if i == 0:
			arrival = Vector3(center) + Vector3(0.5, thickness + 2.5, 0.5)

	DimensionManager.remesh_all(dimension)
	_populate(dimension, arrival, declaration, rng)
	return arrival


## CE QU'ON TROUVE DANS LA FAILLE.
##
## Un décor n'est pas un lieu. Une dimension où il n'y a rien à rencontrer ni
## rien à ramasser ne se visite qu'une fois, et le travail d'architecture qui
## l'a rendue possible ne sert à rien.
##
## LE BESTIAIRE EST HUMAIN, et c'est une contrainte de contenu assumée (les
## espèces animales ont été retirées du périmètre) : il n'y a pas de démons à y
## mettre. On y met donc ce qui est cohérent avec ce roster — des gens qui sont
## entrés et n'en sont pas ressortis. Un ermite qui s'y est réfugié, des
## déserteurs devenus hostiles. C'est une lecture du lieu, pas un pis-aller :
## une faille où l'on croise les traces de ses prédécesseurs raconte plus
## qu'une faille pleine de monstres génériques.
static func _populate(dimension: StringName, arrival: Vector3, declaration: Dictionary,
		rng: RandomNumberGenerator) -> void:
	var spawns: Array = declaration.get("habitants", ["ermite", "deserteur", "deserteur"])
	for entry: String in spawns:
		if not GameData.creatures.has(entry):
			continue
		# Autour du point d'arrivée, jamais dessus : apparaître dans le joueur
		# le repousserait, et un hostile collé au nez ne laisse aucune chance.
		var angle := rng.randf() * TAU
		var distance := rng.randf_range(6.0, 16.0)
		var spot := arrival + Vector3(cos(angle) * distance, 0.0, sin(angle) * distance)
		spot.y = _surface_under(dimension, spot)
		if spot.y == -INF:
			continue  # Le vide : il n'y a pas d'îlot sous ce point.
		var creature := CreatureManager.spawn(entry, spot)
		if creature != null:
			creature.dimension = dimension

	# BUTIN AU SOL. Les matériaux de la faille ne poussent pas ailleurs : c'est
	# ce qui donne une raison d'y descendre, au-delà de la curiosité.
	var materials: Dictionary = declaration.get("materials", {})
	var prize := String(materials.get("sol", "amethyste"))
	var caches := rng.randi_range(3, 6)
	for i in caches:
		var angle := rng.randf() * TAU
		var distance := rng.randf_range(8.0, 40.0)
		var spot := arrival + Vector3(cos(angle) * distance, 0.0, sin(angle) * distance)
		spot.y = _surface_under(dimension, spot)
		if spot.y == -INF:
			continue
		DropManager.drop_materials(spot + Vector3.UP * 0.5,
				{prize: rng.randi_range(4, 12)})


## Hauteur du dessus de l'îlot sous ce point, ou -INF s'il n'y a que du vide.
##
## On sonde vers le BAS depuis le niveau d'arrivée : dans une dimension faite
## d'îlots flottants, « le sol » n'existe pas comme surface continue, et poser
## quoi que ce soit à une hauteur fixe le ferait tomber dans le noir.
static func _surface_under(dimension: StringName, point: Vector3) -> float:
	var x := roundi(point.x)
	var z := roundi(point.z)
	for dy in range(roundi(point.y) + 2, roundi(point.y) - 40, -1):
		if DimensionManager.block_at_in(dimension, Vector3i(x, dy, z)) != 0:
			return float(dy) + 1.0
	return -INF


## Un îlot : un disque de sol qui s'effile vers le bas en pointe rocheuse, avec
## quelques veines lumineuses. La pointe est ce qui le fait lire comme un
## morceau arraché plutôt que comme une galette posée sur rien.
static func _carve_island(dimension: StringName, center: Vector3i, radius: int,
		thickness: int, ground: int, rock: int, glow: int,
		rng: RandomNumberGenerator) -> void:
	var seed_value := rng.randi()
	for depth in thickness:
		# Le rayon décroît avec la profondeur : plat dessus, pointu dessous.
		var level_radius := int(round(radius * (1.0 - float(depth) / float(thickness))))
		if depth == 0:
			level_radius = radius
		for dx in range(-level_radius, level_radius + 1):
			for dz in range(-level_radius, level_radius + 1):
				if dx * dx + dz * dz > level_radius * level_radius:
					continue
				# Bord rongé, sinon l'îlot a un contour de compas.
				if depth == 0 and _edge_noise(center + Vector3i(dx, 0, dz), seed_value) < 0.18 \
						and dx * dx + dz * dz > (level_radius - 1) * (level_radius - 1):
					continue
				var pos := center + Vector3i(dx, -depth, dz)
				var id := ground if depth == 0 else rock
				# Veines lumineuses dans la roche : la faille n'a pas de soleil,
				# sans elles on n'y verrait littéralement rien.
				if depth > 0 and glow != 0 and _edge_noise(pos, seed_value + 7) < 0.06:
					id = glow
				DimensionManager.set_block_in(dimension, pos, id, false)


## Bruit déterministe [0,1) — même hachage que le feuillage des arbres, pour
## que deux systèmes qui rongent un bord le fassent de la même façon.
static func _edge_noise(pos: Vector3i, seed_value: int) -> float:
	var v := (pos.x * 668265263) ^ (pos.y * 374761393) ^ (pos.z * 2246822519) ^ seed_value
	v = (v ^ (v >> 13)) * 1274126177
	return float(v & 0xFFFFFF) / float(0xFFFFFF)
