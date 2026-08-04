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

	# LES ZONES SONT DES BIOMES (2026-08-04). Elles étaient une liste propre à ce
	# constructeur ; ce sont maintenant de vraies fiches de biome, déclarées
	# `dimension: magique`. Un seul mécanisme de végétation pour tout le jeu, et
	# la sonde qui exige qu'une essence pousse dans un biome redevient valable
	# pour TOUTES les essences, sans exemption à plaider.
	var zones: Array[Dictionary] = []
	for biome_id: String in (declaration.get("biomes", []) as Array):
		var biome: Dictionary = GameData.biomes.get(biome_id, {})
		if not biome.is_empty():
			zones.append(biome)
	if zones.is_empty():
		push_warning("RiftBuilder : aucun biome déclaré pour cette dimension.")
		return Vector3.ZERO
	var islands: Dictionary = declaration.get("islands", {})
	var count := int(islands.get("count", 12))
	var radius_range: Array = islands.get("radius", [8, 18])
	var thickness_range: Array = islands.get("thickness", [4, 8])
	var spread := float(islands.get("spread", 110))

	var arrival := Vector3.ZERO
	for i in count:
		# CHAQUE ÎLOT APPARTIENT À UNE ZONE, et les zones se succèdent au lieu
		# d'être tirées au hasard : un monde de rêve doit se lire comme une
		# suite de pays, pas comme une soupe. On tourne dans la liste, ce qui
		# garantit que les quatre existent même sur peu d'îlots.
		var zone: Dictionary = zones[i % zones.size()]
		var center := ORIGIN
		var radius := int(radius_range[1])
		if i > 0:
			center = ORIGIN + Vector3i(
					roundi(rng.randf_range(-spread, spread)),
					roundi(rng.randf_range(-30.0, 34.0)),
					roundi(rng.randf_range(-spread, spread)))
			radius = rng.randi_range(int(radius_range[0]), int(radius_range[1]))
		var thickness := rng.randi_range(int(thickness_range[0]), int(thickness_range[1]))
		# UN ROCHER-CHAMPIGNON A BESOIN DE HAUTEUR. Son intérêt est le surplomb,
		# et un chapeau posé sur trois blocs de pied ne surplombe rien : on
		# triple l'épaisseur pour cette zone-là.
		if String(zone.get("relief", "")) == "champignon":
			thickness *= 3
		_carve_island(dimension, center, radius, thickness, zone, rng)
		_plant_zone(dimension, center, radius, zone, rng, world_seed + i)
		if i == 0:
			arrival = Vector3(center) + Vector3(0.5, thickness + 2.5, 0.5)

	DimensionManager.remesh_all(dimension)
	_populate(dimension, arrival, declaration, rng)
	return arrival


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
	for dy in range(from_y, from_y - 30, -1):
		if DimensionManager.block_at_in(dimension, Vector3i(x, dy, z)) != 0:
			return dy + 1
	return -(1 << 30)


