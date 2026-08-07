extends Node3D
## Scène principale — étapes D.3.1-3. Modes de mesure (critères G.8) :
##   --bench          vol rapide 30 s (étapes 1-2 : 60 fps rayon 8)
##   --statique       caméra immobile (isole le coût GPU du streaming)
##   --bench-mutation casser/poser en continu (étape 3 : aucune frame > 16 ms)
##   --bench-creatures 50 créatures actives (étape 6 : tick CreatureManager < 8 ms)
##   --pos X Z        position de départ (repérages/captures)
## Chaque bench écrit sa capture dans debug/ (artefacts régénérables).
##
## Les SONDES (--probe-*, --test-*) ne sont plus ici : elles vivent sous
## tools/probes/, une par fichier, listées dans ProbeRegistry (2026-07-28).
## Ce script ne garde que ce qui mesure PENDANT que le jeu tourne — les benchs
## instrumentés à la frame, qui ont besoin de _process et de la scène.

const BENCH_WARMUP := 3.0
## L'échauffement attend aussi la fin du chargement initial (file vide),
## sinon la mesure inclut la phase de remplissage du disque de streaming.
const BENCH_WARMUP_MAX := 25.0
const BENCH_DURATION := 30.0
const SLOW_FRAME_THRESHOLD := 1.0 / 60.0
## Cadence du bench de mutation : 2 mutations (1 cassé + 1 posé) par pas.
const MUTATION_INTERVAL := 0.2

const CREATURE_BENCH_COUNT := 50

## MONDE VITRINE. Émis quand toutes les rangées sont posées ; `showcase` porte
## alors le rapport de construction (positions par entrée de catalogue). La
## sonde attend ce signal — sonder pendant la construction mesurerait une
## vitrine à moitié bâtie, ce qui est la façon la plus sûre de rendre une
## assertion vraie ou fausse pour la mauvaise raison.
signal showcase_built
var showcase: RefCounted = null

var bench := false
var mutation_bench := false
var creature_bench := false
var _creature_tick_max_us := 0
var _creature_tick_sum_us := 0
var _creature_tick_samples := 0
var _bench_time := 0.0
var _measure_time := 0.0
var _deltas := PackedFloat32Array()
var _bench_done := false
var _warmup_done := false
var _mutation_timer := 0.0
var _mutation_step_index := 0
var _mutation_count := 0
var _start_pos := Vector2i.ZERO

@onready var camera: Camera3D = $FlyCamera
## Corps visible du joueur — construit dans _ready (peut rester null si le
## modèle est absent : on joue alors sans corps plutôt que de planter).
var player_body: Node3D


