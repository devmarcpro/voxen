extends Node3D
## Scène principale — étapes D.3.1-3. Modes de mesure (critères G.8) :
##   --bench          vol rapide 30 s (étapes 1-2 : 60 fps rayon 8)
##   --statique       caméra immobile (isole le coût GPU du streaming)
##   --bench-mutation casser/poser en continu (étape 3 : aucune frame > 16 ms)
##   --bench-creatures 50 créatures actives (étape 6 : tick CreatureManager < 8 ms)
##   --probe          sonde headless générateur → chunk → mesher
##   --pos X Z        position de départ (repérages/captures)
## Chaque bench écrit bench_screenshot.png à la racine du projet.

const BENCH_WARMUP := 3.0
## L'échauffement attend aussi la fin du chargement initial (file vide),
## sinon la mesure inclut la phase de remplissage du disque de streaming.
const BENCH_WARMUP_MAX := 25.0
const BENCH_DURATION := 30.0
const SLOW_FRAME_THRESHOLD := 1.0 / 60.0
## Cadence du bench de mutation : 2 mutations (1 cassé + 1 posé) par pas.
const MUTATION_INTERVAL := 0.2

const CREATURE_BENCH_COUNT := 50

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


## Drapeaux de démarrage DIRECT (benchs/sondes/tests/réseau CLI) : le monde
## démarre immédiatement avec le profil par défaut, sans menu — les mesures
## et les tests automatisés n'ont pas d'UI à traverser.
const DIRECT_ARGS: Array[String] = [
	"--bench", "--statique", "--bench-mutation", "--bench-creatures",
	"--probe", "--probe-subdiv", "--probe-dungeon", "--probe-save",
	"--probe-save-verify", "--probe-params", "--probe-city", "--probe-ore", "--probe-terrain", "--test-city", "--test-textures", "--test-ore", "--test-input",
	"--bench-network-client", "--host", "--join",
]


func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	WorldManager.chunk_root = $ChunkRoot
	CreatureManager.creature_root = $CreatureRoot
	# Barres de statut (PV/mana/faim) + horloge + température (2026-07-26).
	var status_bars: Control = preload("res://scenes/ui/status_bars.gd").new()
	$HUD.add_child(status_bars)
	status_bars.setup($Player, $FlyCamera)
	# Rotations posées en code (plus lisible qu'une matrice dans le .tscn).
	$Sun.rotation_degrees = Vector3(-50.0, -30.0, 0.0)
	# Le renderer Compatibility ignore le tonemapping : l'exposition se règle
	# par l'énergie lumineuse, sinon les couleurs de la palette délavent.
	$Sun.light_energy = 0.75
	# Ombres bornées et à 2 splits : la passe d'ombre est le principal coût
	# GPU sur la machine cible (G.1 : architecturer pour l'optimisation).
	$Sun.directional_shadow_mode = DirectionalLight3D.SHADOW_PARALLEL_2_SPLITS
	$Sun.directional_shadow_max_distance = 100.0

	var direct := false
	for flag in DIRECT_ARGS:
		if flag in args:
			direct = true
			break
	if direct:
		# Mode direct : profil par défaut (ou --save-dir déjà chargé par
		# SaveManager) — comportement historique des benchs/sondes.
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
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(
		ProjectSettings.globalize_path("res://") + "menu_screenshot.png")
	print("[MENUTEST] capture menu principal : menu_screenshot.png")
	menu._show_panel("new")
	await get_tree().process_frame
	menu._name_edit.text = "Monde de test"
	menu._seed_edit.text = "777"
	menu._relief_slider.value = 0.1
	menu._biome_option.selected = menu._biome_ids.find("desert_aride")
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(
		ProjectSettings.globalize_path("res://") + "menu_new_screenshot.png")
	print("[MENUTEST] capture nouvelle partie : menu_new_screenshot.png")
	menu._on_create()  # → panneau création de personnage (6.3).
	await get_tree().process_frame
	# Création de personnage : Nain + Guerrier, +5 en Force.
	menu._char_race_option.selected = menu._race_ids.find("nain")
	menu._char_class_option.selected = menu._class_ids.find("guerrier")
	menu._refresh_character()
	menu._adjust_stat("force", 5)
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(
		ProjectSettings.globalize_path("res://") + "menu_character_screenshot.png")
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
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(
		ProjectSettings.globalize_path("res://") + "menu_world_screenshot.png")
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


## Démarre le monde ACTIF (profil SaveManager.active_config) : générateur,
## spawn, restauration d'état, puis les branches benchs/sondes du mode direct.
func _start_world(args: Array) -> void:
	WorldManager.initialize_world()

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

	if "--probe" in args:
		_diagnostic_probe()
		return
	if "--probe-subdiv" in args:
		_subdiv_probe()
		return
	if "--probe-save" in args:
		_save_probe()
		return
	if "--probe-save-verify" in args:
		_save_probe_verify()
		return
	if "--probe-dungeon" in args:
		_dungeon_probe()
		return
	if "--probe-params" in args:
		_params_probe()
		return
	if "--probe-city" in args:
		_city_probe()
		return
	if "--probe-ore" in args:
		_ore_probe()
		return
	if "--probe-terrain" in args:
		_terrain_probe()
		return
	if "--test-city" in args:
		_city_capture()
		return
	if "--test-textures" in args:
		_texture_showcase()
		return
	if "--test-ore" in args:
		_ore_visual()
		return
	if "--bench-network-client" in args:
		_network_bench_client()
		return
	if "--test-input" in args:
		_input_smoke_test()
		return
	mutation_bench = "--bench-mutation" in args
	creature_bench = "--bench-creatures" in args
	if creature_bench:
		CreatureManager.natural_spawn_enabled = false  # Le bench gère sa propre population.
		_spawn_bench_creatures()
		TickManager.tick.connect(_on_creature_bench_tick)
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


func _process(delta: float) -> void:
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


## Spawn 50 sangliers en cercle autour du point de départ (critère G.8 :
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
		CreatureManager.spawn("sanglier", Vector3(x, h + 0.5, z))
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
	await RenderingServer.frame_post_draw
	var image := get_viewport().get_texture().get_image()
	var path := ProjectSettings.globalize_path("res://") + "bench_screenshot.png"
	image.save_png(path)
	print("[BENCH] capture : " + path)
	get_tree().quit(0)


## Critère G.8 étape 4 : une façade de 64 blocs détaillés en 4 px doit se
## mesher en < 4 ms. Deux motifs mesurés : « réaliste » (blocs pleins avec
## relief de surface sculpté) et « pire cas » (damier air/solide en 3D —
## chaque cellule isolée, fusion greedy impossible).
func _subdiv_probe() -> void:
	var g := WorldManager.generator
	var col := Vector2i(0, 0)
	var ctx := g.prepare_context(col)
	var key := Vector3i(0, 8, 0)  # Chunk d'air, au-dessus du relief local.
	var id_a: int = GameData.material_runtime_ids["pierre"]
	var id_b: int = GameData.material_runtime_ids["granit"]

	for pattern in ["realiste", "pire_cas"]:
		var data := g.generate_chunk(key, ctx)
		for bx in 8:
			for by in 8:
				var grid := SubdivGrid.create_empty()
				if pattern == "realiste":
					# Bloc plein avec relief : la couche de façade (z = 0)
					# est sculptée une cellule sur trois.
					grid.fill(id_a)
					for cy in 8:
						for cx in 8:
							if (cx + cy * 3) % 3 == 0:
								grid[SubdivGrid.cell_index(cx, cy, 0)] = 0
							elif (cx + cy) % 2 == 0:
								grid[SubdivGrid.cell_index(cx, cy, 0)] = id_b
				else:
					# Damier air/solide 3D : pire cas de fusion greedy.
					for cy in 8:
						for cz in 8:
							for cx in 8:
								if (cx + cy + cz) % 2 == 0:
									grid[SubdivGrid.cell_index(cx, cy, cz)] = id_a
				data.set_subdiv(ChunkData.index_of(bx, by, 0), grid, id_a)
		# Mesure : 20 meshings de la passe fine.
		var total_us := 0
		var max_us := 0
		var vertex_count := 0
		for i in 20:
			var start := Time.get_ticks_usec()
			var arrays := ChunkMesher.mesh_chunk(key, data, g, ctx, {}, true)
			var elapsed := Time.get_ticks_usec() - start
			total_us += elapsed
			max_us = maxi(max_us, elapsed)
			vertex_count = 0 if arrays.is_empty() else (arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array).size()
		print("[SUBDIV] motif=%s : moyen=%.2f ms max=%.2f ms sommets=%d (critère G.8 : < 4 ms)" % [
			pattern, total_us / 20.0 / 1000.0, max_us / 1000.0, vertex_count])
	get_tree().quit(0)


