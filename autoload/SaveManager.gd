extends Node
## SaveManager — sauvegarde différentielle (E.10/G.7, audit 2026-07-21).
## Format : un dossier par monde (user://saves/monde) :
##   world.json       : version, graine, temps (ticks), TABLE DES MATÉRIAUX
##                      (id runtime → id texte au moment de la sauvegarde —
##                      les ids runtime glissent quand un matériau est
##                      ajouté/retiré, la table rend la sauvegarde immune)
##   chunks/x_y_z.bin : uniquement les chunks MODIFIÉS — liste (indice, id)
##                      + sous-grilles de subdivision (diff E.10, jamais le
##                      monde entier : tout le reste est régénérable par la
##                      graine, G.1)
##   state.json       : claims, exploration (minimap), étals, donjons
##                      nettoyés, état du joueur (position, or, compétences,
##                      inventaire)
## Écriture ATOMIQUE (tmp + remplacement) ; le chargeur retombe sur le .tmp
## si le fichier principal manque (crash entre suppression et renommage —
## fenêtre minuscule, couverte quand même). L'autosave sérialise sur le
## thread principal (instantané en octets, bon marché) et ÉCRIT en thread
## (l'I/O est le poste lent, G.7 : « l'autosave ne bloque jamais le jeu »).
## Les entités (créatures) ne sont PAS sauvegardées à cette étape : le spawn
## naturel régénère la faune, les boss de donjon renaissent tant que le
## donjon n'est pas nettoyé — cohérent avec « fixe jusqu'au nettoyage » (3.5)
## à la salle près, signalé comme simplification.
## Ordre d'autoload : APRÈS GameData/TickManager (table de matériaux, ticks),
## AVANT WorldManager (qui consomme graine + diffs dans son _ready).

## Mondes multiples (2026-07-21, menu de démarrage) : un dossier par monde
## sous SAVES_ROOT, nommé d'après le nom choisi (slug) ; `dernier.json` à la
## racine mémorise le dernier monde joué (« Continuer »). world.json porte
## désormais name/params/last_saved en plus de la graine/ticks/table.
const SAVES_ROOT := "user://saves"
const SAVE_DIR := "user://saves/monde"  # Monde par défaut (modes directs/bench, compat).
## Dossier des sondes de sauvegarde — isolé des vrais mondes du joueur.
const PROBE_SAVE_DIR := "user://saves/_sondes"
const SAVE_VERSION := 1
const AUTOSAVE_INTERVAL := 300.0  # 5 min réelles (E.10).
## Modes de mesure/test : la persistance est coupée (mesures et mondes de
## test jamais pollués par une sauvegarde, ni l'inverse). --join : les
## invités ne possèdent pas la sauvegarde du monde (E.10, host seulement).
const DISABLED_ARGS: Array[String] = [
	"--bench", "--statique", "--bench-mutation", "--bench-creatures",
	"--probe", "--probe-subdiv", "--probe-dungeon", "--probe-params",
	"--probe-city", "--probe-ore", "--probe-faim", "--probe-equipement", "--probe-mort", "--probe-faune", "--probe-butin", "--probe-mesh", "--probe-invui", "--probe-survie", "--probe-saves", "--test-input", "--test-menu", "--test-ore", "--bench-network-client", "--join",
	# 2026-07-28 : oublier une sonde ici n'est PAS bénin. `--probe-heure` appelle
	# prepare_new_world() et, sans cette ligne, la sauvegarde de sortie créait un
	# vrai dossier de monde bidon dans user://saves/ À CHAQUE EXÉCUTION *et*
	# réécrivait `dernier.json` — le « continuer » du joueur pointait alors sur le
	# monde de test au lieu de sa partie. Toute nouvelle sonde qui touche à
	# SaveManager doit être ajoutée ici.
	"--probe-heure", "--probe-tour", "--probe-etages",
]

var enabled := true
## Dossier effectif — surchargeable par `--save-dir <chemin>` (sondes/tests :
## ne jamais lire NI écraser la vraie sauvegarde du joueur).
var save_dir := SAVE_DIR
## true si un world.json valide a été chargé (WorldManager lit la graine).
var world_loaded := false
var loaded_seed := 0
## Profil du monde ACTIF : { "name", "seed", "params" (génération, voir
## NoiseGenerator) } — posé par le menu (nouvelle partie/chargement) ou par
## le monde par défaut des modes directs. WorldManager.initialize_world le lit.
var active_config := {}
## Création de personnage EN ATTENTE (nouvelle partie) : { "race", "class",
## "stats" } posée par l'UI de création, appliquée par main._start_world puis
## vidée. Vide pour un monde chargé (le joueur est restauré depuis la save).
var pending_character := {}
## true dès qu'un monde tourne (WorldManager.initialize_world) — les
## sauvegardes (autosave/F9/sortie) ne s'arment qu'à partir de là (jamais
## d'écriture pendant que le menu est ouvert sans monde).
var world_active := false

