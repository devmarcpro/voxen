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
## HORS est ajoute EN FIN d enum a dessein : les valeurs precedentes sont
## ecrites telles quelles dans les layouts caches et lues par le generateur de
## terrain. Les renumeroter transformerait silencieusement toutes les routes des
## mondes deja explores en batiments.
enum Tile { VIDE, ROUTE, BATIMENT, CHAMP, PLACE, HORS }

## Footprint (tuiles de côté) par catégorie. TOUJOURS ≤ 6 : avec un décalage
## d'au moins 1, le plateau ne touche jamais le bord de cellule, donc aucune
## couture de terrassement entre cellules voisines.
##
## La ville passe de 5 à 6 : à 5 tuiles elle avait exactement la même emprise
## qu'un village, ce qui rendait la catégorie invisible en jeu alors que le GDD
## (3.4) lui donne une capacité trois fois supérieure.
## AGRANDIS le 2026-08-09 (demande de l auteur : « un village ne devrait pas
## etre juste 4 maisons avec une rue »). A 5 tuiles, un village offrait 25 cases
## dont 9 de rue, et l on y batissait 4 a 10 maisons : le compte y etait, la
## SENSATION non. Les paliers ayant supprime la falaise de terrassement, rien
## n oblige plus a rester petit. Toujours <= 7 : il faut au moins une position
## de repli dans la cellule pour chercher un site correct.
const FOOTPRINT := {"hameau": 4, "village": 6, "ville": 7}