func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	WorldManager.chunk_root = $ChunkRoot
	CreatureManager.creature_root = $CreatureRoot
	# Barres de statut (PV/mana/faim) + horloge + température (2026-07-26).
	var status_bars: Control = preload("res://scenes/ui/status_bars.gd").new()
	$HUD.add_child(status_bars)
	status_bars.setup($Player, $FlyCamera)
	# Indicateur de combat directionnel + chiffres de dégâts (2026-07-28) :
	# sans eux le combat est mécaniquement complet mais ILLISIBLE.
	var combat_hud: Control = preload("res://scenes/ui/combat_hud.gd").new()
	$HUD.add_child(combat_hud)
	combat_hud.setup($Player)
	var damage_numbers: Node3D = preload("res://scenes/world/damage_numbers.gd").new()
	damage_numbers.name = "DamageNumbers"
	add_child(damage_numbers)
	# Rotations posées en code (plus lisible qu'une matrice dans le .tscn).
	# Orientation initiale seulement : le cycle jour/nuit (E.21) reprend la
	# main dès la première frame — voir DayNightManager, seule source de
	# vérité de l'heure et de l'éclairage.
	$Sun.rotation_degrees = Vector3(-50.0, -30.0, 0.0)
	# Le renderer Compatibility ignore le tonemapping : l'exposition se règle
	# par l'énergie lumineuse, sinon les couleurs de la palette délavent.
	$Sun.light_energy = 0.75
	# Ombres bornées et à 2 splits : la passe d'ombre est le principal coût
	# GPU sur la machine cible (G.1 : architecturer pour l'optimisation).
	$Sun.directional_shadow_mode = DirectionalLight3D.SHADOW_PARALLEL_2_SPLITS
	$Sun.directional_shadow_max_distance = 100.0

	# Corps visible du joueur (2026-07-28) : première personne AVEC pieds et
	# bras. Instancié en CODE, comme les menus — le cache de classes globales
	# n'est régénéré que par l'éditeur, un lancement headless après ajout d'un
	# fichier ne connaîtrait pas encore « PlayerBody ».
	# Le corps SUIT la caméra ; il ne la porte pas et ne participe à aucune
	# collision (voir l'en-tête de player_body.gd).
	player_body = preload("res://scenes/entities/player_body.gd").new()
	player_body.name = "PlayerBody"
	add_child(player_body)
	if player_body.setup(true):
		# L'arme est PORTÉE PAR LA MAIN et non plus posée devant l'objectif :
		# avec de vrais bras, un viewmodel flottant serait visiblement faux.
		var hand: Node3D = player_body.hand_attachment()
		if hand != null:
			var held: Node = $FlyCamera/HeldItem
			held.reparent(hand, false)
			held.set("in_hand", true)
		# BOUCLIER : même objet d'affichage, accroché à l'autre main. Il ne suit
		# PAS la hotbar mais l'ÉQUIPEMENT — d'où un second HeldItem plutôt qu'un
		# partage du premier, qui se reconstruirait à chaque changement d'objet
		# en main et ferait clignoter le bouclier.
		var offhand: Node3D = player_body.offhand_attachment()
		if offhand != null:
			shield_item = preload("res://scenes/entities/held_item.gd").new()
			shield_item.name = "ShieldItem"
			offhand.add_child(shield_item)
			shield_item.set("in_hand", true)
			shield_item.set("source", "main_gauche")
	else:
		player_body.queue_free()
		player_body = null

	# Démarrage DIRECT (benchs/sondes/tests/réseau CLI) : le monde démarre
	# immédiatement avec le profil par défaut, sans menu — les mesures et les
	# tests automatisés n'ont pas d'UI à traverser. La liste des drapeaux vit
	# dans ProbeRegistry, seule source de vérité (elle était auparavant dupliquée
	# ici ET dans la cascade de dispatch, avec un risque de divergence).
	if ProbeRegistry.is_direct(args):
		SaveManager.prepare_default_if_needed()
		_start_world(args)
	else:
		_show_start_menu()


## Menu de démarrage (2026-07-21) : aucun monde n'existe encore — tous les
## systèmes sont gardés sur `WorldManager.generator == null` en attendant.
func _show_start_menu() -> void:
	$Player.input_locked = true
	camera.input_locked = true
	$HUD.visible = false
	# preload (pas le class_name global) : le cache de classes globales n'est
	# régénéré que par l'éditeur — un lancement headless après ajout du
	# fichier ne connaîtrait pas encore « StartMenu ».
	var menu: CanvasLayer = preload("res://scenes/ui/start_menu.gd").new()
	add_child(menu)
	menu.world_ready.connect(_on_menu_world_ready)
	if "--test-menu" in OS.get_cmdline_user_args():
		_menu_smoke_test.call_deferred(menu)