var _pending_edits := {}       # Vector3i chunk -> { indice -> id runtime ACTUEL }
var _pending_sub_edits := {}   # Vector3i chunk -> { indice -> PackedInt32Array(512) }
var _pending_state := {}       # state.json brut (appliqué en différé)
var _last_player_state := {}   # Dernier état joueur sérialisé (voir _gather_state)
var _autosave_timer := 0.0
var _save_task_id := -1
## true si le dossier vient de `--save-dir` (sondes) : ne jamais écrire
## dernier.json (le « Continuer » du joueur ne doit pas pointer un test).
var _custom_dir := false


func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	for flag in DISABLED_ARGS:
		if flag in args:
			enabled = false
			return
	# Chemin de test (`--save-dir`) : charge/prépare immédiatement ce dossier
	# — les sondes n'ont pas de menu. En jeu normal, RIEN n'est chargé ici :
	# le menu de démarrage choisit le monde (load_world_at/prepare_new_world).
	var dir_index := args.find("--save-dir")
	if dir_index >= 0 and dir_index + 1 < args.size():
		save_dir = args[dir_index + 1]
		_custom_dir = true  # Dossier de test : jamais mémorisé comme « dernier monde ».
		if not load_world_at(save_dir):
			active_config = {"name": "test", "seed": 1337, "params": {}}
		return
	# Sondes de sauvegarde SANS --save-dir explicite (2026-07-27) : dossier
	# DÉDIÉ, remis à zéro par --probe-save. Elles tombaient sinon sur le monde
	# par défaut (« monde »), qu'elles polluaient d'un run à l'autre : la paire
	# n'était pas idempotente et --probe-save-verify échouait au deuxième
	# passage (rôle de claim cyclé deux fois, minerai cumulé) — un ÉCHEC DE
	# TEST sans aucun bug dans le code testé, le pire des cas.
	if "--probe-save" in args or "--probe-save-verify" in args or "--probe-save-incr" in args:
		save_dir = PROBE_SAVE_DIR
		_custom_dir = true
		if "--probe-save" in args or "--probe-save-incr" in args:
			_wipe_probe_dir()
			# `active_config` DOIT être posé ici : sans lui,
			# prepare_default_if_needed() (mode direct) se croit sur un monde
			# neuf et réécrase save_dir avec SAVE_DIR — la sonde repartait
			# écrire dans le monde par défaut malgré tout.
			active_config = {"name": "sonde", "seed": 1337, "params": {}}
		elif not load_world_at(save_dir):
			active_config = {"name": "sonde", "seed": 1337, "params": {}}


## Vide le dossier des sondes. Ne touche JAMAIS à un autre dossier : les vrais
## mondes du joueur et les dossiers passés en --save-dir sont hors d'atteinte.
func _wipe_probe_dir() -> void:
	var dir := DirAccess.open(PROBE_SAVE_DIR)
	if dir == null:
		return
	for sub in dir.get_directories():
		var nested := DirAccess.open(PROBE_SAVE_DIR + "/" + sub)
		if nested != null:
			for nested_file in nested.get_files():
				nested.remove(nested_file)
		dir.remove(sub)
	for file_name in dir.get_files():
		dir.remove(file_name)


## Monde par défaut des modes DIRECTS (bench/probe/host/join, sans menu) :
## recharge le dossier « monde » s'il existe, sinon profil neuf par défaut.
func prepare_default_if_needed() -> void:
	if not active_config.is_empty() or world_loaded:
		return
	save_dir = SAVE_DIR
	if enabled and FileAccess.file_exists(save_dir + "/world.json"):
		load_world_at(save_dir)
	else:
		active_config = {"name": "monde", "seed": 1337, "params": {}}
		# Monde par défaut NEUF (mode direct : benchs, captures) : même heure de
		# départ que par le menu, sinon les deux chemins de création divergeaient
		# et une capture de bench se prenait en pleine nuit.
		TickManager.tick_index = DayNightManager.start_tick()


