extends Node
## Entrée/sortie de donjon (E.29, 3.5 — refondu 2026-07-21, demande explicite).
## L'intérieur d'un donjon vit dans une VRAIE DIMENSION SÉPARÉE (&"donjon") :
## ses propres chunks (près de l'origine — précision float32 parfaite), ses
## propres meshes, l'overworld caché/gelé pendant qu'on est dedans
## (WorldManager.set_active_dimension). Remplace l'ancienne « poche » à
## x/z ≈ 20 000 dans l'overworld.
##
## FLUX D'ENTRÉE (demande 2026-07-21) :
## - À pied : entrer dans le périmètre de la cellule donjon affiche un
##   panneau d'infos (danger, salles) + COMPTE À REBOURS DE 3 s — reculer
##   annule ; à zéro, ÉCRAN DE CHARGEMENT puis téléportation dedans.
## - Carte du monde : voyager sur la cellule = entrée DIRECTE (chargement,
##   sans compte à rebours) — voir Player.fast_travel_to_cell.
## - La cellule donjon est couverte de BROUILLARD dans l'overworld (boîtes
##   translucides — le renderer Compatibility n'a pas de vrai brouillard
##   volumétrique, machine cible oblige).
##
## GÉNÉRATION : l'étage (DungeonGenerator, graphe de salles à l'origine) est
## construit en blocs dans les chunks de la dimension au moment de l'entrée,
## sous l'écran de chargement, puis meshé d'un coup (ChunkMesher avec
## générateur NULL = monde vide, la coquille vient des chunks voisins).
## Le vide autour des salles est de l'air — ambiance de fosse assumée.
##
## PERSISTANCE (E.10/3.5 « les changements suivent la sauvegarde
## différentielle standard ») : les blocs minés/posés DANS un donjon sont un
## diff par cellule (`_dungeon_edits`), sauvegardé en ids TEXTE dans
## state.json (immune au glissement des ids runtime) et réappliqué à chaque
## reconstruction. SIMPLIFICATION ASSUMÉE : le boss renaît à chaque entrée
## tant que le donjon n'est pas nettoyé ; pas de subdivision fine en donjon.
##
## NETTOYAGE (3.5) : à la mort du boss, délai de 1,5 jour in-game puis la
## cellule redevient normale/claimable (le brouillard disparaît aussi).

const PERIMETER_WIDTH := 8.0
## Compte à rebours d'entrée à pied (demande explicite : 3 s + infos).
const ENTRY_COUNTDOWN := 3.0
## Cooldown après une téléportation (entrée ou sortie) avant de retester une
## entrée/sortie — évite toute oscillation frame à frame à la limite.
const RETRIGGER_COOLDOWN := 1.5
## 1,5 jour in-game (3.5/E.29) — délai avant qu'un donjon nettoyé (boss
## vaincu) redevienne une cellule normale/claimable.
const CLEANUP_DELAY_TICKS := int(1.5 * 24000)
## Brouillard : rayon de scan en cellules autour du joueur, et hauteur de la
## nappe au-dessus du terrain.
const FOG_SCAN_RADIUS := 2
const FOG_HEIGHT := 36.0

var _player: Node
var _in_dungeon := false
var _current_dungeon_cell := Vector2i.ZERO
var _return_position := Vector3.ZERO
var _cooldown := 0.0
var _cached_cell := Vector2i(1 << 30, 0)
var _cached_donjon_neighbors: Array[Vector2i] = []
var _floors := {}              # Vector2i cellule -> Dictionary (DungeonGenerator.generate_floor), une fois par session.
var _cleaned_cells := {}       # Vector2i cellule -> true (boss vaincu + délai écoulé).
var _cleanup_pending := {}     # Vector2i cellule -> tick cible.

## --- Dimension donjon (chunks/meshes du donjon ACTIF uniquement) ---
var _dungeon_chunks := {}      # Vector3i -> ChunkData
var _dungeon_meshes := {}      # Vector3i -> MeshInstance3D
## Diff persistant par cellule : Vector2i -> { Vector3i chunk -> { indice -> id runtime } }.
var _dungeon_edits := {}
var _dungeon_root: Node3D
var _dungeon_material: ShaderMaterial