## Test de fumée des entrées : kit de départ, capture souris, rotation caméra.
func _input_smoke_test() -> void:
	await get_tree().create_timer(0.5).timeout
	var player := $Player
	print("[TEST] outils au départ : %d" % player.inventory.objects.size())
	for obj: Dictionary in player.inventory.objects:
		print("[TEST]   %s — durete_base=%.1f qualite=%.2f poids=%.1f" % [
			obj.get("item_id", "?"), obj.get("base_hardness", -1.0),
			obj.get("quality", -1.0), obj.get("weight", -1.0)])
	# Clic gauche au centre → doit capturer la souris.
	var press := InputEventMouseButton.new()
	press.button_index = MOUSE_BUTTON_LEFT
	press.pressed = true
	press.position = get_viewport().get_visible_rect().size / 2
	Input.parse_input_event(press)
	await get_tree().process_frame
	await get_tree().process_frame
	print("[TEST] souris capturée : %s" % (Input.mouse_mode == Input.MOUSE_MODE_CAPTURED))
	# Mouvement souris → doit tourner la caméra.
	var rot_before := camera.rotation
	var motion := InputEventMouseMotion.new()
	motion.relative = Vector2(100, 50)
	Input.parse_input_event(motion)
	await get_tree().process_frame
	await get_tree().process_frame
	print("[TEST] rotation : avant=%s après=%s changée=%s" % [
		rot_before, camera.rotation, camera.rotation != rot_before])
	# Combat : spawn un sanglier juste devant, vise, attaque à l'épée.
	# Hauteur de la CAMÉRA échantillonnée à SA PROPRE position (E.2 — le
	# relief peut désormais varier fortement sur quelques blocs, orogenèse
	# 2026-07-20) : sinon le contrôleur de marche re-snappe la caméra au sol
	# RÉEL sous elle dès la frame suivante, loin de la position voulue. Le
	# sanglier réutilise cette MÊME hauteur (pas la sienne propre) : sur un
	# relief très pentu, sa propre hauteur locale peut être à des dizaines de
	# blocs de distance verticale même à 3 blocs à l'horizontale, ce qui
	# rendrait le combat de test impossible (hors de portée d'épée) sans
	# rapport avec un vrai bug de génération — juste un test qui doit rester
	# robuste au relief, pas une exigence gameplay d'alignement au sol exact.
	var gg := WorldManager.generator
	# Spawn PROCHE (2026-07-21, test durci) : à 3+ blocs, le relief spectaculaire
	# (orogenèse/terrasses) peut placer une falaise entre caméra et sanglier —
	# le snap au sol RÉEL l'envoyait 10+ blocs plus bas, hors de portée des
	# deux côtés (fragilité de TEST documentée, pas un bug des mécaniques).
	var spawn_x := 2
	var spawn_z := 0
	var cam_h := gg.height_at(0, 0)
	camera.position = Vector3(0.5, float(cam_h) + 2.9, 0.5)  # feet sur le sommet du bloc de sol, +EYE_HEIGHT.
	camera.rotation_degrees = Vector3(0.0, 0.0, 0.0)
	camera.look_at(Vector3(spawn_x, cam_h + 0.5, spawn_z), Vector3.UP)
	var boar := CreatureManager.spawn("sanglier", Vector3(spawn_x, cam_h + 0.5, spawn_z))
	player.selected_slot = 3  # L'épée (4e entrée : pioche/hache/pelle/épée).
	await get_tree().process_frame
	print("[TEST] créature spawnée, distance=%.1f" % camera.global_position.distance_to(boar.position))
	var attacks := 0
	while attacks < 60 and is_instance_valid(boar) and not boar.is_dead():
		# Re-viser à chaque coup (2026-07-21, test durci) : le sanglier CHASSE
		# et finit sous la caméra — sans suivi, le rayon de visée pointait
		# encore sur son point de spawn et minait le sol à la place.
		camera.look_at(boar.position + Vector3.UP * 0.6, Vector3.UP)
		var click := InputEventMouseButton.new()
		click.button_index = MOUSE_BUTTON_LEFT
		click.pressed = true
		Input.parse_input_event(click)
		await get_tree().process_frame
		var release := InputEventMouseButton.new()
		release.button_index = MOUSE_BUTTON_LEFT
		release.pressed = false
		Input.parse_input_event(release)
		await get_tree().create_timer(0.15).timeout
		attacks += 1
	print("[TEST] combat : %d clics, sanglier mort=%s (PV joueur=%d/%d)" % [
		attacks, not is_instance_valid(boar) or boar.is_dead(), int(player.health), int(player.health_max)])
	# Spawn naturel (hors bench) : ~5 s d'attente réelle doit produire au
	# moins une créature autour du joueur (CreatureManager.SPAWN_INTERVAL_TICKS).
	print("[TEST] créatures avant attente spawn naturel : %d" % CreatureManager.creatures.size())
	await get_tree().create_timer(6.0).timeout
	# Sanglier exclu du spawn naturel (2026-07-20, demande explicite) : pool
	# vide, donc AUCUN spawn naturel attendu tant qu'aucune autre créature
	# hostile n'est ajoutée aux données.
	print("[TEST] créatures après 6 s : %d (spawn naturel désactivé pour le sanglier — 0 attendu)" % CreatureManager.creatures.size())
	# Marche/gravité : lâcher la caméra bien au-dessus du sol doit la reposer
	# exactement sur le PREMIER bloc solide réellement rencontré (collision
	# sur le monde réel, pas sur la hauteur procédurale idéale — celle-ci peut
	# différer localement d'une grotte/surplomb, 2026-07-20). On calcule donc
	# la hauteur attendue via la même requête de blocs que la collision.
	var probe_x := int(camera.position.x)
	var probe_z := int(camera.position.z)
	var eau_id: int = GameData.material_runtime_ids.get("eau", -1)
	var real_ground_h := gg.height_at(probe_x, probe_z) + 20
	while real_ground_h > -64:
		var id := WorldManager.block_at_world(Vector3i(probe_x, real_ground_h, probe_z))
		if id != 0 and id != eau_id:
			break
		real_ground_h -= 1
	# feet sur le sommet du bloc de sol (+1) puis +EYE_HEIGHT (1.9) = +2.9.
	camera.position.y = float(real_ground_h) + 4.9 + 2.9
	await get_tree().create_timer(1.5).timeout
	print("[TEST] marche/gravité : y=%.2f (attendu %.2f = sol+2.9)" % [camera.position.y, float(real_ground_h) + 2.9])

	# Marche horizontale SOUTENUE (2026-07-21, bug réel corrigé : le joueur
	# pouvait rester bloqué immobile au sol malgré une touche directionnelle
	# tenue, tant qu'aucun saut ne « débloquait » la dérive flottante de
	# `_body_blocked_at` — ce test aurait dû détecter ce bug plus tôt, il ne
	# vérifiait jusqu'ici que la chute, jamais un déplacement horizontal réel
	# une fois au repos exact sur le sol).
	var walk_start := Vector2(camera.position.x, camera.position.z)
	var w_press := InputEventKey.new()
	w_press.physical_keycode = KEY_W
	w_press.pressed = true
	Input.parse_input_event(w_press)
	await get_tree().create_timer(1.0).timeout
	var w_release := InputEventKey.new()
	w_release.physical_keycode = KEY_W
	w_release.pressed = false
	Input.parse_input_event(w_release)
	var walked := Vector2(camera.position.x, camera.position.z).distance_to(walk_start)
	print("[TEST] marche soutenue : déplacement=%.2f blocs en 1 s (attendu > 3.0, WALK_SPEED=4.317 façon Minecraft)" % walked)

	# Claims (3.3) : revendiquer, cycler le rôle, dérevendiquer.
	var start_cell: Vector2i = player.current_cell()
	print("[TEST] cellule=%s revendiquée=%s (attendu false)" % [start_cell, ClaimManager.is_claimed(start_cell)])
	var v_press := InputEventKey.new()
	v_press.physical_keycode = KEY_V
	v_press.pressed = true
	Input.parse_input_event(v_press)
	await get_tree().process_frame
	print("[TEST] après V : revendiquée=%s rôle=%s (attendu true/base)" % [ClaimManager.is_claimed(start_cell), ClaimManager.role_of(start_cell)])
	var b_press := InputEventKey.new()
	b_press.physical_keycode = KEY_B
	b_press.pressed = true
	Input.parse_input_event(b_press)
	await get_tree().process_frame
	print("[TEST] après B : rôle=%s (attendu habitation)" % ClaimManager.role_of(start_cell))

	# Voyage rapide (6.3) vers une cellule voisine.
	var target_cell: Vector2i = start_cell + Vector2i(2, 0)
	player.fast_travel_to_cell(target_cell)
	var landed_cell: Vector2i = player.current_cell()
	print("[TEST] voyage rapide : cible=%s atterri=%s (doivent correspondre)" % [target_cell, landed_cell])

	# Carte du monde (M) : écran séparé (ToME-like), stats + relief 3D,
	# fermeture par Échap ou clic de voyage rapide (plus par un 2e M).
	var map_view := get_node("WorldMapView")
	var stats_panel := get_node("HUD/WorldMapPanel")
	var m_press := InputEventKey.new()
	m_press.physical_keycode = KEY_M
	m_press.pressed = true
	Input.parse_input_event(m_press)
	await get_tree().process_frame
	await get_tree().process_frame
	print("[TEST] carte après M : ouverte=%s stats_visibles=%s joueur_verrouille=%s (attendus true/true/true)" % [
		map_view.is_open, stats_panel.visible, player.input_locked])
	# Écran de chargement (2026-07-21) : la mosaïque se construit maintenant
	# par budget de temps sur plusieurs frames (BUILD_BUDGET_MS) — attend que
	# le label "Chargement..." disparaisse réellement plutôt qu'un délai fixe
	# (qui serait trop court sur une grosse carte, trop long sur une petite).
	var waited := 0.0
	while map_view._loading_label.visible and waited < 45.0:
		await get_tree().process_frame
		waited += get_process_delta_time()
	print("[TEST] carte : chargement terminé en %.2f s" % waited)
	await RenderingServer.frame_post_draw
	var map_image := get_viewport().get_texture().get_image()
	map_image.save_png(ProjectSettings.globalize_path("res://") + "map_screenshot.png")
	print("[TEST] capture carte : map_screenshot.png")
	var esc_press := InputEventKey.new()
	esc_press.physical_keycode = KEY_ESCAPE
	esc_press.pressed = true
	Input.parse_input_event(esc_press)
	await get_tree().process_frame
	print("[TEST] carte après Échap : ouverte=%s stats_visibles=%s joueur_verrouille=%s (attendus false/false/false)" % [
		map_view.is_open, stats_panel.visible, player.input_locked])
	# Réouvre et teste le voyage rapide par clic (centre de l'écran = cellule
	# centrale par construction de la grille). ATTENDRE la fin du chargement
	# avant de cliquer (2026-07-21, test durci) : un clic pendant le
	# chargement tombe sur une géométrie de mosaïque pas encore posée
	# (_pixel_to_tile invalide) et ne fait rien — la carte restait ouverte et
	# tous les tests suivants tournaient input verrouillé (cascade).
	Input.parse_input_event(m_press)
	await get_tree().process_frame
	await get_tree().process_frame
	var waited_reopen := 0.0
	while map_view._loading_label.visible and waited_reopen < 45.0:
		await get_tree().process_frame
		waited_reopen += get_process_delta_time()
	var before_cell: Vector2i = player.current_cell()
	var click := InputEventMouseButton.new()
	click.button_index = MOUSE_BUTTON_LEFT
	click.pressed = true
	click.position = get_viewport().get_visible_rect().size / 2
	Input.parse_input_event(click)
	await get_tree().process_frame
	print("[TEST] carte : clic central a fermé=%s (attendu true), cellule avant=%s après=%s" % [
		not map_view.is_open, before_cell, player.current_cell()])
	# Filet : si la carte est restée ouverte malgré tout, fermer par Échap
	# pour ne pas contaminer la suite (input verrouillé).
	if map_view.is_open:
		Input.parse_input_event(esc_press)
		await get_tree().process_frame
	# Molette (slot) et Shift+molette (banque de hotbar).
	var wheel_down := InputEventMouseButton.new()
	wheel_down.button_index = MOUSE_BUTTON_WHEEL_DOWN
	wheel_down.pressed = true
	Input.parse_input_event(wheel_down)
	await get_tree().process_frame
	print("[TEST] molette bas : slot=%d (avant=3, +1 attendu)" % player.selected_slot)
	var shift_wheel := InputEventMouseButton.new()
	shift_wheel.button_index = MOUSE_BUTTON_WHEEL_DOWN
	shift_wheel.pressed = true
	shift_wheel.shift_pressed = true
	Input.parse_input_event(shift_wheel)
	await get_tree().process_frame
	print("[TEST] shift+molette bas : banque=%d (attendu 1)" % player.active_hotbar)
	var shift3 := InputEventKey.new()
	shift3.physical_keycode = KEY_3
	shift3.pressed = true
	shift3.shift_pressed = true
	Input.parse_input_event(shift3)
	await get_tree().process_frame
	print("[TEST] shift+3 : banque=%d (attendu 2)" % player.active_hotbar)
	# Structure de démonstration de subdivision (4.1) devant la caméra :
	# un bloc plein + marches en sous-blocs 16/8/4 px + une sculpture.
	var g := WorldManager.generator
	var h := g.height_at(3, -6)
	var base := Vector3i(3, h + 1, -6)
	WorldManager.set_block(base, GameData.material_runtime_ids["pierre"])
	var granite: int = GameData.material_runtime_ids["granit"]
	var oak: int = GameData.material_runtime_ids["chene"]
	# Sous-bloc 16 px (4 cellules) posé sur le bloc plein.
	print("[TEST] pose 16px : %s" % WorldManager.set_sub_region(base + Vector3i(0, 1, 0), Vector3i(0, 0, 0), 4, granite))
	# Sous-blocs 8 px (2 cellules) en escalier.
	print("[TEST] pose 8px : %s" % WorldManager.set_sub_region(base + Vector3i(0, 1, 0), Vector3i(4, 0, 0), 2, oak))
	# Sous-bloc 4 px (1 cellule).
	print("[TEST] pose 4px : %s" % WorldManager.set_sub_region(base + Vector3i(0, 1, 0), Vector3i(6, 0, 4), 1, granite))
	# Sculpture : creuse un coin 8 px dans le bloc plein.
	print("[TEST] sculpture 8px : %s" % WorldManager.set_sub_region(base, Vector3i(6, 6, 0), 2, 0))
	print("[TEST] grille du bloc sculpté : %d cellules solides" % SubdivGrid.count_solid(WorldManager.subdiv_grid_at(base)))

	# Donjon (E.29 simplifié, 2026-07-21) : trouve une cellule donjon proche,
	# approche son périmètre, vérifie la téléportation aller ET retour.
	var donjon_cell := Vector2i.ZERO
	var donjon_found := false
	for dcx in range(-40, 41):
		if donjon_found:
			break
		for dcz in range(-40, 41):
			var c := Vector2i(dcx, dcz)
			var cwc := POIGenerator.cell_center_world(c)
			var cb: Dictionary = gg.biome_at(cwc.x, cwc.y)
			if not cb.is_empty() and "donjon" in POIGenerator.pois_at_cell(c, WorldManager.world_seed, cb):
				donjon_cell = c
				donjon_found = true
				break
	print("[TEST] donjon trouvé=%s cellule=%s" % [donjon_found, donjon_cell])
	if donjon_found:
		var pre_pos := camera.position
		var cs := ClaimManager.CELL_SIZE
		var edge_x := float(donjon_cell.x * cs)
		var edge_z := float(donjon_cell.y * cs + cs / 2)
		camera.position = Vector3(edge_x, gg.height_at(int(edge_x), int(edge_z)) + 20.0, edge_z)
		# Compte à rebours d'entrée de 3 s (2026-07-21) + écran de chargement.
		await get_tree().create_timer(4.5).timeout
		print("[TEST] donjon entrée : dans_le_donjon=%s (attendu true) pos=%s" % [DungeonManager._in_dungeon, camera.position])
		if DungeonManager._in_dungeon:
			var floor_data: Dictionary = DungeonManager._floors.get(donjon_cell, {})
			print("[TEST] donjon étage : %d salle(s), %d connecteur(s), salle du boss=%d" % [
				floor_data.get("rooms", []).size(), floor_data.get("corridors", []).size(), floor_data.get("boss_room_index", -1)])
			# Capture visuelle de l'intérieur (confirme salles/corridors bien
			# construits en blocs réels, pas seulement les comptes logiques).
			# Attente plus longue que d'habitude : construire un étage entier
			# déclenche des CENTAINES de set_block d'un coup, chacun une
			# requête de remesh urgent asynchrone — la file peut prendre plus
			# de temps à rattraper qu'une mutation isolée (vérifié : les
			# données du monde sont correctes dès l'écriture, block_at_world
			# le confirme immédiatement ; seul l'AFFICHAGE traîne le temps que
			# le mesher rattrape la file).
			camera.rotation_degrees = Vector3(-15.0, 45.0, 0.0)
			await get_tree().create_timer(2.5).timeout
			await RenderingServer.frame_post_draw
			var dungeon_image := get_viewport().get_texture().get_image()
			dungeon_image.save_png(ProjectSettings.globalize_path("res://") + "dungeon_screenshot.png")
			print("[TEST] capture donjon : dungeon_screenshot.png")
			var exit_marker := DungeonManager._exit_marker_position(donjon_cell)
			camera.position = Vector3(exit_marker.x, exit_marker.y + 2.9, exit_marker.z)
			await get_tree().create_timer(1.6).timeout
			print("[TEST] donjon sortie : dans_le_donjon=%s (attendu false)" % DungeonManager._in_dungeon)

	# Boutique passive (7.1/A.8/E.8, GDD étape 9) : pose un étal, met un
	# matériau en vente, force plusieurs heures in-game (push_ticks, pas
	# d'attente réelle), vérifie qu'une vente a eu lieu ET que l'or récolté
	# est bien crédité au joueur.
	var stall_pos := base + Vector3i(2, 0, 2)
	var etal_id: int = GameData.material_runtime_ids["etal_de_vente"]
	WorldManager.set_block(stall_pos, etal_id)
	print("[TEST] étal posé : boutique=%s (attendu true)" % ShopManager.is_stall(stall_pos))
	player.inventory.add_material("pierre", 1)
	var stocked := ShopManager.stock_item(stall_pos, "pierre", player.inventory)
	print("[TEST] étal approvisionné : %s (attendu true)" % stocked)
	TickManager.push_ticks(ShopManager.SALE_INTERVAL_TICKS * 10)  # 10 h in-game d'un coup.
	# Test direct de l'API ShopManager (comme pour stock_item ci-dessus),
	# plutôt que de simuler un vrai visé caméra : la chorégraphie de
	# rotation/raycast pour viser précisément l'étal s'est avérée fragile en
	# test automatisé (la caméra tombe sous la gravité pendant l'attente, le
	# DDA peut alors toucher un autre bloc voisin) — le mécanisme d'interaction
	# clavier (T/G) reste testable manuellement en jeu, ce test-ci vérifie le
	# CŒUR du système (vente + or) indépendamment de la visée.
	var gold_won := ShopManager.collect_gold(stall_pos)
	print("[TEST] boutique : or gagné=%d (attendu > 0)" % gold_won)

	# Menu de triche (F1) : ouverture/fermeture + les 3 actions directes
	# (téléportation biome/POI testée à part car elle déplace le joueur —
	# testée en dernier pour ne pas perturber le reste de la séquence).
	var cheat_menu := get_node("CheatMenu")
	var f1_press := InputEventKey.new()
	f1_press.physical_keycode = KEY_F1
	f1_press.pressed = true
	Input.parse_input_event(f1_press)
	await get_tree().process_frame
	print("[TEST] menu de triche ouvert : %s (attendu true)" % cheat_menu.is_open)
	var icecap: Vector2i = cheat_menu._find_biome_near(int(camera.position.x), int(camera.position.z), "calotte_glaciaire")
	print("[TEST] triche recherche calotte glaciaire : %s (introuvable si (%d,0))" % [icecap, 1 << 30])
	var mats_before: int = player.inventory.material_stacks.size()
	cheat_menu._give_all_materials()
	print("[TEST] triche matériaux : %d types avant, %d après (attendu augmentation)" % [
		mats_before, player.inventory.material_stacks.size()])
	var objects_before: int = player.inventory.objects.size()
	cheat_menu._give_all_items()
	print("[TEST] triche objets : %d avant, %d après (attendu augmentation)" % [
		objects_before, player.inventory.objects.size()])
	var skill_before: int = player.skills.level("minage")
	cheat_menu._max_all_skills()
	print("[TEST] triche compétences : minage %d avant, %d après (attendu augmentation)" % [
		skill_before, player.skills.level("minage")])
	var poi_cell: Vector2i = cheat_menu._find_poi_near(int(camera.position.x), int(camera.position.z), "donjon")
	print("[TEST] triche recherche donjon : cellule trouvée=%s (introuvable si (%d,0))" % [poi_cell, 1 << 30])
	cheat_menu._open()
	await get_tree().create_timer(0.3).timeout
	await RenderingServer.frame_post_draw
	var cheat_image := get_viewport().get_texture().get_image()
	cheat_image.save_png(ProjectSettings.globalize_path("res://") + "cheat_menu_screenshot.png")
	print("[TEST] capture menu de triche : cheat_menu_screenshot.png")
	cheat_menu._close()
	print("[TEST] menu de triche fermé : %s (attendu true)" % (not cheat_menu.is_open))

	# Menu de jeu à onglets (2026-07-21) : ouverture par Tab, inventaire triable
	# (207 matériaux + objets donnés par la triche ci-dessus), navigation entre
	# onglets, capture, fermeture. `player.input_locked` doit basculer.
	var game_menu := get_node("GameMenu")
	var tab_press := InputEventKey.new()
	tab_press.physical_keycode = KEY_TAB
	tab_press.pressed = true
	Input.parse_input_event(tab_press)
	await get_tree().process_frame
	await get_tree().process_frame
	print("[TEST] menu de jeu ouvert : %s joueur_verrouille=%s (attendus true/true)" % [
		game_menu.is_open, player.input_locked])
	game_menu._select_tab("inventaire")
	game_menu._inv_sort_option.selected = 3  # Dureté.
	game_menu._refresh_inventory()
	await get_tree().process_frame
	print("[TEST] onglet inventaire : %d lignes affichées (attendu > 0)" % game_menu._inv_list.get_child_count())
	# Onglet Craft (2026-07-21) : fabrication par recette. Le joueur a tous les
	# matériaux (triche) et compétences maxées → craft d'une épée doit réussir
	# et produire un objet de qualité élevée.
	game_menu._select_tab("craft")
	await get_tree().process_frame
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(
		ProjectSettings.globalize_path("res://") + "game_menu_craft_screenshot.png")
	print("[TEST] onglet craft : %d recette(s) affichée(s)" % game_menu._craft_list.get_child_count())
	var objects_pre_craft: int = player.inventory.objects.size()
	game_menu._craft_choices["epee:bois"] = "chene" if player.inventory.material_stacks.has("chene") else game_menu._owned_of_category("bois")[0]
	game_menu._craft_choices["epee:minerai"] = "fer" if player.inventory.material_stacks.has("fer") else game_menu._owned_of_category("minerai")[0]
	game_menu._do_craft("epee", GameData.items["epee"]["recipe"], "forge")
	await get_tree().process_frame
	var new_sword: Dictionary = player.inventory.objects[player.inventory.objects.size() - 1]
	print("[TEST] craft épée : objets %d→%d qualité=%.2f dureté=%.1f (forge niv %d)" % [
		objects_pre_craft, player.inventory.objects.size(),
		float(new_sword.get("quality", 0.0)), float(new_sword.get("base_hardness", 0.0)),
		player.skills.level("forge")])
	# Fonderie (2026-07-24) : fondre du fer brut → lingot de fer, puis crafter
	# une épée en LINGOT (dureté de base supérieure au minerai brut).
	var fer_before: int = int(player.inventory.material_stacks.get("fer", 0))
	game_menu._do_transform("fonte_fer")
	var lingots: int = int(player.inventory.material_stacks.get("lingot_fer", 0))
	print("[TEST] fonderie : fer %d→%d, lingot_fer=%d (attendu ≥1)" % [
		fer_before, int(player.inventory.material_stacks.get("fer", 0)), lingots])
	game_menu._craft_choices["epee:minerai"] = "lingot_fer"
	game_menu._do_craft("epee", GameData.items["epee"]["recipe"], "forge")
	await get_tree().process_frame
	var lingot_sword: Dictionary = player.inventory.objects[player.inventory.objects.size() - 1]
	print("[TEST] craft épée LINGOT : dureté=%.1f (minerai brut était %.1f — attendu supérieur)" % [
		float(lingot_sword.get("base_hardness", 0.0)), float(new_sword.get("base_hardness", 0.0))])
	game_menu._select_tab("personnage")
	await get_tree().process_frame
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(
		ProjectSettings.globalize_path("res://") + "game_menu_perso_screenshot.png")
	game_menu._select_tab("royaume")
	await get_tree().process_frame
	game_menu._select_tab("monde")
	await get_tree().process_frame
	game_menu._select_tab("inventaire")
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(
		ProjectSettings.globalize_path("res://") + "game_menu_screenshot.png")
	print("[TEST] capture menu de jeu : game_menu_screenshot.png")
	var tab_close := InputEventKey.new()
	tab_close.physical_keycode = KEY_TAB
	tab_close.pressed = true
	Input.parse_input_event(tab_close)
	await get_tree().process_frame
	print("[TEST] menu de jeu fermé : %s joueur_verrouille=%s (attendus false/false)" % [
		not game_menu.is_open, player.input_locked])

	# Laisser le remesh urgent aboutir, cadrer, capturer.
	camera.position = Vector3(base) + Vector3(2.5, 2.5, 3.5)
	camera.look_at(Vector3(base) + Vector3(0.5, 0.5, 0.5))
	await get_tree().create_timer(2.0).timeout
	await RenderingServer.frame_post_draw
	var image := get_viewport().get_texture().get_image()
	var path := ProjectSettings.globalize_path("res://") + "subdiv_screenshot.png"
	image.save_png(path)
	print("[TEST] capture : " + path)
	get_tree().quit(0)


