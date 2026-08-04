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
## Étendue du pays, en blocs, depuis l'origine. Un carré de 320 blocs de côté :
## assez pour marcher longtemps sans jamais voir le bord, assez petit pour être
## bâti d'un coup à l'entrée.
const HALF_SPAN := 160
## Altitude moyenne du sol, et amplitude du relief.
const BASE_Y := 64
const RELIEF := 34.0
## Profondeur de roche sous la surface.
const CRUST := 10


## Construit la dimension et retourne le point d'arrivée du joueur.
##
## TERRAIN CONTINU (2026-08-04, demande de l'auteur : « pas des îles dans le
## vide »). La première version posait des îlots flottants — c'était une preuve
## d'architecture, pas un pays. On ne marche pas dans un archipel : on tombe.
##
## Le relief est fait de bruit SUPERPOSÉ, comme l'overworld, mais avec des
## règles qui n'ont rien de géologique : des terrasses franches, des bosses qui
## se recouvrent, et une amplitude que la Terre n'autorise pas. C'est ce qui
## garde le lieu onirique tout en le rendant praticable.
static func build(dimension: StringName, declaration: Dictionary, world_seed: int) -> Vector3:
	var rng := RandomNumberGenerator.new()
	rng.seed = world_seed ^ 0x5EED_FA11

	var zones: Array[Dictionary] = []
	for biome_id: String in (declaration.get("biomes", []) as Array):
		var biome: Dictionary = GameData.biomes.get(biome_id, {})
		if not biome.is_empty():
			zones.append(biome)
	if zones.is_empty():
		push_warning("RiftBuilder : aucun biome déclaré pour cette dimension.")
		return Vector3.ZERO

	# Les bruits : un pour le relief, un pour le découpage en pays. Le second
	# est BEAUCOUP plus lisse — sans ça, les biomes se mélangeraient tous les
	# dix blocs et aucun pays ne se lirait comme un pays.
	var height_noise := FastNoiseLite.new()
	height_noise.seed = world_seed ^ 0x11AA
	height_noise.frequency = 0.012
	height_noise.fractal_octaves = 4
	var zone_noise := FastNoiseLite.new()
	zone_noise.seed = world_seed ^ 0x22BB
	zone_noise.frequency = 0.0035
	var warp_noise := FastNoiseLite.new()
	warp_noise.seed = world_seed ^ 0x33CC
	warp_noise.frequency = 0.02

	var top_of := {}          # Vector2i(x,z) -> altitude du sol.
	var zone_of := {}         # Vector2i(x,z) -> index de biome.
	for x in range(-HALF_SPAN, HALF_SPAN + 1):
		for z in range(-HALF_SPAN, HALF_SPAN + 1):
			var key := Vector2i(x, z)
			var zi := _zone_at(zone_noise, x, z, zones.size())
			zone_of[key] = zi
			top_of[key] = _height_at(height_noise, warp_noise,
					String((zones[zi] as Dictionary).get("relief", "doux")), x, z)

	# On écrit la croûte : surface + roche en dessous. Sans épaisseur, le monde
	# serait une feuille de papier qu'on traverse au premier coup de pioche.
	for key: Vector2i in top_of:
		var zone: Dictionary = zones[zone_of[key]]
		var ground: int = GameData.material_runtime_ids.get(
				String(zone.get("surface_material", "")), 0)
		var rock: int = GameData.material_runtime_ids.get(
				String(zone.get("subsurface_material", "")), 0)
		var accent: int = GameData.material_runtime_ids.get(
				String(zone.get("accent_material", "")), 0)
		if ground == 0 or rock == 0:
			continue
		var top: int = top_of[key]
		DimensionManager.set_block_in(dimension, Vector3i(key.x, top, key.y), ground, false)
		for d in range(1, CRUST + 1):
			var id := rock
			# Veines de cristal : la dimension n'a pas de soleil, ce sont elles
			# qui l'éclairent depuis les parois et les creux.
			if accent != 0 and _edge_noise(Vector3i(key.x, top - d, key.y), world_seed) < 0.04:
				id = accent
			DimensionManager.set_block_in(dimension, Vector3i(key.x, top - d, key.y), id, false)

	DimensionManager.remesh_all(dimension)

	# La flore, une fois le sol en place : elle a besoin de savoir où il est.
	_plant_world(dimension, zones, top_of, zone_of, rng, world_seed)
	DimensionManager.remesh_all(dimension)

	var landing := Vector3(0.5, float(top_of[Vector2i(0, 0)]) + 2.5, 0.5)
	_populate(dimension, landing, declaration, rng)
	return landing