## --- Brouillard overworld sur les cellules donjon ---
var _fog_root: Node3D
var _fog_boxes := {}           # Vector2i cellule -> MeshInstance3D
var _fog_material: StandardMaterial3D

## --- Ambiance de la dimension (2026-07-21, retour visuel) ---
## Sans ça, une salle close est éclairée par l'AMBIANCE DU CIEL de l'overworld :
## les faces vers le haut échantillonnent le bleu du ciel (sol rendu « eau »),
## l'or vire au vert. En donjon : fond noir, ambiance neutre légèrement chaude
## (torche), soleil éteint — via Camera3D.environment (override propre, sans
## toucher au WorldEnvironment global).
var _dungeon_env: Environment
var _sun: DirectionalLight3D

## --- UI (compte à rebours + écran de chargement) ---
var _ui_layer: CanvasLayer
var _entry_panel: PanelContainer
var _entry_title: Label
var _entry_info: Label
var _entry_countdown_label: Label
var _loading_screen: ColorRect
var _loading_label: Label
var _countdown := -1.0
var _countdown_cell := Vector2i.ZERO
var _entering := false
## Après une sortie, exiger de QUITTER le périmètre avant qu'un nouveau
## compte à rebours puisse démarrer — sinon la position de retour (dans le
## périmètre, forcément : on y est entré) relancerait l'entrée en boucle.
var _must_leave := false


func _ready() -> void:
	EventBus.creature_killed.connect(_on_creature_killed)
	TickManager.tick.connect(_on_tick)
	_dungeon_root = Node3D.new()
	add_child(_dungeon_root)
	_fog_root = Node3D.new()
	add_child(_fog_root)
	_fog_material = StandardMaterial3D.new()
	_fog_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_fog_material.albedo_color = Color(0.72, 0.72, 0.78, 0.4)
	_fog_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_fog_material.cull_mode = BaseMaterial3D.CULL_DISABLED  # Visible aussi depuis l'intérieur de la nappe.
	_dungeon_env = Environment.new()
	_dungeon_env.background_mode = Environment.BG_COLOR
	_dungeon_env.background_color = Color(0.01, 0.01, 0.015)
	_dungeon_env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	_dungeon_env.ambient_light_color = Color(0.52, 0.47, 0.4)  # Torche : neutre légèrement chaud.
	_dungeon_env.ambient_light_energy = 1.1
	_build_ui()


func _process(delta: float) -> void:
	if _cooldown > 0.0:
		_cooldown -= delta
		return
	if _entering:
		return
	if _player == null:
		_player = get_node_or_null("/root/Main/Player")
		if _player == null:
			return
	if WorldManager.generator == null:
		return
	var pos: Vector3 = _player.get_position_for_ai()
	if _in_dungeon:
		_check_exit(pos)
	else:
		_update_cell_cache(pos)
		_update_entry(pos, delta)


# --- Entrée à pied : périmètre → compte à rebours → chargement ---

## Recalcule les cellules donjon voisines + le brouillard seulement quand la
## CELLULE du joueur change (`biome_at`/`pois_at_cell` jamais par frame).
func _update_cell_cache(pos: Vector3) -> void:
	var cell := ClaimManager.cell_of_block(int(pos.x), int(pos.z))
	if cell == _cached_cell:
		return
	_cached_cell = cell
	_cached_donjon_neighbors = _donjon_cells_near(cell)
	_update_fog(cell)


func _update_entry(pos: Vector3, delta: float) -> void:
	var target := Vector2i.ZERO
	var found := false
	for dc in _cached_donjon_neighbors:
		if _distance_to_cell(pos, dc) <= PERIMETER_WIDTH:
			target = dc
			found = true
			break
	if not found:
		_must_leave = false  # Sorti du périmètre : une nouvelle entrée redevient possible.
		if _countdown >= 0.0:
			_cancel_countdown()
		return
	if _must_leave:
		return
	if _countdown < 0.0 or _countdown_cell != target:
		_start_countdown(target)
	_countdown -= delta
	_entry_countdown_label.text = tr("ui.donjon.compte").format({
		"secondes": str(int(maxf(ceilf(_countdown), 1.0)))})
	if _countdown <= 0.0:
		_cancel_countdown()
		_begin_entry(target, pos)