## UNE CAPITALE DEBORDE DE SA CELLULE (2026-08-09, demande de l auteur : « une
## ville peut utiliser plusieurs cellules ; la taille suit les stats du
## royaume »). La fenetre d une capitale s etend sur 2x2 cellules — l ancre plus
## ses voisines +x/+z/+xz — soit 16 tuiles de cote. Seule la capitale d un
## royaume d une certaine taille y a droit : la capitale d un hameau-etat reste
## un village d une cellule, celle d une cite-etat ou plus devient une vraie
## ville. C est la POLITIQUE du monde qui se lit dans la taille des lieux.
const CAPITAL_SPAN_CELLS := 2
## Population d une capitale (au-dela du « ville » 20-40 du GDD 3.4 : c est le
## siege d un royaume, pas une bourgade de plus).
const CAPITAL_POP_RANGE := [40, 90]
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
## UN VILLAGE N EST PLUS UN CARRE (2026-08-09, demande de l auteur : « il faut
## que ca ait une forme organique, pas juste un carre dans la cellule ; le
## village peut se faire n importe comment tant que c est contenu dans la
## cellule »).
##
## CE QUE C ETAIT. Un carre plein de t x t tuiles, t fixe par categorie. Deux
## consequences egalement mauvaises : la silhouette etait un timbre-poste pose
## sur le paysage, et la taille ne disait rien du lieu — une bourgade de 34 ames
## avait exactement la meme emprise qu une de 20, si bien qu elle etouffait.
##
## CE QUE C EST. La population est tiree D ABORD, puis on en DEDUIT la place
## necessaire, puis on fait POUSSER la forme depuis le centre, tuile par tuile,
## en s accrochant a ce qui existe deja. La boite englobante n est plus la forme
## du village : c est juste la fenetre dans laquelle il a pousse. Tout ce qui
## reste hors de la forme redevient du terrain normal — arbres compris, ce qui
## fait que le village est BORDE de nature au lieu d etre pose sur une dalle.
static func tile_plan(cell: Vector2i, world_seed: int, category: String) -> Dictionary:
	var rng := RandomNumberGenerator.new()
	rng.seed = NoiseGenerator.pcg_hash(cell.x, cell.y, world_seed + SEED_CITY)

	var span_tiles := TILES_PER_CELL
	var pop_range: Array = POP_RANGE.get(category, [8, 20])
	if category == "capitale":
		span_tiles = TILES_PER_CELL * CAPITAL_SPAN_CELLS
		pop_range = CAPITAL_POP_RANGE
	var population := rng.randi_range(int(pop_range[0]), int(pop_range[1]))
	var homes_needed := ceili(float(population) / float(RESIDENTS_PER_BUILDING))
	var services: Array = _services_for(category, population, rng)

	# LA PLACE NECESSAIRE SE CALCULE, elle ne se decrete plus. Batiments +
	# services, puis la voirie et les champs qui vont avec : sans cette marge, on
	# obtenait un village ou les rues devoraient les parcelles.
	var built_tiles := homes_needed + services.size()
	var wanted := int(ceil(float(built_tiles) * TILES_PER_BUILT)) + 1
	var t: int = clampi(int(ceil(sqrt(float(wanted)))) + 2, 4, span_tiles)
	wanted = mini(wanted, t * t - 2)
	@warning_ignore("integer_division")
	var offset := (span_tiles - t) / 2
	@warning_ignore("integer_division")
	var center := t / 2

	var types := PackedByteArray()
	types.resize(t * t)
	types.fill(Tile.HORS)

	var shape := _grow_shape(t, center, wanted, rng)
	for idx: int in shape:
		types[idx] = Tile.VIDE

	_trace_streets(types, t, center, rng)
	types[center * t + center] = Tile.PLACE

	# --- ZONAGE : le bati au coeur, les champs sur le POURTOUR DE LA FORME ---
	#
	# Le bord n est plus celui de la boite englobante mais celui du village
	# lui-meme : une tuile qui touche l exterieur est agricole. C est ce qui
	# donne la ceinture de champs quelle que soit la forme.
	var plots: Array[int] = []
	var outskirts: Array[int] = []
	for idx: int in shape:
		if types[idx] != Tile.VIDE:
			continue
		@warning_ignore("integer_division")
		var served := _adjacent_road_dir(types, t, idx % t, idx / t) != Vector3i.ZERO
		if _touches_outside(types, t, idx) or not served:
			outskirts.append(idx)
		else:
			plots.append(idx)

	plots.sort_custom(func(a: int, b: int) -> bool:
		return _ring_of(a, t, center) < _ring_of(b, t, center))
	# Si le pourtour a tout mange, on rend les parcelles desservies : un village
	# sans parcelle n a nulle part ou loger son marchand.
	if plots.size() < built_tiles:
		var rescued: Array[int] = []
		for idx: int in outskirts:
			if plots.size() + rescued.size() >= built_tiles:
				break
			@warning_ignore("integer_division")
			if _adjacent_road_dir(types, t, idx % t, idx / t) != Vector3i.ZERO 					and not _touches_outside(types, t, idx):
				rescued.append(idx)
		for idx: int in rescued:
			outskirts.erase(idx)
			plots.append(idx)
	# DERNIER RECOURS (2026-08-09, vu sur capture : village T=6, ZERO batiment —
	# rues et champs, personne). Dans une PETITE forme, toutes les tuiles
	# touchent le dehors : le zonage « le bord est agricole » les classait
	# toutes champs, et le sauvetage ci-dessus, qui exige de ne pas toucher le
	# bord, ne rendait rien. Une maison de hameau PEUT donner sur les champs —
	# c est meme sa definition. On leve donc la contrainte de bord, et seule
	# reste la desserte : batir sans rue serait pire que ne pas batir.
	if plots.is_empty():
		for idx: int in outskirts.duplicate():
			if plots.size() >= built_tiles:
				break
			@warning_ignore("integer_division")
			if _adjacent_road_dir(types, t, idx % t, idx / t) != Vector3i.ZERO:
				outskirts.erase(idx)
				plots.append(idx)

	var doors := {}
	var archetypes := {}
	var service_at := {}
	var built := 0

	for service: Array in services:
		if plots.is_empty():
			break
		var idx: int = plots.pop_front()
		types[idx] = Tile.BATIMENT
		@warning_ignore("integer_division")
		doors[idx] = _adjacent_road_dir(types, t, idx % t, idx / t)
		archetypes[idx] = String(service[1])
		service_at[idx] = String(service[0])
		built += 1

	var homes := 0
	for idx: int in plots.duplicate():
		if homes >= homes_needed:
			break
		types[idx] = Tile.BATIMENT
		@warning_ignore("integer_division")
		doors[idx] = _adjacent_road_dir(types, t, idx % t, idx / t)
		archetypes[idx] = _pick_archetype(rng)
		plots.erase(idx)
		homes += 1
		built += 1

	for idx: int in plots:
		if types[idx] == Tile.VIDE:
			types[idx] = Tile.CHAMP
	for idx: int in outskirts:
		types[idx] = Tile.CHAMP

	# DIRECTIONS DESSERVIES PAR CHAQUE RUE. La chaussee n occupe plus toute la
	# tuile (2026-08-09, demande de l auteur : « je veux des rues etroites ») :
	# c est une bande de quelques blocs. Une bande a besoin de savoir OU elle va,
	# sinon un carrefour se dessine comme un troncon et la rue se coupe en deux.
	var links := {}
	for idx in types.size():
		if types[idx] != Tile.ROUTE and types[idx] != Tile.PLACE:
			continue
		links[idx] = _road_links(types, t, idx)

	return {"T": t, "offset": offset, "types": types, "doors": doors,
		"archetypes": archetypes, "services": service_at, "links": links,
		"population": population, "buildings": built,
		"span_cells": CAPITAL_SPAN_CELLS if category == "capitale" else 1,
		"category": category}