## Test de fumée du menu (fenêtré, --test-menu — persistance COUPÉE par
## SaveManager) : capture le menu, remplit « nouvelle partie » (plat + désert),
## crée, vérifie que le monde démarré respecte les paramètres, capture.
func _menu_smoke_test(menu: CanvasLayer) -> void:
	await get_tree().create_timer(0.5).timeout
	await _screenshot("menu_screenshot.png")
	print("[MENUTEST] capture menu principal : menu_screenshot.png")
	menu._show_panel("new")
	await get_tree().process_frame
	menu._name_edit.text = "Monde de test"
	menu._seed_edit.text = "777"
	menu._relief_slider.value = 0.1
	menu._biome_option.selected = menu._biome_ids.find("desert_aride")
	await _screenshot("menu_new_screenshot.png")
	print("[MENUTEST] capture nouvelle partie : menu_new_screenshot.png")
	menu._on_create()  # → panneau création de personnage (6.3).
	await get_tree().process_frame
	# Création de personnage : Nain + Guerrier, +5 en Force.
	menu._char_race_option.selected = menu._race_ids.find("nain")
	menu._char_class_option.selected = menu._class_ids.find("guerrier")
	menu._refresh_character()
	menu._adjust_stat("force", 5)
	await _screenshot("menu_character_screenshot.png")
	print("[MENUTEST] capture création perso : menu_character_screenshot.png")
	menu._on_start_character()  # → world_ready → _start_world.
	await get_tree().process_frame
	var g := WorldManager.generator
	var player := $Player
	# Force attendue = base 5 + 5 réparti + Nain +1 + Guerrier +2 = 13.
	# Endurance = 5 + Nain +2 + Guerrier +1 = 8. Épée de départ (Guerrier).
	print("[MENUTEST] monde graine=%d (777) biome(0,0)=%s (desert_aride) hud=%s" % [
		WorldManager.world_seed, g.biome_at(0, 0).get("id", "?") if g != null else "-", $HUD.visible])
	print("[MENUTEST] perso : race=%s classe=%s Force=%d (13) Endurance=%d (8) épée niv=%d (5) objets=%d" % [
		player.race_id, player.class_id, int(player.stats["force"]), int(player.stats["endurance"]),
		player.skills.level("epee"), player.inventory.objects.size()])
	await get_tree().create_timer(4.0).timeout  # Laisser des chunks se mesher.
	await _screenshot("menu_world_screenshot.png")
	print("[MENUTEST] capture monde créé : menu_world_screenshot.png")
	var ok: bool = g != null and WorldManager.world_seed == 777 \
		and g.biome_at(0, 0).get("id", "") == "desert_aride" \
		and player.race_id == "nain" and player.class_id == "guerrier" \
		and int(player.stats["force"]) == 13 and int(player.stats["endurance"]) == 8 \
		and player.skills.level("epee") == 5 and player.inventory.objects.size() >= 1
	print("[MENUTEST] RÉSULTAT : %s" % ("OK" if ok else "ÉCHEC"))
	get_tree().quit(0 if ok else 1)


func _on_menu_world_ready() -> void:
	$Player.input_locked = false
	camera.input_locked = false
	$HUD.visible = true
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	_start_world(OS.get_cmdline_user_args())


## Dossier des captures de debug (benchs, sondes, tests) — JAMAIS la racine
## du projet : elles s'y accumulaient et noyaient l'arborescence. Hors du
## versionné (.gitignore) : ce sont des artefacts régénérables.
const CAPTURE_DIR := "res://debug/"


## Chemin absolu d'une capture, dossier créé au besoin.
func _capture_path(file_name: String) -> String:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(CAPTURE_DIR))
	return ProjectSettings.globalize_path(CAPTURE_DIR) + file_name


## Capture d'écran, sans risque de BLOCAGE en `--headless` (2026-07-28) : le
## RenderingServer y est un DUMMY, `frame_post_draw` ne se déclenche JAMAIS —
## l'attendre gelait le processus indéfiniment au lieu d'échouer. Même garde que
## Probe.screenshot() côté sondes.
## Construit le monde vitrine (coroutine — elle rend la main entre les rangées).
##
## `preload` et non le `class_name` global : le cache de classes de Godot n'est
## pas régénéré hors éditeur, et un script tout neuf référencé par son nom de
## classe reste introuvable jusqu'au prochain lancement de l'éditeur.
func build_showcase() -> void:
	var builder: RefCounted = preload("res://systems/worldgen/showcase_builder.gd").new()
	showcase = builder
	var started := Time.get_ticks_msec()
	await builder.build(self)
	print("[VITRINE] %d entrée(s) de catalogue, %d bloc(s), %d rangée(s) en %d ms (dont %d ms de remaillage, %d ms d'attente moteur)." % [
		(builder.get("positions") as Dictionary).size(), int(builder.get("blocks_written")),
		(builder.get("rows") as Array).size(), Time.get_ticks_msec() - started,
		int(builder.get("flush_ms")), int(builder.get("idle_ms"))])
	showcase_built.emit()


func _screenshot(file_name: String) -> void:
	if DisplayServer.get_name() == "headless":
		push_warning("Capture « %s » ignorée : mode headless (relancer avec fenêtre)." % file_name)
		return
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(_capture_path(file_name))


