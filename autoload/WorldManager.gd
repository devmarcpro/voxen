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
## Dimension active (3.5). Hors overworld, les lectures et mutations de blocs
## sont ROUTÉES vers DimensionManager — et non plus vers DungeonManager, ce qui
## revenait à dire que « pas l'overworld » signifiait « donjon » et interdisait
## toute troisième dimension. Le terrain overworld est caché et son streaming
## gelé
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
## Index spatial du diff (2026-07-27) : colonne Vector2i(x,z) -> { chunk -> true }.
## _dispatch construisait son instantané en scannant _edits EN ENTIER à chaque
## colonne lancée (jusqu'à 6 par frame). Coût nul en partie neuve, mais _edits
## n'est JAMAIS purgé par conception : après une longue session de construction,
## c'est des dizaines de milliers d'itérations par frame de streaming. Cet index
## rend le coût du dispatch proportionnel au voisinage 3×3, plus à la taille du
## monde construit. Reconstruit à la restauration d'une sauvegarde (_reindex_edits).
var _edit_cols := {}
## Variantes de mesh des chunks subdivisés (LOD G.2) + état courant.
var _fine_meshes := {}     # Vector3i -> ArrayMesh (passe fine)
var _coarse_meshes := {}   # Vector3i -> ArrayMesh (blocs pleins dominants)
var _lod_fine := {}        # Vector3i -> bool (variante actuellement affichée)
## Chunks à re-mesher (compteur de version : une mutation pendant un remesh
## en vol déclenche un nouveau remesh, jamais de perte).
var _dirty := {}
## Colonnes à retraiter en priorité (mutations). Dictionary et non Array : le
## test d'appartenance était un Array.has() LINÉAIRE, appelé jusqu'à 7 fois par
## mutation (une par chunk touché) — audit 2026-07-27. L'ordre d'insertion des
## dictionnaires Godot préserve la priorité d'arrivée.
var _urgent_cols := {}
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


## Le rayon de rendu vit désormais dans SettingsManager (user://settings.cfg),
## avec la langue et les touches. L'ancien user://display.cfg est replié au
## premier lancement — voir SettingsManager._migrate_legacy_display().


func _load_display_setting() -> void:
	# Les BENCHS ignorent le réglage sauvegardé : sinon deux mesures prises à
	# des distances d'affichage différentes sont incomparables, et un écart
	# de réglage se lit comme une régression de performance. Constaté le
	# 2026-07-27 : un display.cfg à 14 au lieu de 8 avait triplé le nombre de
	# chunks et fait passer le bench de 245 à 66 fps — sans qu'aucun code de
	# rendu n'ait changé.
	var args := OS.get_cmdline_user_args()
	for flag in ["--bench", "--statique", "--bench-mutation", "--bench-creatures", "--probe-mesh"]:
		if flag in args:
			render_radius = DEFAULT_CHUNK_RADIUS
			_evict_radius = render_radius + 2
			_scale_budgets()
			print("[BENCH] distance d'affichage forcée à %d (réglage joueur ignoré)." % render_radius)
			return
	render_radius = clampi(int(SettingsManager.get_value(
			"display", "render_distance", DEFAULT_CHUNK_RADIUS)), 4, 48)
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
	SettingsManager.set_value("display", "render_distance", render_radius)
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
	# Les diffs restaurés arrivent d'un bloc, sans passer par _note_edit : l'index
	# spatial doit être reconstruit, sinon _dispatch ignorerait toutes les
	# éditions d'une partie chargée (coutures aux frontières de chunk).
	_reindex_edits()
	_build_material()
	SaveManager.world_active = true  # Arme autosave/F9/sauvegarde de sortie.