## Bits de direction vers les tuiles circulables voisines : 1 est, 2 ouest,
## 4 sud, 8 nord. Une place compte comme circulable — c est un carrefour.
static func _road_links(types: PackedByteArray, t: int, idx: int) -> int:
	var tx := idx % t
	@warning_ignore("integer_division")
	var tz := idx / t
	var mask := 0
	var steps: Array = [[Vector2i(1, 0), 1], [Vector2i(-1, 0), 2],
		[Vector2i(0, 1), 4], [Vector2i(0, -1), 8]]
	for entry: Array in steps:
		var step: Vector2i = entry[0]
		var nx := tx + step.x
		var nz := tz + step.y
		if nx < 0 or nx >= t or nz < 0 or nz >= t:
			# UNE RUE QUI SORT DU VILLAGE DOIT ATTEINDRE LE BORD : c est une
			# entree. La couper au ras de la derniere tuile ferait une impasse.
			mask |= int(entry[1])
			continue
		var kind := types[nz * t + nx]
		if kind == Tile.ROUTE or kind == Tile.PLACE or kind == Tile.HORS:
			mask |= int(entry[1])
	return mask


## Demi-largeur de la chaussee, en blocs. Trois donne une rue de sept blocs :
## deux charrettes s y croisent, on y voit les facades des deux cotes, et elle ne
## devore pas les parcelles comme le faisait la tuile entiere de seize.
const STREET_HALF := 3


## La colonne (lx, lz) d une tuile de rue est-elle SUR la chaussee ?
##
## La bande est tracee vers chaque direction desservie, et le carrefour central
## est toujours pave : sans lui, deux bandes perpendiculaires se croiseraient
## sans se toucher aux angles et la rue aurait des trous.
static func on_street(lx: int, lz: int, links: int) -> bool:
	var dx := lx - 8
	var dz := lz - 8
	if absi(dx) <= STREET_HALF and absi(dz) <= STREET_HALF:
		return true
	if absi(dz) <= STREET_HALF:
		if dx > 0 and (links & 1) != 0:
			return true
		if dx < 0 and (links & 2) != 0:
			return true
	if absi(dx) <= STREET_HALF:
		if dz > 0 and (links & 4) != 0:
			return true
		if dz < 0 and (links & 8) != 0:
			return true
	return false


