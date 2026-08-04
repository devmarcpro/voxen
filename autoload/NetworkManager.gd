extends Node
## NetworkManager — host-and-join (8/E.11), API haut niveau Godot (MultiplayerAPI).
## Host autoritaire sur : ticks, monde voxel, entités. Client envoie des
## INTENTIONS ; le host valide et diffuse le résultat (D.2 : toute mutation
## du monde passe par WorldManager.set_block/set_sub_region, qui routent
## eux-mêmes vers ce modèle — voir leurs commentaires).
## Anti-triche minimal (portée/possession) : DIFFÉRÉ à cette étape (E.11 le
## prévoit, pas encore implémenté — le host applique les requêtes telles
## quelles). À ajouter avant tout déploiement public.

const DEFAULT_PORT := 8910
const MAX_PEERS := 8

signal peer_joined(id: int)
signal peer_left(id: int)
signal connected_to_host
signal connection_failed_signal

var is_host := false
var is_client := false


## NOTE : Godot assigne par défaut un OfflineMultiplayerPeer non-null à
## `multiplayer.multiplayer_peer` — tester `!= null` est un piège (toujours
## vrai). On se base sur nos propres drapeaux, mis à jour uniquement par
## host()/join() ci-dessous.
func is_multiplayer_active() -> bool:
	return is_host or is_client


func host(port: int = DEFAULT_PORT) -> bool:
	var peer := ENetMultiplayerPeer.new()
	var err := peer.create_server(port, MAX_PEERS)
	if err != OK:
		push_error("NetworkManager : impossible d'héberger sur le port %d (%s)." % [port, err])
		return false
	multiplayer.multiplayer_peer = peer
	is_host = true
	is_client = false
	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	print("[NET] Hôte démarré sur le port %d." % port)
	return true


func join(address: String, port: int = DEFAULT_PORT) -> bool:
	var peer := ENetMultiplayerPeer.new()
	var err := peer.create_client(address, port)
	if err != OK:
		push_error("NetworkManager : impossible de rejoindre %s:%d (%s)." % [address, port, err])
		return false
	multiplayer.multiplayer_peer = peer
	is_host = false
	is_client = true
	multiplayer.connected_to_server.connect(func() -> void:
		connected_to_host.emit()
		_request_world())
	multiplayer.connection_failed.connect(func() -> void: connection_failed_signal.emit())
	print("[NET] Connexion à %s:%d..." % [address, port])
	return true


func _on_peer_connected(id: int) -> void:
	print("[NET] Pair connecté : %d" % id)
	peer_joined.emit(id)
	# On n'envoie RIEN ici. L'hôte apprend la connexion dès qu'ENet l'établit,
	# mais le client n'a pas encore fini de la sienne : un message poussé à cet
	# instant se perd, et le client reste sur son propre monde sans que rien ne
	# le signale. C'est le client qui RÉCLAME, quand il est prêt (`_request_world`).


## Le client réclame le monde de l'hôte dès qu'il est connecté.
func _request_world() -> void:
	rpc_request_world.rpc_id(1)


## Réclamation, côté hôte. `any_peer` : c'est un client qui appelle.
@rpc("any_peer", "reliable")
func rpc_request_world() -> void:
	if not is_host:
		return
	var asker := multiplayer.get_remote_sender_id()
	rpc_world_handshake.rpc_id(asker, WorldManager.world_seed,
			SaveManager.active_config.get("params", {}))
	rpc_clock.rpc_id(asker, TickManager.tick_index)


## Le monde de l'hôte, transmis à un client qui arrive.
##
## `call_local` serait une erreur ici : l'hôte adopterait son propre monde et
## paierait une reconstruction complète à chaque connexion.
@rpc("authority", "reliable")
func rpc_world_handshake(seed_value: int, params: Dictionary) -> void:
	print("[NET] Monde de l'hôte reçu : graine %d." % seed_value)
	WorldManager.adopt_world(seed_value, params)