func _start_countdown(cell: Vector2i) -> void:
	_countdown = ENTRY_COUNTDOWN
	_countdown_cell = cell
	_ensure_floor_data(cell)
	var center := POIGenerator.cell_center_world(cell)
	var danger := WorldManager.generator.danger_level(center.x, center.y)
	var rooms: int = (_floors.get(cell, {}) as Dictionary).get("rooms", []).size()
	_entry_title.text = tr("ui.donjon.titre")
	_entry_info.text = tr("ui.donjon.infos").format({
		"danger": tr("ui.donjon.danger.%d" % danger), "salles": str(rooms)})
	_entry_panel.visible = true


func _cancel_countdown() -> void:
	_countdown = -1.0
	_entry_panel.visible = false


## Entrée directe depuis la carte du monde (Player.fast_travel_to_cell) :
## chargement immédiat, sans compte à rebours (demande explicite). La
## position de retour est celle d'AVANT le voyage.
func enter_from_map(cell: Vector2i) -> void:
	if _in_dungeon or _entering:
		return
	if _player == null:
		_player = get_node_or_null("/root/Main/Player")
		if _player == null:
			return
	_begin_entry(cell, _player.get_position_for_ai())


## Coroutine : affiche l'écran de chargement, laisse 2 frames le rendre,
## construit la dimension (synchrone — c'est ce que l'écran couvre), entre.
func _begin_entry(cell: Vector2i, return_pos: Vector3) -> void:
	_entering = true
	_loading_label.text = tr("ui.donjon.chargement")
	_loading_screen.visible = true
	await get_tree().process_frame
	await get_tree().process_frame
	_enter_dungeon(cell, return_pos)
	_loading_screen.visible = false
	_entering = false


func _enter_dungeon(cell: Vector2i, return_pos: Vector3) -> void:
	_ensure_floor_data(cell)
	if (_floors.get(cell, {}) as Dictionary).is_empty():
		push_warning("DungeonManager : étage vide pour la cellule %s — entrée annulée." % cell)
		return
	_return_position = return_pos
	_current_dungeon_cell = cell
	# Bascule AVANT la construction : le boss spawné pendant le build
	# appartient ainsi à la dimension donjon (CreatureManager.spawn).
	WorldManager.set_active_dimension(&"donjon")
	_build_dimension(cell)
	_in_dungeon = true
	_cooldown = RETRIGGER_COOLDOWN
	_fog_root.visible = false
	_set_dungeon_ambience(true)
	var center := _entrance_center()
	# Pieds sur le sommet du sol de la salle, + hauteur des yeux (convention
	# fly_camera.gd : feet_y = sommet du bloc).
	_player.teleport_to(Vector3(center.x, center.y + 2.9, center.z))


# --- Sortie ---

## Zone de retour au centre du marqueur de sortie (bloc d'or au sol).
func _check_exit(pos: Vector3) -> void:
	# Distance HORIZONTALE seulement (pos.y est la caméra à hauteur des yeux,
	# ~2.9 blocs au-dessus du sol où repose le marqueur — une distance 3D
	# aurait donc toujours dépassé le seuil, peu importe la position X/Z :
	# bug réel trouvé en testant ce mécanisme, corrigé).
	var exit_center := _exit_marker_position(_current_dungeon_cell)
	var dx := pos.x - exit_center.x
	var dz := pos.z - exit_center.z
	if sqrt(dx * dx + dz * dz) <= 2.0:
		_exit_dungeon()


func _exit_dungeon() -> void:
	_in_dungeon = false
	_cooldown = RETRIGGER_COOLDOWN
	_must_leave = true  # Ne pas relancer un compte à rebours tant qu'on n'a pas quitté le périmètre.
	CreatureManager.despawn_dimension(&"donjon")
	_free_dimension()
	WorldManager.set_active_dimension(&"overworld")
	_fog_root.visible = true
	_set_dungeon_ambience(false)
	_player.teleport_to(_return_position)


