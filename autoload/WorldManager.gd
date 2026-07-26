extends Node
## WorldManager — graine du monde, streaming de chunks, pipeline de meshing,
## mutations du monde (D.1). Étapes D.3.2 + D.3.3.
## - Streaming : pipeline PAR COLONNE (les 8 couches échantillonnées une fois
##   par colonne — G.4), rayon 8 chunks (E.14), plage verticale adaptée au
##   relief, thread principal limité à l'upload des meshes prêts (G.2).
## - Mutations : TOUTE modification du monde passe par la fonction unique
##   set_block() (D.2 — routable en réseau plus tard), qui alimente un diff
##   par chunk (base de la sauvegarde différentielle E.10), émet les signaux
##   EventBus et déclenche un remesh prioritaire asynchrone (critère G.8
##   étape 3 : aucune frame > 16 ms sur mutation).

const DEFAULT_CHUNK_RADIUS := 8    # E.14 : rayon visible par défaut.
## Distance d'affichage RÉGLABLE (2026-07-24, option des paramètres) : rayon
## de chunks streamés autour du joueur. Le débit de streaming (in_flight /
## uploads) est mis à l'échelle avec le rayon pour que le disque se remplisse
## réellement à grande distance (le goulot à gros rayon est le débit, pas le
## coût par bloc). ATTENTION : gros rayon = beaucoup plus de chunks meshés +
## overdraw (pas d'occlusion culling) → coûteux, surtout sur iGPU.
var render_radius := DEFAULT_CHUNK_RADIUS
var _evict_radius := DEFAULT_CHUNK_RADIUS + 2
var _uploads_per_frame := 2
var _max_columns_in_flight := 6
const CHUNK_CACHE_MAX_BASE := 768       # Éviction des données (G.2 : régénérables), mise à l'échelle.
var _chunk_cache_max := CHUNK_CACHE_MAX_BASE
## Bornes verticales du monde (décision 3.2 : -512 → +512, le plafond haut
## est une limite de construction joueur, pas de génération).
const CY_MIN_ABS := -32
const CY_MAX_ABS := 31
const WORLD_Y_MIN := -512
const WORLD_Y_MAX := 511
## Garde-fou de subdivision (G.2) : blocs subdivisés max par chunk.
const SUBDIV_BUDGET_PER_CHUNK := 512
## LOD de distance (G.2) : au-delà de N chunks, la subdivision fine n'est
## JAMAIS meshée — le chunk bascule sur sa variante « blocs pleins ».
const LOD_FINE_RADIUS := 4
## Dégradé de teinte d'herbe (2026-07-21) : résolution de la petite texture de
## teinte par chunk — 3×3 suffit pour un dégradé lisse à l'échelle d'un chunk
## (16 blocs) sans coût significatif (9 appels `biome_at` par chunk créé, une
## seule fois, jamais par frame).
const GRASS_TINT_GRID := 3
## IDs des styles de texture procédurale (doivent correspondre aux constantes
## S_* du shader voxel_material.gdshader — réécriture 2026-07-24).
const TEXTURE_STYLE_IDS := {
	"basic": 0, "stone": 1, "soil": 2, "sand": 3, "wood": 4, "planks": 5,
	"leaves": 6, "ore": 7, "metal": 8, "gem": 9, "bricks": 10, "water": 11,
	"snow": 12, "grass": 13,
}

var world_seed: int = 1337
var generator: NoiseGenerator
## Nœud de scène sous lequel vivent les MeshInstance3D (fourni par main.tscn).
var chunk_root: Node3D
## Dimension active (3.5, 2026-07-21) : &"overworld" ou &"donjon". Hors
## overworld, les lectures/mutations de blocs sont ROUTÉES vers la dimension
## de DungeonManager, le terrain overworld est caché et son streaming gelé
## (les tâches en vol finissent, aucune nouvelle n'est lancée). SIMPLIFICATION
## ASSUMÉE : dimensions non supportées en multijoueur pour l'instant (le
## routage RPC reste overworld-only).
var active_dimension: StringName = &"overworld"

var _material: ShaderMaterial
var _chunks := {}          # Vector3i -> ChunkData (cache, données régénérables)
var _meshes := {}          # Vector3i -> MeshInstance3D
var _empty := {}           # Vector3i -> true : chunks meshés sans aucune face
## Diff des modifications par rapport à la génération (E.10) :
## Vector3i chunk -> { indice_bloc -> id matériau }. Jamais nettoyé par
## l'éviction — c'est LA vérité des changements du monde.
var _edits := {}
## Diff des sous-grilles de subdivision (4.1) :
## Vector3i chunk -> { indice_bloc -> PackedInt32Array(512) }.
var _sub_edits := {}
## Variantes de mesh des chunks subdivisés (LOD G.2) + état courant.
var _fine_meshes := {}     # Vector3i -> ArrayMesh (passe fine)
var _coarse_meshes := {}   # Vector3i -> ArrayMesh (blocs pleins dominants)
var _lod_fine := {}        # Vector3i -> bool (variante actuellement affichée)
## Chunks à re-mesher (compteur de version : une mutation pendant un remesh
## en vol déclenche un nouveau remesh, jamais de perte).
var _dirty := {}
var _urgent_cols: Array[Vector2i] = []
## Époque d'installation de mesh (monotone, +1 par édition) : un remesh SYNCHRONE
## d'édition estampille le chunk ; une tâche async plus ANCIENNE (dispatchée
## avant l'édition) ne peut plus réinstaller un mesh périmé par-dessus.
var _install_epoch := 0
var _installed_epoch := {}  # Vector3i -> époque du dernier mesh installé
## Offsets 2D (dx, dz) du disque de streaming, triés par distance UNE FOIS.
var _sorted_offsets: Array[Vector2i] = []
var _queue: Array[Vector2i] = []   # Colonnes candidates, ordonnées par distance
var _queue_idx := 0
var _in_flight := {}       # Vector2i (colonne) -> id de tâche WorkerThreadPool
var _ranges := {}          # Vector2i (colonne) -> Vector2i (cy_min, cy_max) approx
## Cache de contextes de colonne pour la génération SYNCHRONE (mutations sur
## chunk froid) — thread principal uniquement, borné, régénérable.
var _ctx_cache := {}
var _results := []         # Résultats des threads (protégé par mutex)
var _mutex := Mutex.new()
var _generation := 0       # Incrémenté au hot-reload : invalide les tâches en vol
var _center := Vector2i(1 << 30, 0)