## Emprise du PLATEAU d un batiment : son emprise batie, plus un bloc de
## pourtour (le seuil de la porte, le pied du mur).
##
## CHAQUE BATIMENT A SON PLATEAU (2026-08-09, demande de l auteur). Terrasser la
## tuile ENTIERE aplanissait 16x16 blocs pour une maison qui en occupe 8 : le
## village restait une succession de dalles carrees, et c est ce qui lui donnait
## son air de maquette malgre les paliers.
static func on_building_pad(lx: int, lz: int, archetype: String) -> bool:
	var spec: Dictionary = ARCHETYPES.get(archetype, ARCHETYPES["maison"])
	var margin := int(spec["marge"]) - 1
	return lx >= margin and lx <= 15 - margin and lz >= margin and lz <= 15 - margin


## Tuiles occupees par tuile BATIE, voirie et champs compris. Mesure sur les
## plans obtenus : au-dessous de 2, les rues n ont plus la place de desservir les
## parcelles et le village s etouffe.
const TILES_PER_BUILT := 2.2


## CROISSANCE DE LA FORME. On part du centre et l on agrege, une par une, des
## tuiles voisines de ce qui existe deja.
##
## Le tirage est BIAISE VERS LE CENTRE (on essaie plusieurs candidates et l on
## garde la plus proche) : une croissance uniforme produit des tentacules et des
## villages en etoile de mer. Ce biais donne une masse compacte mais irreguliere
## — ce qu on appelle « organique » quand on regarde un village d en haut.
##
## La forme est CONTENUE DANS LA BOITE par construction : aucune candidate hors
## bornes n est jamais retenue. C est la garantie que le village tient dans sa
## cellule, exigee par l auteur.
static func _grow_shape(t: int, center: int, wanted: int, rng: RandomNumberGenerator) -> Array[int]:
	var shape: Array[int] = [center * t + center]
	var inside := {}
	inside[shape[0]] = true
	var frontier: Array[int] = []
	_push_neighbours(frontier, inside, t, shape[0])
	while shape.size() < wanted and not frontier.is_empty():
		# TROIS CANDIDATES, LA PLUS CENTRALE GAGNE. Une seule candidate au hasard
		# donne des bras ; toutes triees donnerait un disque parfait, donc un
		# carre aux coins arrondis. Trois est le reglage qui laisse des golfes et
		# des caps sans partir en filaments.
		var best := -1
		var best_score := 1 << 30
		for _try in 3:
			if frontier.is_empty():
				break
			var pick := rng.randi_range(0, frontier.size() - 1)
			var candidate: int = frontier[pick]
			@warning_ignore("integer_division")
			var score := absi(candidate % t - center) + absi(candidate / t - center)
			score = score * 4 + rng.randi_range(0, 3)
			if score < best_score:
				if best >= 0:
					frontier.append(best)
				best_score = score
				best = candidate
			frontier.remove_at(pick)
		if best < 0:
			break
		if inside.has(best):
			continue
		inside[best] = true
		shape.append(best)
		_push_neighbours(frontier, inside, t, best)
	return shape


static func _push_neighbours(frontier: Array[int], inside: Dictionary, t: int, idx: int) -> void:
	var tx := idx % t
	@warning_ignore("integer_division")
	var tz := idx / t
	for step: Vector2i in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
		var nx := tx + step.x
		var nz := tz + step.y
		if nx < 0 or nx >= t or nz < 0 or nz >= t:
			continue
		var n := nz * t + nx
		if not inside.has(n):
			frontier.append(n)