## Démarre le monde ACTIF (profil SaveManager.active_config) : générateur,
## spawn, restauration d'état, puis les branches benchs/sondes du mode direct.
func _start_world(args: Array) -> void:
	# GRAINE FORCÉE (`--seed N`), AVANT la création du monde — c'est tout
	# l'enjeu : posée après, elle ne changeait rien, le monde étant déjà bâti
	# sur la graine de la sauvegarde. Sert au harnais réseau, qui doit pouvoir
	# démarrer hôte et client sur des mondes VOLONTAIREMENT différents : sans
	# ça, la poignée de main ne prouverait rien, les deux valant 1337 par
	# défaut.
	var forced_seed := args.find("--seed")
	# MONDE PLAT (`-- --plat`), AVANT la création du générateur, pour la même
	# raison que la graine forcée : `initialize_world` lit les paramètres UNE
	# fois, et un drapeau posé après ne changerait plus rien.
	# `--probe-vitrine` l'implique : la sonde n'a rien à vérifier ailleurs que
	# sur la dalle, et `tools/run_probes.sh` ne passe qu'un drapeau par sonde.
	if "--plat" in args or "--probe-vitrine" in args:
		var config: Dictionary = SaveManager.active_config
		var flat_params: Dictionary = (config.get("params", {}) as Dictionary).duplicate(true)
		flat_params["terrain"] = "plat"
		config["params"] = flat_params
		SaveManager.active_config = config
	WorldManager.initialize_world()
	if forced_seed >= 0 and forced_seed + 1 < args.size():
		# `adopt_world` ET PAS une écriture de config : une sauvegarde chargée a
		# déjà bâti le monde, et `initialize_world` s'arrête net si le générateur
		# existe. Poser la config ne changeait alors rien — l'hôte restait sur la
		# graine de sa sauvegarde, et le test de poignée de main comparait deux
		# fois la même valeur sans s'en apercevoir.
		WorldManager.adopt_world(int(args[forced_seed + 1]), {})

	# Départ au-dessus de la surface réelle du terrain (E.2), position
	# optionnelle via `-- --pos X Z` (repérages/captures).
	var x0 := 0
	var z0 := 0
	var pos_index := args.find("--pos")
	var world_params: Dictionary = SaveManager.active_config.get("params", {})
	if pos_index >= 0 and pos_index + 2 < args.size():
		x0 = int(args[pos_index + 1])
		z0 = int(args[pos_index + 2])
	elif world_params.has("spawn") and (world_params["spawn"] as Array).size() == 2:
		# Point de spawn choisi par le joueur à la création (clic sur l'aperçu).
		x0 = int(world_params["spawn"][0])
		z0 = int(world_params["spawn"][1])
	elif WorldManager.generator != null:
		# Monde fini à grands océans : garantir un spawn sur la terre ferme
		# (l'origine tombe souvent en mer, 2026-07-26).
		var land := WorldManager.generator.find_land_spawn(0, 0)
		x0 = land.x
		z0 = land.y
	_start_pos = Vector2i(x0, z0)
	var h := WorldManager.generator.height_at(x0, z0) if WorldManager.generator != null else 24
	# Spawn au sol en jeu normal (marche par défaut, 6.3) ; les benchs
	# statiques/sondes gardent une hauteur de survol pour de meilleures captures.
	var overhead := "--statique" in args or "--bench-creatures" in args or "--probe" in args or "--test-input" in args
	# +2.9 (pas +1.9) : le joueur se tient SUR le sommet du bloc de sol
	# (feet_y = h+1, convention corrigée le 2026-07-21), l'œil est encore
	# 1.9 plus haut que les pieds (EYE_HEIGHT, fly_camera.gd).
	var spawn_y_offset := 24.0 if overhead else 2.9
	camera.position = Vector3(float(x0) + 0.5, float(h) + spawn_y_offset, float(z0) + 0.5)
	camera.rotation_degrees = Vector3(-12.0 if overhead else 0.0, 0.0, 0.0)

	# Restauration de l'état sauvegardé (claims, exploration, joueur — la
	# position restaurée écrase le spawn par défaut ci-dessus). Sans effet
	# sur un monde neuf.
	SaveManager.apply_pending_state()

	# Configuration du personnage (6.1) : monde CHARGÉ = déjà restauré par
	# apply_pending_state ; monde NEUF = création de personnage en attente ;
	# mode DIRECT (bench/probe/test) = kit par défaut historique.
	if not SaveManager.world_loaded:
		if not SaveManager.pending_character.is_empty():
			$Player.apply_character(SaveManager.pending_character)
			SaveManager.pending_character = {}
		else:
			$Player.apply_default_character()

	# Menu de jeu à onglets (Tab) — instancié en code (comme le menu de
	# démarrage) : preload du script, pas le class_name global (cache de
	# classes non régénéré hors éditeur).
	if get_node_or_null("DialoguePanel") == null:
		var dialogue: CanvasLayer = preload("res://scenes/ui/dialogue_panel.gd").new()
		dialogue.name = "DialoguePanel"
		add_child(dialogue)
	if get_node_or_null("ChestPanel") == null:
		var chest: CanvasLayer = preload("res://scenes/ui/chest_panel.gd").new()
		chest.name = "ChestPanel"
		add_child(chest)
	if get_node_or_null("GameMenu") == null:
		var game_menu: CanvasLayer = preload("res://scenes/ui/game_menu.gd").new()
		game_menu.name = "GameMenu"
		add_child(game_menu)

	# Réseau host-and-join (E.11/8) : indépendant des benchs/probes ci-dessous.
	if "--host" in args:
		NetworkManager.host()
	var join_index := args.find("--join")
	if join_index >= 0 and join_index + 1 < args.size():
		NetworkManager.join(args[join_index + 1])

	# LE MONDE VITRINE. Un monde plat n'a de sens que garni : c'est la même
	# décision, prise une seule fois, plutôt qu'un second interrupteur que le
	# joueur devrait penser à actionner.
	#
	# Reconstruit à CHAQUE démarrage et non une fois pour toutes : la
	# construction est déterministe (graine d'arbre fixée par essence), donc
	# rejouer écrit les mêmes blocs aux mêmes endroits, et les étiquettes — qui
	# sont des nœuds, non persistables — reviennent avec. La contrepartie est
	# assumée : le monde vitrine écrase ce qu'on aurait modifié DANS les rangées.
	# C'est une vitrine, pas une partie.
	if String((SaveManager.active_config.get("params", {}) as Dictionary).get("terrain", "")) == "plat":
		build_showcase()

	# Sondes de diagnostic (--probe-*, --test-*) : dispatch par TABLE, une sonde
	# par fichier sous tools/probes/. Si l'une prend la main, elle mène le
	# scénario jusqu'à get_tree().quit() — main.gd n'a plus rien à faire.
	# (Pas dans debug/ : ce dossier porte un .gdignore, Godot n'y voit aucun
	# script — il ne contient que des artefacts régénérables, captures et logs.)
	if ProbeRegistry.run(self, args):
		return
	mutation_bench = "--bench-mutation" in args
	creature_bench = "--bench-creatures" in args
	if creature_bench:
		CreatureManager.natural_spawn_enabled = false  # Le bench gère sa propre population.
		_spawn_bench_creatures()
		TickManager.tick_post.connect(_on_creature_bench_tick)
	bench = "--bench" in args or "--statique" in args or mutation_bench or creature_bench
	if bench:
		CreatureManager.natural_spawn_enabled = false  # Mesures non polluées par des spawns.
		DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
		camera.bench = "--bench" in args
		# Mesures non contaminées : aucune entrée joueur pendant un bench.
		camera.input_locked = true
		$Player.input_locked = true
		var mode := "vol"
		if mutation_bench:
			mode = "mutation"
		elif not camera.bench:
			mode = "statique"
		print("[BENCH] démarrage (%s) : échauffement puis mesure %.0f s." % [mode, BENCH_DURATION])


