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
## - Aucun marquage visuel de la cellule dans l'overworld (2026-07-28, demande
##   explicite) : les boîtes translucides de « brouillard » qui la couvraient
##   ont été supprimées. Le donjon est déjà matérialisé par sa termitière, qui
##   se voit de loin — la nappe grise n'ajoutait rien et masquait le décor.
##
## GÉNÉRATION : l'étage est un LABYRINTHE de 64×64 blocs (un quart de l'aire
## d'une cellule — DungeonGenerator, réécrit le 2026-08-02), construit en blocs
## dans les chunks de la dimension au moment de l'entrée, sous l'écran de
## chargement, puis meshé d'un coup (ChunkMesher avec générateur NULL = monde
## vide, la coquille vient des chunks voisins). Le volume est écrit ENTIER,
## murs compris : tout ce qui n'est pas écrit reste de l'air, et un labyrinthe
## aux murs vides se survolerait.
## Il est bâti dans la MÊME pierre taillée que la tour de la cellule
## (2026-08-02) : granit, ardoise, marbre… selon le tirage de la cellule.
##
## ÉTAGES (E.29, 2026-07-28) : un donjon compte 2, 4 ou 6 étages selon le danger
## de sa cellule. Chaque étage a son propre plan (graine = cellule + profondeur)
## et son propre diff de blocs. On change d'étage par des ESCALIERS-
## TÉLÉPORTEURS (« l'escalier tp », 2026-08-02) : trois marches aux rampes
## LUMINEUSES, dont le sommet déclenche le changement d'étage.
##   - remontée (marches d'os pâle) : à l'arrivée ; ramène à l'étage du dessus,
##     ou dehors depuis le premier ;
##   - descente (marches de scorie ardente) : dans la case la plus éloignée AU
##     SENS DU LABYRINTHE, ce que le joueur doit CHERCHER ; absente au dernier
##     étage.
## À chaque arrivée, le joueur est déposé à CÔTÉ de l'escalier de remontée et
## dos à lui — posé dessus, il repartirait aussitôt d'où il vient.
## Le boss n'existe QU'AU DERNIER ÉTAGE et lui seul déclenche le nettoyage. Le
## COFFRE (F.6) est POSÉ dans sa salle à la construction de l'étage : un vrai
## coffre, identique à celui que le joueur fabrique.
##
## FORME (2026-08-02) : couloirs de 3 blocs de large tressés en labyrinthe, et
## salles rectangulaires obtenues en abattant les murs intérieurs d'un bloc de
## cases. Les cavités organiques au bruit (`DungeonCavern`) ont été retirées
## avec la matière démoniaque : une architecture de pierre taillée est taillée,
## pas creusée.
##
## BUTIN (2026-08-02) : des caches au sol dans les salles, plus le coffre du
## boss. Déterministe par (cellule, profondeur, graine) et posé UNE SEULE FOIS
## par étage (`_looted_floors`, persisté) — un étage est reconstruit à chaque
## visite, un tirage par visite l'aurait rendu farmable à l'infini.
##
## PERSISTANCE (E.10/3.5 « les changements suivent la sauvegarde
## différentielle standard ») : les blocs minés/posés DANS un donjon sont un
## diff par ÉTAGE (`_dungeon_edits`, clé cellule+profondeur), sauvegardé en ids TEXTE dans
## state.json (immune au glissement des ids runtime) et réappliqué à chaque
## reconstruction. SIMPLIFICATION ASSUMÉE : le boss renaît à chaque entrée
## tant que le donjon n'est pas nettoyé ; pas de subdivision fine en donjon.
##
## NETTOYAGE (3.5) : à la mort du boss, délai de 1,5 jour in-game puis la
## cellule redevient normale/claimable.

const PERIMETER_WIDTH := 8.0
## Compte à rebours d'entrée à pied (demande explicite : 3 s + infos).
const ENTRY_COUNTDOWN := 3.0
## Cooldown après une téléportation (entrée ou sortie) avant de retester une
## entrée/sortie — évite toute oscillation frame à frame à la limite.
const RETRIGGER_COOLDOWN := 1.5
## 1,5 jour in-game (3.5/E.29) — délai avant qu'un donjon nettoyé (boss
## vaincu) redevienne une cellule normale/claimable.
const CLEANUP_DELAY_TICKS := int(1.5 * 24000)

## --- Étages (E.29, 2026-07-28) ---
## Nombre d'étages par niveau de danger de la cellule (danger_level : 0/1/2).
## Le dernier étage n'a PAS d'orifice de descente : c'est le fond, et le seul à
## porter le boss.
const FLOORS_BY_DANGER: Array[int] = [2, 4, 6]
## Rayon de déclenchement d'un orifice. Nettement inférieur à la distance entre
## le point d'arrivée et l'orifice de remontée (4,2 blocs) : sinon le joueur
## repartirait aussitôt d'où il vient, en boucle.
const ORIFICE_RADIUS := 1.6
## ESCALIERS-TÉLÉPORTEURS (2026-08-02, « l'escalier tp »).
##
## Ils remplacent d'abord les « orifices » — deux disques plats posés dans le
## sol, franchis par simple proximité — puis les volées de six marches creusées
## dans la masse, que le labyrinthe n'a pas la place d'accueillir (couloirs de
## trois blocs, étage à un seul niveau). Ce qui reste, et qui était le vrai
## besoin : que la GÉOMÉTRIE annonce l'escalier. Trois marches y suffisent, et
## le franchissement est une téléportation depuis le sommet.
## Matière des marches. Elle DISTINGUE les deux volées d'un coup d'œil : on
## doit savoir si l'on monte vers la sortie ou si l'on s'enfonce, sans avoir à
## s'engager dedans.
const STAIR_TREAD_UP := "os_calcine"     # os pâle : on remonte vers la sortie.
const STAIR_TREAD_DOWN := "chair_noire"  # chair sombre : on descend vers le cœur.

