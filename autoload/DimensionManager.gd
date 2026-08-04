extends Node
## DIMENSIONS (2026-08-03) — registre, aiguillage et stockage voxel.
##
## ---------------------------------------------------------------------------
## POURQUOI CE FICHIER EXISTE
## ---------------------------------------------------------------------------
## Le monde avait deux dimensions, `overworld` et `donjon`, et l'aiguillage
## était écrit ainsi dans WorldManager : « si la dimension active n'est pas
## l'overworld, appeler DungeonManager ». Autrement dit, « pas l'overworld »
## voulait dire « donjon ». Toute troisième dimension aurait exigé de rouvrir
## WorldManager et d'y empiler un second cas particulier, puis un troisième.
##
## Ici, une dimension est une ENTRÉE DE REGISTRE et un STOCKAGE VOXEL. Le
## donjon n'est plus un cas dans le moteur : c'est un CONTENU qui remplit une
## dimension, au même titre que n'importe quelle autre.
##
## ---------------------------------------------------------------------------
## CE QUI EST GÉNÉRIQUE, ET CE QUI NE PEUT PAS L'ÊTRE
## ---------------------------------------------------------------------------
## Générique, et donc ici : garder des blocs hors de l'overworld, les lire, les
## muter, les mailler, allumer ou éteindre le ciel, geler les créatures qui
## n'appartiennent pas à la dimension active.
##
## Pas générique, et donc ailleurs : ce qu'on met DEDANS. Un donjon a des
## étages, des escaliers et un boss ; une faille de mana n'a rien de tout ça.
## C'est pour cette raison que `DungeonManager` garde son propre backend au
## lieu d'être réécrit — il fait déjà ce travail, et le refaire ici aurait
## mélangé les deux responsabilités qu'on est justement en train de séparer.

## Dimension de départ. L'overworld n'est PAS stocké ici : il est infini et
## procédural, c'est WorldManager qui le tient.
const OVERWORLD: StringName = &"overworld"

## Dimension active. Une seule à la fois : le joueur n'est jamais à deux
## endroits, et deux mondes maillés en même temps doubleraient le budget.
##
## LECTURE SEULE, DÉRIVÉE DE WorldManager. Ce champ a d'abord été une variable
## propre, tenue à jour par `_activate` — et c'était un doublon de vérité qui a
## cassé le donjon dans l'heure : DungeonManager bascule la dimension en
## appelant `WorldManager.set_active_dimension` directement, sans passer par
## ici, si bien que ce champ restait à « overworld » pendant que le monde était
## en donjon. L'aiguillage cherchait alors un backend pour l'overworld, n'en
## trouvait pas, et lisait un stockage générique vide : tous les blocs du donjon
## rendaient zéro.
##
## Deux champs qui doivent rester égaux finissent toujours par ne plus l'être.
## Il n'y en a plus qu'un.
var active: StringName:
	get:
		return WorldManager.active_dimension

## Backends spécialisés : dimension → nœud sachant lire et muter ses blocs.
## Une dimension sans backend utilise le stockage générique ci-dessous.
var _backends := {}

## Stockage générique : dimension → { Vector3i(chunk) → ChunkData }.
var _stores := {}
## Meshes vivants : dimension → { Vector3i(chunk) → MeshInstance3D }.
var _meshes := {}
## Racine de scène des meshes de dimension (fournie par main.tscn, comme celle
## des chunks overworld).
var _root: Node3D
var _material: ShaderMaterial

## Position de retour dans l'overworld, empilée à l'entrée. Une PILE et non une
## variable : rien n'interdit à une dimension d'en ouvrir une autre, et un
## simple champ ferait ressortir le joueur au mauvais endroit.
var _return_stack: Array[Vector3] = []


func set_root(root: Node3D) -> void:
	_root = root


## Déclare qu'une dimension est servie par un backend spécialisé.
func register_backend(dimension: StringName, backend: Node) -> void:
	_backends[dimension] = backend


func is_overworld() -> bool:
	return active == OVERWORLD


## La dimension existe-t-elle ? Une dimension inconnue n'est pas une erreur de
## programmation mais une erreur de DONNÉES : on la signale sans planter.
func exists(dimension: StringName) -> bool:
	return dimension == OVERWORLD or GameData.dimensions.has(String(dimension))


