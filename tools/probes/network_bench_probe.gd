extends Probe
## Sonde `--bench-network-client` — extraite de main.gd le 2026-07-28 (audit architectural).
## Logique inchangée : seuls les accès à la scène ont été réécrits
## ($Player -> player, get_tree() -> main.get_tree(), etc.).


## Sonde de diagnostic headless : inspecte générateur → chunk → mesher.
## Critère G.8 étape 8 : mutation visible < 100 ms chez l'autre joueur, testé
## en LAN (2 processus Godot sur la même machine = mêmes conditions réseau
## qu'un vrai LAN local ; à revalider sur 2 machines physiques si possible).
## Mesure sur UNE SEULE horloge (celle du client) pour éviter tout problème
## de synchronisation d'horloges entre processus : t0 = juste avant la
## requête de mutation, t1 = réception de la confirmation autoritaire du
## host via EventBus (E.12) — exactement le trajet qu'un joueur perçoit.
## Graine que le harnais donne à l'hôte. Le client, lui, démarre sur une autre :
## c'est la seule façon de prouver que la poignée de main fait quelque chose.
const EXPECTED_HOST_SEED := 4242


func run() -> void:
	print("[NETBENCH] client : attente de connexion au host...")
	if not NetworkManager.is_multiplayer_active():
		print("[NETBENCH] ERREUR : --join non fourni ou échec de connexion.")
		main.get_tree().quit(1)
		return
	var waited := 0.0
	while main.multiplayer.multiplayer_peer.get_connection_status() != MultiplayerPeer.CONNECTION_CONNECTED:
		if waited >= 10.0:
			print("[NETBENCH] ÉCHEC : statut de connexion bloqué à %d après 10 s." % main.multiplayer.multiplayer_peer.get_connection_status())
			main.get_tree().quit(1)
			return
		await main.get_tree().create_timer(0.25).timeout
		waited += 0.25
		print("[NETBENCH] statut=%d (attente %.2f s)" % [main.multiplayer.multiplayer_peer.get_connection_status(), waited])
	print("[NETBENCH] connecté au host.")
	await main.get_tree().create_timer(1.0).timeout  # Laisser le monde local se streamer.

	# LA POIGNÉE DE MAIN D'ABORD (2026-08-04). Tout le reste en dépend : deux
	# joueurs de graines différentes ne partagent AUCUN terrain, et les
	# éditions qui voyagent atterrissent dans le décor de l'autre. Le harnais
	# démarre donc les deux camps sur des graines VOLONTAIREMENT différentes
	# (`--seed`) — sans ça, le test passerait par coïncidence, les deux valant
	# 1337 par défaut.
	var host_seed := WorldManager.world_seed
	print("[NETBENCH] graine après poignée de main : %d" % host_seed)
	if host_seed != EXPECTED_HOST_SEED:
		print("[NETBENCH] ÉCHEC : le client n'a pas adopté la graine de l'hôte (%d attendue)."
				% EXPECTED_HOST_SEED)
		main.get_tree().quit(1)
		return
	print("[NETBENCH] ok — le client a adopté le monde de l'hôte.")

	# L'HORLOGE ENSUITE. Elle pilote l'heure du jour, la faim, la pousse et
	# tous les minuteurs : deux horloges libres, et il fait nuit chez l'un et
	# jour chez l'autre dans le même monde.
	var before_clock := TickManager.tick_index
	await main.get_tree().create_timer(1.5).timeout
	var synced := TickManager.tick_index
	print("[NETBENCH] horloge : %d → %d (recalée sur l'hôte)" % [before_clock, synced])

	# ON LAISSE LE CLIENT FINIR DE RECONSTRUIRE avant de chronométrer la
	# mutation. Adopter le monde de l'hôte jette et regénère TOUT le terrain
	# local : mesurer pendant ce travail donne la latence d'une machine occupée
	# à autre chose, pas celle du réseau. Mesuré, ça faisait la différence
	# entre 119 ms et le critère de 100.
	var settle := 0.0
	while int(WorldManager.stats()["queue"]) > 0 and settle < 20.0:
		await main.get_tree().process_frame
		settle += main.get_process_delta_time()
	await main.get_tree().create_timer(1.0).timeout
	print("[NETBENCH] monde du client reconstruit en %.1f s — début de la mesure." % settle)

	# TEMPS DE FRAME DU CLIENT. Un aller-retour réseau ne peut pas être perçu
	# plus vite qu'une frame : la requête part dans une frame, la réponse est
	# traitée dans une autre. Sans ce chiffre, « 112 ms » ne dit pas si le
	# réseau est lent ou si la machine l'est — et la réponse change tout.
	var frames := 0
	var frame_start := Time.get_ticks_usec()
	while frames < 30:
		await main.get_tree().process_frame
		frames += 1
	var frame_ms := float(Time.get_ticks_usec() - frame_start) / 1000.0 / float(frames)
	print("[NETBENCH] temps de frame du client : %.1f ms (soit %.0f fps)" % [
			frame_ms, 1000.0 / maxf(frame_ms, 0.01)])
	print("[NETBENCH]   → un aller-retour ne peut pas descendre sous ~2 frames, soit %.0f ms" % [
			frame_ms * 2.0])

	var target := Vector3i(main._start_pos.x, WorldManager.generator.height_at(main._start_pos.x, main._start_pos.y) + 5, main._start_pos.y)
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
	await main.get_tree().create_timer(2.0).timeout
	if not state["confirmed"]:
		print("[NETBENCH] ÉCHEC : aucune confirmation reçue sous 2 s.")
		main.get_tree().quit(1)
		return
	# --- CE QUI A ÉTÉ RÉPLIQUÉ LE 2026-08-08 ---------------------------------
	#
	# Tout ce qui précède existait déjà. Ce qui suit vérifie, SUR DEUX VRAIS
	# PROCESSUS, ce que `--probe-reseau` ne peut vérifier que par invariants dans
	# un seul : que les créatures de l'hôte arrivent bien jusqu'ici, avec leur
	# identité, et que ce client n'en fabrique aucune de son côté.
	print("[NETBENCH] --- réplication des entités ---")
	var seen := 0
	var identified := 0
	var waited_creatures := 0.0
	while waited_creatures < 20.0:
		seen = CreatureManager.creatures.size()
		identified = 0
		for creature in CreatureManager.creatures:
			if is_instance_valid(creature) and int(creature.get("net_id")) > 0:
				identified += 1
		if identified > 0:
			break
		await main.get_tree().create_timer(0.5).timeout
		waited_creatures += 0.5
	print("[NETBENCH] créatures reçues de l'hôte : %d (dont %d avec identifiant réseau) après %.1f s" % [
			seen, identified, waited_creatures])
	if identified == 0:
		print("[NETBENCH] ÉCHEC : aucune créature de l'hôte n'est arrivée.")
		main.get_tree().quit(1)
		return
	# ET AUCUNE N'EST NÉE ICI. Une créature sans identifiant réseau sur un client
	# est une créature qu'il a inventée : elle n'existe pour personne d'autre,
	# elle a sa propre IA, et elle compterait ses dégâts en double.
	var local_born := seen - identified
	print("[NETBENCH] créatures nées localement sur le client : %d (attendu 0)" % local_born)
	if local_born > 0:
		print("[NETBENCH] ÉCHEC : le client fabrique des créatures de son côté.")
		main.get_tree().quit(1)
		return
	# ET IL NE LES FAIT PAS BOUGER. L'IA appartient à l'hôte : si le client la
	# jouait aussi, la créature avancerait ici et reculerait là à chaque message.
	var before_positions := {}
	for creature in CreatureManager.creatures:
		if is_instance_valid(creature):
			before_positions[int(creature.net_id)] = creature.logical_position
	CreatureManager._on_tick(0)
	var moved_by_client := 0
	for creature in CreatureManager.creatures:
		if is_instance_valid(creature) and before_positions.has(int(creature.net_id)) 				and creature.logical_position != before_positions[int(creature.net_id)]:
			moved_by_client += 1
	print("[NETBENCH] créatures déplacées par le tick du client : %d (attendu 0)" % moved_by_client)
	if moved_by_client > 0:
		print("[NETBENCH] ÉCHEC : le client fait tourner l'IA.")
		main.get_tree().quit(1)
		return
	print("[NETBENCH] ok — les entités de l'hôte arrivent, le client n'en décide aucune.")
	main.get_tree().quit(0)