## Sonde headless de génération des minerais (G.9, 2026-07-24) : génère une
## pile de chunks, compte les minerais par profondeur, vérifie que les métaux
## communs sont peu profonds et les gemmes/diamant profonds, et que les filons
## s'adaptent aux montagnes (présents à Y absolu élevé sous un sommet).
func _ore_probe() -> void:
	await get_tree().process_frame
	var g := WorldManager.generator
	# Ensemble des ids de minerai (catégories minerai/mineral/cristal/fossile).
	var ore_ids := {}
	for id: String in GameData.materials:
		if GameData.materials[id]["category"] in ["minerai", "mineral", "cristal", "fossile"]:
			ore_ids[int(GameData.material_runtime_ids[id])] = id
	# Scan d'une pile de chunks sur une colonne plate.
	var col := Vector2i(0, 0)
	var ctx := g.prepare_context(col)
	var h0: int = g.height_at(8, 8)
	var by_depth := {}      # bucket de 40 → nb minerais
	var total_rock := 0
	var total_ore := 0
	var shallow_mats := {}  # depth < 55
	var deep_mats := {}     # depth > 280
	for cy in range(floori(float(h0) / 16.0), -25, -1):
		var data := g.generate_chunk(Vector3i(0, cy, 0), ctx)
		if data.is_uniform():
			continue
		for ly in 16:
			for lz in 16:
				for lx in 16:
					var wy := cy * 16 + ly
					var depth := h0 - wy
					if depth < 5:
						continue
					var bid := data.get_block(lx, ly, lz)
					if bid == 0:
						continue
					total_rock += 1
					if ore_ids.has(bid):
						total_ore += 1
						var bucket := (depth / 40) * 40
						by_depth[bucket] = int(by_depth.get(bucket, 0)) + 1
						if depth < 55:
							shallow_mats[ore_ids[bid]] = true
						elif depth > 280:
							deep_mats[ore_ids[bid]] = true
	print("[OREPROBE] surface h=%d · blocs solides=%d · minerais=%d (%.1f%%)" % [
		h0, total_rock, total_ore, 100.0 * total_ore / maxi(total_rock, 1)])
	var buckets: Array = by_depth.keys()
	buckets.sort()
	for b in buckets:
		print("[OREPROBE]   profondeur %d-%d : %d filons" % [b, b + 40, by_depth[b]])
	print("[OREPROBE] peu profond (<55) : %s" % [shallow_mats.keys()])
	print("[OREPROBE] profond (>280) : %s" % [deep_mats.keys()])
	# Diamant ne doit JAMAIS apparaître peu profond.
	var diamant_shallow := "diamant" in shallow_mats or "tungstene" in shallow_mats
	# Cuivre/étain/fer doivent apparaître dans les couches supérieures.
	var common_shallow := shallow_mats.size() > 0

	# Adaptation aux montagnes : trouver un sommet (surface haute) et vérifier
	# qu'un filon existe à Y absolu élevé (= profondeur normale sous CE sommet).
	var peak := Vector2i.ZERO
	var peak_h := -9999
	for gx in range(-40, 41, 4):
		for gz in range(-40, 41, 4):
			var hh := g.height_at(gx * 16, gz * 16)
			if hh > peak_h:
				peak_h = hh
				peak = Vector2i(gx * 16, gz * 16)
	var mountain_ore := false
	var mountain_ore_y := 0
	# Cherche un minerai entre 20 et 120 sous le sommet (Y absolu élevé).
	for d in range(20, 121):
		var wy := peak_h - d
		var b := g.block_at(peak.x, wy, peak.y)
		if ore_ids.has(b):
			mountain_ore = true
			mountain_ore_y = wy
			break
	print("[OREPROBE] sommet à %s h=%d : filon adapté à Y=%d (%s)" % [peak, peak_h, mountain_ore_y, mountain_ore])

	var ok: bool = total_ore > 0 and common_shallow and not diamant_shallow \
		and 0.3 < (100.0 * total_ore / maxi(total_rock, 1)) and (100.0 * total_ore / maxi(total_rock, 1)) < 12.0 \
		and mountain_ore and mountain_ore_y > 60
	print("[OREPROBE] RÉSULTAT : %s" % ("OK" if ok else "ÉCHEC"))
	get_tree().quit(0 if ok else 1)


