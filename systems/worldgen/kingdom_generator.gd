class_name KingdomGenerator
extends RefCounted
## Royaumes PNJ (GDD 14.4 / E.27 / B.9), générés de façon DÉTERMINISTE.
##
## LE PROBLÈME QUE E.27 RÉSOUT, et qu'il faut comprendre avant de lire le code :
## un monde infini ne peut pas porter un réseau global de royaumes. On ne peut ni
## les énumérer, ni les stocker, ni calculer leurs frontières les unes par
## rapport aux autres — il n'y a pas de « toutes les capitales » à trier.
##
## La solution du GDD est le découpage en SECTEURS de 64×64 cellules. Chaque
## secteur tire ses 0 à 2 capitales tout seul, sans rien savoir de ses voisins.
## Répondre à « quel royaume possède cette cellule ? » ne demande donc que
## d'examiner le secteur courant et ses huit voisins : un travail borné, constant,
## et surtout PUREMENT NUMÉRIQUE — aucune génération de terrain n'est nécessaire.
##
## C'est cette dernière propriété qui compte le plus : la carte du monde peut
## afficher les royaumes lointains avant que le joueur n'y soit jamais allé.
##
## RIEN N'EST PERSISTÉ ICI. Un royaume généré est reproductible depuis la graine,
## exactement comme un village. Ce qui dévie — une conquête, un traité — sera
## stocké ailleurs sous forme d'écart, comme les morts d'un village.

## Côté d'un secteur, en cellules (E.27).
const SECTOR := 64
const SEED_KINGDOM := 90211
const SEED_KINGDOM_SIZE := 90212
const SEED_KINGDOM_TRAITS := 90213

## Tailles de royaume et leur poids (E.27). La distribution est délibérément
## écrasée vers le bas : « la majorité du monde est sauvage ; un royaume est un
## événement », et un grand royaume doit se raconter.
## Le troisième nombre est un BUDGET DE COÛT, pas un nombre de cellules — piège
## dans lequel je suis tombé au premier jet. Chaque pas de croissance coûte 2 à 4
## selon le relief et la corruption (`_entry_cost`), si bien qu'un budget de 1
## ne permettait même pas de sortir de la capitale : tous les royaumes du monde
## faisaient exactement une cellule, et le recensement l'a montré avant que
## quiconque ait pu le voir en jeu.
##
## Ordres de grandeur visés, à coût moyen ~3 par pas :
##   5 → une poignée de cellules · 12 → ~30 · 20 → ~90 · 32 → ~230
const SIZES := [
	["hameau_etat", 40, 5],      # capitale-village seule
	["cite_etat", 30, 12],       # capitale + 1-3 villages
	["petit_royaume", 20, 20],   # 1-2 villes, 3-6 villages
	["grand_royaume", 10, 32],   # 2-4 villes, 6-12 villages
]

## Types de gouvernance (14.4). L'anarchie est incluse : c'est elle qui rend les
## lois décoratives par construction, faute de gardes pour les appliquer.
const GOVERNMENTS := [
	"monarchie_hereditaire", "republique_elue", "theocratie",
	"ploutocratie", "dictature_militaire", "anarchie",
]

## Nombre maximal de cellules examinées lors de la croissance d'un territoire.
## Borne dure : sans elle, un grand royaume dans une plaine parfaite pourrait
## balayer un secteur entier à chaque interrogation de la carte.
## Le budget de coût borne déjà la taille ; celui-ci borne le TRAVAIL, pour le
## cas dégénéré d'une plaine parfaite où tous les pas coûtent le minimum.
const GROWTH_BUDGET := 400


## Secteur contenant cette cellule. Division ARITHMÉTIQUE et non entière
## tronquée : en coordonnées négatives, `-1 / 64` vaut 0 en GDScript, ce qui
## replierait tout le quadrant négatif sur le secteur zéro et collerait deux
## royaumes l'un dans l'autre.
static func sector_of(cell: Vector2i) -> Vector2i:
	return Vector2i(floori(float(cell.x) / float(SECTOR)),
		floori(float(cell.y) / float(SECTOR)))