## ADOPTE LE MONDE D'UN HÔTE (E.11, 2026-08-04).
##
## POURQUOI C'EST LA PREMIÈRE CHOSE À FAIRE EN RÉSEAU. Tout le monde de Voxen
## dérive de sa GRAINE : relief, biomes, arbres, villages, royaumes, donjons.
## Deux joueurs de graines différentes ne partagent rien — ils voient chacun un
## monde cohérent, mais pas le même, et les seules choses qui voyagent (les
## éditions de blocs) atterrissent dans le décor de l'autre.
##
## Jusqu'ici la graine n'était jamais transmise : chaque camp lisait la sienne
## dans sa propre sauvegarde. Ça n'a fonctionné que parce que les deux valaient
## 1337 par défaut — une coïncidence, pas un protocole.
##
## Adopter une graine reconstruit tout, exactement comme un rechargement de
## données à chaud : c'est le même chemin, et il est déjà éprouvé.
func adopt_world(seed_value: int, params: Dictionary) -> void:
	if generator != null and world_seed == seed_value:
		return  # Déjà le bon monde : ne rien jeter pour rien.
	SaveManager.active_config = {
		"name": String(SaveManager.active_config.get("name", "réseau")),
		"seed": seed_value,
		"params": params.duplicate(true),
	}
	world_seed = seed_value
	# Les éditions locales n'ont plus de sens : elles portaient sur un autre
	# monde. Les garder ferait apparaître des blocs posés là où le terrain n'est
	# plus le même.
	_edits.clear()
	_sub_edits.clear()
	_reindex_edits()
	# Les caches dérivés de la graine doivent partir avec elle.
	KingdomGenerator.clear_cache()
	if generator == null:
		initialize_world()
		return
	_on_data_reloaded()


func _process(_delta: float) -> void:
	if chunk_root == null or generator == null:
		return
	_push_season_tint()
	_upload_ready_meshes()  # Draine toujours les résultats en vol (même cachés).
	if active_dimension == &"overworld":
		_launch_tasks()
		_warm_world_metadata()


## TEINTE SAISONNIÈRE, poussée au shader quand elle change.
##
## Une comparaison par frame plutôt qu'un abonnement au changement de saison :
## la teinte se fond sur le dernier quart de chaque saison, donc elle bouge en
## continu et non par paliers. Écrire l'uniform à chaque frame coûterait un
## appel de rendu pour rien la plupart du temps.
var _season_tint := Color.WHITE


func _push_season_tint() -> void:
	if _material == null:
		return
	var tint := CalendarManager.foliage_tint()
	if tint.is_equal_approx(_season_tint):
		return
	_season_tint = tint
	_material.set_shader_parameter("season_tint", Vector3(tint.r, tint.g, tint.b))


## PRÉCHAUFFAGE DES ROYAUMES, hors tick et un secteur par frame.
##
## Générer les royaumes d'un secteur neuf coûtait 43 ms, ramenés à 10 par la
## mémoïsation du coût d'entrée — c'est mieux, mais c'est encore la majorité
## d'un budget de tick, et ça tombait EN PLEIN TICK : `_populate_village`
## demandait le royaume d'un village, et le joueur voyait un `[TICK] 62 ms`.
##
## Ici, le calcul se fait dans `_process` — donc dans une frame, pas dans un
## tick — et par avance : les neuf secteurs autour du joueur sont préparés bien
## avant qu'un village ne les réclame. Le tick ne paie plus rien.
##
## UN SEUL SECTEUR PAR FRAME. Neuf d'un coup rendraient la main après 90 ms, ce
## qui déplacerait le à-coup au lieu de le supprimer.
func _warm_world_metadata() -> void:
	if generator == null:
		return
	var player_cell := ClaimManager.cell_of_block(_center.x * ChunkData.SIZE,
			_center.y * ChunkData.SIZE)

	# LES PLANS DE VILLE D'ABORD, parce que c'est le tick de peuplement qui les
	# réclame et qu'il les réclame sur les NEUF cellules autour du joueur, à
	# chaque passage. Une cellule sans ville s'écarte en quelques microsecondes,
	# mais une cellule qui en a une coûte une dizaine de millisecondes à
	# composer : mesuré, neuf voisines fraîches faisaient un tick à 56 ms.
	for dz in range(-1, 2):
		for dx in range(-1, 2):
			var cell := player_cell + Vector2i(dx, dz)
			if not generator.has_city_layout(cell):
				generator.city_at_cell(cell)
				return  # Un par frame, et on rend la main.

	var sector := KingdomGenerator.sector_of(player_cell)
	# Le secteur courant d'abord, ses voisins ensuite : c'est l'ordre dans lequel
	# le joueur en aura besoin.
	for radius in 2:
		for dz in range(-radius, radius + 1):
			for dx in range(-radius, radius + 1):
				if maxi(absi(dx), absi(dz)) != radius:
					continue
				if KingdomGenerator.warm_sector(sector + Vector2i(dx, dz), world_seed, generator):
					return  # Un par frame, et on rend la main.