# --- Entrée et sortie -------------------------------------------------------

## Entre dans une dimension et retient d'où l'on vient.
func enter(dimension: StringName, from_position: Vector3, arrival: Vector3) -> bool:
	if not exists(dimension):
		push_warning("DimensionManager : dimension inconnue « %s »." % dimension)
		return false
	_return_stack.append(from_position)
	# UNE DIMENSION SANS BACKEND SE CONSTRUIT À L'ENTRÉE. On ne la garde pas
	# entre deux visites : la regénérer est déterministe et coûte moins que de
	# tenir des milliers de chunks en mémoire pour un endroit où le joueur n'est
	# pas — c'est déjà la règle de l'overworld (G.1).
	# ON ACTIVE AVANT DE CONSTRUIRE, et l'ordre compte. Le contenu d'une
	# dimension — créatures, caches de butin — s'enregistre auprès de systèmes
	# qui rangent leurs entrées PAR DIMENSION ACTIVE. Construire d'abord faisait
	# naître les caches sous l'étiquette « overworld » : elles existaient, mais
	# restaient invisibles une fois dans la faille.
	#
	# L'inverse est sans risque : bâtir n'a pas besoin que la dimension soit
	# active, `set_block_in` prend la sienne en paramètre.
	_activate(dimension)
	var landing := arrival
	if not _backends.has(dimension) and chunk_count(dimension) == 0:
		landing = _build(dimension, arrival)
	var player := get_node_or_null("/root/Main/Player")
	if player != null:
		player.teleport_to(landing)
	return true


## Construit le contenu d'une dimension générique. Le constructeur est choisi
## par la donnée `builder` de la fiche : le gestionnaire ne connaît aucun
## contenu, c'est tout l'intérêt.
func _build(dimension: StringName, fallback: Vector3) -> Vector3:
	var declaration: Dictionary = GameData.dimensions.get(String(dimension), {})
	match String(declaration.get("builder", "rift")):
		"rift":
			return RiftBuilder.build(dimension, declaration, WorldManager.world_seed)
		_:
			return fallback


## Revient d'où l'on venait. Sans pile, on retombe au centre de l'overworld,
## ce qui vaut mieux que de rester coincé dans une dimension.
func leave() -> void:
	if active == OVERWORLD:
		return
	# `: Vector3` explicite : `Array.pop_back` rend un Variant, dont l'inférence
	# est traitée comme une erreur dans ce projet.
	var back: Vector3 = _return_stack.pop_back() if not _return_stack.is_empty() else Vector3.ZERO
	CreatureManager.despawn_dimension(active)
	if not _backends.has(active):
		free_dimension(active)
	_activate(OVERWORLD)
	var player := get_node_or_null("/root/Main/Player")
	if player != null:
		player.teleport_to(back)


## Bascule effective : c'est WorldManager qui cache le terrain et gèle son
## streaming, et CreatureManager qui gèle les créatures — on ne duplique ni
## l'un ni l'autre, on les prévient.
func _activate(dimension: StringName) -> void:
	WorldManager.set_active_dimension(dimension)
	_apply_ambience(dimension)
	_set_visible(dimension)


## Ciel, soleil et brouillard d'une dimension, tels que ses données les
## déclarent. L'ambiance était jusqu'ici un environnement construit à la main
## dans DungeonManager, donc invisible à toute autre dimension.
func _apply_ambience(dimension: StringName) -> void:
	var camera := get_viewport().get_camera_3d()
	var sun := get_node_or_null("/root/Main/Sun") as DirectionalLight3D
	var declaration: Dictionary = GameData.dimensions.get(String(dimension), {})
	var ambience: Dictionary = declaration.get("ambience", {})

	if sun != null:
		sun.visible = bool(ambience.get("sunlight", dimension == OVERWORLD))
	if camera == null:
		return
	if dimension == OVERWORLD or ambience.is_empty():
		camera.environment = null
		return
	if not _environments.has(dimension):
		_environments[dimension] = _build_environment(ambience)
	camera.environment = _environments[dimension]


var _environments := {}