## Bascule l'ambiance : environnement caméra sombre + soleil éteint en donjon.
func _set_dungeon_ambience(inside: bool) -> void:
	var camera := get_viewport().get_camera_3d()
	if camera != null:
		camera.environment = _dungeon_env if inside else null
	if _sun == null:
		_sun = get_node_or_null("/root/Main/Sun") as DirectionalLight3D
	if _sun != null:
		_sun.visible = not inside


# --- Dimension donjon : blocs, mutations, meshing ---

## Lecture d'un bloc de la dimension (routée par WorldManager.block_at_world).
func dimension_block_at(pos: Vector3i) -> int:
	var ck := Vector3i(pos.x >> 4, pos.y >> 4, pos.z >> 4)
	var data: ChunkData = _dungeon_chunks.get(ck)
	if data == null:
		return 0
	return data.get_block_by_index((pos.x & 15) | ((pos.z & 15) << 4) | ((pos.y & 15) << 8))


## Mutation d'un bloc de la dimension (routée par WorldManager._apply_block) :
## même contrat que l'overworld — diff persistant, EventBus, remesh.
func dimension_apply_block(pos: Vector3i, material_id: int) -> bool:
	var ck := Vector3i(pos.x >> 4, pos.y >> 4, pos.z >> 4)
	var index := (pos.x & 15) | ((pos.z & 15) << 4) | ((pos.y & 15) << 8)
	var data: ChunkData = _dungeon_chunks.get(ck)
	if data == null:
		data = ChunkData.create_uniform(0)
		_dungeon_chunks[ck] = data
	var old_id := data.get_block_by_index(index)
	if old_id == material_id:
		return false
	data.set_block_by_index(index, material_id)
	# Diff persistant (E.10/3.5) — réappliqué à chaque reconstruction.
	var cell_edits: Dictionary = _dungeon_edits.get_or_add(_current_dungeon_cell, {})
	(cell_edits.get_or_add(ck, {}) as Dictionary)[index] = material_id
	# Remesh synchrone du chunk + des voisins de face touchés (les meshes de
	# donjon sont petits/creux — quelques ms, acceptable sans file asynchrone).
	_remesh_dungeon_chunk(ck)
	var lx := pos.x & 15
	var ly := pos.y & 15
	var lz := pos.z & 15
	if lx == 0:
		_remesh_dungeon_chunk(ck + Vector3i(-1, 0, 0))
	elif lx == 15:
		_remesh_dungeon_chunk(ck + Vector3i(1, 0, 0))
	if ly == 0:
		_remesh_dungeon_chunk(ck + Vector3i(0, -1, 0))
	elif ly == 15:
		_remesh_dungeon_chunk(ck + Vector3i(0, 1, 0))
	if lz == 0:
		_remesh_dungeon_chunk(ck + Vector3i(0, 0, -1))
	elif lz == 15:
		_remesh_dungeon_chunk(ck + Vector3i(0, 0, 1))
	if old_id != 0:
		EventBus.block_destroyed.emit(pos, old_id)
	if material_id != 0:
		EventBus.block_placed.emit(pos, material_id)
	return true


func _ensure_floor_data(cell: Vector2i) -> void:
	if _floors.has(cell):
		return
	# Graine déterministe par cellule (même monde → même donjon, G.1).
	var seed_value := NoiseGenerator.pcg_hash(cell.x, cell.y, WorldManager.world_seed + 77441)
	_floors[cell] = DungeonGenerator.generate_floor(seed_value)