## Liste des mondes sauvegardés : [{ "dir", "name", "seed", "ticks",
## "last_saved" }], du plus récent au plus ancien.
func list_worlds() -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	var root := DirAccess.open(SAVES_ROOT)
	if root == null:
		return result
	for dir_name in root.get_directories():
		var bytes := _read_bytes(SAVES_ROOT + "/" + dir_name + "/world.json")
		if bytes.is_empty():
			continue
		var world: Variant = JSON.parse_string(bytes.get_string_from_utf8())
		if not (world is Dictionary):
			continue
		result.append({
			"dir": SAVES_ROOT + "/" + dir_name,
			"name": String((world as Dictionary).get("name", dir_name)),
			"seed": int((world as Dictionary).get("seed", 0)),
			"ticks": int((world as Dictionary).get("ticks", 0)),
			"last_saved": int((world as Dictionary).get("last_saved", 0)),
		})
	result.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return int(a["last_saved"]) > int(b["last_saved"]))
	return result


## Supprime DÉFINITIVEMENT le monde stocké dans `dir`.
##
## Garde-fou : refuse tout chemin hors de SAVES_ROOT, et refuse de supprimer
## le monde ACTUELLEMENT CHARGÉ (on effacerait le sol sous les pieds du
## joueur, et l'autosave suivante le recréerait à moitié). Retourne false et
## n'écrit rien si l'une des deux conditions n'est pas remplie.
func delete_world(dir_path: String) -> bool:
	if not dir_path.begins_with(SAVES_ROOT + "/"):
		push_error("SaveManager : suppression refusée hors de %s (« %s »)." % [SAVES_ROOT, dir_path])
		return false
	if world_active and dir_path == save_dir:
		push_warning("SaveManager : refus de supprimer le monde en cours de jeu.")
		return false
	var dir := DirAccess.open(dir_path)
	if dir == null:
		return false
	# Les chunks vivent dans un sous-dossier : vider avant de retirer.
	for sub_name in dir.get_directories():
		var nested := DirAccess.open(dir_path + "/" + sub_name)
		if nested != null:
			for nested_file in nested.get_files():
				nested.remove(nested_file)
		dir.remove(sub_name)
	for file_name in dir.get_files():
		dir.remove(file_name)
	DirAccess.remove_absolute(ProjectSettings.globalize_path(dir_path))

	# « Continuer » ne doit plus pointer un monde disparu — sinon le bouton
	# du menu échouerait silencieusement.
	var bytes := _read_bytes(SAVES_ROOT + "/dernier.json")
	if not bytes.is_empty():
		var data: Variant = JSON.parse_string(bytes.get_string_from_utf8())
		if data is Dictionary and String((data as Dictionary).get("dir", "")) == dir_path:
			DirAccess.remove_absolute(ProjectSettings.globalize_path(SAVES_ROOT + "/dernier.json"))
	return true


## « Continuer » : recharge le dernier monde joué (dernier.json). false si aucun.
func continue_last() -> bool:
	var bytes := _read_bytes(SAVES_ROOT + "/dernier.json")
	if bytes.is_empty():
		return false
	var data: Variant = JSON.parse_string(bytes.get_string_from_utf8())
	if not (data is Dictionary):
		return false
	return load_world_at(String((data as Dictionary).get("dir", "")))


## Prépare un monde NEUF (menu « nouvelle partie ») : dossier slug unique,
## profil de génération fourni par le menu, aucun état pendant.
func prepare_new_world(world_name: String, seed_value: int, params: Dictionary) -> void:
	var slug := ""
	for c in world_name.to_lower():
		if (c >= "a" and c <= "z") or (c >= "0" and c <= "9"):
			slug += c
		elif c == " " or c == "-" or c == "_":
			slug += "_"
	if slug == "":
		slug = "monde"
	var dir := SAVES_ROOT + "/" + slug
	var suffix := 2
	while FileAccess.file_exists(dir + "/world.json"):
		dir = SAVES_ROOT + "/" + slug + "_%d" % suffix
		suffix += 1
	save_dir = dir
	# Dossier NEUF : rien sur disque, donc tout est à écrire (l'écriture
	# incrémentale ne peut se fier au disque que si on y a déjà écrit).
	if WorldManager != null:
		WorldManager.mark_all_chunks_dirty()
	active_config = {"name": world_name, "seed": seed_value, "params": params}
	world_loaded = false
	pending_character = {}  # Rempli ensuite par l'UI de création de personnage.
	_pending_edits = {}
	_pending_sub_edits = {}
	_pending_state = {}
	_last_player_state = {}
	# Partie neuve : l'horloge démarre à 8 h du matin, pas à 0 h (voir
	# DayNightManager.START_HOUR). Un monde chargé écrase cette valeur avec le
	# `ticks` de sa sauvegarde — seul le monde NEUF est concerné.
	TickManager.tick_index = DayNightManager.start_tick()