## Capitales d'un secteur : liste de { "cell", "size", "radius" }.
##
## Zéro, une ou deux, tirées à la graine. Elles sont placées sur les cellules du
## secteur les plus FAVORABLES (E.27 : basse corruption, terrain praticable) —
## on n'échantillonne qu'une grille grossière, parce qu'examiner les 4 096
## cellules d'un secteur coûterait cher pour un choix qui n'a pas besoin d'être
## optimal, seulement plausible et stable.
static func capitals_in_sector(sector: Vector2i, world_seed: int,
		generator: NoiseGenerator) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var count := NoiseGenerator.pcg_hash(sector.x, sector.y, world_seed + SEED_KINGDOM) % 3
	if count == 0:
		return out

	var candidates: Array[Dictionary] = []
	const STEP := 8
	for gz in range(0, SECTOR, STEP):
		for gx in range(0, SECTOR, STEP):
			# Décalage pseudo-aléatoire dans la maille : sans lui, toutes les
			# capitales du monde tomberaient sur un quadrillage régulier, ce qui
			# se verrait immédiatement sur la carte.
			var jitter := NoiseGenerator.pcg_hash(sector.x * 977 + gx,
				sector.y * 131 + gz, world_seed + SEED_KINGDOM + 7)
			var cell := Vector2i(
				sector.x * SECTOR + gx + jitter % STEP,
				sector.y * SECTOR + gz + (jitter >> 8) % STEP)
			var score := _favourability(cell, generator)
			if score <= 0.0:
				continue
			candidates.append({"cell": cell, "score": score})
	if candidates.is_empty():
		return out
	candidates.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return float(a["score"]) > float(b["score"]))

	for index in mini(count, candidates.size()):
		var cell: Vector2i = candidates[index]["cell"]
		# Deux capitales d'un même secteur doivent se tenir à distance, sinon
		# leurs territoires se disputent chaque cellule et aucun des deux n'a
		# de forme lisible.
		if index > 0 and cell.distance_to(out[0]["cell"]) < SECTOR * 0.4:
			continue
		var size := _size_for(cell, world_seed)
		out.append({"cell": cell, "size": size[0], "radius": size[1]})
	return out


## Score de site d'une capitale, 0 = inhabitable.
##
## On lit UNIQUEMENT des couches de bruit — hauteur, danger, biome. Rien qui
## demande de générer un chunk : c'est la condition posée par E.27 pour que la
## carte du monde puisse afficher les royaumes lointains.
static func _favourability(cell: Vector2i, generator: NoiseGenerator) -> float:
	var center := POIGenerator.cell_center_world(cell)
	var height := generator.height_at(center.x, center.y)
	if height < generator.water_level + 3:
		return 0.0        # sous l'eau ou sur l'estran
	if height > generator.water_level + 90:
		return 0.0        # haute montagne
	var biome: Dictionary = generator.biome_at(center.x, center.y)
	if biome.is_empty() or not biome.has("village_palette"):
		return 0.0        # biome où l'on ne bâtit pas
	# Basse corruption d'abord : un royaume s'installe là où l'on peut vivre.
	var danger := generator.danger_at(center.x, center.y)
	var score := (1.0 - danger) * 2.0
	# Altitude modérée : ni marécage à ras de l'eau, ni contrefort.
	var altitude := float(height - generator.water_level)
	score += clampf(1.0 - absf(altitude - 20.0) / 60.0, 0.0, 1.0)
	return score


static func _size_for(cell: Vector2i, world_seed: int) -> Array:
	var roll := NoiseGenerator.pcg_hash(cell.x, cell.y, world_seed + SEED_KINGDOM_SIZE) % 100
	var cumulative := 0
	for entry: Array in SIZES:
		cumulative += int(entry[1])
		if roll < cumulative:
			return [String(entry[0]), int(entry[2])]
	return ["hameau_etat", 1]