## Altitude du sol en (x, z), selon le relief du pays.
##
## Le RELIEF N'EST PAS GÉOLOGIQUE, et c'est voulu : des terrasses franches, des
## dômes qui se posent les uns sur les autres, des flèches. La Terre ne fait pas
## ça — c'est précisément pour ça que le lieu se lit comme un rêve.
static func _height_at(height_noise: FastNoiseLite, warp_noise: FastNoiseLite,
		relief: String, x: int, z: int) -> int:
	# Déformation du domaine : on tord les coordonnées avant d'échantillonner,
	# ce qui courbe les crêtes au lieu de les laisser filer droit.
	var wx := float(x) + warp_noise.get_noise_2d(float(x), float(z)) * 18.0
	var wz := float(z) + warp_noise.get_noise_2d(float(z), float(x)) * 18.0
	var n := height_noise.get_noise_2d(wx, wz)          # -1 .. 1
	var h := float(BASE_Y) + n * RELIEF
	match relief:
		"tordu":
			# CRÊTES : la valeur absolue du bruit fait des arêtes vives au lieu
			# de collines molles, et l'exposant les rend franchement acérées.
			h = float(BASE_Y) + pow(absf(n), 0.55) * RELIEF * 1.5
		"champignon":
			# TERRASSES : on quantifie l'altitude par paliers de six blocs, ce
			# qui donne les plateaux étagés du croquis. Le surplomb, lui, vient
			# des flèches posées par-dessus.
			h = float(BASE_Y) + floor(n * RELIEF / 6.0) * 6.0
		"bulbeux":
			# DÔMES : le sinus rend des bosses régulières qui se recouvrent, à
			# mi-chemin entre la colline et la bulle de savon.
			h = float(BASE_Y) + sin(n * PI) * RELIEF * 0.8
		_:
			h = float(BASE_Y) + n * RELIEF * 0.6
	return int(round(h))


## Index du pays en (x, z). Un bruit très lisse, donc de grands territoires.
static func _zone_at(zone_noise: FastNoiseLite, x: int, z: int, count: int) -> int:
	var n := zone_noise.get_noise_2d(float(x), float(z)) * 0.5 + 0.5
	return clampi(int(n * float(count)), 0, count - 1)


## Plante la végétation de chaque pays sur le sol qu'on vient d'écrire.
static func _plant_world(dimension: StringName, zones: Array[Dictionary],
		top_of: Dictionary, zone_of: Dictionary, rng: RandomNumberGenerator,
		world_seed: int) -> void:
	var index := 0
	for key: Vector2i in top_of:
		index += 1
		var zone: Dictionary = zones[zone_of[key]]
		var vegetation: Array = zone.get("vegetation", [])
		if vegetation.is_empty():
			continue
		for entry: Dictionary in vegetation:
			# Un tirage par colonne et par essence : c'est la densité du biome,
			# au même format que l'overworld.
			if rng.randf() >= float(entry.get("density", 0.0)) * 0.35:
				continue
			var species: Dictionary = GameData.trees.get(String(entry["id"]), {})
			if species.is_empty():
				continue
			var base := Vector3i(key.x, int(top_of[key]) + 1, key.y)
			var tree := TreeGenerator.generate(base, world_seed + index, species)
			var blocks: Dictionary = tree["blocks"]
			for pos: Vector3i in blocks:
				DimensionManager.set_block_in(dimension, pos, blocks[pos], false)
			break   # Une essence par colonne : deux arbres au même endroit se
					# traversent, et ça se voit tout de suite.