## La tuile touche-t-elle le dehors ? Sert au zonage : c est le pourtour de la
## FORME qui est agricole, et non le bord de la boite englobante — sans quoi un
## village en croissant aurait ses champs du mauvais cote.
static func _touches_outside(types: PackedByteArray, t: int, idx: int) -> bool:
	var tx := idx % t
	@warning_ignore("integer_division")
	var tz := idx / t
	for step: Vector2i in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
		var nx := tx + step.x
		var nz := tz + step.y
		if nx < 0 or nx >= t or nz < 0 or nz >= t:
			return true
		if types[nz * t + nx] == Tile.HORS:
			return true
	return false


static func _ring_of(idx: int, t: int, center: int) -> int:
	@warning_ignore("integer_division")
	return maxi(absi(idx % t - center), absi(idx / t - center))


## SERVICES d un village, selon sa taille. Un hameau n a pas de guilde et une
## ville n a pas qu une halle : la liste grandit avec le lieu, ce qui donne aux
## trois categories une raison d exister autre que le nombre de maisons.
##
## L ordre compte : les premiers servis prennent les parcelles les plus
## centrales. La halle passe donc devant tout — c est le repere du village.
static func _services_for(category: String, population: int, rng: RandomNumberGenerator) -> Array:
	var out: Array = [["halle", "halle"]]
	out.append(["marchand", "atelier"])
	if population >= 8:
		out.append(["taverne", "maison_etage"])
	if category != "hameau":
		out.append(["forge", "atelier"])
	if category == "ville" or (category == "village" and rng.randf() < 0.5):
		out.append(["guilde", "halle"])
	if category == "ville" or category == "capitale":
		out.append(["casino", "maison_etage"])
		out.append(["temple", "halle"])
	if category == "capitale":
		# LE SIEGE DU ROYAUME. La guilde y est toujours, et le commerce double :
		# une capitale de quatre-vingts ames avec un seul marchand ferait la
		# queue devant l echoppe.
		out.append(["guilde", "halle"])
		out.append(["marchand", "atelier"])
		out.append(["taverne", "maison_etage"])
	return out


## RESEAU DE RUES (2026-08-09, demande de l auteur : « de veritables rues qui
## permettent de naviguer dans le village »).
##
## CE QUE C ETAIT : une CROIX. La ligne centrale, la colonne centrale, et rien
## d autre — jamais. Deux villages du meme monde avaient exactement le meme plan,
## et « naviguer » se resumait a longer l unique axe.
##
## CE QUE C EST : une artere qui SERPENTE de bord a bord, plus des ruelles qui
## en partent pour desservir le reste. L artere devie d une tuile au hasard en
## chemin : c est ce qui fait qu une rue se lit comme une rue et non comme un
## axe de tableur. Les ruelles partent de l artere et vont jusqu a un bord, ce
## qui garantit deux choses sans les verifier apres coup — le reseau est CONNEXE
## (tout part de l artere) et il a plusieurs entrees (chaque brin touche un
## bord), comme l exige le GDD 3.4.
static func _trace_streets(types: PackedByteArray, t: int, center: int,
		rng: RandomNumberGenerator) -> void:
	# ARTERE. Orientation tiree au sort : un village sur deux est traverse dans
	# l autre sens, ce qui suffit deja a casser la repetition d un monde entier.
	var horizontal := rng.randf() < 0.5
	var line := center
	for step in t:
		# UNE RUE NE SORT PAS DU VILLAGE. La forme n est plus un carre plein :
		# tracer en aveugle poserait du gravier en pleine campagne, et le village
		# retrouverait la silhouette carree qu on vient de lui enlever.
		var at := (line * t + step) if horizontal else (step * t + line)
		if types[at] == Tile.HORS:
			continue
		types[at] = Tile.ROUTE
		# Le decrochage se fait EN DEHORS des bords : une artere qui devie sur sa
		# derniere tuile sortirait du footprint ou raterait son entree.
		if step > 0 and step < t - 1 and rng.randf() < 0.35:
			var drift := line + (1 if rng.randf() < 0.5 else -1)
			if drift > 0 and drift < t - 1:
				# On pose le COUDE avant de changer de voie, sinon la rue est
				# coupee en deux troncons qui ne se touchent pas.
				var elbow := (drift * t + step) if horizontal else (step * t + drift)
				if types[elbow] != Tile.HORS:
					types[elbow] = Tile.ROUTE
					line = drift
	# RUELLES. Elles partent de l artere et filent jusqu au bord.
	@warning_ignore("integer_division")
	var branches := maxi(2, t / 2)
	for _b in branches:
		var at := rng.randi_range(1, t - 2)
		var toward_high := rng.randf() < 0.5
		var cross := _artery_lane(types, t, at, horizontal)
		var to := (t - 1) if toward_high else 0
		var direction := 1 if toward_high else -1
		var lane := cross + direction
		while (lane <= to) if toward_high else (lane >= to):
			var here := (lane * t + at) if horizontal else (at * t + lane)
			# La ruelle S ARRETE au bord du village. Elle a rempli son office :
			# atteindre le pourtour, donc offrir une entree.
			if types[here] == Tile.HORS:
				break
			types[here] = Tile.ROUTE
			lane += direction


