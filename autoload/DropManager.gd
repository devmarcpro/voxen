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
## `kind` : "cache" (défaut). Le genre "coffre" existait pour le butin de boss ;
## depuis le 2026-08-03 celui-ci est un VRAI coffre posé (ContainerManager), et
## plus aucune cache ne l'utilise. Le champ reste lu pour les sauvegardes
## antérieures.
var caches: Array[Dictionary] = []

## Durée de vie des caches de donjon. Elles ne doivent PAS expirer au bout d'un
## jour comme un butin de mort : elles font partie du décor de l'étage, et un
## joueur qui explore lentement trouverait des salles vides sans comprendre
## pourquoi. Elles disparaissent en étant ramassées, pas avec le temps.
const DUNGEON_LIFETIME_TICKS := 1 << 40

## Script de rendu d'objet, réutilisé pour les objets au sol (voir
## `_build_cache_markers`). `preload` et non `class_name` : le script n'en
## déclare pas, et la ressource doit exister avant le premier dépôt.
const HELD_ITEM_SCRIPT := preload("res://scenes/entities/held_item.gd")

## Identifiant réseau d'une cache, attribué par l'AUTORITÉ. Comme pour les
## créatures, l'INDEX ne peut pas servir : il change dès qu'une cache est
## ramassée, et deux camps se retrouveraient à parler de deux tas différents en
## croyant désigner le même.
var _next_net_id := 1

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
	var net_id := _next_net_id
	_next_net_id += 1
	caches.append({
		"position": position,
		"objects": typed,
		"gold": gold,
		"expire_tick": TickManager.tick_index + (DUNGEON_LIFETIME_TICKS if in_dungeon else LIFETIME_TICKS),
		"dimension": WorldManager.active_dimension,
		"kind": kind,
		"net_id": net_id,
	})
	_refresh_markers()
	if NetworkManager.is_authority() and NetworkManager.has_peers():
		NetworkManager.rpc_drop.rpc(net_id, position, typed, gold,
				String(WorldManager.active_dimension), kind)


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
	var net_id := int(cache.get("net_id", 0))
	caches.remove_at(index)
	_refresh_markers()
	# UNE CACHE RAMASSÉE DISPARAÎT POUR TOUT LE MONDE. Sans cette annonce, deux
	# joueurs pourraient ramasser le MÊME tas — chacun le voyant encore chez lui
	# — et l'objet serait dupliqué. C'est la duplication la plus facile à
	# provoquer d'un jeu multijoueur, et il suffit de courir à deux vers un mort.
	if net_id > 0 and NetworkManager.is_authority() and NetworkManager.has_peers():
		NetworkManager.rpc_drop_removed.rpc(net_id)
	return gold


## Cache portant cet identifiant réseau, ou -1.
func index_of_net_id(net_id: int) -> int:
	for i in caches.size():
		if int((caches[i] as Dictionary).get("net_id", 0)) == net_id:
			return i
	return -1


## Applique une cache ANNONCÉE par l'autorité. Le client ne décide d'aucun
## butin : il l'affiche.
func apply_remote_drop(net_id: int, position: Vector3, objects: Array, gold: int,
		dimension: StringName, kind: String) -> void:
	if index_of_net_id(net_id) >= 0:
		return  # Déjà connue : un message rejoué ne doit pas dédoubler le tas.
	var typed: Array[Dictionary] = []
	for obj: Variant in objects:
		if obj is Dictionary:
			typed.append(obj)
	caches.append({
		"position": position, "objects": typed, "gold": gold,
		"expire_tick": TickManager.tick_index + LIFETIME_TICKS,
		"dimension": dimension, "kind": kind, "net_id": net_id,
	})
	_next_net_id = maxi(_next_net_id, net_id + 1)
	_refresh_markers()


func apply_remote_removed(net_id: int) -> void:
	var index := index_of_net_id(net_id)
	if index >= 0:
		caches.remove_at(index)
		_refresh_markers()


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
		# partage les coordonnées de l'overworld, ses objets flotteraient
		# donc en plein ciel près du point de spawn.
		if not _visible_here(cache):
			continue
		_build_cache_markers(cache)


## Construit les VRAIS OBJETS AU SOL d'une cache (2026-08-02, demande explicite
## « rajouter dans le code la fonctionnalité pour avoir des items par terre »).
##
## Chaque objet du tas a sa propre représentation, rendue avec SON modèle —
## épée, livre, lingot — et non plus une boîte jaune unique pour tout le tas. On
## voit ce qui traîne avant de s'en approcher, ce qui est tout l'intérêt d'un
## butin au sol dans un donjon.
##
## RÉUTILISE `HeldItem` en source « explicite » plutôt que de refaire le rendu.
## Ce pipeline sait déjà assembler une arme en pièces, extruder un sprite
## d'outil, remapper un .vox par matériaux et texturer un cube de bloc : en
## réécrire une variante ici aurait garanti qu'elle diverge au premier type
## d'objet ajouté.
func _build_cache_markers(cache: Dictionary) -> void:
	var base: Vector3 = cache["position"]
	var objects: Array = cache.get("objects", [])
	# Les objets d'un même tas sont disposés en cercle pour ne pas se
	# superposer, et tournés différemment : un tas de trois épées empilées au
	# même point ne se lit pas comme trois épées.
	for i in objects.size():
		var pivot := Node3D.new()
		var angle := TAU * float(i) / float(maxi(objects.size(), 1))
		var spread := 0.0 if objects.size() == 1 else 0.45
		pivot.position = base + Vector3(cos(angle) * spread, 0.15, sin(angle) * spread)
		pivot.rotation_degrees = Vector3(0.0, rad_to_deg(angle) + 35.0, 0.0)
		_marker_root.add_child(pivot)
		# `HeldItem` est un SCRIPT posé sur un MeshInstance3D dans main.tscn, pas
		# une scène : il n'y a rien à instancier, on construit le nœud et on lui
		# attache le script. Les propriétés doivent être posées AVANT
		# `add_child`, qui déclenche `_ready`.
		var item := MeshInstance3D.new()
		item.set_script(HELD_ITEM_SCRIPT)
		item.source = "explicite"
		item.explicit_entry = {"kind": "object", "object": objects[i]}
		item.in_hand = false
		pivot.add_child(item)
		_markers.append(pivot)

	# L'OR et les MATÉRIAUX en vrac n'ont pas de modèle d'objet : ils gardent un
	# repère géométrique. Le coffre de boss aussi — c'est un contenant, pas un
	# objet du catalogue, et il doit se repérer depuis le seuil de la salle.
	var is_chest: bool = String(cache.get("kind", "cache")) == "coffre"
	var loose: bool = int(cache.get("gold", 0)) > 0 or not (cache.get("materials", {}) as Dictionary).is_empty()
	if not is_chest and not loose:
		return
	var marker := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = Vector3(0.9, 0.6, 0.6) if is_chest else Vector3(0.35, 0.25, 0.35)
	marker.mesh = box
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.95, 0.78, 0.30) if is_chest else Color(0.85, 0.7, 0.2)
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	marker.material_override = mat
	marker.position = base + Vector3(0.0, 0.1, 0.0)
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