## Capture souterraine (fenêtré, --test-ore) : trouve un filon, creuse une
## salle autour pour l'exposer, et capture — pour vérifier que le minerai se
## fond dans sa ROCHE hôte (masque de pépites, 2026-07-24).
func _ore_visual() -> void:
	await get_tree().process_frame
	camera.input_locked = true
	$Player.input_locked = true
	var g := WorldManager.generator
	var ore_ids := {}
	for mid: String in GameData.materials:
		if GameData.materials[mid]["category"] in ["minerai", "mineral", "cristal", "fossile"]:
			ore_ids[int(GameData.material_runtime_ids[mid])] = true
	# Cherche un bloc de minerai à profondeur moyenne autour de l'origine.
	var found := Vector3i.ZERO
	var ok := false
	for cx in range(0, 60):
		if ok:
			break
		for cz in range(0, 60):
			var h := g.height_at(cx, cz)
			for d in range(40, 160):
				var wy := h - d
				if ore_ids.has(g.block_at(cx, wy, cz)):
					found = Vector3i(cx, wy, cz)
					ok = true
					break
			if ok:
				break
	print("[OREVIS] filon trouvé=%s à %s (%s)" % [ok, found, GameData.material_by_runtime[g.block_at(found.x, found.y, found.z)] if ok else "-"])
	if not ok:
		get_tree().quit(1)
		return
	# Creuse une salle autour du filon pour l'exposer.
	for dx in range(-4, 5):
		for dy in range(-3, 4):
			for dz in range(-4, 5):
				if dx * dx + dz * dz <= 20:
					WorldManager.set_block(found + Vector3i(dx, dy, dz), 0)
	camera.position = Vector3(found.x + 0.5, found.y + 1.0, found.z - 5.0)
	camera.look_at(Vector3(found.x + 0.5, found.y + 0.5, found.z + 4.0), Vector3.UP)
	WorldManager.update_center(camera.position)
	await get_tree().create_timer(3.5).timeout
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(
		ProjectSettings.globalize_path("res://") + "ore_visual.png")
	print("[OREVIS] capture : ore_visual.png")
	get_tree().quit(0)


