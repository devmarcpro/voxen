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
	if _remote_markers.has(id):
		_remote_markers[id].queue_free()
		_remote_markers.erase(id)


# --- Réplication de position (E.11 : non-fiable 10-20 Hz) ---
## Vue minimale des autres joueurs : un simple repère 3D par pair — pas
## d'avatar complet (aucun modèle de personnage n'existe encore, 12).

var _remote_markers := {}  # peer_id -> Node3D


@rpc("any_peer", "unreliable")
func rpc_broadcast_position(pos: Vector3) -> void:
	var sender := multiplayer.get_remote_sender_id()
	if sender == 0:
		return  # Appel local direct (ne devrait pas arriver) : ignoré.
	_marker_for(sender).global_position = pos


func _marker_for(id: int) -> Node3D:
	if _remote_markers.has(id):
		return _remote_markers[id]
	var marker := CSGBox3D.new()
	marker.size = Vector3(0.6, 1.8, 0.6)
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.2, 0.6, 1.0)
	marker.material = mat
	get_tree().current_scene.add_child(marker)
	_remote_markers[id] = marker
	return marker
