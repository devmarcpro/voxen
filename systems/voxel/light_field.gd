class_name LightField
extends RefCounted
## Propagation de lumière de bloc (G.3) : niveaux 0-15, décroissance de 1 par
## bloc, arrêt sur les blocs opaques. C'est ce qui donne enfin un sens à la
## stat `luminosite` (A.4.5) : sans elle, une torche n'était qu'un bloc jaune.
##
## Calculé DANS le thread de meshing, à partir du tableau PADDÉ 18³ que le
## mesher construit déjà (chunk + 1 bloc de voisinage). Deux raisons :
##  - un chunk fraîchement généré n'existe pas encore côté thread principal,
##    ses sources ne peuvent donc pas être connues à l'avance ;
##  - le pad porte exactement l'occlusion nécessaire, sans aucun accès
##    concurrent à l'état du monde.
##
## SIMPLIFICATIONS ASSUMÉES, à lever le jour où l'éclairage devient central :
##  - G.3 décrit un flood fill INCRÉMENTAL (deltas, file dédiée, budget par
##    tick) ; ici c'est un recalcul complet par chunk maillé. Le coût est
##    borné (le pad fait 5 832 cellules) mais payé à chaque remesh.
##  - une source située à plus d'un bloc HORS du chunk n'éclaire pas dedans :
##    sa lumière s'arrête à la frontière. Visible seulement pour une torche
##    posée juste derrière une bordure de chunk.
##  - pas de skylight : la lumière du jour est un uniform global (E.21), pas
##    une propagation par colonne comme le prévoit G.3.

const MAX_LEVEL := 15
const SIZE := ChunkData.SIZE
## Mêmes dimensions et strides que le tableau paddé du mesher.
const P := 18
const SX := 1
const SY := 324
const SZ := 18
## Décalages d'INDICE des 6 voisins, dans l'ordre +x, -x, +y, -y, +z, -z.
## La boucle de propagation allouait un Array littéral de 6 Vector3i À CHAQUE
## dépilement — des milliers d'allocations par chunk éclairé, plus le typage
## dynamique du `for offset: Vector3i in [...]`. Les voisins d'une cellule du
## pad sont à distance constante : un simple `index + offset` suffit, les bornes
## étant testées sur les coordonnées décomposées (audit 2026-07-27).
static var NEIGHBOUR_OFFSETS := PackedInt32Array([SX, -SX, SY, -SY, SZ, -SZ])
## Mêmes 6 voisins, en deltas de COORDONNÉES — servent au seul test de bornes.
static var NEIGHBOUR_DX := PackedInt32Array([1, -1, 0, 0, 0, 0])
static var NEIGHBOUR_DY := PackedInt32Array([0, 0, 1, -1, 0, 0])
static var NEIGHBOUR_DZ := PackedInt32Array([0, 0, 0, 0, 1, -1])


## Champ de lumière paddé (18³) calculé depuis `pad`, le tableau de blocs
## paddé du mesher. Retourne un tableau VIDE si aucune source n'est présente —
## le cas de l'immense majorité des chunks, qui ne paie alors rien.
static func compute_from_pad(pad: PackedInt32Array) -> PackedByteArray:
	var emission := GameData.emission_by_runtime
	var transmits := GameData.transmits_by_runtime
	if emission.is_empty():
		return PackedByteArray()

	# 1. Repérage des sources. Une simple lecture de table par cellule : les
	# sources sont rares, la boucle sort presque toujours les mains vides.
	var sources: PackedInt32Array = []
	var levels: PackedInt32Array = []
	for index in pad.size():
		var id := pad[index]
		if id <= 0 or id >= emission.size():
			continue
		var level := int(emission[id])
		if level > 0:
			sources.append(index)
			levels.append(level)
	if sources.is_empty():
		return PackedByteArray()

	var light := PackedByteArray()
	light.resize(P * P * P)
	for i in sources.size():
		light[sources[i]] = maxi(int(light[sources[i]]), levels[i])

	# 2. Propagation en largeur. File à curseur (jamais de suppression en
	# tête, qui serait O(n) sur un Array GDScript).
	var queue := sources.duplicate()
	var cursor := 0
	# Copies LOCALES des tables de voisinage : un accès `static var` coûte plus
	# cher qu'une locale, et celles-ci sont lues 4 fois par voisin visité.
	var off := NEIGHBOUR_OFFSETS
	var ddx := NEIGHBOUR_DX
	var ddy := NEIGHBOUR_DY
	var ddz := NEIGHBOUR_DZ
	while cursor < queue.size():
		var index: int = queue[cursor]
		cursor += 1
		var level := int(light[index])
		if level <= 1:
			continue
		var next_level := level - 1
		# Voisins dans le pad, en sautant ceux qui sortiraient du tableau.
		var x := index % P
		var y := index / SY
		var z := (index / SZ) % P
		for k in 6:
			var nx := x + ddx[k]
			var ny := y + ddy[k]
			var nz := z + ddz[k]
			if nx < 0 or ny < 0 or nz < 0 or nx >= P or ny >= P or nz >= P:
				continue
			var neighbour := index + off[k]
			if int(light[neighbour]) >= next_level:
				continue
			var id := pad[neighbour]
			# Un bloc opaque reçoit la lumière (sa face s'éclaire) mais ne la
			# propage pas plus loin — d'où l'écriture SANS remise en file.
			var opaque := id > 0 and (id >= transmits.size() or transmits[id] == 0)
			light[neighbour] = next_level
			if not opaque:
				queue.append(neighbour)
	return light


## Niveau lu dans un champ paddé, en coordonnées LOCALES au chunk (-1 à SIZE).
## Tolère un champ vide (obscurité totale) et les positions hors bornes.
static func level_at(light: PackedByteArray, local: Vector3i) -> int:
	if light.is_empty():
		return 0
	if local.x < -1 or local.y < -1 or local.z < -1 or local.x > SIZE or local.y > SIZE or local.z > SIZE:
		return 0
	return int(light[(local.x + 1) * SX + (local.z + 1) * SZ + (local.y + 1) * SY])
