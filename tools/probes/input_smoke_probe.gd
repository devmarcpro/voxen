extends Probe
## Sonde `--test-input` — extraite de main.gd le 2026-07-28 (audit architectural).
## Logique inchangée : seuls les accès à la scène ont été réécrits
## ($Player -> player, get_tree() -> main.get_tree(), etc.).


## Test de fumée des entrées : kit de départ, capture souris, rotation caméra.
func run() -> void:
	await main.get_tree().create_timer(0.5).timeout
	var player := player
	print("[TEST] outils au départ : %d" % player.inventory.objects.size())
	for obj: Dictionary in player.inventory.objects:
		print("[TEST]   %s — durete_base=%.1f qualite=%.2f poids=%.1f" % [
			obj.get("item_id", "?"), obj.get("base_hardness", -1.0),
			obj.get("quality", -1.0), obj.get("weight", -1.0)])
	# Clic gauche au centre → doit capturer la souris.
	var press := InputEventMouseButton.new()
	press.button_index = MOUSE_BUTTON_LEFT
	press.pressed = true
	press.position = main.get_viewport().get_visible_rect().size / 2
	Input.parse_input_event(press)
	await main.get_tree().process_frame
	await main.get_tree().process_frame
	print("[TEST] souris capturée : %s" % (Input.mouse_mode == Input.MOUSE_MODE_CAPTURED))
	# Mouvement souris → doit tourner la caméra.
	var rot_before := camera.rotation
	var motion := InputEventMouseMotion.new()
	motion.relative = Vector2(100, 50)
	Input.parse_input_event(motion)
	await main.get_tree().process_frame
	await main.get_tree().process_frame
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
	await main.get_tree().process_frame
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
		await main.get_tree().process_frame
		var release := InputEventMouseButton.new()
		release.button_index = MOUSE_BUTTON_LEFT
		release.pressed = false
		Input.parse_input_event(release)
		await main.get_tree().create_timer(0.15).timeout
		attacks += 1
	print("[TEST] combat : %d clics, sanglier mort=%s (PV joueur=%d/%d)" % [
		attacks, not is_instance_valid(boar) or boar.is_dead(), int(player.health), int(player.health_max)])
	# Spawn naturel (hors bench) : ~5 s d'attente réelle doit produire au
	# moins une créature autour du joueur (CreatureManager.SPAWN_INTERVAL_TICKS).
	print("[TEST] créatures avant attente spawn naturel : %d" % CreatureManager.creatures.size())
	await main.get_tree().create_timer(6.0).timeout
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
	await main.get_tree().create_timer(1.5).timeout
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
	await main.get_tree().create_timer(1.0).timeout
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
	await main.get_tree().process_frame
	print("[TEST] après V : revendiquée=%s rôle=%s (attendu true/base)" % [ClaimManager.is_claimed(start_cell), ClaimManager.role_of(start_cell)])
	var b_press := InputEventKey.new()
	b_press.physical_keycode = KEY_B
	b_press.pressed = true
	Input.parse_input_event(b_press)
	await main.get_tree().process_frame
	print("[TEST] après B : rôle=%s (attendu habitation)" % ClaimManager.role_of(start_cell))

	# Voyage rapide (6.3) vers une cellule voisine.
	var target_cell: Vector2i = start_cell + Vector2i(2, 0)
	player.fast_travel_to_cell(target_cell)
	var landed_cell: Vector2i = player.current_cell()
	print("[TEST] voyage rapide : cible=%s atterri=%s (doivent correspondre)" % [target_cell, landed_cell])

	# Carte du monde (M) : écran séparé (ToME-like), stats + relief 3D,
	# fermeture par Échap ou clic de voyage rapide (plus par un 2e M).
	var map_view := main.get_node("WorldMapView")
	var stats_panel := main.get_node("HUD/WorldMapPanel")
	var m_press := InputEventKey.new()
	m_press.physical_keycode = KEY_M
	m_press.pressed = true
	Input.parse_input_event(m_press)
	await main.get_tree().process_frame
	await main.get_tree().process_frame
	print("[TEST] carte après M : ouverte=%s stats_visibles=%s joueur_verrouille=%s (attendus true/true/true)" % [
		map_view.is_open, stats_panel.visible, player.input_locked])
	# Écran de chargement (2026-07-21) : la mosaïque se construit maintenant
	# par budget de temps sur plusieurs frames (BUILD_BUDGET_MS) — attend que
	# le label "Chargement..." disparaisse réellement plutôt qu'un délai fixe
	# (qui serait trop court sur une grosse carte, trop long sur une petite).
	var waited := 0.0
	while map_view._loading_label.visible and waited < 45.0:
		await main.get_tree().process_frame
		waited += main.get_process_delta_time()
	print("[TEST] carte : chargement terminé en %.2f s" % waited)
	await screenshot("map_screenshot.png")
	print("[TEST] capture carte : map_screenshot.png")
	var esc_press := InputEventKey.new()
	esc_press.physical_keycode = KEY_ESCAPE
	esc_press.pressed = true
	Input.parse_input_event(esc_press)
	await main.get_tree().process_frame
	print("[TEST] carte après Échap : ouverte=%s stats_visibles=%s joueur_verrouille=%s (attendus false/false/false)" % [
		map_view.is_open, stats_panel.visible, player.input_locked])
	# Réouvre et teste le voyage rapide par clic (centre de l'écran = cellule
	# centrale par construction de la grille). ATTENDRE la fin du chargement
	# avant de cliquer (2026-07-21, test durci) : un clic pendant le
	# chargement tombe sur une géométrie de mosaïque pas encore posée
	# (_pixel_to_tile invalide) et ne fait rien — la carte restait ouverte et
	# tous les tests suivants tournaient input verrouillé (cascade).
	Input.parse_input_event(m_press)
	await main.get_tree().process_frame
	await main.get_tree().process_frame
	var waited_reopen := 0.0
	while map_view._loading_label.visible and waited_reopen < 45.0:
		await main.get_tree().process_frame
		waited_reopen += main.get_process_delta_time()
	var before_cell: Vector2i = player.current_cell()
	var click := InputEventMouseButton.new()
	click.button_index = MOUSE_BUTTON_LEFT
	click.pressed = true
	click.position = main.get_viewport().get_visible_rect().size / 2
	Input.parse_input_event(click)
	await main.get_tree().process_frame
	print("[TEST] carte : clic central a fermé=%s (attendu true), cellule avant=%s après=%s" % [
		not map_view.is_open, before_cell, player.current_cell()])
	# Filet : si la carte est restée ouverte malgré tout, fermer par Échap
	# pour ne pas contaminer la suite (input verrouillé).
	if map_view.is_open:
		Input.parse_input_event(esc_press)
		await main.get_tree().process_frame
	# Molette (slot) et Shift+molette (banque de hotbar).
	var wheel_down := InputEventMouseButton.new()
	wheel_down.button_index = MOUSE_BUTTON_WHEEL_DOWN
	wheel_down.pressed = true
	Input.parse_input_event(wheel_down)
	await main.get_tree().process_frame
	print("[TEST] molette bas : slot=%d (avant=3, +1 attendu)" % player.selected_slot)
	var shift_wheel := InputEventMouseButton.new()
	shift_wheel.button_index = MOUSE_BUTTON_WHEEL_DOWN
	shift_wheel.pressed = true
	shift_wheel.shift_pressed = true
	Input.parse_input_event(shift_wheel)
	await main.get_tree().process_frame
	print("[TEST] shift+molette bas : banque=%d (attendu 1)" % player.active_hotbar)
	var shift3 := InputEventKey.new()
	shift3.physical_keycode = KEY_3
	shift3.pressed = true
	shift3.shift_pressed = true
	Input.parse_input_event(shift3)
	await main.get_tree().process_frame
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
		await main.get_tree().create_timer(4.5).timeout
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
			await main.get_tree().create_timer(2.5).timeout
			await screenshot("dungeon_screenshot.png")
			print("[TEST] capture donjon : dungeon_screenshot.png")
			var exit_marker := DungeonManager._exit_marker_position(donjon_cell)
			camera.position = Vector3(exit_marker.x, exit_marker.y + 2.9, exit_marker.z)
			await main.get_tree().create_timer(1.6).timeout
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
	var cheat_menu := main.get_node("CheatMenu")
	var f1_press := InputEventKey.new()
	f1_press.physical_keycode = KEY_F1
	f1_press.pressed = true
	Input.parse_input_event(f1_press)
	await main.get_tree().process_frame
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
	await main.get_tree().create_timer(0.3).timeout
	await screenshot("cheat_menu_screenshot.png")
	print("[TEST] capture menu de triche : cheat_menu_screenshot.png")
	cheat_menu._close()
	print("[TEST] menu de triche fermé : %s (attendu true)" % (not cheat_menu.is_open))

	# Menu de jeu à onglets (2026-07-21) : ouverture par Tab, inventaire triable
	# (207 matériaux + objets donnés par la triche ci-dessus), navigation entre
	# onglets, capture, fermeture. `player.input_locked` doit basculer.
	var game_menu := main.get_node("GameMenu")
	var tab_press := InputEventKey.new()
	tab_press.physical_keycode = KEY_TAB
	tab_press.pressed = true
	Input.parse_input_event(tab_press)
	await main.get_tree().process_frame
	await main.get_tree().process_frame
	print("[TEST] menu de jeu ouvert : %s joueur_verrouille=%s (attendus true/true)" % [
		game_menu.is_open, player.input_locked])
	game_menu._select_tab("inventaire")
	game_menu._inv_sort_option.selected = 3  # Dureté.
	game_menu._refresh_inventory()
	await main.get_tree().process_frame
	print("[TEST] onglet inventaire : %d lignes affichées (attendu > 0)" % game_menu._inv_list.get_child_count())
	# Onglet Craft (2026-07-21) : fabrication par recette. Le joueur a tous les
	# matériaux (triche) et compétences maxées → craft d'une épée doit réussir
	# et produire un objet de qualité élevée.
	game_menu._select_tab("craft")
	await main.get_tree().process_frame
	await screenshot("game_menu_craft_screenshot.png")
	print("[TEST] onglet craft : %d recette(s) affichée(s)" % game_menu._craft_list.get_child_count())
	var objects_pre_craft: int = player.inventory.objects.size()
	game_menu._craft_choices["epee:bois"] = "chene" if player.inventory.material_stacks.has("chene") else game_menu._owned_of_category("bois")[0]
	game_menu._craft_choices["epee:minerai"] = "fer" if player.inventory.material_stacks.has("fer") else game_menu._owned_of_category("minerai")[0]
	game_menu._do_craft("epee", GameData.items["epee"]["recipe"], "forge")
	await main.get_tree().process_frame
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
	await main.get_tree().process_frame
	var lingot_sword: Dictionary = player.inventory.objects[player.inventory.objects.size() - 1]
	print("[TEST] craft épée LINGOT : dureté=%.1f (minerai brut était %.1f — attendu supérieur)" % [
		float(lingot_sword.get("base_hardness", 0.0)), float(new_sword.get("base_hardness", 0.0))])
	game_menu._select_tab("personnage")
	await main.get_tree().process_frame
	await screenshot("game_menu_perso_screenshot.png")
	game_menu._select_tab("royaume")
	await main.get_tree().process_frame
	game_menu._select_tab("monde")
	await main.get_tree().process_frame
	game_menu._select_tab("inventaire")
	await screenshot("game_menu_screenshot.png")
	print("[TEST] capture menu de jeu : game_menu_screenshot.png")
	var tab_close := InputEventKey.new()
	tab_close.physical_keycode = KEY_TAB
	tab_close.pressed = true
	Input.parse_input_event(tab_close)
	await main.get_tree().process_frame
	print("[TEST] menu de jeu fermé : %s joueur_verrouille=%s (attendus false/false)" % [
		not game_menu.is_open, player.input_locked])

	# Laisser le remesh urgent aboutir, cadrer, capturer.
	camera.position = Vector3(base) + Vector3(2.5, 2.5, 3.5)
	camera.look_at(Vector3(base) + Vector3(0.5, 0.5, 0.5))
	await main.get_tree().create_timer(2.0).timeout
	await screenshot("subdiv_screenshot.png")
	print("[TEST] capture : " + capture_path("subdiv_screenshot.png"))
	main.get_tree().quit(0)