## Construit chunks + meshes + boss de la dimension pour `cell` (sous l'écran
## de chargement). L'étage vit à l'origine (salle d'entrée en (0,0,0)).
func _build_dimension(cell: Vector2i) -> void:
	_free_dimension()
	var floor_data: Dictionary = _floors[cell]
	var pierre: int = GameData.material_runtime_ids.get("pierre", 0)
	var or_id: int = GameData.material_runtime_ids.get("or", pierre)

	for room: Dictionary in floor_data["rooms"]:
		_carve_room(room["origin"], room["size"], room["doors"], pierre)
	for corridor: Dictionary in floor_data["corridors"]:
		_carve_corridor(corridor["origin"], corridor["dir"], corridor["length"], pierre)

	# Marqueur de sortie (or) — décalé du point de spawn : s'il coïncidait,
	# le joueur serait re-téléporté dehors dès l'expiration du cooldown.
	var exit_marker := _exit_marker_position(cell)
	_set_dungeon_block(Vector3i(int(exit_marker.x), int(exit_marker.y), int(exit_marker.z)), or_id)

	# Diff persistant du joueur (blocs minés/posés lors de visites passées).
	var cell_edits: Dictionary = _dungeon_edits.get(cell, {})
	for ck: Vector3i in cell_edits:
		var data: ChunkData = _dungeon_chunks.get(ck)
		if data == null:
			data = ChunkData.create_uniform(0)
			_dungeon_chunks[ck] = data
		for index: int in cell_edits[ck]:
			data.set_block_by_index(index, cell_edits[ck][index])

	for ck: Vector3i in _dungeon_chunks:
		_remesh_dungeon_chunk(ck)

	# Boss (E.29 : la salle la plus distante) — un SEUL monstre, faute d'un
	# vrai profil de peuplement par donjon (F.3/F.7, non fait ici).
	var boss_room: Dictionary = floor_data["rooms"][floor_data["boss_room_index"]]
	var boss_center: Vector3i = (boss_room["origin"] as Vector3i) + (boss_room["size"] as Vector3i) / 2
	var boss := CreatureManager.spawn("sanglier", Vector3(boss_center.x + 0.5, boss_center.y + 1.0, boss_center.z + 0.5))
	if boss != null:
		boss.set_meta("dungeon_boss_cell", cell)


func _free_dimension() -> void:
	for ck: Vector3i in _dungeon_meshes:
		_dungeon_meshes[ck].queue_free()
	_dungeon_meshes.clear()
	_dungeon_chunks.clear()


func _set_dungeon_block(pos: Vector3i, id: int) -> void:
	var ck := Vector3i(pos.x >> 4, pos.y >> 4, pos.z >> 4)
	var data: ChunkData = _dungeon_chunks.get(ck)
	if data == null:
		data = ChunkData.create_uniform(0)
		_dungeon_chunks[ck] = data
	data.set_block_by_index((pos.x & 15) | ((pos.z & 15) << 4) | ((pos.y & 15) << 8), id)


## Sol/murs/plafond pleins, portes ouvertes (air) sur 3 blocs de hauteur.
func _carve_room(origin: Vector3i, size: Vector3i, doors: Array, pierre: int) -> void:
	var door_cols := {}  # "x_z" -> true, colonnes où percer la porte.
	for door: Dictionary in doors:
		door_cols["%d_%d" % [int(door["position"][0]), int(door["position"][2])]] = true
	for x in size.x:
		for z in size.z:
			var is_wall := x == 0 or x == size.x - 1 or z == 0 or z == size.z - 1
			var is_door_col: bool = is_wall and door_cols.has("%d_%d" % [x, z])
			for y in range(0, size.y + 1):
				var id := 0
				if y == 0 or y == size.y:
					id = pierre  # Sol/plafond.
				elif is_wall and not (is_door_col and y <= 3):
					id = pierre  # Mur (sauf porte, ouverte jusqu'à 3 blocs de haut).
				_set_dungeon_block(origin + Vector3i(x, y, z), id)


## Corridor 3 blocs de large × 5 de haut, creusé en ligne droite depuis
## `origin` sur `length` blocs dans la direction `dir`.
func _carve_corridor(origin: Vector3i, dir: String, length: int, pierre: int) -> void:
	var d: Vector3i = DungeonGenerator.DIRS[dir]
	var perp := Vector3i(1, 0, 0) if d.x == 0 else Vector3i(0, 0, 1)
	for i in length:
		var center := origin + d * i
		for p: int in [-1, 0, 1]:
			var col := center + perp * p
			for y in range(0, 5):
				var id := 0
				if y == 0 or y == 4:
					id = pierre  # Sol/plafond.
				elif p != 0:
					id = pierre  # Mur latéral.
				_set_dungeon_block(col + Vector3i(0, y, 0), id)