## Matière des RAMPES, et seule source de lumière de l'escalier. La scorie
## ardente porte `luminosite` 40 (soit 6/15 une fois convertie par
## `GameData.emission_by_runtime`), propagée par le champ de lumière (G.3).
##
## POURQUOI LA RAMPE ET PAS LA MARCHE. Les marches ont d'abord été faites en
## scorie et en os calciné — mais `os_calcine` a une luminosité de ZÉRO :
## l'escalier de remontée ne s'allumait pas du tout. Le réflexe aurait été de
## prendre un matériau lumineux pâle à la place, sauf que les seuls disponibles
## sont des GEMMES (opale, quartz, diamant), et les blocs d'un donjon se minent
## — la volée serait devenue une mine à cristaux gratuite. Séparer la marche
## (thématique, inerte) de la rampe (lumineuse) résout les deux : les deux
## escaliers brillent, aucun ne se farme, et ils restent distincts.
## Trouvé par --probe-interieur, qui exigeait une émission non nulle.
const STAIR_GLOW := "scorie_ardente"
var _player: Node
var _in_dungeon := false
var _current_dungeon_cell := Vector2i.ZERO
var _return_position := Vector3.ZERO
var _cooldown := 0.0
var _cached_cell := Vector2i(1 << 30, 0)
var _cached_donjon_neighbors: Array[Vector2i] = []
## Étage COURANT dans le donjon actif (0 = premier, le plus proche de la sortie).
var _current_depth := 0
var _floors := {}              # Vector3i (cellule.x, cellule.y, profondeur) -> Dictionary (DungeonGenerator.generate_floor).
var _cleaned_cells := {}       # Vector2i cellule -> true (boss vaincu + délai écoulé).
var _cleanup_pending := {}     # Vector2i cellule -> tick cible.

## --- Dimension donjon (chunks/meshes du donjon ACTIF uniquement) ---
var _dungeon_chunks := {}      # Vector3i -> ChunkData
var _dungeon_meshes := {}      # Vector3i -> MeshInstance3D
## Diff persistant par ÉTAGE : Vector3i (cellule.x, cellule.y, profondeur) -> { Vector3i chunk -> { indice -> id runtime } }.
var _dungeon_edits := {}
var _dungeon_root: Node3D

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
	TickManager.tick_world.connect(_on_tick)
	# LE DONJON N'EST PLUS UN CAS DU MOTEUR, c'est un backend de dimension. Il
	# garde sa construction — étages, escaliers, boss — mais WorldManager ne le
	# connaît plus : il passe par DimensionManager, qui aiguille ici.
	DimensionManager.register_backend(&"donjon", self)
	_dungeon_root = Node3D.new()
	add_child(_dungeon_root)
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
		_check_transitions(pos)
	else:
		_update_cell_cache(pos)
		_update_entry(pos, delta)


# --- Entrée à pied : périmètre → compte à rebours → chargement ---

## Recalcule les cellules donjon voisines seulement quand la CELLULE du joueur
## change (`biome_at`/`pois_at_cell` jamais par frame).
func _update_cell_cache(pos: Vector3) -> void:
	var cell := ClaimManager.cell_of_block(int(pos.x), int(pos.z))
	if cell == _cached_cell:
		return
	_cached_cell = cell
	_cached_donjon_neighbors = _donjon_cells_near(cell)


func _update_entry(pos: Vector3, delta: float) -> void:
	var target := Vector2i.ZERO
	var found := false
	# Entrée par la TERMITIÈRE (2026-07-27) : le donjon est matérialisé par
	# une masse organique occupant toute sa cellule. On y entre en s'enfonçant
	# dans une de ses CAVITÉS, plus en traversant un périmètre invisible —
	# rien n'indiquait jusqu'ici où commençait la zone de déclenchement.
	for dc in _cached_donjon_neighbors:
		var ground := 0
		if WorldManager.generator != null:
			var centre := POIGenerator.cell_center_world(dc)
			ground = int(floor(WorldManager.generator.height_at(centre.x, centre.y)))
		if DungeonTower.inside_interior(dc, floori(pos.x), floori(pos.y), floori(pos.z),
				ground, WorldManager.world_seed):
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
	_ensure_floor_data(cell, 0)
	var center := POIGenerator.cell_center_world(cell)
	var danger := WorldManager.generator.danger_level(center.x, center.y)
	# Salles du PREMIER étage : c'est ce que le joueur s'apprête à découvrir. La
	# profondeur totale n'est volontairement pas annoncée — la trouver fait
	# partie de l'exploration.
	var rooms: int = (_floors.get(_floor_key(cell, 0), {}) as Dictionary).get("rooms", []).size()
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
	_ensure_floor_data(cell, 0)
	if (_floors.get(_floor_key(cell, 0), {}) as Dictionary).is_empty():
		push_warning("DungeonManager : étage vide pour la cellule %s — entrée annulée." % cell)
		return
	_return_position = return_pos
	_current_dungeon_cell = cell
	_current_depth = 0
	# Bascule AVANT la construction : le boss spawné pendant le build
	# appartient ainsi à la dimension donjon (CreatureManager.spawn).
	WorldManager.set_active_dimension(&"donjon")
	_install_floor(cell, 0)


