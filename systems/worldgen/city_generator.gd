class_name CityGenerator
extends RefCounted
## Génération des villages PNJ (3.3/3.4). REFONTE COMPLÈTE du 2026-08-01.
##
## CE QUI N'ALLAIT PAS DANS LA VERSION PRÉCÉDENTE, constaté sur capture. Un
## village, c'était : un disque de terre nue, une croix de gravier, et TROIS
## boîtes creuses identiques de 10×10, quatre blocs de haut, toit plat, un trou
## de porte, aucune fenêtre, aucun plancher. Les trois quarts du site restaient
## vides.
##
## Trois causes distinctes, et il fallait les traiter toutes les trois :
##
##   1. TROP PEU DE BÂTIMENTS. Le nombre était `population / 3`, donc 3 maisons
##      pour un village de 8 habitants, posées sur 12 emplacements disponibles.
##      Un village aux trois quarts vide ne se lit pas comme un village mais
##      comme un chantier abandonné. Désormais AUCUN emplacement ne reste nu :
##      ce qui n'est pas bâti devient champ ou place.
##   2. UN SEUL TYPE DE BÂTIMENT. Toutes les maisons étaient la même boîte. La
##      variété passe maintenant par des ARCHÉTYPES (maison, longère, atelier,
##      grange, halle) qui diffèrent par l'emprise, la hauteur et la toiture.
##   3. AUCUN DÉTAIL DE CONSTRUCTION. Pas de toit en pente, pas de fenêtre, pas
##      de plancher, pas de poutre. C'est ce qui faisait « boîte » plutôt que
##      « maison », bien plus que la taille ou le nombre.
##
## CE QUI EST CONSERVÉ, et pourquoi. La clé d'architecture d'origine tient
## toujours : une cellule de 128 blocs = 8×8 chunks, donc UNE tuile de village
## (16×16) = UNE colonne de chunk. Aucune structure n'est à cheval sur deux
## chunks horizontalement, la génération reste locale et bon marché. Le
## terrassement reste un plateau unique calculé dans la fonction de hauteur,
## jamais des milliers d'éditions de blocs.

const TILES_PER_CELL := 8
const SEED_CITY := 61879
const SEED_CITY_SIZE := 61880

## Rôles de tuile. Le générateur de terrain lit ces valeurs pour choisir le
## matériau de surface : ce ne sont donc pas de simples étiquettes.
enum Tile { VIDE, ROUTE, BATIMENT, CHAMP, PLACE }

## Footprint (tuiles de côté) par catégorie. TOUJOURS ≤ 6 : avec un décalage
## d'au moins 1, le plateau ne touche jamais le bord de cellule, donc aucune
## couture de terrassement entre cellules voisines.
##
## La ville passe de 5 à 6 : à 5 tuiles elle avait exactement la même emprise
## qu'un village, ce qui rendait la catégorie invisible en jeu alors que le GDD
## (3.4) lui donne une capacité trois fois supérieure.
const FOOTPRINT := {"hameau": 3, "village": 5, "ville": 6}
const POP_RANGE := {"hameau": [4, 8], "village": [8, 20], "ville": [20, 40]}

## Habitants par bâtiment d'habitation. 2 et non 3 : à 3, un village de 8 âmes
## n'avait que 3 maisons. Une maison de village abrite un foyer, pas un dortoir.
const RESIDENTS_PER_BUILDING := 2

## Hauteur maximale atteinte par une construction au-dessus du plateau (faîtage
## de la halle). Sert au calcul de la borne haute du monde généré : la
## sous-estimer TRONQUE les toits, ce qui ne se voit qu'en jeu et de loin.
const MAX_BUILD_HEIGHT := 14

## Conservées pour les sondes existantes, qui mesurent l'emprise d'une maison
## standard. Ce ne sont plus les seules dimensions possibles.
const B_HEIGHT := 4
const B_LO := 4
const B_HI := 11