## Identité d'un royaume, dérivée de sa capitale. Conforme au schéma B.9, à ceci
## près que `territory_cells` n'est PAS un champ : le territoire se calcule
## (voir `territory_of`), il ne se stocke pas — le GDD le dit explicitement,
## « dérivé dynamiquement des claims/conquêtes, pas saisi à la main ».
static func identity(capital: Dictionary, world_seed: int,
		generator: NoiseGenerator) -> Dictionary:
	var cell: Vector2i = capital["cell"]
	var hash_value := NoiseGenerator.pcg_hash(cell.x, cell.y,
		world_seed + SEED_KINGDOM_TRAITS)
	var government: String = GOVERNMENTS[hash_value % GOVERNMENTS.size()]
	# La RACE DOMINANTE découle du biome de la capitale (14.4) — un royaume
	# n'importe pas sa population, il naît de son territoire.
	var center := POIGenerator.cell_center_world(cell)
	var biome: Dictionary = generator.biome_at(center.x, center.y)
	var race := _dominant_race(biome, hash_value)
	# CULTURE (12.5/B.11) — axe INDÉPENDANT de la race : deux royaumes humains
	# voisins peuvent sonner latin et sino. C'est elle qui donnera leur nom aux
	# villes du royaume et aux PNJ qui y naissent, d'où sa place ici, dans
	# l'identité : elle se décide une fois, avec le royaume, et ne bouge plus.
	var culture := NameGenerator.culture_for_race(race, hash_value)
	return {
		"id": id_of(cell),
		"name": WorldNamer.land_name(world_seed + cell.x * 7919 + cell.y * 104729),
		"government_type": government,
		"race": race,
		"culture": culture,
		"capital": cell,
		"size": String(capital["size"]),
		"radius": int(capital["radius"]),
		# Teinte de carte, stable : c'est à elle que le joueur reconnaîtra un
		# royaume d'un coup d'œil, bien avant d'en lire le nom.
		"color": Color.from_hsv(float(hash_value % 360) / 360.0, 0.55, 0.85),
		"taxes": {"base_rate": 0.04 + float(hash_value % 9) * 0.01,
			"tariff_default": 0.05 + float((hash_value >> 8) % 16) * 0.01},
	}


static func id_of(capital_cell: Vector2i) -> String:
	return "royaume_%d_%d" % [capital_cell.x, capital_cell.y]


## Race dominante : ~90 % de la population et l'exclusivité de la gouvernance
## (14.4). On la choisit par le biome, avec un repli sur l'humain — une race
## manquante ne doit jamais empêcher un royaume d'exister.
static func _dominant_race(biome: Dictionary, hash_value: int) -> String:
	var tags: Array = biome.get("tags", [])
	if "froid" in tags or "montagne" in tags:
		return "nain"
	if "foret" in tags or "magique" in tags:
		return "elfe"
	var ids: Array = GameData.races.keys()
	if ids.is_empty():
		return "humain"
	return "humain" if hash_value % 4 != 0 else String(ids[hash_value % ids.size()])


# --- Territoire ---------------------------------------------------------------
#
# « Cellules contiguës autour de la capitale, croissance par coût : le territoire
# s'étend en évitant hautes corruptions et montagnes » (E.27).
#
# Une croissance par coût, et non un simple rayon. Le rayon donnerait des disques
# parfaits, immédiatement lisibles comme artificiels ; le coût fait épouser au
# territoire la forme du terrain — il contourne les massifs, longe les vallées,
# s'arrête devant une zone corrompue. La frontière raconte alors quelque chose.

## Coût d'entrée dans une cellule. Retourne -1 si elle est infranchissable :
## l'eau et la haute montagne bornent un royaume aussi sûrement qu'un traité.
## Enveloppe PUBLIQUE de `_entry_cost` — pour les sondes, qui doivent pouvoir
## chronométrer la brique élémentaire du calcul de territoire. Même convention
## que `NoiseGenerator.pcg_hash` : on expose, on ne duplique pas.
static func entry_cost(cell: Vector2i, generator: NoiseGenerator) -> float:
	return _entry_cost(cell, generator)