## Bascule de dimension (3.5) : cache/révèle le monde overworld et prévient
## les créatures (visibilité + gel des ticks hors dimension active).
func set_active_dimension(dim: StringName) -> void:
	if dim == active_dimension:
		return
	active_dimension = dim
	if chunk_root != null:
		chunk_root.visible = dim == &"overworld"
	CreatureManager.on_dimension_changed(dim)
	# Les caches au sol sont filtrées par dimension (2026-08-02) : sans ce
	# rafraîchissement, les marqueurs de la dimension qu'on vient de quitter
	# resteraient affichés dans celle où l'on arrive.
	DropManager.on_dimension_changed()


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
## Le décor coupe-t-il le segment [from, to] ? Test de LIGNE DE VUE partagé.
##
## POURQUOI ICI (2026-08-02). Le joueur avait le sien (`_raycast_voxel`, avec
## raffinement de subdivision, taillé pour miner au demi-bloc) ; les créatures
## n'en avaient AUCUN. Conséquence : la lame d'un bandit traversait les murs et
## touchait à travers une porte fermée, là où celle du joueur s'arrêtait. Le
## combat ne peut pas être juste si un seul camp respecte le décor.
##
## Échantillonnage au quart de bloc plutôt qu'un DDA exact : un segment de mêlée
## fait 1 à 3 blocs, soit une douzaine de lectures de tableau. Un DDA serait
## plus précis aux arêtes et coûterait plus cher à écrire comme à exécuter, pour
## un gain qu'aucun joueur ne percevrait sur une distance pareille.
const LINE_STEP := 0.25


func line_blocked(from: Vector3, to: Vector3) -> bool:
	var delta := to - from
	var distance := delta.length()
	if distance < 0.0001:
		return false
	var direction := delta / distance
	var travelled := LINE_STEP
	while travelled < distance:
		var point := from + direction * travelled
		if block_at_world(Vector3i(floori(point.x), floori(point.y), floori(point.z))) != 0:
			return true
		travelled += LINE_STEP
	return false


func block_at_world(pos: Vector3i) -> int:
	if generator == null:
		return 0  # Aucun monde actif (menu de démarrage).
	if active_dimension != &"overworld":
		return DimensionManager.block_at(pos)
	var ck := Vector3i(pos.x >> 4, pos.y >> 4, pos.z >> 4)
	var index := (pos.x & 15) | ((pos.z & 15) << 4) | ((pos.y & 15) << 8)
	var chunk_edits: Variant = _edits.get(ck)
	if chunk_edits != null and (chunk_edits as Dictionary).has(index):
		return chunk_edits[index]
	var data: ChunkData = _chunks.get(ck)
	if data != null:
		return data.get_block_by_index(index)
	return generator.block_at(pos.x, pos.y, pos.z)


## Le chunk contenant ce bloc est-il DÉJÀ EN MÉMOIRE ?
##
## `block_at_world` répond toujours, mais pas au même prix : chunk chargé, c'est
## une lecture de tableau ; sinon, c'est une requête au générateur, qui
## reconstruit la colonne (relief, biome, strates, grottes, rivières). Un
## appelant qui en fait plusieurs par tick doit pouvoir choisir un autre chemin
## quand le monde n'est pas là — c'est exactement ce qui coûtait 4,6 ms par
## villageois et par tick.
func is_block_loaded(pos: Vector3i) -> bool:
	if active_dimension != &"overworld":
		return true  # Une dimension tient tout en mémoire, il n'y a rien à streamer.
	return _chunks.has(Vector3i(pos.x >> 4, pos.y >> 4, pos.z >> 4))


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