# Statistiques de meshing (protégées par mutex — critère E.14 : < 4 ms/chunk).
var _mesh_time_total_us: int = 0
var _mesh_time_max_us: int = 0
var _meshed_chunks: int = 0


func _ready() -> void:
	if GameData.materials.is_empty():
		return
	EventBus.data_reloaded.connect(_on_data_reloaded)
	_load_display_setting()  # Lit render_radius sauvegardé (défaut 8).
	_rebuild_offsets()


const DISPLAY_CFG := "user://display.cfg"


func _load_display_setting() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(DISPLAY_CFG) == OK:
		render_radius = clampi(int(cfg.get_value("display", "render_distance", DEFAULT_CHUNK_RADIUS)), 4, 48)
		_evict_radius = render_radius + 2
		_scale_budgets()


## Met à l'échelle le débit de streaming et le cache avec le rayon (le goulot
## à gros rayon est le DÉBIT, pas le coût par bloc).
func _scale_budgets() -> void:
	var scale := maxf(1.0, float(render_radius) / float(DEFAULT_CHUNK_RADIUS))
	_max_columns_in_flight = int(6 * scale)
	_uploads_per_frame = int(2 * scale)
	_chunk_cache_max = int(CHUNK_CACHE_MAX_BASE * scale * scale)


## Distance d'affichage (2026-07-24, option des paramètres) : change le rayon,
## met à l'échelle les budgets, reconstruit la file, sauvegarde, et force un
## re-remplissage si un monde tourne. ATTENTION perf à gros rayon (overdraw).
func set_render_distance(radius: int) -> void:
	render_radius = clampi(radius, 4, 48)
	_evict_radius = render_radius + 2
	_scale_budgets()
	_rebuild_offsets()
	var cfg := ConfigFile.new()
	cfg.set_value("display", "render_distance", render_radius)
	cfg.save(DISPLAY_CFG)
	if generator != null:
		var c := _center
		_center = Vector2i(1 << 30, 0)
		update_center(Vector3(c.x * ChunkData.SIZE, 0, c.y * ChunkData.SIZE))


## (Re)construit le disque d'offsets de streaming, trié par distance.
func _rebuild_offsets() -> void:
	_sorted_offsets.clear()
	for dx in range(-render_radius, render_radius + 1):
		for dz in range(-render_radius, render_radius + 1):
			if dx * dx + dz * dz <= render_radius * render_radius:
				_sorted_offsets.append(Vector2i(dx, dz))
	_sorted_offsets.sort_custom(func(a: Vector2i, b: Vector2i) -> bool:
		return a.x * a.x + a.y * a.y < b.x * b.x + b.y * b.y)


## Démarre le monde ACTIF depuis le profil choisi (SaveManager.active_config —
## menu de démarrage ou monde par défaut des modes directs). Plus rien ne se
## crée dans _ready (2026-07-21) : tant que ce n'est pas appelé, le jeu est
## « au menu », sans monde (generator == null, tous les systèmes gardés).
func initialize_world() -> void:
	if generator != null:
		return
	world_seed = int(SaveManager.active_config.get("seed", 1337))
	generator = NoiseGenerator.new(world_seed, SaveManager.active_config.get("params", {}))
	var restored := SaveManager.take_world_edits()
	if not restored.is_empty():
		_edits = restored["edits"]
		_sub_edits = restored["sub_edits"]
	_build_material()
	SaveManager.world_active = true  # Arme autosave/F9/sauvegarde de sortie.


func _process(_delta: float) -> void:
	if chunk_root == null or generator == null:
		return
	_upload_ready_meshes()  # Draine toujours les résultats en vol (même cachés).
	if active_dimension == &"overworld":
		_launch_tasks()


## Bascule de dimension (3.5) : cache/révèle le monde overworld et prévient
## les créatures (visibilité + gel des ticks hors dimension active).
func set_active_dimension(dim: StringName) -> void:
	if dim == active_dimension:
		return
	active_dimension = dim
	if chunk_root != null:
		chunk_root.visible = dim == &"overworld"
	CreatureManager.on_dimension_changed(dim)


## Appelé par la caméra/le joueur : met à jour le centre de streaming.
func update_center(world_pos: Vector3) -> void:
	if active_dimension != &"overworld":
		return  # En donjon, les coordonnées locales ne doivent JAMAIS piloter le streaming overworld.
	var center := Vector2i(
		floori(world_pos.x / ChunkData.SIZE),
		floori(world_pos.z / ChunkData.SIZE)
	)
	if center == _center:
		return
	_center = center
	_rebuild_queue()
	_evict()
	_update_lod()


# --- Accès et mutation du monde (D.2 : fonction unique) ---

## Id matériau au bloc monde. 0 = air. Priorité : diff d'édition → cache →
## générateur (pur). Utilisable à chaque frame (visée joueur).
func block_at_world(pos: Vector3i) -> int:
	if generator == null:
		return 0  # Aucun monde actif (menu de démarrage).
	if active_dimension != &"overworld":
		return DungeonManager.dimension_block_at(pos)
	var ck := Vector3i(pos.x >> 4, pos.y >> 4, pos.z >> 4)
	var index := (pos.x & 15) | ((pos.z & 15) << 4) | ((pos.y & 15) << 8)
	var chunk_edits: Variant = _edits.get(ck)
	if chunk_edits != null and (chunk_edits as Dictionary).has(index):
		return chunk_edits[index]
	var data: ChunkData = _chunks.get(ck)
	if data != null:
		return data.get_block_by_index(index)
	return generator.block_at(pos.x, pos.y, pos.z)


## LA fonction unique de mutation du monde (D.2), point d'entrée gameplay.
## Réseau (E.11) : hors ligne, applique directement ; en multi, route vers le
## host autoritaire (client = requête RPC, host = application + diffusion) —
## voir _apply_block/rpc_apply_block/rpc_request_block plus bas. Retourne
## false si refusé localement (hors limites, aucun changement) ; en client
## multijoueur, retourne true de façon OPTIMISTE (la confirmation arrive de
## façon asynchrone via la diffusion du host — pas de prédiction/retour en
## arrière à cette étape, simplification assumée).
func set_block(pos: Vector3i, material_id: int) -> bool:
	if not NetworkManager.is_multiplayer_active():
		return _apply_block(pos, material_id)
	if NetworkManager.is_host:
		rpc_apply_block.rpc(pos, material_id)
		return true
	rpc_request_block.rpc_id(1, pos, material_id)
	return true