## Vitrine des textures procédurales (fenêtré, --test-textures) : pose un mur
## d'échantillons (bois, minerai, lingot, gemme, roche, sable, eau) et capture,
## pour juger chaque matériau au 32px/face (réécriture 2026-07-24).
func _texture_showcase() -> void:
	await get_tree().process_frame
	camera.input_locked = true
	$Player.input_locked = true
	# Matériaux montrés, colonne par colonne (chacun 2 blocs de haut).
	var samples := ["chene", "acajou", "fer", "etain", "or", "lingot_fer", "lingot_or",
		"diamant", "emeraude", "pierre", "granit", "gres", "terre", "brique", "eau"]
	var g := WorldManager.generator
	var base_h := g.height_at(0, 0) + 30  # Bien au-dessus du sol, sur une plateforme neuve.
	# Plateforme de pierre + colonnes d'échantillons devant.
	for i in samples.size():
		var mid: int = GameData.material_runtime_ids.get(samples[i], 0)
		if mid == 0:
			continue
		var wx := i * 2
		for hy in 3:
			WorldManager.set_block(Vector3i(wx, base_h + hy, 0), mid)
			WorldManager.set_block(Vector3i(wx + 1, base_h + hy, 0), mid)
	# Caméra face au mur.
	var center_x := samples.size()  # ~milieu
	camera.position = Vector3(center_x, base_h + 2.0, 14.0)
	camera.look_at(Vector3(center_x, base_h + 1.5, 0.0), Vector3.UP)
	WorldManager.update_center(camera.position)
	await get_tree().create_timer(3.0).timeout
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(
		ProjectSettings.globalize_path("res://") + "textures_screenshot.png")
	print("[TEXCAP] vitrine capturée : textures_screenshot.png (%d échantillons)" % samples.size())
	# Zoom rapproché sur les 4 premiers (bois + minerais) pour le détail.
	camera.position = Vector3(2.0, base_h + 1.5, 5.0)
	camera.look_at(Vector3(2.0, base_h + 1.0, 0.0), Vector3.UP)
	await get_tree().create_timer(1.0).timeout
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(
		ProjectSettings.globalize_path("res://") + "textures_closeup.png")
	print("[TEXCAP] gros plan capturé : textures_closeup.png")
	get_tree().quit(0)


## Capture visuelle d'un village (fenêtré, --test-city) : survol en oblique,
## laisse les chunks se streamer, capture. Mesure aussi le fps statique
## au-dessus de la ville (perf de la génération de villes).
func _city_capture() -> void:
	await get_tree().process_frame
	var g := WorldManager.generator
	var found := Vector2i.ZERO
	var layout := {}
	# Cherche de préférence un village plus grand (T=5, plus lisible en photo).
	for cx in range(-60, 61):
		if int(layout.get("T", 0)) >= 5:
			break
		for cz in range(-60, 61):
			var l := g.city_at_cell(Vector2i(cx, cz))
			if not l.is_empty() and (layout.is_empty() or int(l["T"]) > int(layout["T"])):
				found = Vector2i(cx, cz)
				layout = l
				if int(l["T"]) >= 5:
					break
	if layout.is_empty():
		print("[CITYCAP] aucun village trouvé")
		get_tree().quit(1)
		return
	var wx := found.x * 128 + 64
	var wz := found.y * 128 + 64
	var plateau: int = layout["plateau_y"]
	print("[CITYCAP] village cellule=%s T=%d bâtiments=%d, survol pour capture" % [found, layout["T"], layout["buildings"]])
	camera.input_locked = true
	$Player.input_locked = true
	camera.position = Vector3(wx - 34, plateau + 26, wz - 34)
	camera.look_at(Vector3(wx, plateau + 2, wz), Vector3.UP)
	WorldManager.update_center(camera.position)
	# Laisser le streaming se déclencher PUIS se vider (attente minimale + file).
	await get_tree().create_timer(1.5).timeout
	var waited := 1.5
	while int(WorldManager.stats()["queue"]) > 0 and waited < 25.0:
		await get_tree().process_frame
		waited += get_process_delta_time()
	await get_tree().create_timer(1.0).timeout
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(
		ProjectSettings.globalize_path("res://") + "city_screenshot.png")
	print("[CITYCAP] capture : city_screenshot.png (streaming en %.1f s)" % waited)
	get_tree().quit(0)


## Sonde headless de génération de villes (point 5, 2026-07-21) : trouve une
## cellule avec un village CONSTRUCTIBLE, vérifie le plan (routes croix + ≥2
## sorties, bâtiments = population), le terrassement (footprint aplati au
## plateau) et les blocs réels (route en gravier, murs de bâtiment posés).
func _city_probe() -> void:
	await get_tree().process_frame
	var g := WorldManager.generator
	var found_cell := Vector2i.ZERO
	var layout := {}
	for cx in range(-60, 61):
		if not layout.is_empty():
			break
		for cz in range(-60, 61):
			var l := g.city_at_cell(Vector2i(cx, cz))
			if not l.is_empty():
				found_cell = Vector2i(cx, cz)
				layout = l
				break
	print("[CITYPROBE] village constructible trouvé=%s cellule=%s" % [not layout.is_empty(), found_cell])
	if layout.is_empty():
		get_tree().quit(1)
		return
	var t: int = layout["T"]
	var types: PackedByteArray = layout["types"]
	var roads := 0
	var buildings := 0
	for v in types:
		if v == 1:
			roads += 1
		elif v == 2:
			buildings += 1
	# Sorties = tuiles route sur le bord du footprint (la croix en donne 4).
	var exits := 0
	for k in t:
		if types[0 * t + k] == 1 or types[(t - 1) * t + k] == 1:
			exits += 1
		if types[k * t + 0] == 1 or types[k * t + (t - 1)] == 1:
			exits += 1
	print("[CITYPROBE] T=%d routes=%d bâtiments=%d population=%d sorties=%d (attendu ≥2)" % [
		t, roads, buildings, layout["population"], exits])

	# Terrassement : une colonne du footprint doit être aplatie au plateau.
	var cell: Vector2i = layout["cell"]
	var offset: int = layout["offset"]
	var plateau: int = layout["plateau_y"]
	var footprint_wx := cell.x * 128 + offset * 16 + 8
	var footprint_wz := cell.y * 128 + offset * 16 + 8
	var surf := g.sample_surface(footprint_wx, footprint_wz)
	print("[CITYPROBE] terrassement : h=%d (attendu plateau=%d)" % [surf["h"], plateau])

	# Un bloc de route et un mur de bâtiment doivent exister au monde.
	var road_ok := false
	var wall_ok := false
	var gravier: int = GameData.material_runtime_ids.get("gravier", -1)
	for tz in t:
		for tx in t:
			var idx := tz * t + tx
			var wx := cell.x * 128 + (offset + tx) * 16 + 8
			var wz := cell.y * 128 + (offset + tz) * 16 + 8
			if types[idx] == 1 and g.block_at(wx, plateau, wz) == gravier:
				road_ok = true
			if types[idx] == 2:
				# Un coin de la boîte du bâtiment (mur `mur` de la palette) à plateau+1.
				var bwx := cell.x * 128 + (offset + tx) * 16 + CityGenerator.B_LO
				var bwz := cell.y * 128 + (offset + tz) * 16 + CityGenerator.B_LO
				if g.block_at(bwx, plateau + 1, bwz) == int((layout["palette"] as Dictionary)["mur"]):
					wall_ok = true
	print("[CITYPROBE] route posée=%s mur de bâtiment posé=%s" % [road_ok, wall_ok])

	var ok: bool = t >= 3 and roads > 0 and buildings > 0 and exits >= 2 \
		and surf["h"] == plateau and road_ok and wall_ok
	print("[CITYPROBE] RÉSULTAT : %s" % ("OK" if ok else "ÉCHEC"))
	get_tree().quit(0 if ok else 1)