## Voie occupee par l artere a l abscisse `at` — elle a pu decrocher en chemin,
## et une ruelle qui partirait de la voie d origine ne toucherait rien.
static func _artery_lane(types: PackedByteArray, t: int, at: int, horizontal: bool) -> int:
	for lane in t:
		if types[(lane * t + at) if horizontal else (at * t + lane)] == Tile.ROUTE:
			return lane
	@warning_ignore("integer_division")
	return t / 2


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
## HAUTEURS VARIEES (2026-08-09, demande de l auteur : « des batiments de
## hauteurs differentes, certains a etage »).
##
## L archetype fixait une hauteur unique : toutes les maisons d un village
## avaient donc exactement la meme toiture, et une rue entiere se lisait comme
## une seule maison repetee. `variant` decale la hauteur des murs de -1 a +3, et
## au-dela de +1 le batiment gagne un VRAI etage — plancher intermediaire et
## rangee de fenetres hautes, pas seulement des murs plus longs.
##
## La variation porte sur les MURS et pas sur l emprise : deux maisons de tailles
## au sol differentes decolleraient des parcelles, alors que deux maisons de
## hauteurs differentes font une rue.
static func building_blocks(door_dir: Vector3i, palette: Dictionary,
		archetype: String = "maison", variant: int = 0) -> Dictionary:
	var spec: Dictionary = ARCHETYPES.get(archetype, ARCHETYPES["maison"])
	var margin := int(spec["marge"])
	var wall_height := maxi(3, int(spec["murs"]) + clampi(variant, -1, 3))
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

	# UN ETAGE QUAND LA HAUTEUR LE PERMET, et non parce que la fiche le dit :
	# un batiment monte a 8 blocs sans plancher intermediaire est une grange, pas
	# une maison a etage, et ca se voit de l interieur.
	var has_floor := bool(spec["etage"]) or wall_height >= int(spec["murs"]) + 2
	if has_floor and wall_height >= 6:
		# PLANCHER INTERMEDIAIRE, a mi-hauteur, avec une tremie pour l escalier :
		# un etage entierement clos serait une piece inaccessible.
		var floor_y := wall_height / 2
		for x in range(lo + 1, hi):
			for z in range(lo + 1, hi):
				if x >= hi - 2 and z >= hi - 2:
					continue  # Tremie d acces.
				blocks[Vector3i(x, floor_y, z)] = palette.get("poutre", mur)
	_carve_windows(blocks, lo, hi, wall_height, has_floor)
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


