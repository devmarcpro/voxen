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
	multiplayer.connected_to_server.connect(func() -> void: connected_to_host.emit())
	multiplayer.connection_failed.connect(func() -> void: connection_failed_signal.emit())
	print("[NET] Connexion à %s:%d..." % [address, port])
	return true


func _on_peer_connected(id: int) -> void:
	print("[NET] Pair connecté : %d" % id)
	peer_joined.emit(id)


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