## Sonde headless des paramètres de monde (2026-07-21, menu nouvelle partie) :
## un monde « plat + tout désert + sans rivières/cavernes » doit réellement
## l'être, comparé à un monde aux paramètres par défaut sur la même graine.
## Sonde du terrain fini/varié (--probe-terrain, headless) : échantillonne une
## grille sur toute l'étendue du monde et rapporte la distribution océan/plaines/
## collines/montagnes + vérifie que le bord du monde est bien de l'océan.
func _terrain_probe() -> void:
	var g := NoiseGenerator.new(4242, {})
	var wl := g.water_level
	var r := g.world_radius
	var ocean := 0
	var plaine := 0
	var colline := 0
	var montagne := 0
	var total := 0
	var hmin := 1 << 30
	var hmax := -(1 << 30)
	var step := 300
	for wz in range(-r, r + 1, step):
		for wx in range(-r, r + 1, step):
			var h := g.height_at(wx, wz)
			total += 1
			hmin = mini(hmin, h)
			hmax = maxi(hmax, h)
			if h < wl:
				ocean += 1
			elif h < wl + 30:
				plaine += 1
			elif h < wl + 90:
				colline += 1
			else:
				montagne += 1
	# Fertilité sur les terres émergées : doit VARIER (prospection).
	var fmin := 2.0
	var fmax := -1.0
	var fsum := 0.0
	var fn := 0
	for wz in range(-r, r + 1, step):
		for wx in range(-r, r + 1, step):
			if g.height_at(wx, wz) >= wl:
				var f := g.fertility_at(wx, wz)
				fmin = minf(fmin, f)
				fmax = maxf(fmax, f)
				fsum += f
				fn += 1
	var fmean := 0.0 if fn == 0 else fsum / float(fn)
	print("[TERRAIN] fertilité terre : min=%.2f moy=%.2f max=%.2f (doit varier)" % [fmin, fmean, fmax])
	# Couverture des biomes (item : tous les biomes présents dans chaque monde).
	var biome_tally := {}
	for wz in range(-r, r + 1, step):
		for wx in range(-r, r + 1, step):
			var bid: String = g.biome_at(wx, wz).get("id", "")
			if bid != "":
				biome_tally[bid] = int(biome_tally.get(bid, 0)) + 1
	var missing: Array[String] = []
	var overworld_count := 0
	for bid: String in GameData.biomes.keys():
		if String(GameData.biomes[bid].get("dimension", "overworld")) != "overworld":
			continue
		overworld_count += 1
		if not biome_tally.has(bid):
			missing.append(bid)
	print("[BIOMES] présents=%d/%d overworld manquants=%s" % [biome_tally.size(), overworld_count, missing])
	# Garantie « tous les biomes dans CHAQUE monde » : test multi-graines (grille
	# grossière) — chaque graine doit couvrir tous les biomes overworld.
	for test_seed in [1, 7, 42, 1337, 99999]:
		var gs := NoiseGenerator.new(test_seed, {})
		var seen := {}
		for wz in range(-gs.world_radius, gs.world_radius + 1, 600):
			for wx in range(-gs.world_radius, gs.world_radius + 1, 600):
				var bid: String = gs.biome_at(wx, wz).get("id", "")
				if bid != "":
					seen[bid] = true
		var miss: Array[String] = []
		for bid: String in GameData.biomes.keys():
			if String(GameData.biomes[bid].get("dimension", "overworld")) == "overworld" and not seen.has(bid):
				miss.append(bid)
		print("[BIOMES] graine %d : %d biomes, manquants=%s" % [test_seed, seen.size(), miss])
	var pct := func(n: int) -> float: return 100.0 * float(n) / float(total)
	# Bord extérieur : 24 points sur le cercle de rayon = world_radius + marge.
	var edge_ocean := 0
	for i in 24:
		var a := TAU * float(i) / 24.0
		var ex := int(cos(a) * (r + 400))
		var ez := int(sin(a) * (r + 400))
		if g.height_at(ex, ez) < wl:
			edge_ocean += 1
	# Noms générés (monde / continents / océans).
	print("[NOMS] monde=« %s »" % g.world_name())
	var regions := g.detect_regions(96)
	var conts: Array = regions["continents"]
	var ocs: Array = regions["oceans"]
	print("[NOMS] %d continents : %s" % [conts.size(), conts.map(func(c): return c["name"])])
	print("[NOMS] %d océans/mers : %s" % [ocs.size(), ocs.map(func(o): return o["name"])])
	var land_spawn := g.find_land_spawn(0, 0)
	var pc := g.preview_color(land_spawn.x, land_spawn.y)
	print("[TERRAIN] spawn terre=%s couleur_aperçu=(%.2f,%.2f,%.2f)" % [land_spawn, pc.r, pc.g, pc.b])
	# Rend l'aperçu du monde complet en PNG (vérification visuelle headless).
	var n := 192
	var img := Image.create(n, n, false, Image.FORMAT_RGB8)
	var pspan := 2.0 * float(r) / float(n)
	for py in n:
		for px in n:
			img.set_pixelv(Vector2i(px, py), g.preview_color(int(-r + px * pspan), int(-r + py * pspan)))
	img.save_png("user://terrain_preview.png")
	print("[TERRAIN] aperçu sauvé : user://terrain_preview.png")
	print("[TERRAIN] rayon=%d niveau_mer=%d échantillons=%d h∈[%d,%d]" % [r, wl, total, hmin, hmax])
	print("[TERRAIN] océan=%.1f%% plaine=%.1f%% colline=%.1f%% montagne=%.1f%%" % [
		pct.call(ocean), pct.call(plaine), pct.call(colline), pct.call(montagne)])
	print("[TERRAIN] bord océanique : %d/24 points sous le niveau de la mer (attendu 24)" % edge_ocean)
	# Critères : océan présent mais pas majoritaire absurde, plaines dominent la
	# terre (biais plaines), montagnes rares, bord entièrement noyé.
	var land := plaine + colline + montagne
	var plaine_share := 0.0 if land == 0 else float(plaine) / float(land)
	var mtn_share := 0.0 if land == 0 else float(montagne) / float(land)
	var ok: bool = edge_ocean == 24 and ocean > 0 and plaine_share > 0.4 and mtn_share < 0.22
	print("[TERRAIN] biais plaines=%.2f montagnes=%.2f RÉSULTAT : %s" % [
		plaine_share, mtn_share, "OK" if ok else "ÉCHEC"])
	# Bandes climatiques par latitude (style Terre) : biome dominant sur terre
	# à chaque latitude, de l'équateur (centre) au pôle (bord).
	for lat in [0.0, 0.15, 0.3, 0.45, 0.6, 0.75, 0.9]:
		var fz := int(lat * r)
		var tally := {}
		var found := 0
		for wx in range(-r, r + 1, step):
			if g.height_at(wx, fz) >= wl:
				var bid: String = g.biome_at(wx, fz).get("id", "?")
				tally[bid] = int(tally.get(bid, 0)) + 1
				found += 1
		var dom := "(océan)"
		var best := 0
		for k: String in tally:
			if tally[k] > best:
				best = tally[k]
				dom = k
		print("[CLIMAT] lat %.2f (fz=%d) : %s (%d/%d terres)" % [lat, fz, dom, best, found])
	get_tree().quit(0 if ok else 1)


func _params_probe() -> void:
	var flat := NoiseGenerator.new(4242, {"relief": 0.05, "biome_force": "desert_aride",
		"rivieres": false, "cavernes": false, "arbres": 0.0, "niveau_mer": -8})
	var normal := NoiseGenerator.new(4242, {})
	var flat_min := 1 << 30
	var flat_max := -(1 << 30)
	var normal_min := 1 << 30
	var normal_max := -(1 << 30)
	var desert_ok := true
	for gz in range(-40, 41, 8):
		for gx in range(-40, 41, 8):
			var wx := gx * 32
			var wz := gz * 32
			flat_min = mini(flat_min, flat.height_at(wx, wz))
			flat_max = maxi(flat_max, flat.height_at(wx, wz))
			normal_min = mini(normal_min, normal.height_at(wx, wz))
			normal_max = maxi(normal_max, normal.height_at(wx, wz))
			if flat.biome_at(wx, wz).get("id", "") != "desert_aride":
				desert_ok = false
	var flat_span := flat_max - flat_min
	var normal_span := normal_max - normal_min
	var rivers: Array = flat.rivers_near(-500, 500, -500, 500)
	print("[PARAMS] relief plat : h ∈ [%d, %d] (étendue %d) · normal : [%d, %d] (étendue %d)" % [
		flat_min, flat_max, flat_span, normal_min, normal_max, normal_span])
	print("[PARAMS] désert partout=%s (attendu true) · rivières=%d (attendu 0) · mer=%d (attendu -6)" % [
		desert_ok, rivers.size(), flat.water_level])
	var ok: bool = flat_span < maxi(int(normal_span * 0.15), 4) and normal_span > 30 \
		and desert_ok and rivers.is_empty() and flat.water_level == -6
	print("[PARAMS] RÉSULTAT : %s" % ("OK" if ok else "ÉCHEC"))
	get_tree().quit(0 if ok else 1)