## LA FLORE D'UNE ZONE, plantée sur son îlot.
##
## On réutilise `TreeGenerator` tel quel : les arbres de rêve sont des fiches
## d'essence comme les autres, avec des ports poussés à l'absurde. Rien dans le
## générateur n'a eu besoin de savoir qu'il existait une dimension magique —
## c'est exactement ce que valait la peine de généraliser l'architecture.
static func _plant_zone(dimension: StringName, center: Vector3i, radius: int,
		zone: Dictionary, rng: RandomNumberGenerator, seed_value: int) -> void:
	# La végétation d'un biome, au format commun : { id, density }.
	var vegetation: Array = zone.get("vegetation", [])
	if vegetation.is_empty():
		return
	var total_density := 0.0
	for entry: Dictionary in vegetation:
		total_density += float(entry.get("density", 0.0))
	var attempts := int(float(radius * radius) * total_density) + 1
	for i in attempts:
		var angle := rng.randf() * TAU
		var distance := sqrt(rng.randf()) * float(radius - 2)
		var x := center.x + roundi(cos(angle) * distance)
		var z := center.z + roundi(sin(angle) * distance)
		var top := _surface_top(dimension, x, center.y + 4, z)
		if top == -(1 << 30):
			continue
		var pick: Dictionary = vegetation[rng.randi() % vegetation.size()]
		var species_id := String(pick["id"])
		var species: Dictionary = GameData.trees.get(species_id, {})
		if species.is_empty():
			continue
		var tree := TreeGenerator.generate(Vector3i(x, top, z), seed_value + i, species)
		var blocks: Dictionary = tree["blocks"]
		for pos: Vector3i in blocks:
			DimensionManager.set_block_in(dimension, pos, blocks[pos], false)


## Sommet plein de la colonne (x, z) en partant de `from_y`, ou -INF.
static func _surface_top(dimension: StringName, x: int, from_y: int, z: int) -> int:
	for dy in range(from_y, from_y - 90, -1):
		if DimensionManager.block_at_in(dimension, Vector3i(x, dy, z)) != 0:
			return dy + 1
	return -(1 << 30)


## CE QU'ON RENCONTRE ET CE QU'ON RAMASSE.
##
## Le bestiaire est humain — il n'y a pas de créatures de rêve à y mettre. On y
## pose donc ce qui reste cohérent : des gens entrés qui n'en sont pas
## ressortis. Ce n'est pas un pis-aller, c'est une lecture du lieu.
static func _populate(dimension: StringName, arrival: Vector3, declaration: Dictionary,
		rng: RandomNumberGenerator) -> void:
	var spawns: Array = declaration.get("habitants", [])
	for entry: String in spawns:
		if not GameData.creatures.has(entry):
			continue
		var angle := rng.randf() * TAU
		var distance := rng.randf_range(6.0, 16.0)
		var spot := arrival + Vector3(cos(angle) * distance, 0.0, sin(angle) * distance)
		var top := _surface_top(dimension, roundi(spot.x), roundi(arrival.y) + 40, roundi(spot.z))
		if top == -(1 << 30):
			continue
		spot.y = float(top)
		var creature := CreatureManager.spawn(entry, spot)
		if creature != null:
			creature.dimension = dimension

	# Butin : les cristaux du lieu, qui ne poussent nulle part ailleurs.
	var biome_ids: Array = declaration.get("biomes", [])
	for i in rng.randi_range(4, 7):
		if biome_ids.is_empty():
			break
		var zone: Dictionary = GameData.biomes.get(
				String(biome_ids[rng.randi() % biome_ids.size()]), {})
		var prize := String(zone.get("accent_material", ""))
		if prize == "":
			continue
		var angle := rng.randf() * TAU
		var distance := rng.randf_range(8.0, 40.0)
		var spot := arrival + Vector3(cos(angle) * distance, 0.0, sin(angle) * distance)
		var top := _surface_top(dimension, roundi(spot.x), roundi(arrival.y) + 40, roundi(spot.z))
		if top == -(1 << 30):
			continue
		DropManager.drop_materials(Vector3(spot.x, float(top) + 0.5, spot.z),
				{prize: rng.randi_range(4, 12)})


## Bruit déterministe [0,1) — même hachage que le feuillage des arbres, pour
## que deux systèmes qui rongent un bord le fassent de la même façon.
static func _edge_noise(pos: Vector3i, seed_value: int) -> float:
	var v := (pos.x * 668265263) ^ (pos.y * 374761393) ^ (pos.z * 2246822519) ^ seed_value
	v = (v ^ (v >> 13)) * 1274126177
	return float(v & 0xFFFFFF) / float(0xFFFFFF)