## Écriture DONNÉES d'une mutation : cache chunk + diff (_edits) + index spatial
## + suivi de sauvegarde. AUCUN remesh, AUCUN signal — c'est la partie commune au
## chemin instantané (_apply_block) et au chemin batché (set_block_batched), pour
## qu'il n'existe qu'UNE seule écriture du diff (deux copies divergeraient).
## Retourne l'ancien id, ou -1 si la mutation est refusée (hors bornes, ou aucun
## changement).
func _write_block_data(pos: Vector3i, material_id: int) -> int:
	if pos.y < WORLD_Y_MIN or pos.y > WORLD_Y_MAX:
		return -1
	var old_id := block_at_world(pos)
	if old_id == material_id:
		return -1

	var ck := Vector3i(pos.x >> 4, pos.y >> 4, pos.z >> 4)
	var index := (pos.x & 15) | ((pos.z & 15) << 4) | ((pos.y & 15) << 8)
	var data := _get_chunk_sync(ck)
	data.set_block_by_index(index, material_id)
	if not _edits.has(ck):
		_edits[ck] = {}
	_edits[ck][index] = material_id
	_note_edit(ck)
	_dirty_save[ck] = true
	# Un bloc plein remplace toute subdivision (diff nettoyé en conséquence).
	# Fait ICI, avant le remesh, et non après comme auparavant : un instantané de
	# tâche pris entre les deux verrait une sous-grille déjà effacée du chunk mais
	# encore présente dans le diff, et la ré-attacherait par-dessus le bloc plein.
	if _sub_edits.has(ck):
		_sub_edits[ck].erase(index)
	return old_id


## Chunks à remesher pour une mutation en `pos` : le chunk porteur, plus les
## voisins qui partagent la face modifiée (sans quoi une couture apparaît à la
## frontière). Facteur commun aux deux chemins de mutation.
func _touched_chunks(pos: Vector3i) -> Array[Vector3i]:
	var ck := Vector3i(pos.x >> 4, pos.y >> 4, pos.z >> 4)
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
	return touched


## Application RÉELLE de la mutation JOUEUR (identique sur toutes les machines,
## D.2). Ne jamais appeler directement depuis le gameplay — passer par
## set_block() pour que le routage réseau reste correct.
## Remesh SYNCHRONE immédiat : c'est ce qui donne l'édition instantanée (passer
## par la file async ajoutait un délai énorme, l'édition attendant un slot de
## worker libre derrière de longues tâches de streaming). Pour une mutation de
## SIMULATION (fluides, intégrité, croissance), utiliser set_block_batched().
func _apply_block(pos: Vector3i, material_id: int) -> bool:
	if active_dimension != &"overworld":
		return DimensionManager.apply_block(pos, material_id)
	var old_id := _write_block_data(pos, material_id)
	if old_id < 0:
		return false

	var touched := _touched_chunks(pos)
	for tck: Vector3i in touched:
		_mark_dirty(tck)
	# Remesh SYNCHRONE sur le thread principal : seuls les chunks déjà chargés.
	# _remesh_chunk_now efface leur drapeau dirty, la file async ne les reprend
	# donc pas.
	_install_epoch += 1
	for tck: Vector3i in touched:
		if _meshes.has(tck) or _chunks.has(tck):
			_remesh_chunk_now(tck, _install_epoch)

	# Couplage inter-systèmes par l'EventBus uniquement (E.12).
	if old_id != 0:
		EventBus.block_destroyed.emit(pos, old_id)
	if material_id != 0:
		EventBus.block_placed.emit(pos, material_id)
	return true