## Construit un étage et y dépose le joueur. Partagé par l'entrée, la descente
## et la remontée — un seul endroit décide de la position et de l'orientation
## d'arrivée, sinon les trois divergeraient.
func _install_floor(cell: Vector2i, depth: int) -> void:
	_ensure_floor_data(cell, depth)
	_build_dimension(cell, depth)
	_current_depth = depth
	_in_dungeon = true
	_cooldown = RETRIGGER_COOLDOWN
	_set_dungeon_ambience(true)
	var center := _entrance_center()
	var orifice := _ascent_orifice_position()
	# Pieds sur le sommet du sol de la salle, + hauteur des yeux (convention
	# fly_camera.gd : feet_y = sommet du bloc). Le joueur arrive DOS à l'orifice
	# de remontée : il doit chercher la descente (demande explicite).
	# Résolution PARESSEUSE du joueur, comme dans `_process` et `enter_from_map`.
	# Ce point d'entrée-ci s'en passait et supposait que `_process` avait déjà
	# tourné : appelé avant (sonde, entrée scriptée), il plantait sur un `_player`
	# nul — « Nonexistent function 'teleport_to' in base 'Nil' ».
	if _player == null:
		_player = get_node_or_null("/root/Main/Player")
	if _player != null:
		_player.teleport_to(Vector3(center.x, center.y + 2.9, center.z),
			_arrival_yaw(orifice, center))
	print("[DONJON] cellule %s — étage %d/%d%s." % [
		cell, depth + 1, _floor_count(cell),
		" (fond : boss présent)" if depth == _floor_count(cell) - 1 else ""])


# --- Franchissement des orifices (descente / remontée / sortie) ---

## Le joueur est-il sur un orifice ? Distance HORIZONTALE seulement (pos.y est la
## caméra à hauteur des yeux, ~2,9 blocs au-dessus du sol où repose l'orifice —
## une distance 3D aurait donc toujours dépassé le seuil, peu importe la position
## X/Z : bug réel trouvé en testant ce mécanisme, corrigé).
func _on_orifice(pos: Vector3, orifice: Vector3) -> bool:
	var dx := pos.x - orifice.x
	var dz := pos.z - orifice.z
	return sqrt(dx * dx + dz * dz) <= ORIFICE_RADIUS


func _check_transitions(pos: Vector3) -> void:
	if _on_orifice(pos, _ascent_orifice_position()):
		_ascend()
		return
	var key := _floor_key(_current_dungeon_cell, _current_depth)
	if _current_depth < _floor_count(_current_dungeon_cell) - 1:
		if _on_orifice(pos, _descent_orifice_position(key)):
			_descend()


## Descend d'un étage. Les créatures de l'étage quitté sont retirées : chaque
## étage a sa propre population, et un monstre laissé derrière continuerait de
## vivre dans une dimension que plus personne n'occupe.
## Enveloppes PUBLIQUES de la navigation d'étage (2026-08-03). Descendre,
## monter et sortir n'existaient qu'en privé, appelés par les escaliers et le
## compte à rebours d'entrée ; le menu de triche, qui doit pouvoir atteindre
## n'importe quel étage, n'avait aucun moyen légitime de les déclencher.
func descend() -> void:
	_descend()


func ascend() -> void:
	_ascend()


func leave() -> void:
	_exit_dungeon()


func _descend() -> void:
	CreatureManager.despawn_dimension(&"donjon")
	_install_floor(_current_dungeon_cell, _current_depth + 1)


## Remonte d'un étage — ou sort du donjon depuis le premier.
func _ascend() -> void:
	if _current_depth <= 0:
		_exit_dungeon()
		return
	CreatureManager.despawn_dimension(&"donjon")
	_install_floor(_current_dungeon_cell, _current_depth - 1)


func _exit_dungeon() -> void:
	_in_dungeon = false
	_current_depth = 0  # La prochaine entrée repart du premier étage.
	_cooldown = RETRIGGER_COOLDOWN
	_must_leave = true  # Ne pas relancer un compte à rebours tant qu'on n'a pas quitté le périmètre.
	CreatureManager.despawn_dimension(&"donjon")
	_free_dimension()
	WorldManager.set_active_dimension(&"overworld")
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
	# Diff persistant (E.10/3.5) — réappliqué à chaque reconstruction. Indexé par
	# ÉTAGE et non par cellule (2026-07-28) : sans la profondeur dans la clé, un
	# bloc miné au 3e étage réapparaîtrait au 1er, aux mêmes coordonnées locales.
	var floor_edits: Dictionary = _dungeon_edits.get_or_add(
		_floor_key(_current_dungeon_cell, _current_depth), {})
	(floor_edits.get_or_add(ck, {}) as Dictionary)[index] = material_id
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


## Clé d'un étage : la cellule + sa profondeur. Tout ce qui est propre à UN
## étage (géométrie, diff des blocs modifiés) est indexé par cette clé et non
## plus par la seule cellule (2026-07-28, multi-étage).
static func _floor_key(cell: Vector2i, depth: int) -> Vector3i:
	return Vector3i(cell.x, cell.y, depth)


## Nombre d'étages du donjon de `cell`, d'après le danger de la cellule (E.29).
func _floor_count(cell: Vector2i) -> int:
	if WorldManager.generator == null:
		return FLOORS_BY_DANGER[0]
	var centre := POIGenerator.cell_center_world(cell)
	var danger := WorldManager.generator.danger_level(centre.x, centre.y)
	return FLOORS_BY_DANGER[clampi(danger, 0, FLOORS_BY_DANGER.size() - 1)]


