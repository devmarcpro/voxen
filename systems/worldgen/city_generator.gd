class_name CityGenerator
extends RefCounted
## Génération de villes (point 5 du programme 2026-07-21, demande explicite) —
## classe statique pure (comme TreeGenerator/POIGenerator). Une ville est un
## damier de STRUCTURES 16×16 (routes + bâtiments) posé dans le footprint d'un
## village (POIGenerator). CLÉ D'ARCHITECTURE : une cellule de 128 blocs fait
## exactement 8×8 chunks, donc UNE tuile de ville (16×16) = UNE colonne de
## chunk. Chaque bâtiment tient dans sa tuile → aucune structure à cheval sur
## plusieurs chunks horizontalement, la génération reste locale et bon marché.
##
## LOGIQUE DEMANDÉE :
## - Routes en CROIX (rangée + colonne centrales du footprint) → réseau
##   connexe atteignant les 4 bords du footprint = 4 entrées/sorties (≥2 exigé).
## - Bâtiments = tuiles NON-route ADJACENTES à une route (ils entourent les
##   routes), porte tournée vers la route adjacente.
## - Nombre de bâtiments dérivé de la POPULATION (target = ceil(pop/RESIDENTS)).
## - Le TERRASSEMENT (aplatir le site) se fait dans la fonction de hauteur du
##   générateur (NoiseGenerator), PAS par des milliers d'éditions de blocs —
##   recommandation validée : plateau unique + jupe de fondation automatique
##   (le remplissage sous le plateau est le terrain normal, la coupe au-dessus
##   est de l'air), site choisi plat (rejet des pentes fortes, NoiseGenerator).

const TILES_PER_CELL := 8
const SEED_CITY := 61879
const SEED_CITY_SIZE := 61880
const RESIDENTS_PER_BUILDING := 3

## Footprint (tuiles de côté) par catégorie — TOUJOURS ≤ 5 pour garder au
## moins 1 tuile de marge dans la cellule 8×8 (offset ≥ 1) : le footprint ne
## touche jamais le bord de cellule, donc le plateau unique ne crée aucune
## couture de terrassement entre cellules voisines.
const FOOTPRINT := {"hameau": 3, "village": 5, "ville": 5}
const POP_RANGE := {"hameau": [4, 8], "village": [8, 20], "ville": [20, 40]}

## Bâtiment dans sa tuile 16×16 : boîte [B_LO..B_HI] (3 blocs de marge au bord
## de tuile → les murs ne touchent jamais la frontière de chunk, aucune
## couture horizontale). Plancher = le sol terrassé lui-même (non posé).
const B_LO := 3
const B_HI := 12
const B_HEIGHT := 4          # Hauteur des murs (plancher exclu).


## Catégorie de taille d'un village en `cell` (déterministe, seed dédiée).
static func size_category(cell: Vector2i, world_seed: int) -> String:
	var roll := NoiseGenerator.pcg_hash(cell.x, cell.y, world_seed + SEED_CITY_SIZE) % 100
	if roll < 35:
		return "hameau"
	if roll >= 85:
		return "ville"
	return "village"