## Un îlot : un disque de sol qui s'effile vers le bas en pointe rocheuse, avec
## quelques veines lumineuses. La pointe est ce qui le fait lire comme un
## morceau arraché plutôt que comme une galette posée sur rien.
static func _carve_island(dimension: StringName, center: Vector3i, radius: int,
		thickness: int, zone: Dictionary, rng: RandomNumberGenerator) -> void:
	var ground: int = GameData.material_runtime_ids.get(String(zone.get("surface_material", "")), 0)
	var rock: int = GameData.material_runtime_ids.get(String(zone.get("sub_material", "")), 0)
	var accent: int = GameData.material_runtime_ids.get(String(zone.get("accent_material", "")), 0)
	if ground == 0 or rock == 0:
		return
	var relief := String(zone.get("relief", "doux"))
	var seed_value := rng.randi()

	for depth in thickness:
		var t := float(depth) / float(maxi(thickness, 1))
		var level_radius := radius
		match relief:
			"bulbeux":
				# COLLINE EN BULBE : le rayon GONFLE sous la surface avant de se
				# refermer. Ça donne un îlot en goutte, impossible en géologie
				# et immédiatement lisible comme un décor de rêve.
				level_radius = int(round(radius * (1.0 + 0.35 * sin(t * PI)) * (1.0 - t * 0.55)))
			"champignon":
				# ROCHER-CHAMPIGNON (croquis de l'auteur) : un CHAPEAU LARGE
				# posé sur un PIED ÉTROIT, avec un surplomb franc. C'est le
				# profil de Zhangjiajie, et il est impossible à obtenir en
				# affinant vers le bas — il faut PINCER juste sous la surface
				# puis tenir le pied fin sur toute la hauteur.
				if t < 0.22:
					level_radius = radius                       # le chapeau
				else:
					var pinch := (t - 0.22) / 0.78
					level_radius = maxi(2, int(round(radius * lerpf(0.9, 0.22, pinch))))
			"tordu":
				level_radius = int(round(radius * (1.0 - t * 0.85)))
			_:
				level_radius = int(round(radius * (1.0 - t * 0.9)))
		if depth == 0:
			level_radius = radius
		# DÉRIVE LATÉRALE : chaque couche est décalée, si bien que la pointe de
		# l'îlot part en vrille au lieu de tomber à l'aplomb. C'est ce qui fait
		# la « montagne tordue » demandée.
		var lean := Vector3i.ZERO
		if relief == "tordu":
			lean = Vector3i(roundi(sin(t * 5.0) * float(radius) * 0.45), 0,
					roundi(cos(t * 4.0) * float(radius) * 0.45))
		for dx in range(-level_radius, level_radius + 1):
			for dz in range(-level_radius, level_radius + 1):
				if dx * dx + dz * dz > level_radius * level_radius:
					continue
				if depth == 0 and _edge_noise(center + Vector3i(dx, 0, dz), seed_value) < 0.18 \
						and dx * dx + dz * dz > (level_radius - 1) * (level_radius - 1):
					continue
				var pos := center + lean + Vector3i(dx, -depth, dz)
				var id := ground if depth == 0 else rock
				# Veines de cristal : la dimension n'a pas de soleil, ce sont
				# elles qui l'éclairent — et elles remplacent la scorie ardente
				# du premier jet, écartée pour rester à l'écart de tout ce qui
				# évoque la lave.
				if depth > 0 and accent != 0 and _edge_noise(pos, seed_value + 7) < 0.05:
					id = accent
				DimensionManager.set_block_in(dimension, pos, id, false)

	# FLÈCHES TORDUES au-dessus des cimes : des aiguilles qui montent en
	# spirale, sans aucun aplomb. Le relief « tordu » ne serait qu'un cône
	# penché sans elles.
	if relief == "tordu":
		var spires := rng.randi_range(2, 4)
		for i in spires:
			var angle := rng.randf() * TAU
			var base := center + Vector3i(
					roundi(cos(angle) * float(radius) * 0.4), 1,
					roundi(sin(angle) * float(radius) * 0.4))
			var height := rng.randi_range(8, 20)
			for h in height:
				var twist := float(h) * 0.55 + angle
				var sway := float(h) * 0.22
				var pos := base + Vector3i(roundi(cos(twist) * sway), h,
						roundi(sin(twist) * sway))
				var thick := maxi(0, 2 - h / 7)
				for ox in range(-thick, thick + 1):
					for oz in range(-thick, thick + 1):
						DimensionManager.set_block_in(dimension,
								pos + Vector3i(ox, 0, oz),
								accent if (h % 5 == 0 and accent != 0) else rock, false)


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
		var top := _surface_top(dimension, roundi(spot.x), roundi(arrival.y) + 4, roundi(spot.z))
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
		var top := _surface_top(dimension, roundi(spot.x), roundi(arrival.y) + 4, roundi(spot.z))
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