func _ensure_floor_data(cell: Vector2i, depth: int = 0) -> void:
	var key := _floor_key(cell, depth)
	if _floors.has(key):
		return
	# Graine déterministe par cellule ET par profondeur (même monde → même
	# donjon, G.1) : deux étages d'un même donjon ont des plans DIFFÉRENTS, mais
	# chacun reste identique d'une visite à l'autre.
	var seed_value := NoiseGenerator.pcg_hash(cell.x, cell.y, WorldManager.world_seed + 77441 + depth * 1013)
	# Le nombre de salles monte avec la profondeur (2026-08-02) : les premiers
	# étages restent lisibles, le fond du nid devient un labyrinthe.
	# `has_deeper` : il n'y a pas d'escalier de descente au dernier étage, et
	# c'est le GÉNÉRATEUR qui doit le savoir — sinon il place un escalier que
	# le creusement devra ensuite retirer, avec le risque classique que les deux
	# ne soient pas d'accord sur son existence.
	_floors[key] = DungeonGenerator.generate_floor(
			seed_value, depth, depth < _floor_count(cell) - 1)


## Construit chunks + meshes + boss de la dimension pour `cell` (sous l'écran
## de chargement). L'étage vit à l'origine (salle d'entrée en (0,0,0)).
func _build_dimension(cell: Vector2i, depth: int = 0) -> void:
	_free_dimension()
	var key := _floor_key(cell, depth)
	var floor_data: Dictionary = _floors[key]
	# Maçonnerie : la MÊME pierre taillée que la tour de la cellule (2026-08-02).
	# Chaque donjon a sa roche (granit, ardoise, marbre…), tirée de la cellule :
	# les étages doivent être bâtis dans la pierre de la tour qu'on vient de
	# traverser pour entrer, sinon l'intérieur n'a aucun rapport avec l'extérieur.
	var palette := _nest_palette_ids(cell)
	var seed_value := NoiseGenerator.pcg_hash(cell.x, cell.y, WorldManager.world_seed + 77441 + depth * 1013)

	_carve_maze(floor_data, palette, seed_value)

	_floor_seed = seed_value

	# ESCALIERS-TÉLÉPORTEURS. Ce ne sont plus des volées de marches creusées
	# dans la masse : un labyrinthe à un seul niveau n'a pas la place de faire
	# monter six marches, et l'auteur a demandé que « l'escalier tp ». Chacun
	# est une petite estrade de marches au milieu de sa case, franchie en
	# montant dessus. La matière les distingue au premier regard : os pâle pour
	# remonter vers la sortie, scorie ardente pour s'enfoncer.
	_ascent_landing = _carve_stair_pad(
			floor_data["up_stair"], STAIR_TREAD_UP, false, palette, seed_value)
	_descent_landing = Vector3(1 << 24, 0, 0)  # Hors d'atteinte tant qu'il n'existe pas.
	var down: Vector3i = floor_data["down_stair"]
	if down.y >= 0:
		_descent_landing = _carve_stair_pad(down, STAIR_TREAD_DOWN, true, palette, seed_value)

	# Diff persistant du joueur (blocs minés/posés lors de visites passées).
	var cell_edits: Dictionary = _dungeon_edits.get(key, {})
	for ck: Vector3i in cell_edits:
		var data: ChunkData = _dungeon_chunks.get(ck)
		if data == null:
			data = ChunkData.create_uniform(0)
			_dungeon_chunks[ck] = data
		for index: int in cell_edits[ck]:
			data.set_block_by_index(index, cell_edits[ck][index])

	for ck: Vector3i in _dungeon_chunks:
		_remesh_dungeon_chunk(ck)

	# Boss : UNIQUEMENT au dernier étage (choix utilisateur 2026-07-28). Les
	# étages intermédiaires sont une descente sans climax — c'est le fond du nid
	# qui tient le combat, et lui seul libère la cellule à sa mort.
	if depth == _floor_count(cell) - 1:
		var boss_room: Dictionary = floor_data["rooms"][floor_data["boss_room_index"]]
		var boss_center: Vector3i = (boss_room["origin"] as Vector3i) + (boss_room["size"] as Vector3i) / 2
		# « chef_de_bande » et non plus « sanglier » (2026-08-02, faune animale
		# supprimée). Choix heureux : ce chef ne spawne PLUS en pleine nature
		# depuis que bandit est le seul ennemi sauvage, donc le rencontrer est
		# désormais propre aux donjons — un boss qu'on ne croise nulle part
		# ailleurs, ce que le sanglier n'était pas.
		var boss := CreatureManager.spawn("chef_de_bande", Vector3(boss_center.x + 0.5, boss_center.y + 1.0, boss_center.z + 0.5))
		if boss != null:
			boss.set_meta("dungeon_boss_cell", cell)
			boss.set_meta("dungeon_boss_depth", depth)

	_place_boss_chest(cell, depth, floor_data, palette, seed_value)
	_populate_floor(floor_data, depth, seed_value)
	_place_floor_loot(key, depth, floor_data, seed_value)