# --- Mutations de SIMULATION : batching (2026-07-27) ---
#
# Pourquoi : _apply_block remaille SYNCHRONEMENT jusqu'à 7 chunks (+ autant de
# recalculs de LightField) par appel. C'est le bon compromis pour l'édition
# manuelle — un clic, une réponse immédiate. C'est ruineux pour un système de
# simulation : un fluide s'écoulant sur 20 blocs par tick produirait jusqu'à 140
# remesh synchrones à 10 Hz. Les mutations de simulation accumulent donc leurs
# chunks touchés et ne paient QU'UN remesh par chunk et par tick, quel que soit
# le nombre de blocs écrits dedans.
#
# LIMITE CONNUE : le flush reste synchrone. Si un tick touche 200 chunks
# DISTINCTS, les 200 remesh tombent dans la même frame. Le batching supprime la
# redondance (cas normal : beaucoup de blocs, peu de chunks), pas ce pic
# pathologique — le budget de flush par frame viendra si la mesure le réclame.

## Chunks touchés depuis le dernier flush (Vector3i -> true).
var _batch_touched := {}
## Mutations batchées en attente de signal : [pos, old_id, new_id]. Émettre
## depuis la boucle de simulation exposerait les abonnés à un monde à moitié muté.
var _batch_events: Array = []


## Mutation SANS remesh immédiat, destinée aux systèmes de simulation (fluides,
## intégrité structurelle, croissance/fertilité). Le diff, le cache chunk et le
## suivi de sauvegarde sont mis à jour TOUT DE SUITE — un block_at_world() juste
## après voit bien la nouvelle valeur. Seuls le meshing et les signaux sont
## différés jusqu'à flush_batched_edits().
##
## NON ROUTÉ EN RÉSEAU : la simulation est déterministe et rejoue à l'identique
## sur chaque machine depuis le même tick_index (E.11). Router chaque bloc de
## fluide en RPC saturerait le lien.
##
## LIMITE ASSUMÉE : hors overworld, l'appel retombe sur DungeonManager, qui
## remaille SYNCHRONEMENT — le batching n'y produit aucun gain. Sans objet tant
## qu'aucun système de simulation ne tourne en donjon (3.5) ; à revoir le jour où
## un fluide devra couler dans une salle.
func set_block_batched(pos: Vector3i, material_id: int) -> bool:
	if generator == null:
		return false
	if active_dimension != &"overworld":
		return DimensionManager.apply_block(pos, material_id)
	var old_id := _write_block_data(pos, material_id)
	if old_id < 0:
		return false
	# Le chunk porteur ET ses voisins de bordure : un chunk touché 500 fois
	# n'apparaît qu'une seule fois dans le dictionnaire — c'est là qu'est le gain.
	for tck: Vector3i in _touched_chunks(pos):
		_batch_touched[tck] = true
	_batch_events.append([pos, old_id, material_id])
	return true


## Y a-t-il des mutations batchées en attente ? (évite au TickManager de payer un
## appel de fonction et une itération pour rien au tick le plus courant)
func has_batched_edits() -> bool:
	return not _batch_touched.is_empty()


## Vide le lot : UN remesh par chunk touché, puis les signaux. À appeler une fois
## par tick, en fin de phase monde (TickManager) — jamais depuis un système de
## simulation lui-même, sinon on retombe sur le coût par-bloc qu'on évitait.
func flush_batched_edits() -> void:
	if _batch_touched.is_empty():
		return
	_install_epoch += 1
	var epoch := _install_epoch
	for tck: Vector3i in _batch_touched:
		_mark_dirty(tck)
		# Chunk non chargé : le drapeau dirty suffit, la file de streaming le
		# remaillera à son arrivée. Le forcer ici paierait un generate_chunk
		# complet sur le thread principal pour un chunk que personne ne voit.
		if _meshes.has(tck) or _chunks.has(tck):
			_remesh_chunk_now(tck, epoch)
	_batch_touched.clear()

	# Signaux APRÈS le remesh : un abonné qui lit le monde le voit cohérent.
	var events := _batch_events
	_batch_events = []
	for e: Array in events:
		var pos: Vector3i = e[0]
		if int(e[1]) != 0:
			EventBus.block_destroyed.emit(pos, int(e[1]))
		if int(e[2]) != 0:
			EventBus.block_placed.emit(pos, int(e[2]))


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
	_note_edit(ck)
	var uniform := SubdivGrid.uniform_value(grid)
	if uniform.x == 1:
		# Redevenu uniforme (plein ou vide) : re-fusion en bloc simple.
		data.set_block_by_index(index, uniform.y)
		_edits[ck][index] = uniform.y
		_sub_edits[ck].erase(index)
		_dirty_save[ck] = true
	else:
		var dominant := SubdivGrid.dominant_id(grid)
		data.set_subdiv(index, grid, dominant)
		_edits[ck][index] = dominant
		_sub_edits[ck][index] = grid.duplicate()
		_dirty_save[ck] = true

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