func _process(delta: float) -> void:
	# Autosave sur horloge RÉELLE (E.10 : « 5 min réelles ») — usage légitime
	# de _process : ce n'est pas du temps de jeu (E.1). Un monde neuf
	# s'autosave aussi (pas seulement un monde déjà chargé). `world_active` :
	# jamais d'écriture tant que le menu est ouvert sans monde.
	if not enabled or not world_active:
		return
	_autosave_timer += delta
	if _autosave_timer >= AUTOSAVE_INTERVAL:
		_autosave_timer = 0.0
		save_now()


func _unhandled_key_input(event: InputEvent) -> void:
	# F9 : sauvegarde manuelle (parallèle du F5 de rechargement des données).
	if not enabled or not world_active:
		return
	var key := event as InputEventKey
	if key != null and key.pressed and not key.echo and key.physical_keycode == KEY_F9:
		save_now()
		EventBus.ui_notification.emit("ui.toast.partie_sauvegardee")


func _exit_tree() -> void:
	# Sauvegarde de sortie SYNCHRONE (fermeture de fenêtre ou quit()) — l'ordre
	# d'autoload garantit que WorldManager (readied après nous) sort AVANT nous
	# mais reste alloué : ses données sont encore lisibles ici.
	if not enabled or not world_active:
		return
	_wait_pending_write()
	save_now(true)
	_wait_pending_write()


## Consommé par WorldManager._ready : diffs du monde chargés (une seule fois).
func take_world_edits() -> Dictionary:
	if _pending_edits.is_empty() and _pending_sub_edits.is_empty():
		return {}
	var result := {"edits": _pending_edits, "sub_edits": _pending_sub_edits}
	_pending_edits = {}
	_pending_sub_edits = {}
	return result


# --- Écriture ---

## Sauvegarde complète. `sync` = écrire sur place (sortie de jeu) ; sinon
## l'instantané est construit ici (thread principal, aucun état partagé)
## et l'I/O part en tâche WorkerThreadPool.
func save_now(sync: bool = false) -> void:
	if not enabled:
		return
	_wait_pending_write()

	# 1. Instantané en octets/texte — plus AUCUNE référence aux structures
	# vivantes une fois construit (le thread d'écriture ne partage rien).
	var files := {}  # chemin relatif -> PackedByteArray
	files["world.json"] = JSON.stringify({
		"version": SAVE_VERSION,
		"name": String(active_config.get("name", "monde")),
		"seed": WorldManager.world_seed,
		"params": active_config.get("params", {}),
		"ticks": TickManager.tick_index,
		"last_saved": int(Time.get_unix_time_from_system()),
		"material_table": GameData.material_by_runtime,
	}, "\t").to_utf8_buffer()

	# Chunks : uniquement ceux RETOUCHÉS depuis la dernière écriture. Les
	# autres sont déjà sur disque et n'ont pas changé (2026-07-27) — sans ça
	# le coût d'un autosave croissait avec tout ce que le joueur avait bâti.
	var edits: Dictionary = WorldManager.edits_for_save()
	var sub_edits: Dictionary = WorldManager.sub_edits_for_save()
	for ck: Vector3i in WorldManager.take_dirty_save_chunks():
		files["chunks/%d_%d_%d.bin" % [ck.x, ck.y, ck.z]] = _encode_chunk(
			edits.get(ck, {}), sub_edits.get(ck, {}))

	files["state.json"] = JSON.stringify(_gather_state(), "\t").to_utf8_buffer()

	# Mémorise le dernier monde joué (« Continuer » au menu) — fichier hors
	# du dossier du monde, même mécanisme atomique. Jamais pour un dossier
	# de test (--save-dir).
	var last := {}
	if not _custom_dir:
		last = {"path": SAVES_ROOT + "/dernier.json",
			"bytes": JSON.stringify({"dir": save_dir}).to_utf8_buffer()}

	# 2. Écriture (atomique fichier par fichier).
	if sync:
		_write_files(files)
		if not last.is_empty():
			_write_atomic(last["path"], last["bytes"])
	else:
		_save_task_id = WorkerThreadPool.add_task(
			func() -> void:
				_write_files(files)
				if not last.is_empty():
					_write_atomic(last["path"], last["bytes"]),
			false, "Voxen save")