## COFFRE DU BOSS : un VRAI COFFRE POSÉ (2026-08-03, demande de l'auteur),
## identique à celui que le joueur fabrique. C'était jusqu'ici une « cache au
## sol » de DropManager avec un marqueur plus gros — donc un objet qui n'existait
## qu'en tant que butin, impossible à distinguer d'un tas par terre, et sans
## rapport avec le coffre du catalogue.
##
## Le contenu est posé D'AUTORITÉ (`ContainerManager.fill`) et non par la pose de
## bloc : le bloc est écrit directement dans les chunks de la dimension, sans
## passer par `EventBus.block_placed`.
func _place_boss_chest(cell: Vector2i, depth: int, floor_data: Dictionary,
		palette: PackedInt32Array, seed_value: int) -> void:
	if depth != _floor_count(cell) - 1:
		return   # Le coffre est la récompense du FOND, comme le boss.
	var key := _floor_key(cell, depth)
	if _looted_floors.has(key):
		return   # Étage déjà pillé : pas de coffre qui repousse.
	var rooms: Array = floor_data["rooms"]
	if rooms.is_empty():
		return
	var room: Dictionary = rooms[int(floor_data.get("boss_room_index", 0))]
	var origin: Vector3i = room["origin"]
	var size: Vector3i = room["size"]
	# Adossé à un coin de la salle et non au centre : le centre est occupé par
	# le boss, et un coffre sous ses pieds serait invisible pendant le combat.
	var pos := Vector3i(origin.x + 1, 1, origin.z + 1)
	var chest_id: int = GameData.material_runtime_ids.get("coffre", 0)
	if chest_id == 0:
		return
	_set_dungeon_block(pos, chest_id)
	var content := DungeonLoot.boss_chest(depth, seed_value)
	ContainerManager.fill(pos, "coffre", content.get("objects", []), int(content.get("gold", 0)))


## Tous les types d'ennemis du catalogue, triés. Lu une fois : le tri est
## indispensable au déterminisme (l'ordre d'itération d'un Dictionary Godot suit
## l'insertion, donc l'ordre de lecture des fichiers).
##
## Le critère est le PROFIL D'IA et non un tag : `hostile` attaque à vue,
## `bete_sauvage` riposte une fois blessée (creature.gd). Les deux ont leur
## place dans un donjon — le GDD 3.5 cite explicitement l'ermite, qui est une
## bête sauvage — et prendre le tag aurait laissé passer les civils.
static var _enemy_pool := PackedStringArray()


func _enemy_types() -> PackedStringArray:
	if not _enemy_pool.is_empty():
		return _enemy_pool
	var ids: Array[String] = []
	for id: String in GameData.creatures:
		var profile := String((GameData.creatures[id] as Dictionary).get("ai_profile", ""))
		if profile == "hostile" or profile == "bete_sauvage":
			ids.append(id)
	ids.sort()
	_enemy_pool = PackedStringArray(ids)
	return _enemy_pool


## Peuple l'étage. TOUS LES TYPES sont représentés (demande explicite du
## 2026-08-02) : on distribue d'abord un exemplaire de chaque, puis on complète
## au hasard jusqu'au quota. Sans ce premier passage, un tirage purement
## aléatoire laisse statistiquement les types rares absents de la plupart des
## étages, et « tous les types d'ennemis dans le donjon » n'est pas tenu.
##
## Le quota monte avec la profondeur (E.29 : la difficulté croît en descendant).
##
## SIMPLIFICATION ASSUMÉE, la même que pour le boss : les ennemis renaissent à
## chaque entrée tant que le donjon n'est pas nettoyé. Le GDD 3.5 veut un
## peuplement FIXE qui se vide à mesure ; le tenir demanderait de persister
## chaque mort, ce que la sauvegarde ne fait pas encore pour les créatures.
func _populate_floor(floor_data: Dictionary, depth: int, seed_value: int) -> void:
	var types := _enemy_types()
	if types.is_empty():
		return
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value ^ 0x5EED

	# Emplacements candidats : blocs praticables ATTEINGNABLES depuis l'arrivée,
	# à distance de l'escalier de remontée — un ennemi collé au point
	# d'apparition attaque avant que le joueur ait vu l'étage.
	var reachable := DungeonGenerator.reachable_blocks(floor_data)
	var up: Vector3i = floor_data["up_stair"]
	var spots: Array[Vector2i] = []
	for pos: Vector2i in reachable:
		var dx := pos.x - up.x
		var dz := pos.y - up.z
		if dx * dx + dz * dz >= 100:  # au moins 10 blocs de l'escalier d'arrivée
			spots.append(pos)
	if spots.is_empty():
		return
	spots.sort_custom(func(a: Vector2i, b: Vector2i) -> bool:
		return a.x * 4096 + a.y < b.x * 4096 + b.y)  # Ordre stable avant tirage.

	var quota := mini(types.size() + depth * 3, 24)
	for index in quota:
		# Premier tour : un de chaque type. Ensuite : au hasard.
		var type_id: String = types[index] if index < types.size() else types[rng.randi() % types.size()]
		var spot: Vector2i = spots[rng.randi() % spots.size()]
		CreatureManager.spawn(type_id, Vector3(spot.x + 0.5, 1.0, spot.y + 0.5))


## Étages déjà pillés : Vector3i (cellule.x, cellule.y, profondeur) -> true.
##
## Un étage est RECONSTRUIT à chaque visite (seuls les blocs modifiés sont
## persistés, pas le plan). Sans cette mémoire, le butin au sol réapparaîtrait
## à chaque entrée et le donjon deviendrait une machine à or : sortir, rentrer,
## re-ramasser. Persisté avec le reste de l'état du donjon.
var _looted_floors := {}


## Disperse les caches au sol de l'étage, une seule fois par étage et par
## partie. Les positions et le contenu sont déterministes (DungeonLoot) : un
## joueur qui ressort et rentre retrouve exactement ce qu'il a laissé, tant
## qu'il n'a rien ramassé.
func _place_floor_loot(key: Vector3i, depth: int, floor_data: Dictionary, seed_value: int) -> void:
	if _looted_floors.has(key):
		return
	_looted_floors[key] = true
	for entry: Dictionary in DungeonLoot.floor_caches(floor_data, depth, seed_value):
		# Le sol du labyrinthe est PLAT (y=0 plein, on marche en y=1) : plus de
		# correction de relief à appliquer, contrairement aux anciennes cavités
		# organiques dont le sol ondulait et enterrait les caches.
		var pos: Vector3 = entry["position"]
		DropManager.drop(Vector3(pos.x, 1.0, pos.z), entry["objects"], int(entry["gold"]))


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


