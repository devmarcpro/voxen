class_name DungeonGenerator
extends RefCounted
## Génération procédurale d'un étage de donjon (E.29, 3.5) — classe statique
## pure, comme TreeGenerator/PlantGenerator/POIGenerator : mêmes coordonnées
## + même graine → même donjon, à chaque appel (G.1).
##
## CE QUE CE FICHIER DÉCIDE, ET CE QU'IL NE DÉCIDE PAS. Il produit le GRAPHE de
## l'étage : quelles salles, où, reliées par quels couloirs. La FORME des
## salles ne lui appartient pas — elles ne sont plus des boîtes depuis le
## 2026-08-02, mais des cavités organiques sculptées au bruit par
## `DungeonCavern`, et creusées par `DungeonManager._carve_room`. Ici, une
## salle n'est qu'une boîte ENGLOBANTE servant au placement et au test de
## chevauchement.
##
## SIMPLIFICATIONS ENCORE EN PLACE :
## - Salles JAMAIS tournées, seulement translatées : chaque salle garde
##   l'orientation de ses portes telle que déclarée dans son JSON. Formes
##   moins variées qu'un vrai algorithme avec rotation, mais génération
##   robuste et simple. La déformation au bruit compense largement : deux
##   salles du même gabarit ne se ressemblent plus.
## - Pas de modèles .vox de décor importés (B.10 prévoit `vox_model`, ignoré).
## - Peuplement en créatures : seul le boss du dernier étage existe. Le BUTIN,
##   lui, est posé depuis le 2026-08-02 (voir DungeonLoot).

const DIRS := {
	"nord": Vector3i(0, 0, 1),
	"sud": Vector3i(0, 0, -1),
	"est": Vector3i(1, 0, 0),
	"ouest": Vector3i(-1, 0, 0),
}
const OPPOSITE := {"nord": "sud", "sud": "nord", "est": "ouest", "ouest": "est"}

## Nombre de salles visé, entrée comprise. Le GDD n'en demandait que « 2-3 »
## pour le jalon D.3.8 ; l'auteur en a demandé davantage le 2026-08-02, un
## étage de quatre salles se traversant en moins d'une minute.
##
## Le compte MONTE AVEC LA PROFONDEUR : les premiers étages restent lisibles,
## les derniers deviennent de vrais labyrinthes. C'est aussi ce qui rend la
## descente coûteuse en temps, donc le retour à la surface un choix.
const BASE_ROOM_COUNT := 8
const ROOMS_PER_DEPTH := 2
const MAX_ROOM_COUNT := 18
## Tentatives de placement par porte ouverte. Relevé de 6 à 12 avec
## l'agrandissement des salles : elles se gênent davantage, et un budget trop
## court faisait échouer les placements tardifs — l'étage plafonnait alors bien
## en dessous du nombre visé.
const MAX_ATTEMPTS_PER_DOOR := 12


## Nombre de salles d'un étage donné.
static func room_count_for(depth: int) -> int:
	return mini(MAX_ROOM_COUNT, BASE_ROOM_COUNT + ROOMS_PER_DEPTH * depth)