## Plan de tuiles d'une ville (pur, sans terrain) :
## { "T", "offset", "types" (PackedByteArray T*T : 0 vide/place, 1 route,
##   2 bâtiment), "doors" (idx tuile → Vector3i direction route), "population",
##   "buildings" }.
static func tile_plan(cell: Vector2i, world_seed: int, category: String) -> Dictionary:
	var t: int = FOOTPRINT.get(category, 5)
	@warning_ignore("integer_division")
	var offset := (TILES_PER_CELL - t) / 2
	var rng := RandomNumberGenerator.new()
	rng.seed = NoiseGenerator.pcg_hash(cell.x, cell.y, world_seed + SEED_CITY)

	var pop_range: Array = POP_RANGE.get(category, [8, 20])
	var population := rng.randi_range(pop_range[0], pop_range[1])
	var target_buildings := int(ceil(population / float(RESIDENTS_PER_BUILDING)))

	var types := PackedByteArray()
	types.resize(t * t)
	@warning_ignore("integer_division")
	var center := (t - 1) / 2   # T impair → centre entier.
	for i in t:
		types[center * t + i] = 1  # Rangée centrale (route horizontale).
		types[i * t + center] = 1  # Colonne centrale (route verticale).

	# Bâtiments : tuiles non-route adjacentes à une route, dans un ordre
	# déterministe mélangé, jusqu'à atteindre le nombre cible.
	var order: Array[Vector2i] = []
	for tz in t:
		for tx in t:
			order.append(Vector2i(tx, tz))
	for i in range(order.size() - 1, 0, -1):
		var j := rng.randi() % (i + 1)
		var tmp := order[i]
		order[i] = order[j]
		order[j] = tmp

	var doors := {}
	var built := 0
	for tile: Vector2i in order:
		if built >= target_buildings:
			break
		var idx := tile.y * t + tile.x
		if types[idx] != 0:
			continue
		var road_dir := _adjacent_road_dir(types, t, tile.x, tile.y)
		if road_dir == Vector3i.ZERO:
			continue
		types[idx] = 2
		doors[idx] = road_dir
		built += 1

	return {"T": t, "offset": offset, "types": types, "doors": doors,
		"population": population, "buildings": built}


## Direction (monde, XZ) vers une tuile route orthogonalement adjacente, ou
## Vector3i.ZERO si aucune — sert à orienter la porte du bâtiment.
static func _adjacent_road_dir(types: PackedByteArray, t: int, tx: int, tz: int) -> Vector3i:
	if tx + 1 < t and types[tz * t + tx + 1] == 1:
		return Vector3i(1, 0, 0)
	if tx - 1 >= 0 and types[tz * t + tx - 1] == 1:
		return Vector3i(-1, 0, 0)
	if tz + 1 < t and types[(tz + 1) * t + tx] == 1:
		return Vector3i(0, 0, 1)
	if tz - 1 >= 0 and types[(tz - 1) * t + tx] == 1:
		return Vector3i(0, 0, -1)
	return Vector3i.ZERO


## Blocs LOCAUX d'un bâtiment dans sa tuile : Vector3i(lx, ly, lz) → id, avec
## lx/lz dans 0..15 (position dans la tuile = position dans le chunk) et ly
## RELATIF au sommet du plateau (ly=1 = un bloc au-dessus du sol terrassé).
## Murs (`mur`) sur le périmètre, toit (`toit`) en dalle, porte de 2 de haut
## ouverte vers la route. Le plancher n'est PAS posé (c'est le sol terrassé).
static func building_blocks(door_dir: Vector3i, palette: Dictionary) -> Dictionary:
	var mur: int = palette["mur"]
	var toit: int = palette["toit"]
	var blocks := {}
	for x in range(B_LO, B_HI + 1):
		for z in range(B_LO, B_HI + 1):
			var is_wall := x == B_LO or x == B_HI or z == B_LO or z == B_HI
			if is_wall:
				for y in range(1, B_HEIGHT + 1):
					blocks[Vector3i(x, y, z)] = mur
			blocks[Vector3i(x, B_HEIGHT + 1, z)] = toit  # Dalle de toit.
	# Porte : ouverture 2 de haut au centre du mur tourné vers la route.
	@warning_ignore("integer_division")
	var c := (B_LO + B_HI) / 2
	var door_cells: Array[Vector3i] = []
	if door_dir.x > 0:
		door_cells = [Vector3i(B_HI, 1, c), Vector3i(B_HI, 2, c)]
	elif door_dir.x < 0:
		door_cells = [Vector3i(B_LO, 1, c), Vector3i(B_LO, 2, c)]
	elif door_dir.z > 0:
		door_cells = [Vector3i(c, 1, B_HI), Vector3i(c, 2, B_HI)]
	else:
		door_cells = [Vector3i(c, 1, B_LO), Vector3i(c, 2, B_LO)]
	for cell: Vector3i in door_cells:
		blocks.erase(cell)
	return blocks