## Catégorie de taille d'un village en `cell` (déterministe, seed dédiée).
static func size_category(cell: Vector2i, world_seed: int) -> String:
	var roll := NoiseGenerator.pcg_hash(cell.x, cell.y, world_seed + SEED_CITY_SIZE) % 100
	if roll < 35:
		return "hameau"
	if roll >= 85:
		return "ville"
	return "village"


## Plan de tuiles d'un village (pur, sans terrain).
##
## Retourne { "T", "offset", "types" (PackedByteArray, valeurs de Tile),
## "doors" (idx → direction de la route), "archetypes" (idx → nom),
## "population", "buildings" }.
static func tile_plan(cell: Vector2i, world_seed: int, category: String) -> Dictionary:
	var t: int = FOOTPRINT.get(category, 5)
	@warning_ignore("integer_division")
	var offset := (TILES_PER_CELL - t) / 2
	var types := PackedByteArray()
	types.resize(t * t)
	types.fill(Tile.VIDE)

	var rng := RandomNumberGenerator.new()
	rng.seed = NoiseGenerator.pcg_hash(cell.x, cell.y, world_seed + SEED_CITY)

	# --- 1. Les RUES ---------------------------------------------------------
	#
	# Une croix centrale traversant tout le footprint : le réseau est connexe et
	# atteint les quatre bords, donc quatre entrées (le GDD en exige au moins
	# deux). Pour une ville, on ajoute une seconde paire d'axes — c'est ce qui
	# fait la différence de silhouette entre un village et une ville, bien plus
	# que le seul nombre de maisons.
	@warning_ignore("integer_division")
	var center := t / 2
	var road_rows := [center]
	var road_cols := [center]
	if t >= 6:
		road_rows.append(0)
		road_cols.append(t - 1)
	for tz in t:
		for tx in t:
			if tx in road_cols or tz in road_rows:
				types[tz * t + tx] = Tile.ROUTE

	# --- 2. La PLACE centrale ------------------------------------------------
	#
	# Un village a un centre. C'est là qu'on le revendique (3.4), donc il doit se
	# repérer d'un coup d'œil : la place est pavée et la halle la borde. Sans
	# point focal, un village n'est qu'un alignement de maisons.
	types[center * t + center] = Tile.PLACE

	# --- 3. Les PARCELLES ----------------------------------------------------
	#
	# Toute tuile non-route TOUCHANT une route est constructible. Les tuiles
	# enclavées (les coins lointains, qu'aucune rue ne dessert) deviennent des
	# champs : elles restaient auparavant en terre nue, ce qui était le principal
	# responsable de l'impression de vide.
	var plots: Array[int] = []
	var landlocked: Array[int] = []
	for tz in t:
		for tx in t:
			var idx := tz * t + tx
			if types[idx] != Tile.VIDE:
				continue
			if _adjacent_road_dir(types, t, tx, tz) == Vector3i.ZERO:
				landlocked.append(idx)
			else:
				plots.append(idx)

	# Ordre de bâtisse mélangé : sans ça, les maisons se posent toujours dans le
	# même coin et les champs finissent tous du même côté.
	_shuffle(plots, rng)

	var pop_range: Array = POP_RANGE.get(category, [8, 20])
	var population := rng.randi_range(int(pop_range[0]), int(pop_range[1]))
	var target := ceili(float(population) / float(RESIDENTS_PER_BUILDING))

	var doors := {}
	var archetypes := {}
	var built := 0

	# LA HALLE d'abord, sur une parcelle qui borde la place : c'est le bâtiment
	# repère, il ne peut pas être relégué au hasard en périphérie.
	var hall_idx := _plot_next_to(plots, t, center)
	if hall_idx >= 0:
		types[hall_idx] = Tile.BATIMENT
		@warning_ignore("integer_division")
		var hall_dir := _adjacent_road_dir(types, t, hall_idx % t, hall_idx / t)
		doors[hall_idx] = hall_dir
		archetypes[hall_idx] = "halle"
		plots.erase(hall_idx)
		built += 1

	for idx: int in plots:
		if built >= target:
			break
		types[idx] = Tile.BATIMENT
		@warning_ignore("integer_division")
		var dir := _adjacent_road_dir(types, t, idx % t, idx / t)
		doors[idx] = dir
		archetypes[idx] = _pick_archetype(rng)
		built += 1

	# --- 4. Ce qui reste : des CHAMPS, jamais du vide ------------------------
	for idx: int in plots:
		if types[idx] == Tile.VIDE:
			types[idx] = Tile.CHAMP
	for idx: int in landlocked:
		types[idx] = Tile.CHAMP

	return {"T": t, "offset": offset, "types": types, "doors": doors,
		"archetypes": archetypes, "population": population, "buildings": built}