## Pose une sous-grille ENTIÈRE sur un bloc, d'un coup.
##
## POURQUOI ELLE MANQUAIT, ET POURQUOI ELLE MANQUAIT VRAIMENT. `set_sub_region`
## sculpte une région à la fois : reproduire une grille de 512 cellules avec
## elle demande des dizaines d'appels, dont chacun REMAILLE SON CHUNK
## SYNCHRONEMENT. Tous les producteurs de géométrie fine — générateur d'arbres,
## générateur de plantes — bâtissent pourtant leur grille complète d'un bloc, et
## le générateur de monde l'écrit telle quelle dans le chunk. Faute d'API, tout
## code hors génération (sonde de capture, menu de triche) devait attraper le
## `ChunkData` par un chemin privé pour faire la même chose.
##
## Retourne false si le bloc est hors du monde ou hors de l'overworld.
func set_subdiv_grid(block_pos: Vector3i, grid: PackedInt32Array, material_id: int) -> bool:
	if active_dimension != &"overworld":
		return false  # Pas de sculpture fine en donjon (simplification 3.5 assumée).
	if block_pos.y < WORLD_Y_MIN or block_pos.y > WORLD_Y_MAX:
		return false
	var ck := Vector3i(block_pos.x >> 4, block_pos.y >> 4, block_pos.z >> 4)
	var index := (block_pos.x & 15) | ((block_pos.z & 15) << 4) | ((block_pos.y & 15) << 8)
	var data := _get_chunk_sync(ck)
	if data == null:
		return false

	var uniform := SubdivGrid.uniform_value(grid)
	if not _edits.has(ck):
		_edits[ck] = {}
	if not _sub_edits.has(ck):
		_sub_edits[ck] = {}
	_note_edit(ck)
	if uniform.x == 1:
		# Grille pleine ou vide : c'est un bloc simple, pas une sous-grille.
		data.set_block_by_index(index, uniform.y)
		_edits[ck][index] = uniform.y
		_sub_edits[ck].erase(index)
	else:
		var dominant := SubdivGrid.dominant_id(grid)
		data.set_subdiv(index, grid, dominant)
		_edits[ck][index] = dominant
		_sub_edits[ck][index] = grid.duplicate()
	_dirty_save[ck] = true

	# Une sous-grille peut toucher n'importe laquelle des six faces du bloc :
	# on remaille les voisins de bordure sans chercher lesquels, il y en a au
	# plus trois et le test coûterait plus cher que le remaillage évité.
	var touched: Array[Vector3i] = [ck]
	for axis: Vector3i in [Vector3i(1, 0, 0), Vector3i(-1, 0, 0), Vector3i(0, 1, 0),
			Vector3i(0, -1, 0), Vector3i(0, 0, 1), Vector3i(0, 0, -1)]:
		var neighbour := Vector3i((block_pos.x + axis.x) >> 4, (block_pos.y + axis.y) >> 4,
				(block_pos.z + axis.z) >> 4)
		if neighbour != ck and not (neighbour in touched):
			touched.append(neighbour)
	for tck: Vector3i in touched:
		_mark_dirty(tck)
	_install_epoch += 1
	for tck: Vector3i in touched:
		if _meshes.has(tck) or _chunks.has(tck):
			_remesh_chunk_now(tck, _install_epoch)
	return true


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
## Chunks à réécrire à la prochaine sauvegarde (voir take_dirty_save_chunks).
var _dirty_save := {}


func edits_for_save() -> Dictionary:
	return _edits