## Application RÉELLE de la mutation (identique sur toutes les machines,
## D.2). Ne jamais appeler directement depuis le gameplay — passer par
## set_block() pour que le routage réseau reste correct.
func _apply_block(pos: Vector3i, material_id: int) -> bool:
	if active_dimension != &"overworld":
		return DungeonManager.dimension_apply_block(pos, material_id)
	if pos.y < WORLD_Y_MIN or pos.y > WORLD_Y_MAX:
		return false
	var old_id := block_at_world(pos)
	if old_id == material_id:
		return false

	var ck := Vector3i(pos.x >> 4, pos.y >> 4, pos.z >> 4)
	var index := (pos.x & 15) | ((pos.z & 15) << 4) | ((pos.y & 15) << 8)
	var data := _get_chunk_sync(ck)
	data.set_block_by_index(index, material_id)
	if not _edits.has(ck):
		_edits[ck] = {}
	_edits[ck][index] = material_id

	# Remesh du chunk + des voisins partageant la face modifiée. On collecte
	# la liste pour un remesh SYNCHRONE immédiat (voir plus bas) : passer par
	# la file async du streaming ajoutait un délai énorme (l'édition attendait
	# un slot de worker libre derrière de longues tâches de streaming).
	var touched: Array[Vector3i] = [ck]
	var lx := pos.x & 15
	var ly := pos.y & 15
	var lz := pos.z & 15
	if lx == 0:
		touched.append(ck + Vector3i(-1, 0, 0))
	elif lx == 15:
		touched.append(ck + Vector3i(1, 0, 0))
	if ly == 0:
		touched.append(ck + Vector3i(0, -1, 0))
	elif ly == 15:
		touched.append(ck + Vector3i(0, 1, 0))
	if lz == 0:
		touched.append(ck + Vector3i(0, 0, -1))
	elif lz == 15:
		touched.append(ck + Vector3i(0, 0, 1))
	for tck: Vector3i in touched:
		_mark_dirty(tck)
	# Remesh SYNCHRONE immédiat sur le thread principal (édition instantanée) :
	# seuls les chunks déjà chargés. _remesh_chunk_now efface leur drapeau dirty,
	# la file async ne les reprend donc pas.
	_install_epoch += 1
	for tck: Vector3i in touched:
		if _meshes.has(tck) or _chunks.has(tck):
			_remesh_chunk_now(tck, _install_epoch)

	# Un bloc plein remplace toute subdivision (diff nettoyé en conséquence).
	if _sub_edits.has(ck):
		_sub_edits[ck].erase(index)

	# Couplage inter-systèmes par l'EventBus uniquement (E.12).
	if old_id != 0:
		EventBus.block_destroyed.emit(pos, old_id)
	if material_id != 0:
		EventBus.block_placed.emit(pos, material_id)
	return true


## Diffusion autoritaire (E.11 : "host autoritaire... diffuse le résultat").
## call_local=true : s'exécute aussi localement chez le host lui-même, dans
## le même appel — host et clients suivent alors le même code (_apply_block).
@rpc("authority", "call_local", "reliable")
func rpc_apply_block(pos: Vector3i, material_id: int) -> void:
	_apply_block(pos, material_id)


## Requête d'un client (E.11 : "client envoie des intentions... le host
## valide"). Anti-triche (portée/possession) DIFFÉRÉ — voir NetworkManager.
@rpc("any_peer", "reliable")
func rpc_request_block(pos: Vector3i, material_id: int) -> void:
	if not NetworkManager.is_host:
		return
	rpc_apply_block.rpc(pos, material_id)


## Mutation d'une RÉGION de sous-grille (4.1 : subdivision 32→16→8→4).
## `cell_min` en cellules de 4 px (0..7), `cell_size` 1/2/4 cellules.
## Retourne "ok", "budget" (garde-fou G.2 atteint) ou "invalid". Réseau :
## même routage host-autoritaire que set_block (voir son commentaire) — un
## client reçoit "ok" de façon optimiste, la confirmation vient du host.
func set_sub_region(block_pos: Vector3i, cell_min: Vector3i, cell_size: int, material_id: int) -> String:
	if not NetworkManager.is_multiplayer_active():
		return _apply_sub_region(block_pos, cell_min, cell_size, material_id)
	if NetworkManager.is_host:
		rpc_apply_sub_region.rpc(block_pos, cell_min, cell_size, material_id)
		return "ok"
	rpc_request_sub_region.rpc_id(1, block_pos, cell_min, cell_size, material_id)
	return "ok"


