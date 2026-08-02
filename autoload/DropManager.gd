extends Node
## DropManager — objets tombés au sol (A.10 : « chaque objet de l'inventaire a
## 10 % de chance de tomber au sol sur le lieu de mort, récupérable pendant
## 1 jour in-game »). C'est aujourd'hui le SEUL producteur de caches : le loot
## de créatures (F.7) et le lâcher volontaire d'objets n'existent pas encore,
## mais l'API (`drop`) est déjà la bonne porte d'entrée pour eux.
##
## Persistant via SaveManager (E.10, state.json). L'expiration est comptée en
## TICKS (E.1), jamais en secondes réelles : une cache posée avant une
## sauvegarde expire correctement au rechargement.

## 1 jour in-game (E.1 : 24 000 ticks/jour, même horloge que le reste).
const LIFETIME_TICKS := 24000
## Distance de ramassage, en blocs.
const PICKUP_RADIUS := 3.0
## Purge périodique — inutile de balayer la liste à chaque tick (G.1 : throttle).
const PURGE_INTERVAL_TICKS := 100

## Caches actives : [{ "position": Vector3, "objects": Array[Dictionary],
##                     "gold": int, "expire_tick": int, "dimension": StringName,
##                     "kind": String }]
##
## `dimension` (2026-08-02) — BUG RÉEL corrigé en même temps que le loot de
## donjon. Un donjon est une dimension séparée qui occupe LES MÊMES
## COORDONNÉES que l'overworld, près de l'origine du monde. Sans ce champ, une
## cache posée dans une salle de donjon était visible ET ramassable depuis
## l'overworld, à quelques blocs du point de spawn du joueur. Personne ne
## l'avait vu parce que rien ne déposait encore de cache en donjon.
##
## `kind` : "cache" (défaut) ou "coffre" — purement visuel, le coffre de boss
## mérite d'être reconnaissable de loin.
var caches: Array[Dictionary] = []

## Durée de vie des caches de donjon. Elles ne doivent PAS expirer au bout d'un
## jour comme un butin de mort : elles font partie du décor de l'étage, et un
## joueur qui explore lentement trouverait des salles vides sans comprendre
## pourquoi. Elles disparaissent en étant ramassées, pas avec le temps.
const DUNGEON_LIFETIME_TICKS := 1 << 40

var _marker_root: Node3D
var _markers: Array[Node3D] = []
var _purge_counter := 0


func _ready() -> void:
	TickManager.tick_world.connect(_on_tick)


## Dépose une cache. `objects` = instances d'objets (ItemFactory), `gold` =
## or lâché. Ne crée rien si les deux sont vides.
## `kind` : "coffre" pour un coffre de boss (marqueur distinct, jamais
## expirant). Une cache est toujours attachée à la dimension COURANTE : c'est
## celle où le joueur se trouve au moment du dépôt, donc celle où elle doit
## être visible.
func drop(position: Vector3, objects: Array, gold: int = 0, kind: String = "cache") -> void:
	if objects.is_empty() and gold <= 0:
		return
	var typed: Array[Dictionary] = []
	for obj: Variant in objects:
		if obj is Dictionary:
			typed.append(obj)
	var in_dungeon := WorldManager.active_dimension != &"overworld"
	caches.append({
		"position": position,
		"objects": typed,
		"gold": gold,
		"expire_tick": TickManager.tick_index + (DUNGEON_LIFETIME_TICKS if in_dungeon else LIFETIME_TICKS),
		"dimension": WorldManager.active_dimension,
		"kind": kind,
	})
	_refresh_markers()


## Dépose une cache de MATÉRIAUX en vrac (lâcher volontaire depuis
## l'inventaire). Même durée de vie et même ramassage que les objets.
func drop_materials(position: Vector3, stacks: Dictionary) -> void:
	if stacks.is_empty():
		return
	caches.append({
		"position": position,
		"objects": [] as Array[Dictionary],
		"materials": stacks.duplicate(),
		"gold": 0,
		"expire_tick": TickManager.tick_index + LIFETIME_TICKS,
		"dimension": WorldManager.active_dimension,
		"kind": "cache",
	})
	_refresh_markers()


## Appelé par WorldManager à chaque bascule de dimension : les marqueurs
## visibles changent entièrement (voir `_visible_here`).
func on_dimension_changed() -> void:
	_refresh_markers()


## Une cache appartient-elle à la dimension où se trouve le joueur ?
## Les caches d'avant 2026-08-02 n'ont pas le champ : on les suppose dans
## l'overworld, ce qu'elles étaient toutes (rien ne déposait en donjon).
func _visible_here(cache: Dictionary) -> bool:
	return StringName(cache.get("dimension", &"overworld")) == WorldManager.active_dimension