## HORLOGE DE L'HÔTE (E.1 : « ordre d'un tick déterministe, host-autoritaire »).
##
## Chaque camp faisait avancer son propre `TickManager` : l'heure du jour, la
## faim, la pousse des arbres et tous les minuteurs dérivaient l'un de l'autre
## dès la première seconde. Il pouvait faire nuit chez l'un et jour chez
## l'autre, dans le même monde.
##
## Le client ne cesse pas de tourner pour autant — il continue à ticker seul
## entre deux messages, sinon le jeu saccaderait au rythme du réseau. Il se
## RECALE simplement sur l'hôte quand celui-ci parle.
@rpc("authority", "unreliable")
func rpc_clock(tick_index: int) -> void:
	TickManager.tick_index = tick_index


## Cadence de recalage de l'horloge, en secondes réelles. Une par seconde
## suffit : le tick dure 0,1 s, donc la dérive entre deux messages reste sous
## le dixième de seconde, invisible.
const CLOCK_SYNC_PERIOD := 1.0

var _clock_timer := 0.0


func _process(delta: float) -> void:
	if not is_host:
		return
	_clock_timer += delta
	if _clock_timer < CLOCK_SYNC_PERIOD:
		return
	_clock_timer = 0.0
	if multiplayer.get_peers().size() > 0:
		rpc_clock.rpc(TickManager.tick_index)


func _on_peer_disconnected(id: int) -> void:
	print("[NET] Pair déconnecté : %d" % id)
	peer_left.emit(id)
	if _remote_bodies.has(id):
		_remote_bodies[id].queue_free()
		_remote_bodies.erase(id)


# --- Réplication de pose (E.11 : non-fiable 10-20 Hz) ---
## AVATARS COMPLETS depuis le 2026-07-28 : les autres joueurs étaient des
## boîtes bleues (« aucun modèle de personnage n'existe encore »). Le gabarit
## humanoïde existe maintenant, et c'est LE MÊME corps que celui du joueur
## local — un seul nœud à maintenir, aucune divergence possible entre ce qu'on
## voit de soi et ce que les autres voient.
##
## Le LACET et le TANGAGE sont répliqués en plus de la position. Ce n'est pas
## cosmétique : dans un combat directionnel, ne pas voir où l'adversaire
## regarde, c'est ne pas voir arriver son coup. La position transmise est celle
## de l'ŒIL (ce que la caméra connaît) ; les pieds s'en déduisent.

var _remote_bodies := {}  # peer_id -> PlayerBody (ou Node3D de repli)


@rpc("any_peer", "unreliable")
func rpc_broadcast_pose(pos: Vector3, yaw: float, pitch: float) -> void:
	var sender := multiplayer.get_remote_sender_id()
	if sender == 0:
		return  # Appel local direct (ne devrait pas arriver) : ignoré.
	var body := _body_for(sender)
	if body == null:
		return
	if body.has_method("apply_remote_pose"):
		body.apply_remote_pose(pos - Vector3(0.0, FlyCamera.EYE_HEIGHT, 0.0), yaw, pitch)
	else:
		body.global_position = pos


func _body_for(id: int) -> Node3D:
	if _remote_bodies.has(id):
		return _remote_bodies[id]
	# `false` : ce n'est pas le joueur local, sa tête reste VISIBLE (on ne
	# masque le crâne que pour celui dont la caméra est dedans).
	var body: Node3D = preload("res://scenes/entities/player_body.gd").new()
	body.name = "JoueurDistant%d" % id
	get_tree().current_scene.add_child(body)
	if not body.setup(false):
		# Modèle absent : repli sur l'ancien repère plutôt que rien du tout —
		# mieux vaut une boîte visible qu'un joueur invisible.
		body.queue_free()
		body = _fallback_marker()
	_remote_bodies[id] = body
	return body


func _fallback_marker() -> Node3D:
	var marker := CSGBox3D.new()
	marker.size = Vector3(0.6, 1.8, 0.6)
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.2, 0.6, 1.0)
	marker.material = mat
	get_tree().current_scene.add_child(marker)
	return marker