func _apply_sub_region(block_pos: Vector3i, cell_min: Vector3i, cell_size: int, material_id: int) -> String:
	if active_dimension != &"overworld":
		return "invalid"  # Pas de sculpture fine en donjon (simplification 3.5 assumée).
	if block_pos.y < WORLD_Y_MIN or block_pos.y > WORLD_Y_MAX:
		return "invalid"
	var ck := Vector3i(block_pos.x >> 4, block_pos.y >> 4, block_pos.z >> 4)
	var index := (block_pos.x & 15) | ((block_pos.z & 15) << 4) | ((block_pos.y & 15) << 8)
	var data := _get_chunk_sync(ck)
	var old_id := data.get_block_by_index(index)

	var grid: PackedInt32Array
	if data.subdivs.has(index):
		grid = data.subdivs[index]
	else:
		# Nouveau bloc subdivisé : budget par chunk (G.2, message au joueur).
		if data.subdivs.size() >= SUBDIV_BUDGET_PER_CHUNK:
			return "budget"
		# Bloc plein → grille remplie de son matériau (sculpture) ;
		# bloc d'air → grille vide (construction fine).
		grid = SubdivGrid.create_full(old_id)
	SubdivGrid.set_region(grid, cell_min, cell_size, material_id)

	if not _edits.has(ck):
		_edits[ck] = {}
	if not _sub_edits.has(ck):
		_sub_edits[ck] = {}
	var uniform := SubdivGrid.uniform_value(grid)
	if uniform.x == 1:
		# Redevenu uniforme (plein ou vide) : re-fusion en bloc simple.
		data.set_block_by_index(index, uniform.y)
		_edits[ck][index] = uniform.y
		_sub_edits[ck].erase(index)
	else:
		var dominant := SubdivGrid.dominant_id(grid)
		data.set_subdiv(index, grid, dominant)
		_edits[ck][index] = dominant
		_sub_edits[ck][index] = grid.duplicate()

	# Remesh ; voisins si la région touche une face du bloc. Comme _apply_block,
	# on REMAILLE SYNCHRONEMENT tout de suite (sinon le bloc subdivisé n'apparaît
	# qu'après rechargement du chunk — bug signalé 2026-07-26).
	var touched: Array[Vector3i] = [ck]
	var lx := block_pos.x & 15
	var ly := block_pos.y & 15
	var lz := block_pos.z & 15
	if lx == 0 and cell_min.x == 0:
		touched.append(ck + Vector3i(-1, 0, 0))
	elif lx == 15 and cell_min.x + cell_size == SubdivGrid.SIZE:
		touched.append(ck + Vector3i(1, 0, 0))
	if ly == 0 and cell_min.y == 0:
		touched.append(ck + Vector3i(0, -1, 0))
	elif ly == 15 and cell_min.y + cell_size == SubdivGrid.SIZE:
		touched.append(ck + Vector3i(0, 1, 0))
	if lz == 0 and cell_min.z == 0:
		touched.append(ck + Vector3i(0, 0, -1))
	elif lz == 15 and cell_min.z + cell_size == SubdivGrid.SIZE:
		touched.append(ck + Vector3i(0, 0, 1))
	for tck: Vector3i in touched:
		_mark_dirty(tck)
	_install_epoch += 1
	for tck: Vector3i in touched:
		if _meshes.has(tck) or _chunks.has(tck):
			_remesh_chunk_now(tck, _install_epoch)

	if material_id != 0:
		EventBus.block_placed.emit(block_pos, material_id)
	else:
		EventBus.block_destroyed.emit(block_pos, old_id)
	return "ok"


@rpc("authority", "call_local", "reliable")
func rpc_apply_sub_region(block_pos: Vector3i, cell_min: Vector3i, cell_size: int, material_id: int) -> void:
	_apply_sub_region(block_pos, cell_min, cell_size, material_id)


@rpc("any_peer", "reliable")
func rpc_request_sub_region(block_pos: Vector3i, cell_min: Vector3i, cell_size: int, material_id: int) -> void:
	if not NetworkManager.is_host:
		return
	rpc_apply_sub_region.rpc(block_pos, cell_min, cell_size, material_id)


## Sous-grille d'un bloc (lecture seule) — vide si le bloc n'est pas subdivisé.
func subdiv_grid_at(block_pos: Vector3i) -> PackedInt32Array:
	if active_dimension != &"overworld":
		return PackedInt32Array()  # Pas de subdivision en donjon (3.5 simplifié).
	var ck := Vector3i(block_pos.x >> 4, block_pos.y >> 4, block_pos.z >> 4)
	var data: ChunkData = _chunks.get(ck)
	if data == null:
		return PackedInt32Array()
	var index := (block_pos.x & 15) | ((block_pos.z & 15) << 4) | ((block_pos.y & 15) << 8)
	return data.subdivs.get(index, PackedInt32Array())


## Nombre de cellules pleines de la sous-grille d'un bloc (précalculé,
## ChunkData.subdiv_solid) — -1 si le bloc n'est PAS subdivisé (bloc plein
## ou chunk hors cache : le niveau bloc fait alors foi). Pour la collision
## E.22 (« solide si >= 50 % du volume »), O(1) par requête.
func subdiv_solid_count(block_pos: Vector3i) -> int:
	if active_dimension != &"overworld":
		return -1  # Blocs de donjon toujours pleins (pas de subdivision).
	var ck := Vector3i(block_pos.x >> 4, block_pos.y >> 4, block_pos.z >> 4)
	var data: ChunkData = _chunks.get(ck)
	if data == null:
		return -1
	var index := (block_pos.x & 15) | ((block_pos.z & 15) << 4) | ((block_pos.y & 15) << 8)
	return int(data.subdiv_solid.get(index, -1))


## Matériau de base du monde (palette + bruit par voxel) — partagé avec les
## meshes de la dimension donjon (DungeonManager), jamais reconstruit ailleurs.
func base_material() -> ShaderMaterial:
	return _material


## Accès lecture des diffs pour SaveManager (E.10) — thread principal
## uniquement, jamais depuis une tâche (l'instantané en octets est construit
## avant tout passage en thread d'écriture).
func edits_for_save() -> Dictionary:
	return _edits


func sub_edits_for_save() -> Dictionary:
	return _sub_edits


## Statistiques pour le HUD et le bench.
func stats() -> Dictionary:
	_mutex.lock()
	var avg_us := _mesh_time_total_us / maxi(_meshed_chunks, 1)
	var max_us := _mesh_time_max_us
	var tasks := _meshed_chunks
	_mutex.unlock()
	return {
		"meshes": _meshes.size(),
		"cache": _chunks.size(),
		"queue": (_queue.size() - _queue_idx) + _in_flight.size(),
		"meshing_avg_ms": avg_us / 1000.0,
		"meshing_max_ms": max_us / 1000.0,
		"total_tasks": tasks,
	}


# --- Pipeline interne ---