## Coûts d'entrée déjà calculés. `_entry_cost` est une fonction PURE de la
## cellule — deux échantillons de bruit et rien d'autre — et le Dijkstra de
## `territory_of` l'appelle une fois depuis CHACUN des quatre voisins de chaque
## cellule atteinte. Mesuré : 148 cellules atteintes coûtaient 15,5 ms, dont
## 86 % dans ces appels redondants.
##
## Mémoïser ne change aucun résultat, seulement le nombre de fois qu'on le
## calcule — la génération reste déterministe au bloc près.
static var _entry_cache := {}
const ENTRY_CACHE_LIMIT := 65536


static func _entry_cost(cell: Vector2i, generator: NoiseGenerator) -> float:
	if _entry_cache.has(cell):
		return _entry_cache[cell]
	var cost := _compute_entry_cost(cell, generator)
	# Plafond simple : au-delà, on vide. Un joueur qui traverse le monde finirait
	# sinon par garder en mémoire le coût de chaque cellule visitée, et les
	# cellules lointaines ne resserviront pas.
	if _entry_cache.size() >= ENTRY_CACHE_LIMIT:
		_entry_cache.clear()
	_entry_cache[cell] = cost
	return cost


static func _compute_entry_cost(cell: Vector2i, generator: NoiseGenerator) -> float:
	var center := POIGenerator.cell_center_world(cell)
	var height := generator.height_at(center.x, center.y)
	if height < generator.water_level + 1:
		return -1.0
	if height > generator.water_level + 110:
		return -1.0
	var cost := 1.0
	# La corruption repousse : un royaume ne s'étend pas vers ce qui le menace.
	cost += generator.danger_at(center.x, center.y) * 3.0
	# Le relief coûte, sans interdire.
	cost += clampf(float(height - generator.water_level) / 90.0, 0.0, 1.0) * 2.0
	return cost


## Territoire d'une capitale : ensemble de cellules, capitale comprise.
##
## Dijkstra borné par un BUDGET DE COÛT dérivé de la taille du royaume. Le budget
## et non un nombre de cellules : c'est ce qui fait qu'un hameau-État en plaine
## occupe plus de terrain qu'un hameau-État en montagne, alors que les deux sont
## de la même « taille » politique.
static func territory_of(capital: Dictionary, generator: NoiseGenerator) -> Dictionary:
	var origin: Vector2i = capital["cell"]
	var budget := float(capital["radius"])
	var reached := {origin: 0.0}
	var frontier: Array[Vector2i] = [origin]
	var examined := 0

	while not frontier.is_empty() and examined < GROWTH_BUDGET:
		# Cellule de moindre coût atteint : on étend toujours par le chemin le
		# plus facile, sinon la forme dépendrait de l'ordre d'insertion.
		var best := 0
		for index in frontier.size():
			if reached[frontier[index]] < reached[frontier[best]]:
				best = index
		var current: Vector2i = frontier[best]
		frontier.remove_at(best)
		examined += 1
		var current_cost: float = reached[current]

		for offset: Vector2i in [Vector2i(1, 0), Vector2i(-1, 0),
				Vector2i(0, 1), Vector2i(0, -1)]:
			var neighbour := current + offset
			var step := _entry_cost(neighbour, generator)
			if step < 0.0:
				continue
			var total := current_cost + step
			if total > budget:
				continue
			if reached.has(neighbour) and float(reached[neighbour]) <= total:
				continue
			reached[neighbour] = total
			frontier.append(neighbour)
	return reached


## Royaume possédant cette cellule, ou {} si elle est en terre sauvage.
##
## On n'examine que le secteur courant et ses huit voisins : un territoire ne
## peut pas s'étendre au-delà, le budget de croissance étant très inférieur à la
## taille d'un secteur. C'est ce qui rend la requête bornée dans un monde infini.
##
## En cas de litige — deux royaumes atteignent la même cellule — c'est le COÛT
## qui tranche, puis l'identifiant. « Deux royaumes proches bornent leurs
## territoires » (E.27) : la frontière tombe naturellement là où les deux
## croissances s'équilibrent, sans arbitrage global.
static func kingdom_at(cell: Vector2i, world_seed: int,
		generator: NoiseGenerator) -> Dictionary:
	var best := {}
	var best_cost := INF
	var sector := sector_of(cell)
	for dz in range(-1, 2):
		for dx in range(-1, 2):
			for capital: Dictionary in capitals_in_sector(
					sector + Vector2i(dx, dz), world_seed, generator):
				var territory := territory_of(capital, generator)
				if not territory.has(cell):
					continue
				var cost := float(territory[cell])
				var candidate := identity(capital, world_seed, generator)
				if cost < best_cost or (is_equal_approx(cost, best_cost)
						and String(candidate["id"]) < String(best.get("id", "~"))):
					best_cost = cost
					best = candidate
	return best


