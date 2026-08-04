class_name DungeonGenerator
extends RefCounted
## Génération d'un ÉTAGE DE DONJON EN LABYRINTHE (3.5/E.29) — réécrit le
## 2026-08-02 sur demande de l'auteur : « l'étage d'un donjon est un labyrinthe
## qui fait un quart de la taille d'une cellule, rempli de couloirs et de salles
## avec un escalier pour monter et un escalier pour descendre ».
##
## CE QUI A CHANGÉ. La version précédente faisait croître un GRAPHE de salles
## préfabriquées reliées par des connecteurs, à extension libre : l'étage
## s'étalait où il pouvait, sans emprise définie, et se traversait en ligne
## droite de salle en salle. Un labyrinthe demande l'inverse — une emprise
## FERMÉE et connue, et un maillage dense où l'on peut se tromper de chemin.
##
## EMPRISE. Un quart de l'AIRE d'une cellule (128²/4), soit 64×64 blocs. La
## grille compte 12×12 cases de 5 blocs (couloir de 3 + mur de 2), plus 2 blocs
## de marge de chaque côté : 12×5 + 4 = 64 exactement.
##
## CE QUE CE FICHIER PRODUIT, ET CE QU'IL NE PRODUIT PAS. Il produit une GRILLE
## D'OCCUPATION au bloc (`open`), plus les métadonnées de placement (salles,
## escaliers, apparition). Il ne creuse rien : DungeonManager lit la grille et
## pose les blocs. Le partage des rôles est le même qu'avant, seule la monnaie
## d'échange a changé — une grille plutôt qu'une liste de boîtes, parce qu'un
## labyrinthe est mal décrit par des boîtes.
##
## ALGORITHME : parcours en profondeur aléatoire (labyrinthe parfait, une seule
## route entre deux points) PUIS TRESSAGE — on rouvre une partie des culs-de-sac
## pour créer des boucles. Un labyrinthe parfait se parcourt à la main droite et
## devient une corvée ; les boucles rendent le choix de direction réellement
## incertain. Enfin des SALLES : des rectangles de cases dont on abat les murs
## intérieurs, qui donnent le rythme (couloir étroit → grande salle) et les
## emplacements de butin et d'ennemis.

## Cases de labyrinthe par côté.
const GRID := 12
## Blocs par case : 3 de couloir + 2 de mur.
const PITCH := 5
const CORRIDOR := 3
## Marge de pierre pleine autour de la grille (le labyrinthe ne doit pas
## déboucher sur le vide de la dimension).
const MARGIN := 2
## Côté de l'étage en blocs — un quart de l'aire d'une cellule (128²/4 = 64²).
const SPAN := GRID * PITCH + MARGIN * 2
## Hauteur libre sous plafond (le sol est en y=0, le plafond en y=CEILING).
const CEILING := 6

## Proportion de culs-de-sac rouverts (tressage). À 0 le labyrinthe est parfait
## et se résout mécaniquement à la main droite ; à 1 il n'a plus d'impasses du
## tout et perd son intérêt. 0,4 en laisse assez pour récompenser l'exploration.
const BRAID_RATIO := 0.4

## Salles : nombre de base et par étage, et dimensions en CASES.
const BASE_ROOM_COUNT := 3
const ROOMS_PER_DEPTH := 1
const MAX_ROOM_COUNT := 7
const ROOM_MIN_CELLS := 2
const ROOM_MAX_CELLS := 3

const DIRS := {
	"nord": Vector3i(0, 0, 1),
	"sud": Vector3i(0, 0, -1),
	"est": Vector3i(1, 0, 0),
	"ouest": Vector3i(-1, 0, 0),
}
const OPPOSITE := {"nord": "sud", "sud": "nord", "est": "ouest", "ouest": "est"}