## Ids runtime de la pierre taillée de CETTE cellule. Passe par DungeonTower,
## qui porte le cache : la tour de l'overworld et les étages doivent tirer la
## même roche pour la même cellule, et deux caches séparés finiraient par
## diverger au premier changement de règle de tirage.
func _nest_palette_ids(cell: Vector2i) -> PackedInt32Array:
	return DungeonTower.palette_for(cell, WorldManager.world_seed)


## Maçonnerie de l'étage en (wx,wy,wz) : appareillage de la palette, comme la
## tour de l'overworld. `palette` vide (données manquantes) → repli sur la
## pierre, pour ne jamais produire un donjon en air.
func _nest_material(pos: Vector3i, palette: PackedInt32Array, seed_value: int) -> int:
	if palette.is_empty():
		return GameData.material_runtime_ids.get("pierre", 0)
	return DungeonTower.interior_material(pos.x, pos.y, pos.z, seed_value, palette)


## Creuse l'étage ENTIER depuis la grille du labyrinthe (2026-08-02).
##
## Remplace les quatre fonctions précédentes (`_carve_room`, `_carve_corridor`,
## `_carve_door_throat`, `_carve_stairs`), qui sculptaient des cavités
## organiques reliées par des boyaux. Une architecture de pierre taillée n'a
## pas de cavités organiques, et un labyrinthe n'a pas de portes à percer : la
## grille dit pour chaque bloc s'il est praticable, et il n'y a rien à
## réconcilier entre deux représentations.
##
## Le volume est écrit EN ENTIER, pierre comprise. C'est indispensable : tout ce
## qui n'est pas écrit reste de l'air dans la dimension, et un labyrinthe dont
## les murs seraient du vide se survolerait d'un bout à l'autre.
func _carve_maze(floor_data: Dictionary, palette: PackedInt32Array, seed_value: int) -> void:
	var open: PackedByteArray = floor_data["open"]
	var span: int = floor_data["span"]
	var ceiling := DungeonGenerator.CEILING
	for z in span:
		for x in span:
			var walkable := open[z * span + x] == 1
			for y in range(0, ceiling + 1):
				var pos := Vector3i(x, y, z)
				# Praticable : sol en y=0, plafond en y=CEILING, air entre les
				# deux. Sinon : pierre pleine sur toute la hauteur.
				var solid := true
				if walkable and y > 0 and y < ceiling:
					solid = false
				_set_dungeon_block(pos, _nest_material(pos, palette, seed_value) if solid else 0)

	# TORCHES MURALES. Sans elles, l'étage est noir dès qu'on s'éloigne des deux
	# escaliers — seule source de lumière du donjon — et un labyrinthe qu'on ne
	# voit pas ne se parcourt pas, il se subit. Un bloc de scorie ardente
	# (luminosité 40, propagée par le champ de lumière G.3) est SERTI DANS LE MUR
	# à hauteur d'épaule, aux intersections de la grille : c'est régulier sans
	# être aligné sur le monde, et ça donne un repère de progression.
	var glow: int = GameData.material_runtime_ids.get(STAIR_GLOW, 0)
	if glow != 0:
		var pitch := DungeonGenerator.PITCH
		for z in span:
			for x in span:
				if open[z * span + x] == 0:
					continue
				# Une torche par case sur deux, dans les deux axes.
				if (x / pitch) % 2 != 0 or (z / pitch) % 2 != 0:
					continue
				if x % pitch != DungeonGenerator.CORRIDOR / 2 or z % pitch != DungeonGenerator.CORRIDOR / 2:
					continue
				# Sertie dans le premier mur voisin trouvé : une torche flottant
				# au milieu d'un couloir barrerait le passage.
				for step: Vector2i in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
					var wx := x + step.x
					var wz := z + step.y
					if wx < 0 or wx >= span or wz < 0 or wz >= span:
						continue
					if open[wz * span + wx] == 1:
						continue
					_set_dungeon_block(Vector3i(wx, 3, wz), glow)
					break


## Escalier-TÉLÉPORTEUR : une volée de trois marches au milieu d'une case, dont
## le sommet (ou le fond) déclenche le changement d'étage. Renvoie ce point.
##
## POURQUOI SI COURT. La version précédente creusait une volée de six marches
## dans la masse, ce qui supposait de la place autour. Un labyrinthe n'en a
## pas : les couloirs font trois blocs de large et l'étage est un seul niveau.
## Trois marches suffisent à ce que la géométrie ANNONCE l'escalier — c'est tout
## ce qu'on lui demande, puisque le franchissement est une téléportation
## (« l'escalier tp », demande explicite du 2026-08-02).
##
## Les rampes de scorie ardente sont la seule source de lumière de l'étage : la
## marche elle-même ne peut pas l'être (voir STAIR_GLOW — `os_calcine` a une
## luminosité nulle, et les seuls matériaux clairs lumineux sont des gemmes,
## qui feraient de l'escalier une mine à cristaux gratuite).
func _carve_stair_pad(base: Vector3i, tread_material: String, going_down: bool,
		palette: PackedInt32Array, seed_value: int) -> Vector3:
	var tread: int = GameData.material_runtime_ids.get(tread_material, 0)
	var rail: int = GameData.material_runtime_ids.get(STAIR_GLOW, tread)
	var steps := 3
	var step_dy := -1 if going_down else 1
	for i in steps:
		var y := (0 if going_down else 1) + step_dy * i
		for p in range(-1, 2):
			var col := Vector3i(base.x + p, y, base.z + i - 1)
			_set_dungeon_block(col, tread)
			# Dégage la hauteur d'homme au-dessus de chaque marche, sans quoi
			# une volée montante se cognerait au plafond de l'étage.
			for dy in range(1, 4):
				_set_dungeon_block(Vector3i(col.x, y + dy, col.z), 0)
		# Descente : il faut aussi creuser SOUS la volée, sinon les marches
		# s'enfoncent dans la pierre pleine du sol et l'escalier est un relief
		# décoratif dans lequel on ne peut pas entrer.
		if going_down:
			for p in range(-1, 2):
				for dy in range(1, 4):
					_set_dungeon_block(Vector3i(base.x + p, y + dy, base.z + i - 1), 0)
	# Rampes lumineuses de part et d'autre de la volée.
	for i in steps:
		var y := (0 if going_down else 1) + step_dy * i
		for side: int in [-2, 2]:
			_set_dungeon_block(Vector3i(base.x + side, y + 1, base.z + i - 1), rail)
	var top_y := (0 if going_down else 1) + step_dy * (steps - 1)
	return Vector3(base.x + 0.5, float(top_y) + 1.0, base.z + float(steps - 2) + 0.5)


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