## Construit le ShaderMaterial partagé : palette de couleurs + paramètres de
## bruit par id matériau runtime (9.1/G.2), depuis les données GameData.
func _build_material() -> void:
	var palette_img := Image.create_empty(256, 1, false, Image.FORMAT_RGBA8)
	var noise_img := Image.create_empty(256, 1, false, Image.FORMAT_RGBAF)
	var style_img := Image.create_empty(256, 1, false, Image.FORMAT_R8) # 2026-07-24
	style_img.fill(Color(0,0,0,0)) # Assure un style 0 (basic_noise) par défaut

	for id in GameData.materials:
		var mat: Dictionary = GameData.materials[id]
		var rid: int = GameData.material_runtime_ids[id]
		palette_img.set_pixel(rid, 0, Color.html(mat["color"]))
		var noise: Dictionary = mat["noise"]
		# Canal .a = motif de texture CURÉ optionnel (2026-07-26) : 0 = auto (le
		# shader varie par matériau), >0 force un sous-type (cristallin, terne,
		# aiguilles…). Voir voxel_material.gdshader (mpat).
		noise_img.set_pixel(rid, 0, Color(
			float(noise["amplitude"]), float(noise["scale"]), float(noise["seed_offset"]),
			float(mat.get("texture_pattern", 0))
		))
		# Encode le style de texture en ID pour le shader (2026-07-24).
		var style_name: String = mat.get("texture_style", "basic")
		var style_id: int = TEXTURE_STYLE_IDS.get(style_name, 0)
		style_img.set_pixel(rid, 0, Color(float(style_id) / 255.0, 0, 0))

	_material = ShaderMaterial.new()
	_material.shader = load("res://scenes/world/voxel_material.gdshader")
	_material.set_shader_parameter("palette", ImageTexture.create_from_image(palette_img))
	_material.set_shader_parameter("noise_params", ImageTexture.create_from_image(noise_img))
	_material.set_shader_parameter("style_map", ImageTexture.create_from_image(style_img)) # 2026-07-24
	_material.set_shader_parameter("world_seed", float(world_seed % 65536))
	_material.set_shader_parameter("herbe_id", int(GameData.material_runtime_ids.get("herbe", -1)))
	_material.set_shader_parameter("eau_id", int(GameData.material_runtime_ids.get("eau", -1)))  # Seule l'eau ondule (pas la lave).


## Petite texture GRASS_TINT_GRID×GRASS_TINT_GRID de teinte d'herbe pour le
## chunk `key` (2026-07-21) : échantillonne le biome RÉEL (pas juste son
## centre) à des points alignés sur les bords du chunk (0, 8, 16 blocs pour
## une grille 3×3) — les chunks voisins échantillonnent EXACTEMENT les mêmes
## coordonnées monde à leur bord partagé (`biome_at` est une fonction pure),
## donc les valeurs de bord coïncident : aucune marche visible à la jointure.
## Le filtrage linéaire du sampler (voxel_material.gdshader) interpole le
## reste en dégradé lisse, à la charge du GPU (gratuit).
func _grass_tint_texture(key: Vector3i) -> ImageTexture:
	var n := GRASS_TINT_GRID
	var img := Image.create_empty(n, n, false, Image.FORMAT_RGBAF)
	var bx := key.x * ChunkData.SIZE
	var bz := key.z * ChunkData.SIZE
	for gz in n:
		for gx in n:
			var wx := bx + int(round(float(gx) / float(n - 1) * ChunkData.SIZE))
			var wz := bz + int(round(float(gz) / float(n - 1) * ChunkData.SIZE))
			var biome: Dictionary = generator.biome_at(wx, wz)
			var tint: Array = biome.get("grass_tint", [1.0, 1.0, 1.0])
			img.set_pixel(gx, gz, Color(tint[0], tint[1], tint[2]))
	var tex := ImageTexture.create_from_image(img)
	return tex


## Hot-reload F5 : les ids runtime, couleurs, biomes et strates ont pu
## changer — on invalide tout ce qui en dérive, le streaming reconstruit.
## Les éditions (_edits) sont CONSERVÉES : ce sont des changements du monde,
## pas des données dérivées (attention : si les ids runtime changent parce
## qu'un matériau a été ajouté/supprimé, les ids stockés peuvent glisser —
## acceptable en debug, la sauvegarde E.10 stockera des ids texte).
func _on_data_reloaded() -> void:
	if generator == null:
		return  # Pas encore de monde (menu) : rien à invalider.
	_generation += 1
	for key in _meshes:
		_meshes[key].queue_free()
	_meshes.clear()
	_chunks.clear()
	_empty.clear()
	_ranges.clear()
	_ctx_cache.clear()
	_fine_meshes.clear()
	_coarse_meshes.clear()
	_lod_fine.clear()
	_queue.clear()
	_queue_idx = 0
	# Les tâches en vol seront jetées à l'arrivée (générations différentes).
	generator = NoiseGenerator.new(world_seed, SaveManager.active_config.get("params", {}))
	_build_material()
	var center := _center
	_center = Vector2i(1 << 30, 0)
	update_center(Vector3(center.x * ChunkData.SIZE, 0, center.y * ChunkData.SIZE))


func _rebuild_queue() -> void:
	# Parcours des offsets pré-triés : file ordonnée par distance sans tri par
	# frame. La complétude d'une colonne est vérifiée au lancement de tâche.
	_queue.clear()
	_queue_idx = 0
	for off in _sorted_offsets:
		var col := _center + off
		if not _in_flight.has(col):
			_queue.append(col)


func _col_dist2(col: Vector2i) -> int:
	var dx := col.x - _center.x
	var dz := col.y - _center.y
	return dx * dx + dz * dz


func _chunk_dist2(key: Vector3i) -> int:
	var dx := key.x - _center.x
	var dz := key.z - _center.y
	return dx * dx + dz * dz


## Plage verticale approchée d'une colonne (mémoïsée — échantillonnage léger).
func _range_for(col: Vector2i) -> Vector2i:
	var rng: Vector2i
	if _ranges.has(col):
		rng = _ranges[col]
	else:
		rng = generator.cy_range(col)
		rng.x = maxi(rng.x, CY_MIN_ABS)
		rng.y = mini(rng.y, CY_MAX_ABS)
		if _ranges.size() > 8192:
			_ranges.clear()  # Régénérable à coût négligeable.
		_ranges[col] = rng
	return rng


## Chunks à traiter d'une colonne : manquants (ni mesh ni vide connu) +
## chunks marqués dirty (mutations), y compris hors plage approchée
## (un joueur peut creuser plus profond que la marge de streaming).
func _missing_cys(col: Vector2i) -> PackedInt32Array:
	var rng := _range_for(col)
	var missing := PackedInt32Array()
	for cy in range(rng.x, rng.y + 1):
		var key := Vector3i(col.x, cy, col.y)
		if _dirty.has(key) or (not _meshes.has(key) and not _empty.has(key)):
			missing.append(cy)
	for key: Vector3i in _dirty:
		if key.x == col.x and key.z == col.y and (key.y < rng.x or key.y > rng.y):
			missing.append(key.y)
	missing.sort()
	return missing