## Décalages de case. L'ORDRE COMPTE : les paires sont rangées (est, ouest) puis
## (nord, sud), ce qui fait de `d ^ 1` la direction opposée de `d` — utilisé
## pour ouvrir les deux côtés d'un mur d'un seul geste.
const CELL_STEPS: Array[Vector2i] = [
	Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1),
]


## Nombre de salles d'un étage donné (croît avec la profondeur).
static func room_count_for(depth: int) -> int:
	return mini(MAX_ROOM_COUNT, BASE_ROOM_COUNT + ROOMS_PER_DEPTH * depth)


## Coin bas-gauche (en blocs) de la case (i, j).
static func cell_origin(i: int, j: int) -> Vector2i:
	return Vector2i(MARGIN + i * PITCH, MARGIN + j * PITCH)


## Centre (en blocs) de la case (i, j).
static func cell_center(i: int, j: int) -> Vector2i:
	var o := cell_origin(i, j)
	return o + Vector2i(CORRIDOR / 2, CORRIDOR / 2)


## Génère l'étage.
##
## Retour :
##   "span"       : côté en blocs (SPAN)
##   "open"       : PackedByteArray SPAN×SPAN, 1 = sol praticable (indice z*SPAN+x)
##   "rooms"      : [{ "origin": Vector3i, "size": Vector3i, "cells": Rect2i }]
##   "up_stair"   : Vector3i — escalier de REMONTÉE (vers la sortie)
##   "down_stair" : Vector3i — escalier de DESCENTE, ou (-1,-1,-1) au dernier étage
##   "spawn"      : Vector3i — arrivée du joueur, sur l'escalier de remontée
##   "boss_room_index" : salle la plus reculée (boss/trésor)
static func generate_floor(seed_value: int, depth: int = 0, has_deeper: bool = true) -> Dictionary:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value

	# --- 1. Labyrinthe parfait par parcours en profondeur ---
	# `links[case]` = masque des 4 directions ouvertes (bit d = CELL_STEPS[d]).
	var links := PackedInt32Array()
	links.resize(GRID * GRID)
	var visited := PackedByteArray()
	visited.resize(GRID * GRID)
	var start := Vector2i(rng.randi() % GRID, rng.randi() % GRID)
	var stack: Array[Vector2i] = [start]
	visited[start.y * GRID + start.x] = 1
	while not stack.is_empty():
		var current: Vector2i = stack[stack.size() - 1]
		var options: Array[int] = []
		for d in CELL_STEPS.size():
			var n: Vector2i = current + CELL_STEPS[d]
			if n.x < 0 or n.x >= GRID or n.y < 0 or n.y >= GRID:
				continue
			if visited[n.y * GRID + n.x] == 0:
				options.append(d)
		if options.is_empty():
			stack.pop_back()
			continue
		var d_pick: int = options[rng.randi() % options.size()]
		var next: Vector2i = current + CELL_STEPS[d_pick]
		links[current.y * GRID + current.x] |= 1 << d_pick
		links[next.y * GRID + next.x] |= 1 << (d_pick ^ 1)
		visited[next.y * GRID + next.x] = 1
		stack.append(next)

	# --- 2. Tressage : on rouvre une part des culs-de-sac ---
	for j in GRID:
		for i in GRID:
			var mask := links[j * GRID + i]
			# Un cul-de-sac n'a qu'une seule sortie : son masque est une
			# puissance de deux.
			if mask == 0 or (mask & (mask - 1)) != 0:
				continue
			if rng.randf() > BRAID_RATIO:
				continue
			var closed: Array[int] = []
			for d in CELL_STEPS.size():
				if mask & (1 << d):
					continue
				var n := Vector2i(i, j) + CELL_STEPS[d]
				if n.x < 0 or n.x >= GRID or n.y < 0 or n.y >= GRID:
					continue
				closed.append(d)
			if closed.is_empty():
				continue
			var d_open: int = closed[rng.randi() % closed.size()]
			var n2 := Vector2i(i, j) + CELL_STEPS[d_open]
			links[j * GRID + i] |= 1 << d_open
			links[n2.y * GRID + n2.x] |= 1 << (d_open ^ 1)

	# --- 3. Salles : rectangles de cases dont les murs intérieurs tombent ---
	var rooms: Array[Dictionary] = []
	var target_rooms := room_count_for(depth)
	var room_cells := PackedByteArray()
	room_cells.resize(GRID * GRID)
	for attempt in 60:
		if rooms.size() >= target_rooms:
			break
		var w := ROOM_MIN_CELLS + rng.randi() % (ROOM_MAX_CELLS - ROOM_MIN_CELLS + 1)
		var h := ROOM_MIN_CELLS + rng.randi() % (ROOM_MAX_CELLS - ROOM_MIN_CELLS + 1)
		var ox := rng.randi() % maxi(GRID - w, 1)
		var oz := rng.randi() % maxi(GRID - h, 1)
		# Jamais deux salles qui se touchent : elles fusionneraient en une seule
		# nappe informe et le rythme couloir/salle disparaîtrait. On teste donc
		# le rectangle ÉLARGI D'UNE CASE.
		var clash := false
		for j in range(maxi(oz - 1, 0), mini(oz + h + 1, GRID)):
			for i in range(maxi(ox - 1, 0), mini(ox + w + 1, GRID)):
				if room_cells[j * GRID + i] == 1:
					clash = true
					break
			if clash:
				break
		if clash:
			continue
		for j in range(oz, oz + h):
			for i in range(ox, ox + w):
				room_cells[j * GRID + i] = 1
				# Abat les murs intérieurs de la salle.
				if i + 1 < ox + w:
					links[j * GRID + i] |= 1 << 0
					links[j * GRID + i + 1] |= 1 << 1
				if j + 1 < oz + h:
					links[j * GRID + i] |= 1 << 2
					links[(j + 1) * GRID + i] |= 1 << 3
		var o := cell_origin(ox, oz)
		rooms.append({
			"cells": Rect2i(ox, oz, w, h),
			"origin": Vector3i(o.x, 0, o.y),
			"size": Vector3i(w * PITCH - (PITCH - CORRIDOR), CEILING, h * PITCH - (PITCH - CORRIDOR)),
		})

	# --- 4. Grille d'occupation au BLOC ---
	var open := PackedByteArray()
	open.resize(SPAN * SPAN)
	for j in GRID:
		for i in GRID:
			var o := cell_origin(i, j)
			_fill(open, o.x, o.y, CORRIDOR, CORRIDOR)
			var mask := links[j * GRID + i]
			# Percement des murs. Seuls l'est et le nord sont traités : le mur
			# ouest d'une case EST le mur est de sa voisine, et le percer des
			# deux côtés le percerait deux fois.
			if mask & (1 << 0):
				_fill(open, o.x + CORRIDOR, o.y, PITCH - CORRIDOR, CORRIDOR)
			if mask & (1 << 2):
				_fill(open, o.x, o.y + CORRIDOR, CORRIDOR, PITCH - CORRIDOR)

	# --- 5. Escaliers et apparition ---
	# Remontée : la case de départ du parcours. Descente : la case la PLUS LOIN
	# d'elle AU SENS DU LABYRINTHE (BFS sur les liens, pas à vol d'oiseau) —
	# c'est ce que le joueur doit chercher, et la mesurer à vol d'oiseau
	# donnerait parfois une descente toute proche, à deux murs de l'arrivée.
	var up_cell := start
	var far_cell := _farthest_cell(links, up_cell)
	var up_center := cell_center(up_cell.x, up_cell.y)
	var down_center := cell_center(far_cell.x, far_cell.y)

	# Salle du boss : celle qui contient la case la plus reculée, sinon la
	# dernière posée — il en faut TOUJOURS une, c'est elle qui porte le coffre.
	var boss_index := maxi(rooms.size() - 1, 0)
	for index in rooms.size():
		if (rooms[index]["cells"] as Rect2i).has_point(far_cell):
			boss_index = index
			break

	# CULS-DE-SAC : les cases n'ayant qu'une seule sortie, hors salles. Ce sont
	# les emplacements naturels du butin d'un labyrinthe — sans récompense au
	# bout, explorer une impasse est une pure perte de temps et le joueur
	# apprend vite à ne plus le faire, ce qui vide le labyrinthe de son sens.
	var dead_ends: Array[Vector3i] = []
	for j in GRID:
		for i in GRID:
			if room_cells[j * GRID + i] == 1:
				continue
			var mask := links[j * GRID + i]
			if mask != 0 and (mask & (mask - 1)) == 0:
				var c := cell_center(i, j)
				dead_ends.append(Vector3i(c.x, 0, c.y))

	return {
		"span": SPAN,
		"open": open,
		"rooms": rooms,
		"dead_ends": dead_ends,
		"boss_room_index": boss_index,
		"up_stair": Vector3i(up_center.x, 0, up_center.y),
		"down_stair": Vector3i(down_center.x, 0, down_center.y) if has_deeper else Vector3i(-1, -1, -1),
		"spawn": Vector3i(up_center.x, 0, up_center.y),
	}