# --- Cache --------------------------------------------------------------------
#
# `kingdom_at` examine neuf secteurs, échantillonne 64 sites par secteur et fait
# croître un territoire par Dijkstra. C'est bon marché UNE fois, ruineux à
# chaque pixel de la carte du monde — laquelle interroge des milliers de
# cellules à chaque ouverture, zoom ou déplacement.
#
# Le résultat étant purement dérivé de la graine, il ne change jamais : le cache
# est donc trivialement correct. Il est BORNÉ et purgé en bloc, comme le cache de
# villes : un cache non borné dans un monde infini est une fuite de mémoire
# déguisée en optimisation.

const CACHE_LIMIT := 4096

static var _sector_cache := {}
static var _cell_cache := {}


static func _capitals_cached(sector: Vector2i, world_seed: int,
		generator: NoiseGenerator) -> Array[Dictionary]:
	if _sector_cache.has(sector):
		return _sector_cache[sector]
	var capitals := capitals_in_sector(sector, world_seed, generator)
	# Le territoire est calculé UNE fois par capitale et rangé avec elle : c'est
	# lui le vrai coût, pas le tirage des capitales.
	for capital: Dictionary in capitals:
		capital["territory"] = territory_of(capital, generator)
		capital["identity"] = identity(capital, world_seed, generator)
	if _sector_cache.size() > 256:
		_sector_cache.clear()
	_sector_cache[sector] = capitals
	return capitals


## Version mise en cache de `kingdom_at`. C'est CELLE-CI qu'appellent l'interface
## et le jeu ; la version nue reste pour les sondes, qui doivent pouvoir mesurer
## le calcul réel.
static func kingdom_at_cached(cell: Vector2i, world_seed: int,
		generator: NoiseGenerator) -> Dictionary:
	if _cell_cache.has(cell):
		return _cell_cache[cell]
	var best := {}
	var best_cost := INF
	var sector := sector_of(cell)
	for dz in range(-1, 2):
		for dx in range(-1, 2):
			for capital: Dictionary in _capitals_cached(
					sector + Vector2i(dx, dz), world_seed, generator):
				var territory: Dictionary = capital["territory"]
				if not territory.has(cell):
					continue
				var cost := float(territory[cell])
				var candidate: Dictionary = capital["identity"]
				if cost < best_cost or (is_equal_approx(cost, best_cost)
						and String(candidate["id"]) < String(best.get("id", "~"))):
					best_cost = cost
					best = candidate
	if _cell_cache.size() > CACHE_LIMIT:
		_cell_cache.clear()
	_cell_cache[cell] = best
	return best


## Le secteur est-il déjà calculé ? Sert au PRÉCHAUFFAGE : c'est ce qui permet
## de payer le coût hors du tick, avant que quiconque en ait besoin.
static func sector_ready(sector: Vector2i) -> bool:
	return _sector_cache.has(sector)


## Calcule un secteur s'il ne l'est pas déjà. Retourne true si du travail a
## réellement été fait — l'appelant s'en sert pour n'en faire qu'un par frame.
static func warm_sector(sector: Vector2i, world_seed: int, generator: NoiseGenerator) -> bool:
	if _sector_cache.has(sector):
		return false
	_capitals_cached(sector, world_seed, generator)
	return true


## À appeler au chargement d'un monde : deux mondes de graines différentes ne
## partagent aucun royaume, et garder le cache les mélangerait.
static func clear_cache() -> void:
	_sector_cache.clear()
	_cell_cache.clear()
	# Le coût d'entrée dépend du RELIEF, donc de la graine : le garder d'un
	# monde à l'autre donnerait des frontières calculées sur le mauvais terrain.
	_entry_cache.clear()