static func _shuffle(values: Array[int], rng: RandomNumberGenerator) -> void:
	for i in range(values.size() - 1, 0, -1):
		var j := rng.randi_range(0, i)
		var swap := values[i]
		values[i] = values[j]
		values[j] = swap


## Parcelle orthogonalement adjacente à la tuile centrale, ou -1.
static func _plot_next_to(plots: Array[int], t: int, center: int) -> int:
	for idx: int in plots:
		var tx := idx % t
		@warning_ignore("integer_division")
		var tz := idx / t
		if absi(tx - center) + absi(tz - center) == 1:
			return idx
	return plots[0] if not plots.is_empty() else -1


## Direction (monde, XZ) vers une tuile route orthogonalement adjacente, ou
## Vector3i.ZERO si aucune — sert à orienter la façade du bâtiment.
static func _adjacent_road_dir(types: PackedByteArray, t: int, tx: int, tz: int) -> Vector3i:
	if tx + 1 < t and types[tz * t + tx + 1] == Tile.ROUTE:
		return Vector3i(1, 0, 0)
	if tx - 1 >= 0 and types[tz * t + tx - 1] == Tile.ROUTE:
		return Vector3i(-1, 0, 0)
	if tz + 1 < t and types[(tz + 1) * t + tx] == Tile.ROUTE:
		return Vector3i(0, 0, 1)
	if tz - 1 >= 0 and types[(tz - 1) * t + tx] == Tile.ROUTE:
		return Vector3i(0, 0, -1)
	return Vector3i.ZERO


# --- Archétypes de bâtiment --------------------------------------------------
#
# Chacun décrit une EMPRISE dans sa tuile 16×16, une hauteur de mur et un type
# de toit. La variété vient d'abord de la SILHOUETTE : deux maisons de même
# palette mais de proportions différentes se lisent comme deux maisons, deux
# boîtes identiques se lisent comme une répétition.
#
#   marge : distance au bord de tuile (≥ 2 pour ne jamais toucher la frontière
#           de chunk — c'est ce qui garantit qu'aucune structure ne déborde,
#           débord de toit compris)
#   murs  : hauteur des murs au-dessus du plancher
#   toit  : "pignon" (deux pans, faîtage sur X) ou "croupe" (quatre pans)
#   etage : vrai = un second rang de fenêtres

const ARCHETYPES := {
	"maison":       {"marge": 4, "murs": 4, "toit": "pignon", "etage": false, "pans": 2},
	"longere":      {"marge": 3, "murs": 4, "toit": "pignon", "etage": false, "pans": 3},
	"atelier":      {"marge": 4, "murs": 5, "toit": "croupe", "etage": false, "pans": 2},
	"grange":       {"marge": 3, "murs": 6, "toit": "pignon", "etage": false, "pans": 3},
	"maison_etage": {"marge": 4, "murs": 7, "toit": "pignon", "etage": true, "pans": 2},
	"halle":        {"marge": 2, "murs": 6, "toit": "croupe", "etage": true, "pans": 4},
}

## Tirage pondéré des archétypes d'habitation. La maison domine — un village
## fait de granges et d'ateliers n'aurait personne pour y vivre.
const ARCHETYPE_WEIGHTS := [
	["maison", 40], ["longere", 20], ["maison_etage", 15],
	["atelier", 15], ["grange", 10],
]


static func _pick_archetype(rng: RandomNumberGenerator) -> String:
	var total := 0
	for entry: Array in ARCHETYPE_WEIGHTS:
		total += int(entry[1])
	var roll := rng.randi_range(0, total - 1)
	for entry: Array in ARCHETYPE_WEIGHTS:
		roll -= int(entry[1])
		if roll < 0:
			return String(entry[0])
	return "maison"