## Matériau des meshes de donjon : CELUI du monde, partagé (2026-08-09). Le
## duplicata n'existait que pour poser une texture de teinte d'herbe neutre ;
## la teinte vivant désormais par sommet (COLOR.gba, blanc par défaut quand le
## ctx n'en fournit pas — cas du donjon), il ne servait plus qu'à FIGER le
## daylight du donjon à l'instant de son premier maillage. Partager corrige ça.
func _dimension_material() -> ShaderMaterial:
	return WorldManager.base_material()


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
	if WorldManager.generator == null:
		return false
	# DÉLÈGUE au générateur (2026-08-02) au lieu de refaire le tirage de POI.
	# Cette fonction en portait sa propre copie : biome → `pois_at_cell`. Tant
	# que la règle tenait au seul biome, les deux versions tombaient d'accord.
	# En ajoutant « sol émergé » côté générateur, elles ont divergé — la tour
	# n'était plus bâtie mais la cellule restait annoncée comme donjon, ce qui
	# donnait un donjon invisible et un périmètre d'entrée dans le vide.
	# Une règle, un endroit.
	return WorldManager.generator.has_dungeon(cell)


func _distance_to_cell(pos: Vector3, cell: Vector2i) -> float:
	var cs := ClaimManager.CELL_SIZE
	var min_x := float(cell.x * cs)
	var min_z := float(cell.y * cs)
	var dx := maxf(maxf(min_x - pos.x, pos.x - (min_x + cs)), 0.0)
	var dz := maxf(maxf(min_z - pos.z, pos.z - (min_z + cs)), 0.0)
	return sqrt(dx * dx + dz * dz)


## Centre (dimension) de la salle d'entrée — position d'arrivée du joueur.
## L'entrée est TOUJOURS à l'origine (DungeonGenerator, rooms[0]).
## Point d'arrivée dans la salle d'entrée. Sa hauteur SUIT LE RELIEF du sol
## depuis le 2026-08-02 : les salles ne sont plus à fond plat, et un y figé à 0
## faisait apparaître le joueur enterré jusqu'aux yeux dans les zones hautes.
func _entrance_center() -> Vector3:
	# Le plan porte désormais son propre point d'apparition (2026-08-02) : dans
	# un labyrinthe, il n'y a plus de « salle d'entrée » dont on pourrait
	# déduire le centre depuis un prefab, et la position dépend du tirage.
	var key := _floor_key(_current_dungeon_cell, _current_depth)
	var floor_data: Dictionary = _floors.get(key, {})
	var spawn: Vector3i = floor_data.get("spawn", Vector3i(DungeonGenerator.SPAN / 2, 0, DungeonGenerator.SPAN / 2))
	# On dépose le joueur À CÔTÉ de l'escalier de remontée et non dessus : posé
	# sur le palier, il repartirait à l'étage précédent dans la seconde.
	return Vector3(float(spawn.x) + 2.5, 1.0, float(spawn.z) + 0.5)


# --- Escaliers d'étage (2026-08-02, remplacent les « orifices » plats) ---
#
# Deux volées par étage : une qui MONTE dans la salle d'entrée (retour), une
# qui DESCEND dans la salle la plus éloignée (progression, absente au fond).
# Le changement d'étage se déclenche sur le PALIER, au bout de la volée — pas
# sur une plaque au sol qu'aucune géométrie n'annonçait.
## Paliers des deux escaliers de l'étage COURANT, posés par `_build_dimension`.
## Ils ne sont plus calculables à l'avance : leur position dépend du relief du
## sol et de la longueur de la volée, donc de la construction elle-même.
var _ascent_landing := Vector3.ZERO
var _descent_landing := Vector3.ZERO
## Graine de l'étage courant — nécessaire hors construction pour interroger le
## relief du sol (point d'arrivée du joueur).
var _floor_seed := 0


func _ascent_orifice_position() -> Vector3:
	return _ascent_landing


## Ouverture de DESCENTE : au centre de la salle la plus éloignée de l'entrée
## (`boss_room_index` = résultat du BFS de profondeur). C'est elle que le joueur
## doit trouver pour s'enfoncer.
func _descent_orifice_position(_key: Vector3i) -> Vector3:
	return _descent_landing