## Sonde donjon headless (2026-07-21, dimension séparée) : trouve une cellule
## donjon, s'approche (compte à rebours 3 s + écran de chargement), vérifie
## l'entrée en dimension, le sol réel, le boss, mine un bloc (diff persistant),
## sort par le marqueur, vérifie le retour overworld. Aucune capture d'écran :
## sûre en --headless (contrairement à --test-input).
func _dungeon_probe() -> void:
	await get_tree().process_frame
	var gg := WorldManager.generator
	var donjon_cell := Vector2i.ZERO
	var found := false
	for dcx in range(-40, 41):
		if found:
			break
		for dcz in range(-40, 41):
			var c := Vector2i(dcx, dcz)
			var cwc := POIGenerator.cell_center_world(c)
			var cb: Dictionary = gg.biome_at(cwc.x, cwc.y)
			if not cb.is_empty() and "donjon" in POIGenerator.pois_at_cell(c, WorldManager.world_seed, cb):
				donjon_cell = c
				found = true
				break
	print("[DONJONPROBE] cellule trouvée=%s %s" % [found, donjon_cell])
	if not found:
		get_tree().quit(1)
		return
	var cs := ClaimManager.CELL_SIZE
	var edge_x := float(donjon_cell.x * cs)
	var edge_z := float(donjon_cell.y * cs + cs / 2)
	camera.position = Vector3(edge_x, gg.height_at(int(edge_x), int(edge_z)) + 20.0, edge_z)
	await get_tree().create_timer(4.5).timeout  # Compte à rebours 3 s + chargement.
	var entered: bool = DungeonManager._in_dungeon
	var dim_ok: bool = WorldManager.active_dimension == &"donjon"
	print("[DONJONPROBE] entré=%s (attendu true) dimension=%s (attendu donjon)" % [entered, WorldManager.active_dimension])
	if not entered:
		get_tree().quit(1)
		return
	var feet := camera.global_position - Vector3(0, 1.9, 0)  # EYE_HEIGHT — feet_y = sommet du bloc de sol.
	var floor_pos := Vector3i(floori(feet.x), floori(feet.y + 0.001) - 1, floori(feet.z))
	var floor_id := WorldManager.block_at_world(floor_pos)
	var boss_count := 0
	for c in CreatureManager.creatures:
		if is_instance_valid(c) and c.dimension == &"donjon":
			boss_count += 1
	print("[DONJONPROBE] sol=%d (attendu != 0) boss=%d (attendu 1)" % [floor_id, boss_count])
	# Histogramme des ids matériau émis dans le mesh du chunk d'entrée (debug
	# rendu : un id inattendu ici = bug de meshing, pas de shader).
	var entry_mesh: MeshInstance3D = DungeonManager._dungeon_meshes.get(Vector3i.ZERO)
	if entry_mesh != null:
		var arrays: Array = entry_mesh.mesh.surface_get_arrays(0)
		var uvs: PackedVector2Array = arrays[Mesh.ARRAY_TEX_UV]
		var histo := {}
		for uv in uvs:
			var mid := int(round(uv.x))
			histo[mid] = int(histo.get(mid, 0)) + 1
		var named := {}
		for mid: int in histo:
			var mat_name: String = GameData.material_by_runtime[mid] if mid < GameData.material_by_runtime.size() else "?%d" % mid
			named[mat_name] = histo[mid]
		print("[DONJONPROBE] ids dans le mesh d'entrée : %s" % [named])
	var mined := WorldManager.set_block(floor_pos, 0)
	var mined_read := WorldManager.block_at_world(floor_pos)
	var edits: Dictionary = DungeonManager.save_state().get("edits", {})
	print("[DONJONPROBE] minage=%s relu=%d (attendu 0) diff_cellules=%d (attendu 1)" % [mined, mined_read, edits.size()])
	var exit_marker := DungeonManager._exit_marker_position(donjon_cell)
	camera.position = Vector3(exit_marker.x, exit_marker.y + 2.9, exit_marker.z)
	await get_tree().create_timer(1.8).timeout
	var back: bool = not DungeonManager._in_dungeon and WorldManager.active_dimension == &"overworld"
	print("[DONJONPROBE] retour overworld=%s (attendu true)" % back)
	var ok: bool = entered and dim_ok and floor_id != 0 and boss_count == 1 \
		and mined and mined_read == 0 and edits.size() == 1 and back
	print("[DONJONPROBE] RÉSULTAT : %s" % ("OK" if ok else "ÉCHEC"))
	get_tree().quit(0 if ok else 1)


## Sonde de sauvegarde E.10, phase 1 (écriture) — à lancer avec
## `--save-dir <dossier de test>` pour ne jamais toucher la vraie sauvegarde.
## Mute le monde (bloc, sous-grille), claim, XP, or, ticks, puis sauvegarde
## SYNCHRONE et quitte. La phase 2 (--probe-save-verify, processus séparé)
## relit tout et compare.
func _save_probe() -> void:
	await get_tree().process_frame
	var g := WorldManager.generator
	var player := $Player
	var h := g.height_at(10, 10)
	print("[SAVEPROBE] écriture dans : %s" % SaveManager.save_dir)
	# Mutations du monde : un bloc cassé, un bloc posé, une sous-grille.
	var granit: int = GameData.material_runtime_ids["granit"]
	print("[SAVEPROBE] casse (10,%d,10) : %s" % [h, WorldManager.set_block(Vector3i(10, h, 10), 0)])
	print("[SAVEPROBE] pose granit (10,%d,10) : %s" % [h + 3, WorldManager.set_block(Vector3i(10, h + 3, 10), granit)])
	print("[SAVEPROBE] sous-grille 8px : %s" % WorldManager.set_sub_region(Vector3i(12, h + 1, 10), Vector3i(0, 0, 0), 2, granit))
	# État de jeu : claim + rôle, XP, or, inventaire, temps.
	var cell := ClaimManager.cell_of_block(10, 10)
	print("[SAVEPROBE] claim %s : %s, rôle après cycle : %s" % [cell, ClaimManager.claim(cell), ClaimManager.cycle_role(cell)])
	player.skills.gain_xp("minage", 500.0)
	player.gold = 42
	player.inventory.add_material("pierre", 7)
	TickManager.push_ticks(123)
	print("[SAVEPROBE] minage=%d or=%d pierre=%d ticks=%d" % [
		player.skills.level("minage"), player.gold,
		player.inventory.material_stacks.get("pierre", 0), TickManager.tick_index])
	SaveManager.save_now(true)
	print("[SAVEPROBE] sauvegarde synchrone écrite.")
	get_tree().quit(0)


## Sonde de sauvegarde E.10, phase 2 (relecture dans un processus neuf).
func _save_probe_verify() -> void:
	# L'état différé (SaveManager._apply_state) s'applique après _ready.
	await get_tree().process_frame
	await get_tree().process_frame
	var g := WorldManager.generator
	var player := $Player
	var h := g.height_at(10, 10)
	var granit: int = GameData.material_runtime_ids["granit"]
	var broken := WorldManager.block_at_world(Vector3i(10, h, 10))
	var placed := WorldManager.block_at_world(Vector3i(10, h + 3, 10))
	# La sous-grille vit dans le DIFF restauré (le chunk n'est pas encore en
	# cache au démarrage — subdiv_grid_at ne verrait rien) : lecture directe.
	var sub_pos := Vector3i(12, h + 1, 10)
	var sck := Vector3i(sub_pos.x >> 4, sub_pos.y >> 4, sub_pos.z >> 4)
	var sindex := (sub_pos.x & 15) | ((sub_pos.z & 15) << 4) | ((sub_pos.y & 15) << 8)
	var grid: PackedInt32Array = (WorldManager.sub_edits_for_save().get(sck, {}) as Dictionary).get(sindex, PackedInt32Array())
	var solid := SubdivGrid.count_solid(grid) if grid.size() == SubdivGrid.CELLS else -1
	var cell := ClaimManager.cell_of_block(10, 10)
	print("[SAVEVERIFY] bloc cassé=%d (attendu 0) posé=%d (attendu %d = granit)" % [broken, placed, granit])
	print("[SAVEVERIFY] sous-grille restaurée : %d cellules pleines (attendu 8)" % solid)
	print("[SAVEVERIFY] claim %s rôle=%s (attendu habitation)" % [cell, ClaimManager.role_of(cell)])
	print("[SAVEVERIFY] minage=%d (attendu >= 1) or=%d (attendu 42) pierre=%d (attendu 7)" % [
		player.skills.level("minage"), player.gold, player.inventory.material_stacks.get("pierre", 0)])
	print("[SAVEVERIFY] ticks=%d (attendu >= 123)" % TickManager.tick_index)
	var ok: bool = broken == 0 and placed == granit and solid == 8 \
		and ClaimManager.role_of(cell) == "habitation" and player.gold == 42 \
		and player.skills.level("minage") >= 1 \
		and int(player.inventory.material_stacks.get("pierre", 0)) == 7 \
		and TickManager.tick_index >= 123
	print("[SAVEVERIFY] RÉSULTAT : %s" % ("OK" if ok else "ÉCHEC"))
	get_tree().quit(0 if ok else 1)


## Sonde de diagnostic headless : inspecte générateur → chunk → mesher.
## Critère G.8 étape 8 : mutation visible < 100 ms chez l'autre joueur, testé
## en LAN (2 processus Godot sur la même machine = mêmes conditions réseau
## qu'un vrai LAN local ; à revalider sur 2 machines physiques si possible).
## Mesure sur UNE SEULE horloge (celle du client) pour éviter tout problème
## de synchronisation d'horloges entre processus : t0 = juste avant la
## requête de mutation, t1 = réception de la confirmation autoritaire du
## host via EventBus (E.12) — exactement le trajet qu'un joueur perçoit.
func _network_bench_client() -> void:
	print("[NETBENCH] client : attente de connexion au host...")
	if not NetworkManager.is_multiplayer_active():
		print("[NETBENCH] ERREUR : --join non fourni ou échec de connexion.")
		get_tree().quit(1)
		return
	var waited := 0.0
	while multiplayer.multiplayer_peer.get_connection_status() != MultiplayerPeer.CONNECTION_CONNECTED:
		if waited >= 10.0:
			print("[NETBENCH] ÉCHEC : statut de connexion bloqué à %d après 10 s." % multiplayer.multiplayer_peer.get_connection_status())
			get_tree().quit(1)
			return
		await get_tree().create_timer(0.25).timeout
		waited += 0.25
		print("[NETBENCH] statut=%d (attente %.2f s)" % [multiplayer.multiplayer_peer.get_connection_status(), waited])
	print("[NETBENCH] connecté au host.")
	await get_tree().create_timer(1.0).timeout  # Laisser le monde local se streamer.

	var target := Vector3i(_start_pos.x, WorldManager.generator.height_at(_start_pos.x, _start_pos.y) + 5, _start_pos.y)
	var granite: int = GameData.material_runtime_ids["granit"]
	var t0 := Time.get_ticks_usec()
	# Dictionnaire = type référence : les booléens/nombres capturés dans une
	# lambda GDScript le sont PAR VALEUR (copie figée à la création), jamais
	# par référence — un piège si le code appelant relit la variable après.
	var state := {"confirmed": false}

	var on_placed := func(pos: Vector3i, material_id: int) -> void:
		if pos == target and material_id == granite and not state["confirmed"]:
			state["confirmed"] = true
			var elapsed_ms := (Time.get_ticks_usec() - t0) / 1000.0
			print("[NETBENCH] mutation confirmée par le host en %.1f ms (critère G.8 : < 100 ms)" % elapsed_ms)
	EventBus.block_placed.connect(on_placed)

	WorldManager.set_block(target, granite)  # Requête (client → host, RPC fiable, E.11).
	await get_tree().create_timer(2.0).timeout
	if not state["confirmed"]:
		print("[NETBENCH] ÉCHEC : aucune confirmation reçue sous 2 s.")
		get_tree().quit(1)
		return
	get_tree().quit(0)