## Blocs LOCAUX d'un bâtiment dans sa tuile : Vector3i(lx, ly, lz) → id, avec
## lx/lz dans 0..15 (position dans la tuile = position dans le chunk) et ly
## RELATIF au sommet du plateau (ly = 1 : un bloc au-dessus du sol terrassé).
##
## `palette` porte `mur`, `toit`, `sol` et `poutre` (bois de structure).
static func building_blocks(door_dir: Vector3i, palette: Dictionary,
		archetype: String = "maison") -> Dictionary:
	var spec: Dictionary = ARCHETYPES.get(archetype, ARCHETYPES["maison"])
	var margin := int(spec["marge"])
	var wall_height := int(spec["murs"])
	var lo := margin
	var hi := 15 - margin
	var mur: int = palette["mur"]
	var toit: int = palette["toit"]
	var sol: int = palette["sol"]
	var poutre: int = palette.get("poutre", mur)

	var blocks := {}

	# PLANCHER. Il n'y en avait aucun : on marchait sur la terre du plateau,
	# dedans comme dehors, et rien ne distinguait l'intérieur une fois la porte
	# franchie.
	for x in range(lo, hi + 1):
		for z in range(lo, hi + 1):
			blocks[Vector3i(x, 0, z)] = sol

	# MURS, avec chaînage d'angle en poutre : les quatre arêtes verticales
	# tranchent sur le remplissage et donnent au volume une lecture de charpente
	# plutôt que de bloc plein.
	for y in range(1, wall_height + 1):
		for x in range(lo, hi + 1):
			for z in range(lo, hi + 1):
				if x != lo and x != hi and z != lo and z != hi:
					continue
				var is_corner := (x == lo or x == hi) and (z == lo or z == hi)
				blocks[Vector3i(x, y, z)] = poutre if is_corner else mur
	# Sablière : un rang de poutre en tête de mur, sous la toiture.
	for x in range(lo, hi + 1):
		for z in range(lo, hi + 1):
			if x == lo or x == hi or z == lo or z == hi:
				blocks[Vector3i(x, wall_height, z)] = poutre

	_carve_windows(blocks, lo, hi, wall_height, bool(spec["etage"]))
	_carve_door(blocks, lo, hi, door_dir, poutre)
	_add_roof(blocks, lo, hi, wall_height, String(spec["toit"]), toit, int(spec["pans"]))
	return blocks


## Perce les fenêtres. Régulières et symétriques : une tous les trois blocs sur
## chaque face, à hauteur de regard. C'est le détail qui coûte le moins cher et
## qui change le plus — un mur aveugle ne se lit jamais comme une habitation.
static func _carve_windows(blocks: Dictionary, lo: int, hi: int,
		wall_height: int, has_upper: bool) -> void:
	var rows: Array[int] = [2]
	if has_upper and wall_height >= 6:
		rows.append(wall_height - 2)
	for y: int in rows:
		if y < 1 or y >= wall_height:
			continue
		for offset in range(lo + 2, hi - 1, 3):
			blocks.erase(Vector3i(offset, y, lo))
			blocks.erase(Vector3i(offset, y, hi))
			blocks.erase(Vector3i(lo, y, offset))
			blocks.erase(Vector3i(hi, y, offset))