## Chunk modifié → binaire : version, liste (indice, id), sous-grilles.
func _encode_chunk(chunk_edits: Dictionary, chunk_subs: Dictionary) -> PackedByteArray:
	var buf := StreamPeerBuffer.new()
	buf.put_u16(SAVE_VERSION)
	buf.put_u32(chunk_edits.size())
	for index: int in chunk_edits:
		buf.put_u16(index)
		buf.put_u16(chunk_edits[index])
	buf.put_u32(chunk_subs.size())
	for index: int in chunk_subs:
		buf.put_u16(index)
		var grid: PackedInt32Array = chunk_subs[index]
		for c in SubdivGrid.CELLS:
			buf.put_u16(grid[c])
	return buf.data_array


func _gather_state() -> Dictionary:
	var state := {
		"claims": ClaimManager.save_state(),
		"villages": VillageManager.save_state(),
		"exploration": ExplorationManager.save_state(),
		"shops": ShopManager.save_state(),
		"dungeons": DungeonManager.save_state(),
		"drops": DropManager.save_state(),
	}
	# Filet : si le joueur n'est plus joignable (sauvegarde de sortie après
	# libération de la scène), on réécrit son DERNIER état connu plutôt que
	# de perdre inventaire/position dans ce state.json.
	var player := get_node_or_null("/root/Main/Player")
	if player != null:
		_last_player_state = player.save_state()
	if not _last_player_state.is_empty():
		state["player"] = _last_player_state
	return state


## Corps de tâche (thread d'écriture) — ne touche que `files`, jamais l'état vivant.
func _write_files(files: Dictionary) -> void:
	DirAccess.make_dir_recursive_absolute(save_dir + "/chunks")
	for rel: String in files:
		_write_atomic(save_dir + "/" + rel, files[rel])


## tmp + remplacement : le fichier cible n'est jamais laissé à moitié écrit ;
## si un crash frappe entre suppression et renommage, le chargeur récupère
## le .tmp (fenêtre minuscule mais couverte — voir _read_bytes).
func _write_atomic(path: String, bytes: PackedByteArray) -> void:
	var tmp := path + ".tmp"
	var f := FileAccess.open(tmp, FileAccess.WRITE)
	if f == null:
		push_error("SaveManager : impossible d'écrire %s (%s)." % [tmp, error_string(FileAccess.get_open_error())])
		return
	f.store_buffer(bytes)
	f.flush()
	f.close()
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(path)
	var err := DirAccess.rename_absolute(tmp, path)
	if err != OK:
		push_error("SaveManager : renommage %s → %s refusé (%s)." % [tmp, path, error_string(err)])


func _wait_pending_write() -> void:
	if _save_task_id != -1:
		WorkerThreadPool.wait_for_task_completion(_save_task_id)
		_save_task_id = -1


# --- Lecture ---

## Charge le monde du dossier `dir` (world.json + chunks + state) dans les
## structures « pendantes » — consommées par WorldManager.initialize_world et
## apply_pending_state. Retourne false si le dossier n'a pas de monde valide.
func load_world_at(dir: String) -> bool:
	if dir == "":
		return false
	save_dir = dir
	var world_bytes := _read_bytes(save_dir + "/world.json")
	if world_bytes.is_empty():
		return false  # Aucun monde sauvegardé ici.
	var world: Variant = JSON.parse_string(world_bytes.get_string_from_utf8())
	if not (world is Dictionary) or int(world.get("version", -1)) != SAVE_VERSION:
		push_warning("SaveManager : world.json illisible ou version inconnue — monde neuf.")
		return false
	loaded_seed = int(world["seed"])
	world_loaded = true
	active_config = {
		"name": String(world.get("name", "monde")),
		"seed": loaded_seed,
		"params": world.get("params", {}),
	}
	TickManager.tick_index = int(world.get("ticks", 0))

	# Remap id runtime SAUVEGARDÉ → id runtime ACTUEL via les ids texte
	# (table figée à la sauvegarde) — un matériau disparu devient de l'air.
	var table: Array = world.get("material_table", [])
	var remap := PackedInt32Array()
	remap.resize(table.size())
	for old_id in table.size():
		var new_id: int = GameData.material_runtime_ids.get(String(table[old_id]), 0)
		if new_id == 0 and old_id != 0:
			push_warning("SaveManager : matériau sauvegardé « %s » absent des données — remplacé par de l'air." % table[old_id])
		remap[old_id] = new_id

	var chunk_dir := DirAccess.open(save_dir + "/chunks")
	if chunk_dir != null:
		for file_name in chunk_dir.get_files():
			if file_name.ends_with(".bin"):
				_load_chunk_file(file_name, remap)

	var state_bytes := _read_bytes(save_dir + "/state.json")
	if not state_bytes.is_empty():
		var state: Variant = JSON.parse_string(state_bytes.get_string_from_utf8())
		if state is Dictionary:
			_pending_state = state
			# Amorce le filet de _gather_state : même si le joueur n'est
			# jamais joignable cette session, son état chargé n'est pas perdu.
			var loaded_player: Variant = (state as Dictionary).get("player")
			if loaded_player is Dictionary:
				_last_player_state = loaded_player

	print("SaveManager : monde « %s » chargé (graine %d, tick %d, %d chunk(s) modifié(s))." % [
		active_config["name"], loaded_seed, TickManager.tick_index, _pending_edits.size()])
	return true