func _build_environment(ambience: Dictionary) -> Environment:
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color.html(String(ambience.get("background", "#050508")))
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color.html(String(ambience.get("ambient", "#39304C")))
	env.ambient_light_energy = float(ambience.get("ambient_energy", 0.6))
	if bool(ambience.get("fog", false)):
		env.fog_enabled = true
		env.fog_light_color = Color.html(String(ambience.get("fog_color", "#1A1428")))
		env.fog_density = float(ambience.get("fog_density", 0.02))
	return env


## N'affiche que les meshes de la dimension active : deux mondes visibles à la
## fois se traverseraient à l'écran.
func _set_visible(dimension: StringName) -> void:
	for dim: StringName in _meshes:
		var visible_now := dim == dimension
		for ck: Vector3i in _meshes[dim]:
			(_meshes[dim][ck] as MeshInstance3D).visible = visible_now


# --- Blocs (aiguillés depuis WorldManager) ----------------------------------

## Lecture d'un bloc hors overworld.
func block_at(pos: Vector3i) -> int:
	if _backends.has(active):
		return int((_backends[active] as Node).call("dimension_block_at", pos))
	var store: Dictionary = _stores.get(active, {})
	var data: ChunkData = store.get(Vector3i(pos.x >> 4, pos.y >> 4, pos.z >> 4))
	if data == null:
		return 0
	return data.get_block_by_index(_index_of(pos))


## Lit un bloc dans une dimension DONNÉE, active ou non.
##
## `block_at` répond pour la dimension active ; un constructeur, lui, sonde ce
## qu'il vient de bâtir AVANT que le joueur n'y soit — pour savoir où poser une
## créature ou une cache, par exemple.
func block_at_in(dimension: StringName, pos: Vector3i) -> int:
	var store: Dictionary = _stores.get(dimension, {})
	var data: ChunkData = store.get(Vector3i(pos.x >> 4, pos.y >> 4, pos.z >> 4))
	if data == null:
		return 0
	return data.get_block_by_index(_index_of(pos))


## Mutation d'un bloc hors overworld. Même contrat que l'overworld : la
## fonction remaille et notifie, l'appelant n'a rien d'autre à faire.
func apply_block(pos: Vector3i, material_id: int) -> bool:
	if _backends.has(active):
		return bool((_backends[active] as Node).call("dimension_apply_block", pos, material_id))
	return set_block_in(active, pos, material_id, true)


## Écrit un bloc dans une dimension donnée, active ou non.
##
## `remesh` à false pendant une CONSTRUCTION : bâtir une pièce de mille blocs
## en remaillant à chaque bloc coûterait mille maillages pour un seul résultat.
## L'appelant remaille une fois à la fin (`remesh_all`).
func set_block_in(dimension: StringName, pos: Vector3i, material_id: int, remesh: bool) -> bool:
	var store: Dictionary = _stores.get_or_add(dimension, {})
	var ck := Vector3i(pos.x >> 4, pos.y >> 4, pos.z >> 4)
	var data: ChunkData = store.get(ck)
	if data == null:
		data = ChunkData.create_uniform(0)
		store[ck] = data
	var index := _index_of(pos)
	var old_id := data.get_block_by_index(index)
	if old_id == material_id:
		return false
	data.set_block_by_index(index, material_id)
	if remesh:
		_remesh_around(dimension, pos, ck)
		if old_id != 0:
			EventBus.block_destroyed.emit(pos, old_id)
		if material_id != 0:
			EventBus.block_placed.emit(pos, material_id)
	return true


## Remaille tous les chunks d'une dimension — à appeler une fois après une
## construction en masse.
func remesh_all(dimension: StringName) -> void:
	for ck: Vector3i in (_stores.get(dimension, {}) as Dictionary):
		_remesh(dimension, ck)
	_set_visible(active)


## Vide une dimension et ses meshes. Les dimensions générées à la volée n'ont
## pas à survivre à la sortie : les regénérer coûte moins que de les garder en
## mémoire, et c'est déjà la règle de l'overworld (G.1).
func free_dimension(dimension: StringName) -> void:
	for ck: Vector3i in (_meshes.get(dimension, {}) as Dictionary):
		(_meshes[dimension][ck] as MeshInstance3D).queue_free()
	_meshes.erase(dimension)
	_stores.erase(dimension)


func chunk_count(dimension: StringName) -> int:
	return (_stores.get(dimension, {}) as Dictionary).size()