func _mark_dirty(ck: Vector3i) -> void:
	_dirty[ck] = int(_dirty.get(ck, 0)) + 1
	var col := Vector2i(ck.x, ck.z)
	if not _urgent_cols.has(col):
		_urgent_cols.append(col)


## Chunk présent en cache, sinon généré de façon synchrone (mutation : on a
## besoin des données TOUT DE SUITE ; coût ~5 ms sur cache froid, rare).
func _get_chunk_sync(ck: Vector3i) -> ChunkData:
	var data: ChunkData = _chunks.get(ck)
	if data == null:
		var col := Vector2i(ck.x, ck.z)
		var ctx: Variant = _ctx_cache.get(col)
		if ctx == null:
			ctx = generator.prepare_context(col)
			if _ctx_cache.size() > 64:
				_ctx_cache.clear()
			_ctx_cache[col] = ctx
		data = generator.generate_chunk(ck, ctx)
		var chunk_edits: Variant = _edits.get(ck)
		if chunk_edits != null:
			for index: int in chunk_edits:
				data.set_block_by_index(index, chunk_edits[index])
		# Puis les sous-grilles (les ids dominants sont déjà dans les edits).
		var chunk_sub_edits: Variant = _sub_edits.get(ck)
		if chunk_sub_edits != null:
			for index: int in chunk_sub_edits:
				data.attach_subdiv(index, (chunk_sub_edits[index] as PackedInt32Array).duplicate())
		_chunks[ck] = data
	return data


## Y a-t-il un bloc du matériau `material_id` (station : établi/four) posé dans
## la CELLULE de 128 blocs contenant (wx,wz) ? (2026-07-26) Scan des éditions
## joueur (`_edits`, sparse) des chunks de la cellule — bon marché. Sert au
## gating de craft par station (« être dans la même cellule que l'établi »).
func station_in_cell(wx: int, wz: int, material_id: int) -> bool:
	if material_id <= 0:
		return false
	var cell := ClaimManager.cell_of_block(wx, wz)
	var cx0 := cell.x * (ClaimManager.CELL_SIZE / ChunkData.SIZE)  # chunk de départ
	var cz0 := cell.y * (ClaimManager.CELL_SIZE / ChunkData.SIZE)
	var span := ClaimManager.CELL_SIZE / ChunkData.SIZE            # chunks par côté de cellule
	for key: Vector3i in _edits:
		if key.x < cx0 or key.x >= cx0 + span or key.z < cz0 or key.z >= cz0 + span:
			continue
		for idx: int in _edits[key]:
			if int(_edits[key][idx]) == material_id:
				return true
	return false


## Remesh SYNCHRONE d'un chunk (thread principal) pour une édition instantanée.
## La donnée en cache est déjà à jour ; on ne fait que mailler + installer, sans
## passer par la file async (qui pouvait attendre un slot de worker occupé).
func _remesh_chunk_now(ck: Vector3i, epoch: int) -> void:
	var data := _get_chunk_sync(ck)
	var col := Vector2i(ck.x, ck.z)
	var ctx: Variant = _ctx_cache.get(col)
	if ctx == null:
		ctx = generator.prepare_context(col)
		if _ctx_cache.size() > 64:
			_ctx_cache.clear()
		_ctx_cache[col] = ctx
	var arrays: Array = []
	var coarse_arrays: Array = []
	if not (data.is_uniform() and data.uniform_id == 0):
		arrays = ChunkMesher.mesh_chunk(ck, data, generator, ctx, _edits, true)
		if not data.subdivs.is_empty():
			coarse_arrays = ChunkMesher.mesh_chunk(ck, data, generator, ctx, _edits, false)
	_install_chunk_mesh(ck, arrays, coarse_arrays, epoch)
	_dirty.erase(ck)


func _launch_tasks() -> void:
	# 1. Colonnes urgentes d'abord (mutations → remesh réactif).
	var i := 0
	while _in_flight.size() < _max_columns_in_flight and i < _urgent_cols.size():
		var col := _urgent_cols[i]
		if _in_flight.has(col):
			i += 1
			continue
		_urgent_cols.remove_at(i)
		var cys := _missing_cys(col)
		if not cys.is_empty():
			_dispatch(col, cys, true)
	# 2. File de streaming normale.
	while _in_flight.size() < _max_columns_in_flight and _queue_idx < _queue.size():
		var col: Vector2i = _queue[_queue_idx]
		_queue_idx += 1
		if _in_flight.has(col):
			continue
		var cys := _missing_cys(col)
		if not cys.is_empty():
			_dispatch(col, cys, false)


## `urgent` : true = remesh de mutation (seuls les chunks DEMANDÉS sont
## traités) ; false = streaming initial (la bande exacte de surface est
## comblée en entier, la plage approchée pouvant l'avoir manquée).
func _dispatch(col: Vector2i, cys: PackedInt32Array, urgent: bool) -> void:
	# Instantanés pour le thread : éditions des colonnes 3×3 voisines (pour
	# la coquille du mesher) + versions dirty des chunks demandés.
	var edits_snapshot := {}
	for key: Vector3i in _edits:
		if absi(key.x - col.x) <= 1 and absi(key.z - col.y) <= 1:
			edits_snapshot[key] = (_edits[key] as Dictionary).duplicate()
	var sub_edits_snapshot := {}
	for key: Vector3i in _sub_edits:
		if absi(key.x - col.x) <= 1 and absi(key.z - col.y) <= 1:
			var grids := {}
			for index: int in _sub_edits[key]:
				grids[index] = (_sub_edits[key][index] as PackedInt32Array).duplicate()
			if not grids.is_empty():
				sub_edits_snapshot[key] = grids
	var dirty_versions := {}
	for cy in cys:
		var key := Vector3i(col.x, cy, col.y)
		if _dirty.has(key):
			dirty_versions[key] = _dirty[key]
	# Remesh de MUTATION : la donnée en cache reflète DÉJÀ toutes les éditions
	# (appliquées dans _apply_block). On la duplique pour le thread au lieu de
	# régénérer le chunk depuis le bruit (minerais 3D + karst + rivières +
	# arbres) — c'est ça qui rendait chaque clic lent (2026-07-25).
	var data_snapshot := {}
	if urgent:
		for cy in cys:
			var key := Vector3i(col.x, cy, col.y)
			if _chunks.has(key):
				data_snapshot[key] = (_chunks[key] as ChunkData).duplicate_data()
	var task_id := WorkerThreadPool.add_task(
		_column_task.bind(col, cys, _generation, edits_snapshot, sub_edits_snapshot, dirty_versions, urgent, data_snapshot, _install_epoch),
		false, "Voxen column")
	_in_flight[col] = task_id