## DECOR DE VILLAGE (2026-08-09, demande de l auteur : « il faudra mettre de la
## decoration, de la vegetation, etc »).
##
## CE QUI MANQUAIT. Hors des murs, un village etait de la matiere nue : du
## gravier sur les rues, de la terre sur les champs, du pave sur la place. Aucun
## objet, aucune plante, rien qui indique que quelqu un vit la. Un village se
## reconnait pourtant a ses traces d usage bien avant a son plan.
##
## POURQUOI DES BLOCS PRECALCULES ET PAS DES ENTITES. Le decor suit exactement
## le chemin des batiments : un dictionnaire local (lx, ly, lz) -> id, calcule
## une fois par cellule et cache avec le layout. Il ne coute donc rien au
## streaming, il se sauvegarde tout seul (c est du terrain), et le joueur peut
## le casser comme le reste du monde — ce qu une entite decorative n aurait pas
## permis sans un systeme entier derriere.
##
## `ly` est RELATIF au palier de la tuile, comme pour les batiments.
static func decor_blocks(tile_type: int, palette: Dictionary, service: String,
		seed_value: int) -> Dictionary:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value
	var blocks := {}
	match tile_type:
		Tile.PLACE:
			_decor_square(blocks, palette, service, rng)
		Tile.ROUTE:
			# PLUS DE DECOR DE RUE (2026-08-09). Une rue ne repose plus sur un
			# palier : elle suit le terrain. Un decor pose a une hauteur relative
			# au palier flotterait au-dessus de la chaussee ou serait enterre
			# dessous. Les torches ont demenage au pied des batiments, ou le
			# plateau existe encore et ou la hauteur est donc connue.
			pass
		Tile.CHAMP:
			_decor_field(blocks, palette, rng)
	return blocks


## LA PLACE : un puits, et de quoi tenir un marche.
##
## Le puits est le point focal du village — c est ce qu on cherche des yeux en
## arrivant, et ce qui donne a la place une raison d etre autre que « la case du
## milieu ». Les etals l entourent sans le masquer.
static func _decor_square(blocks: Dictionary, palette: Dictionary, _service: String,
		rng: RandomNumberGenerator) -> void:
	var stone: int = palette.get("pave", palette["mur"])
	var wood: int = palette.get("poutre", palette["mur"])
	var water: int = palette.get("eau", 0)
	# PUITS : une margelle carree creuse, l eau au fond. Decale du centre exact
	# pour ne pas couper la place en quatre quartiers identiques.
	var cx := 6 + rng.randi_range(0, 3)
	var cz := 6 + rng.randi_range(0, 3)
	for dx in range(-1, 2):
		for dz in range(-1, 2):
			if dx == 0 and dz == 0:
				if water != 0:
					blocks[Vector3i(cx, 0, cz)] = water
				continue
			blocks[Vector3i(cx + dx, 1, cz + dz)] = stone
	# Deux montants et un linteau : la silhouette qui fait lire « puits » de loin.
	for y in range(2, 4):
		blocks[Vector3i(cx - 1, y, cz)] = wood
		blocks[Vector3i(cx + 1, y, cz)] = wood
	blocks[Vector3i(cx, 4, cz)] = wood
	blocks[Vector3i(cx - 1, 4, cz)] = wood
	blocks[Vector3i(cx + 1, 4, cz)] = wood
	# ETALS DE MARCHE : un plateau sur pieds, contre un bord de la place.
	for _stall in rng.randi_range(2, 4):
		var sx := rng.randi_range(1, 13)
		var sz := rng.randi_range(1, 13)
		if absi(sx - cx) <= 2 and absi(sz - cz) <= 2:
			continue  # Jamais sur le puits.
		blocks[Vector3i(sx, 1, sz)] = wood
		blocks[Vector3i(sx + 1, 1, sz)] = wood
	_scatter_torches(blocks, palette, rng, 2)