static func _index_of(pos: Vector3i) -> int:
	return (pos.x & 15) | ((pos.z & 15) << 4) | ((pos.y & 15) << 8)


func _remesh_around(dimension: StringName, pos: Vector3i, ck: Vector3i) -> void:
	_remesh(dimension, ck)
	# Un bloc en bordure de chunk change la face VISIBLE du chunk voisin : sans
	# ce rattrapage, miner contre une paroi laisse un trou qui ne s'ouvre qu'au
	# rechargement.
	if (pos.x & 15) == 0:
		_remesh(dimension, ck + Vector3i(-1, 0, 0))
	elif (pos.x & 15) == 15:
		_remesh(dimension, ck + Vector3i(1, 0, 0))
	if (pos.y & 15) == 0:
		_remesh(dimension, ck + Vector3i(0, -1, 0))
	elif (pos.y & 15) == 15:
		_remesh(dimension, ck + Vector3i(0, 1, 0))
	if (pos.z & 15) == 0:
		_remesh(dimension, ck + Vector3i(0, 0, -1))
	elif (pos.z & 15) == 15:
		_remesh(dimension, ck + Vector3i(0, 0, 1))


func _remesh(dimension: StringName, ck: Vector3i) -> void:
	var store: Dictionary = _stores.get(dimension, {})
	var meshes: Dictionary = _meshes.get_or_add(dimension, {})
	var data: ChunkData = store.get(ck)
	if data == null or (data.is_uniform() and data.uniform_id == 0):
		_drop_mesh(meshes, ck)
		return
	# Les faces de contact avec les chunks voisins doivent être connues, sinon
	# chaque frontière de chunk se dessine comme une paroi extérieure.
	var neighbor_edits := {}
	for dir: Vector3i in [Vector3i(-1, 0, 0), Vector3i(1, 0, 0), Vector3i(0, -1, 0),
			Vector3i(0, 1, 0), Vector3i(0, 0, -1), Vector3i(0, 0, 1)]:
		var neighbour: ChunkData = store.get(ck + dir)
		if neighbour != null:
			neighbor_edits[ck + dir] = _boundary_blocks(neighbour)
	var arrays := ChunkMesher.mesh_chunk(ck, data, null, {}, neighbor_edits, true)
	if arrays.is_empty():
		_drop_mesh(meshes, ck)
		return
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	if meshes.has(ck):
		(meshes[ck] as MeshInstance3D).mesh = mesh
		return
	var instance := MeshInstance3D.new()
	instance.mesh = mesh
	instance.material_override = _dimension_material()
	instance.position = Vector3(ck * ChunkData.SIZE)
	instance.visible = dimension == active
	if _root != null:
		_root.add_child(instance)
	else:
		add_child(instance)
	meshes[ck] = instance


func _drop_mesh(meshes: Dictionary, ck: Vector3i) -> void:
	if meshes.has(ck):
		(meshes[ck] as MeshInstance3D).queue_free()
		meshes.erase(ck)


## Blocs de bordure d'un chunk voisin, au format attendu par le mailleur.
func _boundary_blocks(data: ChunkData) -> Dictionary:
	var out := {}
	for y in ChunkData.SIZE:
		for z in ChunkData.SIZE:
			for x in ChunkData.SIZE:
				if x != 0 and x != 15 and y != 0 and y != 15 and z != 0 and z != 15:
					continue
				var index := x | (z << 4) | (y << 8)
				var id := data.get_block_by_index(index)
				if id != 0:
					out[index] = id
	return out


## Matériau partagé des dimensions : la même palette que l'overworld, pour que
## la pierre ait la même tête des deux côtés.
##
## La teinte d'herbe est NEUTRALISÉE par une texture d'un pixel blanc. Sans
## elle, le shader lirait une carte de teinte absente et l'herbe des dimensions
## sortirait noire — c'est déjà la raison d'être du même détour côté donjon.
func _dimension_material() -> ShaderMaterial:
	if _material == null:
		_material = WorldManager.base_material().duplicate() as ShaderMaterial
		var img := Image.create_empty(1, 1, false, Image.FORMAT_RGBAF)
		img.set_pixel(0, 0, Color(1, 1, 1))
		_material.set_shader_parameter("grass_tint_map", ImageTexture.create_from_image(img))
	return _material