## (Re)meshe un chunk de la dimension : générateur NULL (monde vide), la
## coquille vient des blocs de bordure des 6 chunks voisins (le mécanisme
## `neighbor_edits` du mesher, réutilisé tel quel — jamais un second mesher).
func _remesh_dungeon_chunk(ck: Vector3i) -> void:
	var data: ChunkData = _dungeon_chunks.get(ck)
	if data == null or (data.is_uniform() and data.uniform_id == 0):
		if _dungeon_meshes.has(ck):
			_dungeon_meshes[ck].queue_free()
			_dungeon_meshes.erase(ck)
		return
	var neighbor_edits := {}
	for dir: Vector3i in [Vector3i(-1, 0, 0), Vector3i(1, 0, 0), Vector3i(0, -1, 0),
			Vector3i(0, 1, 0), Vector3i(0, 0, -1), Vector3i(0, 0, 1)]:
		var ndata: ChunkData = _dungeon_chunks.get(ck + dir)
		if ndata != null:
			neighbor_edits[ck + dir] = _boundary_blocks(ndata)
	var arrays := ChunkMesher.mesh_chunk(ck, data, null, {}, neighbor_edits, true)
	if arrays.is_empty():
		if _dungeon_meshes.has(ck):
			_dungeon_meshes[ck].queue_free()
			_dungeon_meshes.erase(ck)
		return
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	if _dungeon_meshes.has(ck):
		_dungeon_meshes[ck].mesh = mesh
	else:
		var instance := MeshInstance3D.new()
		instance.mesh = mesh
		instance.material_override = _dimension_material()
		instance.position = Vector3(ck * ChunkData.SIZE)
		_dungeon_root.add_child(instance)
		_dungeon_meshes[ck] = instance


## Blocs non-air de la bordure d'un chunk, au format {indice → id} attendu
## par la surimpression de coquille du mesher.
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


## Matériau des meshes de donjon : celui du monde (palette + bruit par voxel),
## avec une teinte d'herbe neutre (aucune herbe en donjon, mais le shader
## attend la texture).
func _dimension_material() -> ShaderMaterial:
	if _dungeon_material == null:
		_dungeon_material = WorldManager.base_material().duplicate() as ShaderMaterial
		var img := Image.create_empty(1, 1, false, Image.FORMAT_RGBAF)
		img.set_pixel(0, 0, Color(1, 1, 1))
		_dungeon_material.set_shader_parameter("grass_tint_map", ImageTexture.create_from_image(img))
	return _dungeon_material


# --- Brouillard overworld (cellules donjon) ---

func _update_fog(center_cell: Vector2i) -> void:
	var wanted := {}
	for dz in range(-FOG_SCAN_RADIUS, FOG_SCAN_RADIUS + 1):
		for dx in range(-FOG_SCAN_RADIUS, FOG_SCAN_RADIUS + 1):
			var c := center_cell + Vector2i(dx, dz)
			if _is_donjon_cell(c):
				wanted[c] = true
	for c: Vector2i in _fog_boxes.keys():
		if not wanted.has(c):
			_fog_boxes[c].queue_free()
			_fog_boxes.erase(c)
	for c: Vector2i in wanted:
		if _fog_boxes.has(c):
			continue
		var cs := ClaimManager.CELL_SIZE
		var cx := c.x * cs + cs / 2
		var cz := c.y * cs + cs / 2
		var h := WorldManager.generator.height_at(cx, cz)
		var box := BoxMesh.new()
		box.size = Vector3(cs, FOG_HEIGHT, cs)
		var instance := MeshInstance3D.new()
		instance.mesh = box
		instance.material_override = _fog_material
		instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		instance.position = Vector3(float(cx), h + FOG_HEIGHT * 0.35, float(cz))
		_fog_root.add_child(instance)
		_fog_boxes[c] = instance