## Perce la porte, face à la rue, et l'encadre de poutres. L'encadrement n'est
## pas décoratif : sans lui, un trou de deux blocs dans un mur uni ne se
## distingue pas d'une fenêtre agrandie.
static func _carve_door(blocks: Dictionary, lo: int, hi: int,
		door_dir: Vector3i, poutre: int) -> void:
	@warning_ignore("integer_division")
	var c := (lo + hi) / 2
	var cells: Array[Vector3i] = []
	var frame: Array[Vector3i] = []
	if door_dir.x > 0:
		cells = [Vector3i(hi, 1, c), Vector3i(hi, 2, c)]
		frame = [Vector3i(hi, 1, c - 1), Vector3i(hi, 2, c - 1),
			Vector3i(hi, 1, c + 1), Vector3i(hi, 2, c + 1), Vector3i(hi, 3, c)]
	elif door_dir.x < 0:
		cells = [Vector3i(lo, 1, c), Vector3i(lo, 2, c)]
		frame = [Vector3i(lo, 1, c - 1), Vector3i(lo, 2, c - 1),
			Vector3i(lo, 1, c + 1), Vector3i(lo, 2, c + 1), Vector3i(lo, 3, c)]
	elif door_dir.z > 0:
		cells = [Vector3i(c, 1, hi), Vector3i(c, 2, hi)]
		frame = [Vector3i(c - 1, 1, hi), Vector3i(c - 1, 2, hi),
			Vector3i(c + 1, 1, hi), Vector3i(c + 1, 2, hi), Vector3i(c, 3, hi)]
	else:
		cells = [Vector3i(c, 1, lo), Vector3i(c, 2, lo)]
		frame = [Vector3i(c - 1, 1, lo), Vector3i(c - 1, 2, lo),
			Vector3i(c + 1, 1, lo), Vector3i(c + 1, 2, lo), Vector3i(c, 3, lo)]
	for cell: Vector3i in cells:
		blocks.erase(cell)
	for cell: Vector3i in frame:
		if blocks.has(cell):
			blocks[cell] = poutre


## Toiture. Le toit plat d'une seule dalle était le défaut le plus visible : vu
## d'en haut, un village n'était qu'une collection de rectangles.
##
## « pignon » : deux pans montant vers un faîtage, avec un débord d'un bloc — le
## débord donne l'ombre portée et empêche le toit de se confondre avec le mur.
## « croupe » : quatre pans convergents, pour les bâtiments carrés et
## remarquables (halle, atelier).
## `levels` PLAFONNE la hauteur de la toiture. Sans ce plafond, un pignon monte
## jusqu'au sommet du triangle, soit la moitié de la largeur : une maison de
## 8 blocs de large portait 5 rangs de toit sur 4 rangs de mur, et se lisait
## comme un toit posé sur un moignon. Une fois le plafond atteint, on referme
## par une croupe plate — c'est un toit tronqué, silhouette parfaitement
## courante et bien plus juste en proportion.
static func _add_roof(blocks: Dictionary, lo: int, hi: int, wall_height: int,
		style: String, toit: int, levels: int = 3) -> void:
	var eave_lo := lo - 1
	var eave_hi := hi + 1
	var base := wall_height + 1
	var level := 0
	if style == "croupe":
		while eave_lo + level <= eave_hi - level:
			var inner_lo := eave_lo + level
			var inner_hi := eave_hi - level
			var capping := level >= levels or inner_lo >= inner_hi - 1
			for x in range(inner_lo, inner_hi + 1):
				for z in range(inner_lo, inner_hi + 1):
					if capping or x == inner_lo or x == inner_hi 							or z == inner_lo or z == inner_hi:
						blocks[Vector3i(x, base + level, z)] = toit
			if capping:
				return
			level += 1
		return

	# Pignon : le faîtage suit l'axe X, les pans descendent sur Z. Les deux
	# extrémités sont refermées par un triangle de toiture — sans lui, la maison
	# reste ouverte sous les rampants.
	while eave_lo + level <= eave_hi - level:
		var z_low := eave_lo + level
		var z_high := eave_hi - level
		var capping := level >= levels or z_low >= z_high - 1
		for x in range(eave_lo, eave_hi + 1):
			for z in range(z_low, z_high + 1):
				if capping or z == z_low or z == z_high:
					blocks[Vector3i(x, base + level, z)] = toit
		# Fermeture des pignons : le triangle de mur sous les rampants. Sans
		# lui, la maison reste ouverte à ses deux extrémités.
		for z in range(z_low, z_high + 1):
			blocks[Vector3i(eave_lo, base + level, z)] = toit
			blocks[Vector3i(eave_hi, base + level, z)] = toit
		if capping:
			return
		level += 1