## Objet d'affichage du bouclier, accroché à la main gauche. Il se rafraîchit
## tout seul (HeldItem.source == "bouclier") : rien à piloter d'ici.
var shield_item: MeshInstance3D


func _process(delta: float) -> void:
	# Le corps suit la caméra : purement VISUEL, donc _process est légitime
	# (E.1 réserve le tick au gameplay, pas à l'affichage). Placé avant tout
	# retour anticipé — un bench ne doit pas figer le corps en l'air.
	if player_body != null:
		player_body.follow_camera(camera, FlyCamera.EYE_HEIGHT, delta)
		# IK. L'ORDRE COMPTE : les jambes d'abord, parce qu'elles peuvent
		# ABAISSER le bassin (bord de bloc) et donc déplacer les épaules ;
		# les bras ensuite, qui visent des cibles en espace MONDE et doivent
		# partir de la position d'épaule définitive.
		player_body.solve_legs()
		# La phase de marche descend du CORPS vers le joueur : c'est elle qui
		# fait balancer la main libre (voir Player._free_hand_target). Poussée
		# ici, avant l'IK, pour que la cible calculée soit celle de CETTE frame.
		$Player.set_body_gait(
			float(player_body.get("_gait_phase")), float(player_body.get("_gait_amount")))
		# ENVERGURE DU BRAS GAUCHE : d'où il part et jusqu'où il va. Sans elle le
		# joueur posait la seconde main sur le manche sans savoir si le bras y
		# arrivait — sur une arme à long manche il n'y arrivait pas, et la main
		# restait en l'air à côté de l'arme.
		$Player.set_left_arm_span(
			player_body.shoulder_world_position("gauche"),
			player_body.arm_reach("gauche"))
		# POSITION RÉELLE de la main droite (frame précédente) : l'arme y est
		# accrochée, c'est donc de là que part son manche — et pas de la cible
		# que l'IK n'atteint qu'approximativement.
		$Player.set_right_hand_actual(player_body.hand_world_position("droite"))
		var targets: Dictionary = $Player.hand_targets(
			player_body.HAND_ARC_RADIUS, player_body.OFFHAND_ALONG_WEAPON, delta)
		for side: String in targets:
			player_body.solve_arm(side, targets[side])
		# N'afficher que les membres réellement utilisés : la main gauche
		# n'apparaît que si l'arme la mobilise (deux mains). `hand_targets`
		# la renseigne précisément dans ce cas — une seule source de vérité.
		# N'AFFICHER QUE LES MEMBRES UTILES. La main libre a désormais une cible
		# elle aussi (pour que le bras ne pende pas, collé au buste, sur le corps
		# vu de l'extérieur) — mais elle ne doit pas pour autant faire surgir un
		# avant-bras au milieu de l'écran en première personne. On demande donc
		# au joueur ce que la gauche FAIT, au lieu de déduire de la présence
		# d'une cible.
		player_body.set_local_limbs(bool($Player.left_hand_busy()))
		# La main PORTE l'arme, l'axe de VISÉE l'oriente : héritée de l'os,
		# elle pointait là où pointait l'avant-bras, donc en travers.
		var part_scale: float = preload("res://scenes/entities/held_item.gd").PART_SCALE
		player_body.point_weapon($Player.weapon_direction(), part_scale)
		# La main gauche tient soit une PLAQUE, qui doit faire face à la menace,
		# soit une ARME, qui doit pointer le long de son propre arc. Les deux
		# géométries n'ont rien à voir : un bouclier orienté comme une lame
		# présenterait sa tranche, une lame orientée comme une plaque frapperait
		# de plat.
		if $Player.offhand_weapon().is_empty():
			player_body.point_shield(-camera.global_basis.z, part_scale)
		else:
			player_body.point_offhand_weapon($Player.offhand_direction(), part_scale)

	# Instrumentation de mesure uniquement — aucune logique de gameplay ici (E.1).
	if not bench or _bench_done:
		return
	_bench_time += delta
	if not _warmup_done:
		var loading := int(WorldManager.stats()["queue"]) > 0
		if (_bench_time >= BENCH_WARMUP and not loading) or _bench_time >= BENCH_WARMUP_MAX:
			_warmup_done = true
			print("[BENCH] échauffement terminé à %.1f s — mesure lancée." % _bench_time)
		return
	_deltas.append(delta)
	_measure_time += delta
	if mutation_bench:
		_mutation_timer += delta
		while _mutation_timer >= MUTATION_INTERVAL:
			_mutation_timer -= MUTATION_INTERVAL
			_mutation_step()
	if _measure_time >= BENCH_DURATION:
		_bench_done = true
		_finish_bench()