func _load_chunk_file(file_name: String, remap: PackedInt32Array) -> void:
	var parts := file_name.trim_suffix(".bin").split("_")
	if parts.size() != 3:
		return
	var ck := Vector3i(int(parts[0]), int(parts[1]), int(parts[2]))
	var bytes := _read_bytes(save_dir + "/chunks/" + file_name)
	if bytes.is_empty():
		return
	var buf := StreamPeerBuffer.new()
	buf.data_array = bytes
	if buf.get_available_bytes() < 6 or buf.get_u16() != SAVE_VERSION:
		push_warning("SaveManager : chunk %s corrompu ou version inconnue — ignoré." % file_name)
		return
	var n_edits := buf.get_u32()
	if buf.get_available_bytes() < n_edits * 4:
		push_warning("SaveManager : chunk %s tronqué — ignoré." % file_name)
		return
	var chunk_edits := {}
	for i in n_edits:
		var index := buf.get_u16()
		var old_id := buf.get_u16()
		chunk_edits[index] = remap[old_id] if old_id < remap.size() else 0
	var n_subs := buf.get_u32()
	if buf.get_available_bytes() < n_subs * (2 + SubdivGrid.CELLS * 2):
		push_warning("SaveManager : sous-grilles de %s tronquées — blocs pleins conservés." % file_name)
		n_subs = 0
	var chunk_subs := {}
	for i in n_subs:
		var index := buf.get_u16()
		var grid := PackedInt32Array()
		grid.resize(SubdivGrid.CELLS)
		for c in SubdivGrid.CELLS:
			var old_id := buf.get_u16()
			grid[c] = remap[old_id] if old_id < remap.size() else 0
		chunk_subs[index] = grid
	if not chunk_edits.is_empty():
		_pending_edits[ck] = chunk_edits
	if not chunk_subs.is_empty():
		_pending_sub_edits[ck] = chunk_subs


## Lit un fichier ; retombe sur son .tmp si l'original manque (crash entre
## suppression et renommage d'une écriture atomique). Vide si aucun des deux.
func _read_bytes(path: String) -> PackedByteArray:
	var actual := path
	if not FileAccess.file_exists(actual):
		actual = path + ".tmp"
		if not FileAccess.file_exists(actual):
			return PackedByteArray()
		push_warning("SaveManager : %s manquant — récupération du .tmp (écriture interrompue)." % path)
	return FileAccess.get_file_as_bytes(actual)


## Applique state.json aux managers + joueur — appelé par main.gd APRÈS
## l'initialisation du monde et le positionnement du spawn (la position
## restaurée écrase alors le spawn par défaut). Idempotent (état vidé après).
func apply_pending_state() -> void:
	if _pending_state.is_empty():
		return  # Rien à appliquer (monde neuf, ou déjà appliqué).
	ClaimManager.restore_state(_pending_state.get("claims", {}))
	VillageManager.restore_state(_pending_state.get("villages", {}))
	ExplorationManager.restore_state(_pending_state.get("exploration", []))
	ShopManager.restore_state(_pending_state.get("shops", {}))
	DungeonManager.restore_state(_pending_state.get("dungeons", {}))
	DropManager.restore_state(_pending_state.get("drops", []))
	var player := get_node_or_null("/root/Main/Player")
	var player_state: Variant = _pending_state.get("player")
	if player != null and player_state is Dictionary:
		player.restore_state(player_state)
	_pending_state = {}