func _diagnostic_probe() -> void:
	var g := WorldManager.generator
	for col: Vector2i in [Vector2i(0, 0), Vector2i(0, -30), Vector2i(0, -60), Vector2i(0, -120)]:
		var ctx := g.prepare_context(col)
		var rng := g.cy_range(col)
		print("[PROBE] col=%s hmin=%d hmax=%d plage_approx=%s" % [col, ctx["hmin"], ctx["hmax"], rng])
		for cy in range(rng.x, rng.y + 1):
			var key := Vector3i(col.x, cy, col.y)
			var data := g.generate_chunk(key, ctx)
			var uniform := data.is_uniform()
			var arrays: Array = []
			if not (uniform and data.uniform_id == 0):
				arrays = ChunkMesher.mesh_chunk(key, data, g, ctx)
			var vertex_count: int = 0 if arrays.is_empty() else (arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array).size()
			print("[PROBE]   cy=%d uniforme=%s id_u=%d sommets=%d" % [cy, uniform, data.uniform_id, vertex_count])
	var h0 := g.height_at(0, 0)
	print("[PROBE] hauteur(0,0)=%d bloc(0,h,0)=%d bloc(0,h+1,0)=%d bloc(0,h-5,0)=%d" % [
		h0, g.block_at(0, h0, 0), g.block_at(0, h0 + 1, 0), g.block_at(0, h0 - 5, 0)])
	# Test de mutation bout-en-bout (set_block → diff → remesh urgent).
	var target := Vector3i(0, h0, 0)
	var before := WorldManager.block_at_world(target)
	var ok := WorldManager.set_block(target, 0)
	var after := WorldManager.block_at_world(target)
	print("[PROBE] mutation : avant=%d ok=%s après=%d (attendu 0)" % [before, ok, after])
	# Relevé du relief et des biomes sur ±6400 blocs.
	var peak := 0
	var peak_pos := Vector2i.ZERO
	var counts := {}
	for gz in range(-100, 101, 4):
		for gx in range(-100, 101, 4):
			var hh := g.height_at(gx * 64, gz * 64)
			if hh > peak:
				peak = hh
				peak_pos = Vector2i(gx * 64, gz * 64)
			var b := g.biome_at(gx * 64, gz * 64)
			var biome_id: String = b.get("id", "?")
			counts[biome_id] = int(counts.get(biome_id, 0)) + 1
	print("[PROBE] pic=%d à %s ; répartition biomes (échantillon 2601 colonnes) : %s" % [peak, peak_pos, counts])

	# Vérification DÉDIÉE de la calotte glaciaire (2026-07-21, retour
	# utilisateur : « pas de biome glaciaire trouvé ») : le scan ±6400 blocs
	# ci-dessus ne peut JAMAIS l'atteindre (elle n'existe qu'au voisinage des
	# "pôles" climatiques, à ±LATITUDE_HALF_PERIOD=12000 blocs de l'équateur,
	# NoiseGenerator) — ce test balaie explicitement une pleine période de
	# latitude pour confirmer qu'elle est bien GÉNÉRÉE au moins quelque part,
	# indépendamment du rayon de recherche du menu de triche (question
	# distincte : la génération existe-t-elle, ou seulement la recherche
	# était-elle trop courte ?).
	var icecap_found := false
	var icecap_pos := Vector2i.ZERO
	for gz2 in range(-13000, 13001, 200):
		if icecap_found:
			break
		for gx2 in range(-2000, 2001, 200):
			if g.biome_at(gx2, gz2).get("id", "") == "calotte_glaciaire":
				icecap_found = true
				icecap_pos = Vector2i(gx2, gz2)
				break
	print("[PROBE] calotte glaciaire générée quelque part sur une période de latitude : %s à %s" % [icecap_found, icecap_pos])

	# Vérification du placement de POI (E.2) : compte les types trouvés sur un
	# échantillon de cellules (128 blocs chacune), doit rester proche des
	# poi_weights par défaut du GDD (village 4 %, donjon 6 %, camp 8 %,
	# sanctuaire 3 %, filon_majeur 6 % — modulés par la disponibilité de
	# poi_weights par biome, tous n'en ont pas forcément).
	var poi_counts := {}
	var poi_cells := 0
	for pcz in range(-50, 51):
		for pcx in range(-50, 51):
			var cell := Vector2i(pcx, pcz)
			var center := POIGenerator.cell_center_world(cell)
			var pb := g.biome_at(center.x, center.y)
			if pb.is_empty():
				continue
			var pois := POIGenerator.pois_at_cell(cell, WorldManager.world_seed, pb)
			poi_cells += 1
			for p in pois:
				poi_counts[p] = int(poi_counts.get(p, 0)) + 1
	print("[PROBE] POI (échantillon %d cellules) : %s" % [poi_cells, poi_counts])

	# Vérification des arbres : cherche d'abord une colonne en forêt tempérée
	# (densité 0.05), puis balaye alentour pour trouver quelques arbres et
	# affiche les matériaux de tronc/canopée par nom.
	var forest_pos := Vector2i.ZERO
	var forest_found := false
	for gz2 in range(-150, 151, 3):
		if forest_found:
			break
		for gx2 in range(-150, 151, 3):
			var b0: Dictionary = g.biome_at(gx2 * 16, gz2 * 16)
			if b0.get("id", "") == "foret_temperee":
				forest_pos = Vector2i(gx2 * 16, gz2 * 16)
				forest_found = true
				break
	print("[PROBE] forêt tempérée trouvée à %s : %s" % [forest_pos, forest_found])
	var found := 0
	if forest_found:
		for dz in range(-64, 64):
			if found >= 3:
				break
			var wz := forest_pos.y + dz
			for dx in range(-64, 64):
				if found >= 3:
					break
				var wx := forest_pos.x + dx
				var h := g.height_at(wx, wz)
				var trunk_id := g.block_at(wx, h + 1, wz)
				if trunk_id == 0:
					continue
				var top_id := g.block_at(wx, h + 4, wz)
				var trunk_name: String = GameData.material_by_runtime[trunk_id] if trunk_id < GameData.material_by_runtime.size() else "?"
				var top_name: String = GameData.material_by_runtime[top_id] if top_id > 0 and top_id < GameData.material_by_runtime.size() else "air"
				print("[PROBE] arbre à x=%d z=%d h=%d : tronc(h+1)=%s canopée(h+4)=%s" % [wx, wz, h, trunk_name, top_name])
				found += 1
	print("[PROBE] arbres trouvés dans le balayage : %d" % found)

	# Localise un représentant de chaque essence pour les captures de contrôle
	# (scan par cellule, cohérent avec le système de placement — G.4/E.2).
	for species_id in ["sapin", "palmier", "baobab"]:
		var pos := Vector3i.ZERO
		var species_found := false
		for cx in range(-800, 801):
			if species_found:
				break
			for cz in range(-800, 801):
				var cand: Dictionary = g._tree_candidate_in_cell(cx, cz)
				if not cand.is_empty() and cand["species_id"] == species_id:
					pos = cand["base"]
					species_found = true
					break
		print("[PROBE] essence=%s trouvée=%s pos=%s" % [species_id, species_found, pos])
		if species_found:
			var tree := g.tree_at_base(pos.x, pos.y, pos.z)
			var by_y := {}
			for p: Vector3i in (tree["blocks"] as Dictionary):
				var r := (Vector2(p.x - pos.x, p.z - pos.z)).length()
				by_y[p.y] = maxf(by_y.get(p.y, 0.0), r)
			var ys: Array = by_y.keys()
			ys.sort()
			var profile := []
			for y in ys:
				profile.append("%d:%.1f" % [y, by_y[y]])
			print("[PROBE]   profil rayon par hauteur : %s" % " ".join(profile))
			print("[PROBE]   total blocs=%d bois=%d" % [(tree["blocks"] as Dictionary).size(), (tree["wood_positions"] as Array).size()])
			if species_id == "baobab":
				# Simule l'abattage complet (WorldManager.set_block par bloc)
				# + la libération d'eau (tag contient_liquide).
				for p: Vector3i in (tree["blocks"] as Dictionary):
					WorldManager.set_block(p, 0)
				var water_id: int = GameData.material_runtime_ids.get("eau", 0)
				WorldManager.set_block(pos, water_id)
				var remaining := 0
				for p: Vector3i in (tree["blocks"] as Dictionary):
					if p != pos and WorldManager.block_at_world(p) != 0:
						remaining += 1
				print("[PROBE]   abattage : blocs résiduels non-air=%d (attendu 0) eau à la base=%s (attendu true)" % [
					remaining, WorldManager.block_at_world(pos) == water_id])
	get_tree().quit(0)