## Ouvre un rectangle de blocs dans la grille d'occupation.
static func _fill(open: PackedByteArray, x0: int, z0: int, w: int, h: int) -> void:
	for z in range(z0, z0 + h):
		if z < 0 or z >= SPAN:
			continue
		for x in range(x0, x0 + w):
			if x < 0 or x >= SPAN:
				continue
			open[z * SPAN + x] = 1


## Case la plus éloignée de `from` EN NOMBRE DE PAS DANS LE LABYRINTHE (BFS sur
## les liens ouverts). Sert à placer l'escalier de descente le plus loin
## possible du point d'arrivée.
static func _farthest_cell(links: PackedInt32Array, from: Vector2i) -> Vector2i:
	var dist := PackedInt32Array()
	dist.resize(GRID * GRID)
	dist.fill(-1)
	dist[from.y * GRID + from.x] = 0
	var queue: Array[Vector2i] = [from]
	var best := from
	var head := 0
	while head < queue.size():
		var current: Vector2i = queue[head]
		head += 1
		var here := dist[current.y * GRID + current.x]
		if here > dist[best.y * GRID + best.x]:
			best = current
		var mask := links[current.y * GRID + current.x]
		for d in CELL_STEPS.size():
			if not (mask & (1 << d)):
				continue
			var n: Vector2i = current + CELL_STEPS[d]
			if n.x < 0 or n.x >= GRID or n.y < 0 or n.y >= GRID:
				continue
			if dist[n.y * GRID + n.x] >= 0:
				continue
			dist[n.y * GRID + n.x] = here + 1
			queue.append(n)
	return best


## Blocs praticables atteignables depuis l'escalier de remontée (BFS au bloc).
## Sert aux VÉRIFICATIONS et au placement : un ennemi, un coffre ou l'escalier
## de descente posé dans une poche non reliée serait perdu pour toujours.
static func reachable_blocks(floor_data: Dictionary) -> Dictionary:
	var open: PackedByteArray = floor_data["open"]
	var span: int = floor_data["span"]
	var start: Vector3i = floor_data["spawn"]
	var seen := {}
	var origin := Vector2i(start.x, start.z)
	if open[origin.y * span + origin.x] == 0:
		return seen
	seen[origin] = true
	var queue: Array[Vector2i] = [origin]
	var head := 0
	while head < queue.size():
		var current: Vector2i = queue[head]
		head += 1
		for step: Vector2i in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
			var n: Vector2i = current + step
			if n.x < 0 or n.x >= span or n.y < 0 or n.y >= span:
				continue
			if open[n.y * span + n.x] == 0 or seen.has(n):
				continue
			seen[n] = true
			queue.append(n)
	return seen