## Orientation à l'arrivée sur un étage : le joueur regarde À L'OPPOSÉ de
## l'orifice de remontée (demande explicite — « il est dos à l'escalier de
## sortie »). Un Node3D regarde le long de son -Z, d'où le atan2 sur les
## composantes négatées.
func _arrival_yaw(from_orifice: Vector3, to_player: Vector3) -> float:
	# PROJECTION HORIZONTALE OBLIGATOIRE (corrigé le 2026-08-02). Un lacet est
	# un angle dans le plan ; normaliser le vecteur en 3D laissait la composante
	# verticale absorber une part de sa longueur, et l'orientation obtenue
	# n'était que partiellement « dos à l'escalier ». Invisible tant que le
	# palier et le point d'arrivée étaient à la même altitude — ce qui a cessé
	# d'être vrai avec les escaliers-téléporteurs, dont le palier est surélevé.
	var dir := to_player - from_orifice
	dir.y = 0.0
	if dir.length_squared() < 0.001:
		return 0.0
	dir = dir.normalized()
	return rad_to_deg(atan2(-dir.x, -dir.z))


## Position du « marqueur de sortie ». Conservé comme ALIAS de l'orifice de
## remontée (2026-07-28) : depuis l'étage 0, le franchir fait bien sortir dans
## l'overworld, et les sondes existantes s'y réfèrent encore sous ce nom.
func _exit_marker_position(_cell: Vector2i) -> Vector3:
	return _ascent_orifice_position()


func _on_creature_killed(_killer: Variant, victim: Node) -> void:
	if victim == null or not victim.has_meta("dungeon_boss_cell"):
		return
	var cell: Vector2i = victim.get_meta("dungeon_boss_cell")
	_cleanup_pending[cell] = TickManager.tick_index + CLEANUP_DELAY_TICKS

	# LE COFFRE N'EST PLUS LÂCHÉ ICI (2026-08-03). Il est POSÉ dans la salle du
	# boss à la construction de l'étage (`_place_boss_chest`) : c'est un vrai
	# coffre, identique à celui que le joueur fabrique, et non plus une cache au
	# sol déguisée par un marqueur plus gros. Le garder ici aurait produit DEUX
	# récompenses pour un seul boss.
	#
	# Conséquence voulue : le coffre se voit AVANT le combat, au fond de la
	# salle. C'est une promesse lisible plutôt qu'une surprise — et le joueur
	# peut choisir de le vider en fuyant s'il ne se sent pas de tuer le boss.
	var depth := int(victim.get_meta("dungeon_boss_depth", _current_depth))
	EventBus.ui_notification.emit("ui.toast.coffre_boss")
	print("[DONJON] boss vaincu, cellule %s (étage %d). Nettoyage dans %d ticks." % [
		cell, depth + 1, CLEANUP_DELAY_TICKS])


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
		# La cellule redevient normale : le cache de voisinage est invalidé
		# (recalculé au prochain déplacement du joueur).
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
	# Clé « x,z,profondeur » depuis 2026-07-28 (multi-étage). L'ancien format
	# « x,z » reste relu (voir restore_state) : une sauvegarde antérieure garde
	# donc ses blocs modifiés, rattachés au premier étage.
	for key: Vector3i in _dungeon_edits:
		var chunks_out := {}
		for ck: Vector3i in _dungeon_edits[key]:
			var blocks_out := {}
			for index: int in _dungeon_edits[key][ck]:
				var rid: int = _dungeon_edits[key][ck][index]
				blocks_out[str(index)] = GameData.material_by_runtime[rid] if rid < GameData.material_by_runtime.size() else "air"
			chunks_out["%d,%d,%d" % [ck.x, ck.y, ck.z]] = blocks_out
		edits_out["%d,%d,%d" % [key.x, key.y, key.z]] = chunks_out
	# Étages déjà pillés (2026-08-02) : sans eux, recharger une partie ferait
	# réapparaître tout le butin au sol du donjon.
	var looted := []
	for key: Vector3i in _looted_floors:
		looted.append([key.x, key.y, key.z])
	return {"cleaned": cleaned, "pending": pending, "edits": edits_out, "looted": looted}


func restore_state(data: Dictionary) -> void:
	_cleaned_cells.clear()
	_cleanup_pending.clear()
	_dungeon_edits.clear()
	_looted_floors.clear()
	for entry: Variant in data.get("looted", []):
		if entry is Array and (entry as Array).size() == 3:
			_looted_floors[Vector3i(int(entry[0]), int(entry[1]), int(entry[2]))] = true
	for entry: Variant in data.get("cleaned", []):
		if entry is Array and (entry as Array).size() == 2:
			_cleaned_cells[Vector2i(int(entry[0]), int(entry[1]))] = true
	for entry: Variant in data.get("pending", []):
		if entry is Array and (entry as Array).size() == 3:
			_cleanup_pending[Vector2i(int(entry[0]), int(entry[1]))] = int(entry[2])
	var edits_in: Dictionary = data.get("edits", {})
	for cell_key: String in edits_in:
		var cell_parts := cell_key.split(",")
		# « x,z,profondeur » (format courant) ou « x,z » (sauvegardes d'avant le
		# multi-étage, 2026-07-28) : ces dernières sont rattachées à l'étage 0,
		# le seul qui existait alors. Une sauvegarde ancienne garde ainsi ses
		# blocs modifiés au lieu de les perdre silencieusement.
		var floor_key: Vector3i
		if cell_parts.size() == 3:
			floor_key = Vector3i(int(cell_parts[0]), int(cell_parts[1]), int(cell_parts[2]))
		elif cell_parts.size() == 2:
			floor_key = Vector3i(int(cell_parts[0]), int(cell_parts[1]), 0)
		else:
			continue
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
		_dungeon_edits[floor_key] = cell_edits


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