## Chunks dont les modifications ont changé DEPUIS LA DERNIÈRE ÉCRITURE, puis
## remise à zéro du suivi (2026-07-27).
##
## Pourquoi : l'autosave réécrivait TOUS les chunks modifiés depuis le début de
## la partie, toutes les 5 minutes. Le coût grandissait indéfiniment avec ce
## que le joueur avait construit — après une longue session de construction,
## chaque autosave repassait des milliers de fichiers alors que deux ou trois
## avaient bougé. Les fichiers déjà écrits restent valides sur disque : ne
## réécrire que le delta est exact ET borné.
func take_dirty_save_chunks() -> Dictionary:
	var dirty := _dirty_save
	_dirty_save = {}
	return dirty


## Re-signale TOUS les chunks modifiés comme à écrire — utilisé quand on ne
## peut pas se fier à l'état du disque (nouveau dossier de sauvegarde).
func mark_all_chunks_dirty() -> void:
	_dirty_save = {}
	# Une seule passe via l'index spatial : il couvre déjà _edits ET _sub_edits.
	for col: Vector2i in _edit_cols:
		for ck: Vector3i in (_edit_cols[col] as Dictionary):
			_dirty_save[ck] = true


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
	# Largeur pilotée par le catalogue (GameData.palette_size) et non figée à
	# 256 : le shader lit ces textures en texelFetch par index exact (2026-07-27).
	var palette_width := GameData.palette_size()
	var palette_img := Image.create_empty(palette_width, 1, false, Image.FORMAT_RGBA8)
	var noise_img := Image.create_empty(palette_width, 1, false, Image.FORMAT_RGBAF)
	var style_img := Image.create_empty(palette_width, 1, false, Image.FORMAT_R8) # 2026-07-24
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
	# La palette de pierre taillée des tours est mise en cache par cellule et
	# stocke des ids RUNTIME, qui viennent de glisser : sans cette purge, les
	# tours déjà visitées se rebâtiraient dans les mauvaises roches.
	DungeonTower.reset_caches()
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


## Enregistre un chunk édité dans l'index spatial. Appelé par TOUTE écriture de
## _edits / _sub_edits — un oubli se traduirait par des coutures aux frontières
## de chunk (les éditions manquantes de l'instantané ne seraient pas surimposées
## à la coquille du mesher).
func _note_edit(ck: Vector3i) -> void:
	var col := Vector2i(ck.x, ck.z)
	var set: Variant = _edit_cols.get(col)
	if set == null:
		set = {}
		_edit_cols[col] = set
	(set as Dictionary)[ck] = true


## Reconstruit l'index depuis _edits/_sub_edits (restauration de sauvegarde : les
## diffs arrivent d'un bloc, sans passer par _note_edit).
func _reindex_edits() -> void:
	_edit_cols.clear()
	for ck: Vector3i in _edits:
		_note_edit(ck)
	for ck: Vector3i in _sub_edits:
		_note_edit(ck)


func _mark_dirty(ck: Vector3i) -> void:
	_dirty[ck] = int(_dirty.get(ck, 0)) + 1
	_urgent_cols[Vector2i(ck.x, ck.z)] = true


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
	# Parcours par INDEX SPATIAL : seules les colonnes DE LA CELLULE sont visitées,
	# au lieu de scanner tout le diff du monde à chaque test de craft.
	for cx in range(cx0, cx0 + span):
		for cz in range(cz0, cz0 + span):
			var near: Variant = _edit_cols.get(Vector2i(cx, cz))
			if near == null:
				continue
			for key: Vector3i in (near as Dictionary):
				var chunk_edits: Variant = _edits.get(key)
				if chunk_edits == null:
					continue
				for idx: int in (chunk_edits as Dictionary):
					if int((chunk_edits as Dictionary)[idx]) == material_id:
						return true
	return false