## LA RUE : des torches, et de la verdure qui deborde.
##
## Les torches ne sont pas qu un ornement : elles sont ce qui rend un village
## habitable la nuit, quand la portee de vision tombe (E.21). Un village noir
## est un village qu on traverse au pas de course.
static func _decor_street(blocks: Dictionary, palette: Dictionary,
		rng: RandomNumberGenerator) -> void:
	_scatter_torches(blocks, palette, rng, rng.randi_range(1, 3))
	var bush: int = palette.get("buisson", 0)
	if bush == 0:
		return
	# La verdure se tient sur les BORDS de la tuile : au milieu, elle barrerait
	# la rue qu on vient tout juste de rendre navigable.
	for _plant in rng.randi_range(0, 3):
		var edge := rng.randi_range(0, 3)
		var along := rng.randi_range(2, 13)
		var at := Vector3i(0, 1, 0)
		match edge:
			0: at = Vector3i(along, 1, 0)
			1: at = Vector3i(along, 1, 15)
			2: at = Vector3i(0, 1, along)
			_: at = Vector3i(15, 1, along)
		blocks[at] = bush


## LE CHAMP : des rangs de culture, une cloture, et parfois un arbre.
##
## LES RANGS SONT LE SUJET. De la terre nue se lit comme un chantier ; ce sont
## les lignes regulieres qui disent « quelqu un cultive ici ». On alterne rang
## seme et rang de passage, comme un vrai champ — un tapis plein donnerait une
## moquette verte.
static func _decor_field(blocks: Dictionary, palette: Dictionary,
		rng: RandomNumberGenerator) -> void:
	var crop: int = palette.get("culture", 0)
	var fence: int = palette.get("poutre", palette["mur"])
	# Rangs dans un sens ou dans l autre, une chance sur deux : deux champs
	# voisins ne doivent pas etre le meme champ deux fois.
	var along_x := rng.randf() < 0.5
	if crop != 0:
		for line in range(2, 14, 2):
			for along in range(2, 14):
				var at := Vector3i(along, 1, line) if along_x else Vector3i(line, 1, along)
				blocks[at] = crop
	# CLOTURE : QUATRE PIQUETS D ANGLE, et rien de plus.
	#
	# Vu sur capture le 2026-08-09 : une rangee de poteaux tous les deux blocs
	# sur deux cotes de chaque tuile produisait, une fois les champs mis bout a
	# bout, une PALISSADE continue en pleine campagne. Elle bouchait la vue,
	# barrait le passage et ne ressemblait a rien de rural. Quatre piquets
	# suffisent a dire « parcelle » sans construire de rempart.
	for corner: Vector2i in [Vector2i(1, 1), Vector2i(14, 1), Vector2i(1, 14), Vector2i(14, 14)]:
		blocks[Vector3i(corner.x, 1, corner.y)] = fence
	# UN ARBRE, parfois : c est ce qui casse la geometrie du damier agricole.
	if rng.randf() < 0.35:
		var tx := rng.randi_range(3, 12)
		var tz := rng.randi_range(3, 12)
		var trunk: int = palette.get("tronc", fence)
		var leaves: int = palette.get("feuillage", 0)
		var height := rng.randi_range(3, 5)
		for y in range(1, height + 1):
			blocks[Vector3i(tx, y, tz)] = trunk
		if leaves != 0:
			for dx in range(-2, 3):
				for dz in range(-2, 3):
					if absi(dx) + absi(dz) > 3:
						continue
					for dy in range(0, 2):
						var at := Vector3i(tx + dx, height + dy, tz + dz)
						if dx == 0 and dz == 0 and dy == 0:
							continue
						blocks[at] = leaves


static func _scatter_torches(blocks: Dictionary, palette: Dictionary,
		rng: RandomNumberGenerator, count: int) -> void:
	var torch: int = palette.get("torche", 0)
	var post: int = palette.get("poutre", palette["mur"])
	if torch == 0:
		return
	for _t in count:
		var x := rng.randi_range(1, 14)
		var z := rng.randi_range(1, 14)
		for y in range(1, 3):
			blocks[Vector3i(x, y, z)] = post
		blocks[Vector3i(x, 3, z)] = torch
