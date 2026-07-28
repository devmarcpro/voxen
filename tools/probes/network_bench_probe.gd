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
	main.get_tree().quit(0)