# --- Cellules donjon / nettoyage ---

func _donjon_cells_near(cell: Vector2i) -> Array[Vector2i]:
	var found: Array[Vector2i] = []
	for dz in [-1, 0, 1]:
		for dx in [-1, 0, 1]:
			var c := cell + Vector2i(dx, dz)
			if _is_donjon_cell(c):
				found.append(c)
	return found


## API publique (ClaimManager : une cellule donjon active n'est pas claimable,
## 3.3 ; Player.fast_travel_to_cell : TP carte = entrée directe).
func is_dungeon_cell(cell: Vector2i) -> bool:
	return _is_donjon_cell(cell)


## Un donjon "nettoyé" (boss vaincu + délai écoulé) cesse d'être traité comme
## tel — la cellule redevient normale/claimable (3.5).
func _is_donjon_cell(cell: Vector2i) -> bool:
	if _cleaned_cells.has(cell):
		return false
	var center := POIGenerator.cell_center_world(cell)
	var biome: Dictionary = WorldManager.generator.biome_at(center.x, center.y)
	if biome.is_empty():
		return false
	return "donjon" in POIGenerator.pois_at_cell(cell, WorldManager.world_seed, biome)


func _distance_to_cell(pos: Vector3, cell: Vector2i) -> float:
	var cs := ClaimManager.CELL_SIZE
	var min_x := float(cell.x * cs)
	var min_z := float(cell.y * cs)
	var dx := maxf(maxf(min_x - pos.x, pos.x - (min_x + cs)), 0.0)
	var dz := maxf(maxf(min_z - pos.z, pos.z - (min_z + cs)), 0.0)
	return sqrt(dx * dx + dz * dz)


## Centre (dimension) de la salle d'entrée — position d'arrivée du joueur.
## L'entrée est TOUJOURS à l'origine (DungeonGenerator, rooms[0]).
func _entrance_center() -> Vector3:
	var entree_size: Array = GameData.dungeon_rooms.get("entree", {}).get("size", [7, 5, 7])
	return Vector3(float(entree_size[0]) * 0.5, 0.0, float(entree_size[2]) * 0.5)


## Position du marqueur de sortie — coin de la salle d'entrée, à distance
## sûre (> seuil de sortie 2.0) du point d'arrivée central.
func _exit_marker_position(_cell: Vector2i) -> Vector3:
	return Vector3(1.5, 0.0, 1.5)


func _on_creature_killed(_killer: Variant, victim: Node) -> void:
	if victim == null or not victim.has_meta("dungeon_boss_cell"):
		return
	var cell: Vector2i = victim.get_meta("dungeon_boss_cell")
	_cleanup_pending[cell] = TickManager.tick_index + CLEANUP_DELAY_TICKS
	print("[DONJON] boss vaincu, cellule %s — nettoyage dans %d ticks (1,5 jour in-game)." % [cell, CLEANUP_DELAY_TICKS])


func _on_tick(tick_index: int) -> void:
	if _cleanup_pending.is_empty():
		return
	var done: Array[Vector2i] = []
	for cell: Vector2i in _cleanup_pending:
		if tick_index >= _cleanup_pending[cell]:
			done.append(cell)
	for cell in done:
		_cleanup_pending.erase(cell)
		_cleaned_cells[cell] = true
		# La cellule redevient normale : son brouillard disparaît, et le cache
		# de voisinage est invalidé (recalculé au prochain déplacement).
		if _fog_boxes.has(cell):
			_fog_boxes[cell].queue_free()
			_fog_boxes.erase(cell)
		_cached_cell = Vector2i(1 << 30, 0)
		EventBus.dungeon_cleared.emit(cell)


# --- Sauvegarde (E.10, via SaveManager) ---
## Persisté : cellules nettoyées, délais en cours, et DIFF DES BLOCS par
## donjon (ids TEXTE — immune au glissement des ids runtime, même politique
## que la table de matériaux de world.json). Les étages eux-mêmes ne le sont
## pas (reconstruits déterministes par graine). SIMPLIFICATION ASSUMÉE : le
## boss d'un donjon non nettoyé renaît à la session/l'entrée suivante.