## Un pas du bench de mutation (critère G.8 étape 3) : casse un bloc de
## surface et pose un bloc de terre à côté, à des positions balayées.
func _mutation_step() -> void:
	_mutation_step_index += 1
	# Balayage en lignes : chaque pas touche une position VIERGE (les deux
	# mutations doivent réussir, sinon le bench ne mesure rien).
	var dx := (_mutation_step_index % 20) - 10
	var dz := (_mutation_step_index / 20) % 20 - 10
	var x := _start_pos.x + dx
	var z := _start_pos.y + dz
	var h := WorldManager.generator.height_at(x, z)
	if WorldManager.set_block(Vector3i(x, h, z), 0):
		_mutation_count += 1
	var terre_id: int = GameData.material_runtime_ids.get("terre", 0)
	if WorldManager.set_block(Vector3i(x, h + 3, z), terre_id):
		_mutation_count += 1


## Spawn 50 bandits en cercle autour du point de départ (critère G.8 :
## 50 créatures actives, tick < 8 ms). Portée d'aggro réglée pour que
## certaines poursuivent le joueur (chemin coûteux) et d'autres déambulent.
func _spawn_bench_creatures() -> void:
	var g := WorldManager.generator
	for i in CREATURE_BENCH_COUNT:
		var angle := TAU * i / float(CREATURE_BENCH_COUNT)
		var radius := 6.0 + (i % 5) * 3.0
		var x := _start_pos.x + int(cos(angle) * radius)
		var z := _start_pos.y + int(sin(angle) * radius)
		var h := g.height_at(x, z)
		CreatureManager.spawn("bandit", Vector3(x, h + 0.5, z))
	print("[BENCH] %d créatures spawnées." % CreatureManager.creatures.size())