## Corps de tâche (thread) : UNE colonne entière — contexte de bruit
## échantillonné une fois (G.4), puis génération + meshing de chaque chunk.
## Dépose un résultat par chunk + une sentinelle de fin de colonne.
func _column_task(col: Vector2i, cys: PackedInt32Array, gen: int, edits_snapshot: Dictionary, sub_edits_snapshot: Dictionary, dirty_versions: Dictionary, urgent: bool, data_snapshot: Dictionary = {}, epoch: int = 0) -> void:
	var ctx := generator.prepare_context(col)
	# Plage exacte des chunks pouvant porter des faces : un chunk entièrement
	# sous la surface la plus basse du voisinage (hmin-1) est enterré de tous
	# côtés — ni génération ni meshing. Au-dessus de hmax : air. Les chunks
	# ÉDITÉS font exception (un bloc posé en plein ciel doit se mesher).
	var cy_lo_exact := floori(float(int(ctx["hmin"]) - 1) / 16.0)
	var cy_hi_exact := floori(float(int(ctx["hmax"]) + 1) / 16.0)
	var cy_lo := maxi(mini(cy_lo_exact, cys[0]), CY_MIN_ABS)
	var cy_hi := mini(maxi(cy_hi_exact, cys[cys.size() - 1]), CY_MAX_ABS)

	for cy in range(cy_lo, cy_hi + 1):
		var key := Vector3i(col.x, cy, col.y)
		var in_exact := cy >= cy_lo_exact and cy <= cy_hi_exact
		var requested := cys.has(cy)
		var edited: bool = edits_snapshot.has(key)
		# Remesh de mutation (urgent) : ne JAMAIS régénérer/remesher la bande
		# exacte entière — elle est déjà meshée, seuls les chunks demandés
		# (dirty + manquants) comptent. Audit 2026-07-21 : sans ce garde,
		# casser un bloc en montagne (hmax-hmin ~300) régénérait ~20 chunks
		# qui s'écoulaient ensuite au budget d'upload 2/frame.
		if urgent and not requested:
			continue
		if not requested and not in_exact:
			continue
		var dirty_version: int = dirty_versions.get(key, -1)
		if in_exact or edited or sub_edits_snapshot.has(key):
			var data: ChunkData
			if data_snapshot.has(key):
				# Donnée en cache (mutation) : déjà à jour, ni régénération ni
				# ré-application d'édition/sous-grille nécessaires.
				data = data_snapshot[key]
			else:
				data = generator.generate_chunk(key, ctx)
				if edited:
					var chunk_edits: Dictionary = edits_snapshot[key]
					for index: int in chunk_edits:
						data.set_block_by_index(index, chunk_edits[index])
				# Sous-grilles (subdivision 4.1) — les ids dominants sont déjà
				# posés par les edits ci-dessus.
				if sub_edits_snapshot.has(key):
					var grids: Dictionary = sub_edits_snapshot[key]
					for index: int in grids:
						data.attach_subdiv(index, grids[index])
			# NOTE : l'ArrayMesh est construit sur le thread PRINCIPAL à
			# l'upload — en renderer Compatibility (OpenGL mono-thread), le
			# construire ici force des synchronisations avec le rendu
			# (mesuré : 6 % de frames lentes contre 0,08 %).
			var arrays: Array = []
			var coarse_arrays: Array = []
			var start := Time.get_ticks_usec()
			if not (data.is_uniform() and data.uniform_id == 0):
				arrays = ChunkMesher.mesh_chunk(key, data, generator, ctx, edits_snapshot, true)
				# Variante LOD (G.2) : uniquement pour les chunks subdivisés.
				if not data.subdivs.is_empty():
					coarse_arrays = ChunkMesher.mesh_chunk(key, data, generator, ctx, edits_snapshot, false)
			var elapsed := Time.get_ticks_usec() - start
			_mutex.lock()
			_mesh_time_total_us += elapsed
			_mesh_time_max_us = maxi(_mesh_time_max_us, elapsed)
			_meshed_chunks += 1
			_results.append({"key": key, "gen": gen, "data": data, "arrays": arrays,
				"coarse_arrays": coarse_arrays, "dirty_version": dirty_version, "epoch": epoch})
			_mutex.unlock()
		else:
			# Hors plage exacte et non édité : vide garanti (air ou enterré).
			# Pas de données poussées — elles seraient fausses pour les chunks
			# enterrés, et tout est régénérable à la demande (G.1).
			_mutex.lock()
			_meshed_chunks += 1
			_results.append({"key": key, "gen": gen, "data": null, "arrays": [],
				"coarse_arrays": [], "dirty_version": dirty_version, "epoch": epoch})
			_mutex.unlock()

	_mutex.lock()
	_results.append({"col": col, "done": true, "gen": gen})
	_mutex.unlock()