## Génère l'étage : { "rooms": [{ "def_id", "origin": Vector3i, "size": Vector3i,
## "tags": [], "graph_index": int }], "corridors": [{ "origin": Vector3i,
## "dir": String, "length": int }], "boss_room_index": int }.
static func generate_floor(seed_value: int, target_rooms: int = BASE_ROOM_COUNT) -> Dictionary:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value

	var room_defs: Array = GameData.dungeon_rooms.values().filter(func(r): return r["id"] != "entree")
	var connector_defs: Array = GameData.dungeon_connectors.values()
	var entree_def: Dictionary = GameData.dungeon_rooms.get("entree", {})
	if entree_def.is_empty() or room_defs.is_empty() or connector_defs.is_empty():
		return {}  # Données de donjon absentes (ne devrait pas arriver, GameData valide leur présence).

	var rooms: Array[Dictionary] = []
	var corridors: Array[Dictionary] = []
	var edges: Array[Vector2i] = []  # (room_index_a, room_index_b) — pour le BFS de profondeur.
	var open_doors: Array[Dictionary] = []  # { "room_index", "door_index" }

	rooms.append({
		"def_id": "entree", "origin": Vector3i.ZERO,
		"size": Vector3i(entree_def["size"][0], entree_def["size"][1], entree_def["size"][2]),
		"tags": entree_def.get("special_tags", []), "doors": entree_def["doors"], "doors_used": [false],
	})
	open_doors.append({"room_index": 0, "door_index": 0})

	while rooms.size() < target_rooms and not open_doors.is_empty():
		var pick := rng.randi() % open_doors.size()
		var chosen: Dictionary = open_doors[pick]
		open_doors.remove_at(pick)
		var src_room: Dictionary = rooms[chosen["room_index"]]
		if src_room["doors_used"][chosen["door_index"]]:
			continue
		var door: Dictionary = src_room["doors"][chosen["door_index"]]
		var direction: String = door["direction"]
		var door_local := Vector3i(door["position"][0], door["position"][1], door["position"][2])
		var d: Vector3i = DIRS[direction]

		var connector: Dictionary = connector_defs[rng.randi() % connector_defs.size()]
		var length: int = connector["length"]
		var attach_world: Vector3i = src_room["origin"] + door_local + d * (length + 1)

		var candidates := room_defs.duplicate()
		for i in range(candidates.size() - 1, 0, -1):
			var j := rng.randi() % (i + 1)
			var tmp = candidates[i]
			candidates[i] = candidates[j]
			candidates[j] = tmp
		var placed := false
		var attempts := 0
		for candidate: Dictionary in candidates:
			if attempts >= MAX_ATTEMPTS_PER_DOOR:
				break
			var required_dir: String = OPPOSITE[direction]
			var matching_doors := []
			for i in candidate["doors"].size():
				if candidate["doors"][i]["direction"] == required_dir:
					matching_doors.append(i)
			if matching_doors.is_empty():
				continue
			attempts += 1
			var door_index: int = matching_doors[rng.randi() % matching_doors.size()]
			var next_door_local := Vector3i(candidate["doors"][door_index]["position"][0],
					candidate["doors"][door_index]["position"][1], candidate["doors"][door_index]["position"][2])
			var next_origin := attach_world - next_door_local
			var next_size := Vector3i(candidate["size"][0], candidate["size"][1], candidate["size"][2])
			if _overlaps_any(next_origin, next_size, rooms) or _overlaps_corridor(next_origin, next_size, corridors):
				continue
			# Placement accepté.
			src_room["doors_used"][chosen["door_index"]] = true
			var new_index := rooms.size()
			var doors_used_init: Array = []
			for i in candidate["doors"].size():
				doors_used_init.append(i == door_index)
			rooms.append({
				"def_id": candidate["id"], "origin": next_origin, "size": next_size,
				"tags": candidate.get("special_tags", []), "doors": candidate["doors"], "doors_used": doors_used_init,
			})
			corridors.append({"origin": src_room["origin"] + door_local + d, "dir": direction, "length": length})
			edges.append(Vector2i(chosen["room_index"], new_index))
			for i in candidate["doors"].size():
				if i != door_index:
					open_doors.append({"room_index": new_index, "door_index": i})
			placed = true
			break
		# Échec (toutes les candidates testées en collision) : la porte reste
		# simplement inutilisée, pas de boucle infinie (max `target_rooms`
		# itérations de toute façon).
		if not placed:
			continue

	var boss_index := _deepest_room(rooms.size(), edges)
	return {"rooms": rooms, "corridors": corridors, "boss_room_index": boss_index}


static func _overlaps_any(origin: Vector3i, size: Vector3i, rooms: Array[Dictionary]) -> bool:
	for room: Dictionary in rooms:
		if _aabb_overlap(origin, size, room["origin"], room["size"]):
			return true
	return false


static func _overlaps_corridor(origin: Vector3i, size: Vector3i, corridors: Array[Dictionary]) -> bool:
	for c: Dictionary in corridors:
		var d: Vector3i = DIRS[c["dir"]]
		var perp: Vector3i = Vector3i(1, 0, 0) if d.x == 0 else Vector3i(0, 0, 1)
		var c_origin: Vector3i = c["origin"] - perp
		var c_length: int = c["length"]
		var c_size: Vector3i = Vector3i(1, 5, 1) + perp * 2 + Vector3i(absi(d.x), 0, absi(d.z)) * (c_length - 1)
		if _aabb_overlap(origin, size, c_origin, c_size):
			return true
	return false


static func _aabb_overlap(a_origin: Vector3i, a_size: Vector3i, b_origin: Vector3i, b_size: Vector3i) -> bool:
	const MARGIN := 1  # Marge d'1 bloc : jamais deux salles mur-à-mur sans le vouloir.
	return (a_origin.x - MARGIN < b_origin.x + b_size.x and a_origin.x + a_size.x + MARGIN > b_origin.x
			and a_origin.z - MARGIN < b_origin.z + b_size.z and a_origin.z + a_size.z + MARGIN > b_origin.z
			and a_origin.y < b_origin.y + b_size.y and a_origin.y + a_size.y > b_origin.y)


## BFS depuis l'entrée (index 0) — la salle la plus distante devient la salle
## du boss (E.29 : « la salle la plus distante de l'entrée »).
static func _deepest_room(room_count: int, edges: Array[Vector2i]) -> int:
	if room_count <= 1:
		return 0
	var adjacency := {}
	for i in room_count:
		adjacency[i] = []
	for e in edges:
		adjacency[e.x].append(e.y)
		adjacency[e.y].append(e.x)
	var dist := {0: 0}
	var queue: Array[int] = [0]
	var farthest := 0
	while not queue.is_empty():
		var current: int = queue.pop_front()
		for neighbor in adjacency[current]:
			if not dist.has(neighbor):
				dist[neighbor] = dist[current] + 1
				queue.append(neighbor)
				if dist[neighbor] > dist[farthest]:
					farthest = neighbor
	return farthest