func _on_creature_bench_tick(_tick_index: int) -> void:
	if not bench or _bench_done or not _warmup_done:
		return
	var us: int = CreatureManager.last_tick_us
	_creature_tick_sum_us += us
	_creature_tick_max_us = maxi(_creature_tick_max_us, us)
	_creature_tick_samples += 1


func _finish_bench() -> void:
	var frames := _deltas.size()
	var total := 0.0
	var worst := 0.0
	var slow := 0
	for d in _deltas:
		total += d
		worst = maxf(worst, d)
		if d > SLOW_FRAME_THRESHOLD:
			slow += 1
	var avg_fps := frames / maxf(total, 0.001)
	var s := WorldManager.stats()
	print("[BENCH] frames=%d fps_moyen=%.1f fps_min=%.1f frames>16.7ms=%d (%.2f %%)" % [
		frames, avg_fps, 1.0 / maxf(worst, 0.0001), slow, 100.0 * slow / maxi(frames, 1)])
	print("[BENCH] meshes=%d cache=%d taches=%d meshing_moyen=%.2f ms meshing_max=%.2f ms" % [
		s["meshes"], s["cache"], s["total_tasks"], s["meshing_avg_ms"], s["meshing_max_ms"]])
	if mutation_bench:
		print("[BENCH] mutations=%d pire_frame=%.2f ms" % [_mutation_count, worst * 1000.0])
	if creature_bench:
		var avg_us := _creature_tick_sum_us / maxi(_creature_tick_samples, 1)
		print("[BENCH] créatures=%d tick_moyen=%.2f ms tick_max=%.2f ms (critère G.8 : < 8 ms)" % [
			CreatureManager.creatures.size(), avg_us / 1000.0, _creature_tick_max_us / 1000.0])
	# Répartition du tick par phase (TickManager, 2026-07-28) : sans cette
	# lecture, l'instrumentation par phase n'apparaîtrait nulle part et on en
	# serait réduit à un total qui ne désigne aucun coupable.
	var t := TickManager.stats()
	print("[BENCH] tick pire=%.2f ms — entités %.2f | monde %.2f | flush %.2f | post %.2f (budget %.0f ms)" % [
		t["max_ms"], t["entities_ms"], t["world_ms"], t["flush_ms"], t["post_ms"],
		TickManager.TICK_BUDGET_US / 1000.0])
	await _screenshot("bench_screenshot.png")
	var path := _capture_path("bench_screenshot.png")
	print("[BENCH] capture : " + path)
	get_tree().quit(0)