func save_state() -> Dictionary:
	var cleaned := []
	for cell: Vector2i in _cleaned_cells:
		cleaned.append([cell.x, cell.y])
	var pending := []
	for cell: Vector2i in _cleanup_pending:
		pending.append([cell.x, cell.y, int(_cleanup_pending[cell])])
	var edits_out := {}
	for cell: Vector2i in _dungeon_edits:
		var chunks_out := {}
		for ck: Vector3i in _dungeon_edits[cell]:
			var blocks_out := {}
			for index: int in _dungeon_edits[cell][ck]:
				var rid: int = _dungeon_edits[cell][ck][index]
				blocks_out[str(index)] = GameData.material_by_runtime[rid] if rid < GameData.material_by_runtime.size() else "air"
			chunks_out["%d,%d,%d" % [ck.x, ck.y, ck.z]] = blocks_out
		edits_out["%d,%d" % [cell.x, cell.y]] = chunks_out
	return {"cleaned": cleaned, "pending": pending, "edits": edits_out}


func restore_state(data: Dictionary) -> void:
	_cleaned_cells.clear()
	_cleanup_pending.clear()
	_dungeon_edits.clear()
	for entry: Variant in data.get("cleaned", []):
		if entry is Array and (entry as Array).size() == 2:
			_cleaned_cells[Vector2i(int(entry[0]), int(entry[1]))] = true
	for entry: Variant in data.get("pending", []):
		if entry is Array and (entry as Array).size() == 3:
			_cleanup_pending[Vector2i(int(entry[0]), int(entry[1]))] = int(entry[2])
	var edits_in: Dictionary = data.get("edits", {})
	for cell_key: String in edits_in:
		var cell_parts := cell_key.split(",")
		if cell_parts.size() != 2:
			continue
		var cell := Vector2i(int(cell_parts[0]), int(cell_parts[1]))
		var chunks_in: Dictionary = edits_in[cell_key]
		var cell_edits := {}
		for ck_key: String in chunks_in:
			var ck_parts := ck_key.split(",")
			if ck_parts.size() != 3:
				continue
			var ck := Vector3i(int(ck_parts[0]), int(ck_parts[1]), int(ck_parts[2]))
			var blocks_in: Dictionary = chunks_in[ck_key]
			var chunk_edits := {}
			for index_key: String in blocks_in:
				chunk_edits[int(index_key)] = GameData.material_runtime_ids.get(String(blocks_in[index_key]), 0)
			cell_edits[ck] = chunk_edits
		_dungeon_edits[cell] = cell_edits


# --- UI ---

func _build_ui() -> void:
	_ui_layer = CanvasLayer.new()
	_ui_layer.layer = 80
	add_child(_ui_layer)

	_entry_panel = PanelContainer.new()
	_entry_panel.visible = false
	_entry_panel.set_anchors_and_offsets_preset(Control.PRESET_CENTER_TOP)
	_entry_panel.offset_top = 90.0
	var vbox := VBoxContainer.new()
	_entry_title = Label.new()
	_entry_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_entry_info = Label.new()
	_entry_info.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_entry_countdown_label = Label.new()
	_entry_countdown_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(_entry_title)
	vbox.add_child(_entry_info)
	vbox.add_child(_entry_countdown_label)
	_entry_panel.add_child(vbox)
	_ui_layer.add_child(_entry_panel)

	_loading_screen = ColorRect.new()
	_loading_screen.color = Color(0.02, 0.02, 0.03, 1.0)
	_loading_screen.set_anchors_preset(Control.PRESET_FULL_RECT)
	_loading_screen.visible = false
	_loading_label = Label.new()
	_loading_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_loading_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_loading_label.set_anchors_preset(Control.PRESET_FULL_RECT)
	_loading_screen.add_child(_loading_label)
	_ui_layer.add_child(_loading_screen)