func _upload_ready_meshes() -> void:
	# Le budget G.2 (2 uploads/frame) ne s'applique qu'aux VRAIS meshes :
	# les résultats vides et les sentinelles sont drainés librement.
	var batch := []
	var budget := _uploads_per_frame
	_mutex.lock()
	while not _results.is_empty():
		var front: Dictionary = _results[0]
		if not front.has("done") and not (front["arrays"] as Array).is_empty():
			if budget == 0:
				break
			budget -= 1
		batch.append(_results.pop_front())
	_mutex.unlock()

	for result: Dictionary in batch:
		if result.has("done"):
			# Fin de colonne : libérer le slot, récolter la tâche, et
			# re-planifier si des mutations sont arrivées entre-temps.
			var col: Vector2i = result["col"]
			if _in_flight.has(col):
				WorkerThreadPool.wait_for_task_completion(_in_flight[col])
				_in_flight.erase(col)
			for key: Vector3i in _dirty:
				if key.x == col.x and key.z == col.y:
					if not _urgent_cols.has(col):
						_urgent_cols.append(col)
					break
			continue
		if result["gen"] != _generation:
			continue  # Résultat obsolète (hot-reload entre-temps).
		var key: Vector3i = result["key"]
		if result["data"] != null:
			_chunks[key] = result["data"]
		# Le remesh reflète les mutations jusqu'à la version capturée ; une
		# mutation plus récente garde le chunk dirty (nouvelle passe).
		var dirty_version: int = result["dirty_version"]
		if dirty_version >= 0 and int(_dirty.get(key, -2)) == dirty_version:
			_dirty.erase(key)
		_install_chunk_mesh(key, result["arrays"], result["coarse_arrays"], int(result.get("epoch", 0)))


## Installe (ou remplace) le mesh d'un chunk sur le thread PRINCIPAL —
## construction de l'ArrayMesh + MeshInstance. Partagé par l'upload async et le
## remesh synchrone d'édition (_remesh_chunk_now).
func _install_chunk_mesh(key: Vector3i, arrays: Array, coarse_arrays: Array, epoch: int) -> void:
	# Garde anti-écrasement : ne jamais installer un résultat plus ancien que le
	# dernier mesh déjà posé pour ce chunk (édition synchrone vs tâche async).
	if int(_installed_epoch.get(key, -1)) > epoch:
		return
	_installed_epoch[key] = epoch
	if arrays.is_empty():
		if _meshes.has(key):
			_meshes[key].queue_free()
			_meshes.erase(key)
		_forget_lod(key)
		_empty[key] = true
		return
	_empty.erase(key)
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	# Variante LOD des chunks subdivisés (G.2) : bascule à la distance.
	var shown := mesh
	if coarse_arrays.is_empty():
		_forget_lod(key)
	else:
		var coarse := ArrayMesh.new()
		coarse.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, coarse_arrays)
		_fine_meshes[key] = mesh
		_coarse_meshes[key] = coarse
		var want_fine := _chunk_dist2(key) <= LOD_FINE_RADIUS * LOD_FINE_RADIUS
		_lod_fine[key] = want_fine
		shown = mesh if want_fine else coarse
	if _meshes.has(key):
		_meshes[key].mesh = shown  # Remplacement en place (mutation).
	else:
		var instance := MeshInstance3D.new()
		instance.mesh = shown
		# Teinte d'herbe par biome AVEC DÉGRADÉ (2026-07-21) : ShaderMaterial
		# DUPLIQUÉ par chunk (pas un `instance uniform` — plafond matériel
		# global de 4096 emplacements dépassé en jeu réel, voir
		# voxel_material.gdshader) portant une petite texture de teinte
		# GRID_SIZE×GRID_SIZE échantillonnée au biome réel (pas juste le
		# centre du chunk) à des points alignés sur les BORDS du chunk —
		# le filtrage linéaire du sampler produit un dégradé lisse à
		# l'intérieur du chunk, et les points d'échantillon partagés avec
		# les chunks voisins (mêmes coordonnées MONDE, fonction pure
		# `biome_at`) garantissent la continuité aux jointures (pas de
		# marche visible entre deux chunks de biomes différents).
		var chunk_material := _material.duplicate() as ShaderMaterial
		chunk_material.set_shader_parameter("grass_tint_map", _grass_tint_texture(key))
		# Origine MONDE du chunk (blocs) → texture calculée en coords locales
		# précises (anti-tremblement loin de l'origine, 2026-07-26).
		chunk_material.set_shader_parameter("chunk_origin", Vector3(key * ChunkData.SIZE))
		instance.material_override = chunk_material
		instance.position = Vector3(key * ChunkData.SIZE)
		chunk_root.add_child(instance)
		_meshes[key] = instance


## Éviction (G.2) : mesh libéré immédiatement hors rayon ; données gardées en
## cache borné puis jetées (régénérables par la graine — jamais stockées).
## Les chunks édités gardent leurs données (diff _edits conservé à vie).
func _evict() -> void:
	var to_remove: Array[Vector3i] = []
	for key: Vector3i in _meshes:
		if _chunk_dist2(key) > _evict_radius * _evict_radius:
			to_remove.append(key)
	for key in to_remove:
		_meshes[key].queue_free()
		_meshes.erase(key)
		_forget_lod(key)
		_installed_epoch.erase(key)
	if _chunks.size() > _chunk_cache_max:
		var cached: Array[Vector3i] = []
		for key: Vector3i in _chunks:
			if not _edits.has(key):
				cached.append(key)
		cached.sort_custom(func(a: Vector3i, b: Vector3i) -> bool:
			return _chunk_dist2(a) > _chunk_dist2(b))
		for i in mini(cached.size(), _chunks.size() - _chunk_cache_max):
			_chunks.erase(cached[i])
	# Le registre des chunks vides est borné lui aussi (régénérable).
	if _empty.size() > 16384:
		var far_keys: Array[Vector3i] = []
		for key: Vector3i in _empty:
			if _chunk_dist2(key) > 4 * _evict_radius * _evict_radius:
				far_keys.append(key)
		for key in far_keys:
			_empty.erase(key)


## Bascule fine ↔ LOD des chunks subdivisés selon la distance (G.2).
func _update_lod() -> void:
	for key: Vector3i in _coarse_meshes:
		if not _meshes.has(key):
			continue
		var want_fine := _chunk_dist2(key) <= LOD_FINE_RADIUS * LOD_FINE_RADIUS
		if bool(_lod_fine.get(key, true)) != want_fine:
			_meshes[key].mesh = _fine_meshes[key] if want_fine else _coarse_meshes[key]
			_lod_fine[key] = want_fine


func _forget_lod(key: Vector3i) -> void:
	_fine_meshes.erase(key)
	_coarse_meshes.erase(key)
	_lod_fine.erase(key)


func _exit_tree() -> void:
	# Attendre proprement les tâches encore en vol.
	for col in _in_flight:
		WorkerThreadPool.wait_for_task_completion(_in_flight[col])
	_in_flight.clear()