## Cache la plus proche de `position` dans PICKUP_RADIUS, ou -1. Ignore les
## caches d'une AUTRE dimension : sans ce filtre, un joueur debout près de
## l'origine de l'overworld ramassait le butin posé dans un donjon.
func nearest_cache(position: Vector3) -> int:
	var best := -1
	var best_dist := PICKUP_RADIUS * PICKUP_RADIUS
	for i in caches.size():
		if not _visible_here(caches[i]):
			continue
		var d: float = (caches[i]["position"] as Vector3).distance_squared_to(position)
		if d <= best_dist:
			best_dist = d
			best = i
	return best


## Vide la cache `index` dans l'inventaire fourni et retourne l'or récupéré.
## L'appelant crédite l'or (le porte-monnaie vit sur le joueur, pas ici).
func collect(index: int, inventory: Inventory) -> int:
	if index < 0 or index >= caches.size():
		return 0
	var cache: Dictionary = caches[index]
	for obj: Dictionary in cache["objects"]:
		inventory.add_object(obj)
	for material_id: String in (cache.get("materials", {}) as Dictionary):
		inventory.add_material(material_id, int(cache["materials"][material_id]))
	var gold := int(cache["gold"])
	caches.remove_at(index)
	_refresh_markers()
	return gold


func _on_tick(_tick_index: int) -> void:
	_purge_counter += 1
	if _purge_counter < PURGE_INTERVAL_TICKS:
		return
	_purge_counter = 0
	var before := caches.size()
	var kept: Array[Dictionary] = []
	for cache in caches:
		if int(cache["expire_tick"]) > TickManager.tick_index:
			kept.append(cache)
	if kept.size() != before:
		caches = kept
		_refresh_markers()


## Marqueurs visuels — une petite boîte par cache. Reconstruits en bloc à
## chaque changement : les caches se comptent sur les doigts d'une main, un
## suivi incrémental serait de la complexité pour rien.
func _refresh_markers() -> void:
	for marker in _markers:
		if is_instance_valid(marker):
			marker.queue_free()
	_markers.clear()
	if caches.is_empty():
		return
	if _marker_root == null or not is_instance_valid(_marker_root):
		var main := get_node_or_null("/root/Main")
		if main == null:
			return
		_marker_root = Node3D.new()
		_marker_root.name = "DropMarkers"
		main.add_child(_marker_root)
	for cache in caches:
		# Une cache d'une autre dimension n'a pas de marqueur : le donjon
		# partage les coordonnées de l'overworld, ses boîtes flotteraient
		# donc en plein ciel près du point de spawn.
		if not _visible_here(cache):
			continue
		var is_chest: bool = String(cache.get("kind", "cache")) == "coffre"
		var marker := MeshInstance3D.new()
		var box := BoxMesh.new()
		# Le coffre de boss est plus gros et plus clair : c'est la récompense
		# du donjon, il doit se repérer du seuil de la salle.
		box.size = Vector3(0.9, 0.6, 0.6) if is_chest else Vector3(0.5, 0.35, 0.5)
		marker.mesh = box
		var mat := StandardMaterial3D.new()
		mat.albedo_color = Color(0.95, 0.78, 0.30) if is_chest else Color(0.75, 0.6, 0.25)
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		marker.material_override = mat
		marker.position = cache["position"]
		_marker_root.add_child(marker)
		_markers.append(marker)


# --- Sauvegarde (E.10, via SaveManager) ---

func save_state() -> Array:
	var out: Array = []
	for cache in caches:
		var pos: Vector3 = cache["position"]
		out.append({
			"pos": [pos.x, pos.y, pos.z],
			"objects": cache["objects"],
			"materials": cache.get("materials", {}),
			"gold": int(cache["gold"]),
			"expire_tick": int(cache["expire_tick"]),
			"dimension": String(cache.get("dimension", &"overworld")),
			"kind": String(cache.get("kind", "cache")),
		})
	return out


func restore_state(data: Array) -> void:
	caches.clear()
	for entry: Variant in data:
		if not (entry is Dictionary):
			continue
		var cache: Dictionary = entry
		var pos: Array = cache.get("pos", [])
		if pos.size() != 3:
			continue
		var objects: Array[Dictionary] = []
		for obj: Variant in cache.get("objects", []):
			if obj is Dictionary:
				objects.append(obj)
		caches.append({
			"position": Vector3(float(pos[0]), float(pos[1]), float(pos[2])),
			"objects": objects,
			"materials": cache.get("materials", {}),
			"gold": int(cache.get("gold", 0)),
			"expire_tick": int(cache.get("expire_tick", 0)),
			# Sauvegardes d'avant 2026-08-02 : pas de dimension, et toutes
			# étaient dans l'overworld — rien ne déposait encore en donjon.
			"dimension": StringName(cache.get("dimension", "overworld")),
			"kind": String(cache.get("kind", "cache")),
		})
	_refresh_markers()