## Ce bloc appartient-il à une STRUCTURE SCELLÉE, inviolable quel que soit
## l'outil ? (2026-08-02) Aujourd'hui : la tour de donjon (GDD 3.5, « structure
## d'entrée scellée »).
##
## POURQUOI UN TEST DE LIEU ET NON UN TAG DE MATÉRIAU. La tour est bâtie en
## pierre taillée depuis le 2026-08-02, et la pierre taillée est un matériau de
## CONSTRUCTION que le joueur fabrique au tailleur de pierre et pose où il veut.
## Marquer le matériau « incassable » aurait rendu indestructible tout ce que le
## joueur bâtit avec — y compris sa propre maison. Ce qui doit être scellé, c'est
## l'endroit.
##
## Le test est bon marché et court-circuité dans l'ordre le moins cher : hors
## overworld, pas de générateur, puis emprise horizontale (une soustraction et
## deux multiplications), et seulement ensuite le cache de cellule qui sait s'il
## y a réellement un donjon là.
func is_sealed_structure(pos: Vector3i) -> bool:
	if active_dimension != &"overworld" or generator == null:
		return false
	var cell := ClaimManager.cell_of_block(pos.x, pos.z)
	if not DungeonTower.contains(cell, pos.x, pos.z):
		return false
	return DungeonManager.is_dungeon_cell(cell)


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
	# 1. Colonnes urgentes d'abord (mutations → remesh réactif). Instantané des
	# clés : on efface pendant l'itération. Une colonne déjà en vol reste dans le
	# dictionnaire et sera retentée au prochain passage.
	if not _urgent_cols.is_empty():
		for col: Vector2i in _urgent_cols.keys():
			if _in_flight.size() >= _max_columns_in_flight:
				break
			if _in_flight.has(col):
				continue
			_urgent_cols.erase(col)
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
	# Parcours par INDEX SPATIAL (2026-07-27) : un scan complet de _edits ici
	# rendait le coût du dispatch proportionnel à la taille du monde construit.
	# Sélection strictement identique à l'ancienne (|dx| <= 1 et |dz| <= 1), seul
	# le chemin d'accès change.
	var edits_snapshot := {}
	var sub_edits_snapshot := {}
	for dx in [-1, 0, 1]:
		for dz in [-1, 0, 1]:
			var near: Variant = _edit_cols.get(col + Vector2i(dx, dz))
			if near == null:
				continue
			for key: Vector3i in (near as Dictionary):
				var chunk_edits: Variant = _edits.get(key)
				if chunk_edits != null:
					edits_snapshot[key] = (chunk_edits as Dictionary).duplicate()
				var chunk_subs: Variant = _sub_edits.get(key)
				if chunk_subs == null or (chunk_subs as Dictionary).is_empty():
					continue
				var grids := {}
				for index: int in (chunk_subs as Dictionary):
					grids[index] = ((chunk_subs as Dictionary)[index] as PackedInt32Array).duplicate()
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
	# Drain à CURSEUR (2026-07-27) : pop_front() est O(n) sur un Array GDScript,
	# et il était appelé EN SECTION CRITIQUE — à gros rayon, avec des centaines de
	# résultats en attente, le drain devenait quadratique tout en bloquant les
	# workers qui veulent déposer les leurs. On avance un curseur, puis on ne
	# recopie qu'une fois la queue restante.
	var cursor := 0
	var count := _results.size()
	while cursor < count:
		var front: Dictionary = _results[cursor]
		if not front.has("done") and not (front["arrays"] as Array).is_empty():
			if budget == 0:
				break
			budget -= 1
		batch.append(front)
		cursor += 1
	if cursor > 0:
		_results = _results.slice(cursor)
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
					_urgent_cols[col] = true
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


## Attend la fin de toutes les tâches de meshing en vol. À appeler avant TOUTE
## mutation des données que ces tâches lisent (GameData) : elles y accèdent
## sans verrou, ce qui n'est sûr que parce que GameData est en lecture seule
## une fois chargé. Le hot-reload F5 rompait cette garantie — il réécrivait
## `materials` / `material_by_runtime` pendant que des threads les parcouraient.
func wait_for_in_flight() -> void:
	for col in _in_flight:
		WorkerThreadPool.wait_for_task_completion(_in_flight[col])
	_in_flight.clear()


func _exit_tree() -> void:
	wait_for_in_flight()
