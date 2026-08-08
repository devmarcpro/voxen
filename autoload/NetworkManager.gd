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


## TOUTE PARTIE EST UNE PARTIE MULTIJOUEUR (2026-08-08, décision d'architecture
## de l'auteur : « il faut que de base le jeu gère toute partie comme une partie
## multijoueur avec un seul joueur »).
##
## ---------------------------------------------------------------------------
## LE PROBLÈME QUE ÇA RÈGLE
## ---------------------------------------------------------------------------
## Chaque système écrit depuis le 2026-07-20 l'a été en solo, puis aurait dû
## être « porté » au réseau. Ça ne marche pas : porter, c'est réécrire, et on ne
## réécrit jamais quinze systèmes. Pire, tant que le solo emprunte un chemin et
## le réseau un autre, c'est le chemin réseau qui n'est JAMAIS exercé — donc
## celui qui casse, et personne ne le voit avant de brancher deux machines.
##
## LA RÈGLE, désormais : il n'y a qu'UN chemin. Toute mutation d'état passe par
## une fonction gardée par l'autorité, et le solo l'emprunte comme le réseau.
## Godot fournit exactement ce qu'il faut : en l'absence d'hôte ou de client,
## `multiplayer.multiplayer_peer` est un `OfflineMultiplayerPeer` où l'on est
## SERVEUR (id 1) et où un `rpc()` s'exécute localement. Le solo est donc, pour
## de bon, une partie à un joueur — pas une simulation de partie à un joueur.
##
## CE QU'IL FAUT ÉCRIRE POUR QU'UN NOUVEAU SYSTÈME SOIT « RÉSEAU » : rien de
## particulier. On demande `is_authority()` avant de décider, on passe par un
## `@rpc("authority", "call_local")` pour appliquer, et c'est tout. Si la
## fonction marche en solo, elle marche en réseau — parce que c'est le même
## code, exercé par toutes les sondes depuis le premier jour.
##
## `is_multiplayer_active()` reste, mais elle ne veut plus dire « faut-il
## router ? » (la réponse est TOUJOURS oui) : elle veut dire « y a-t-il
## quelqu'un d'autre ? », ce qui n'intéresse que l'affichage et les
## diagnostics.
func is_multiplayer_active() -> bool:
	return is_host or is_client


## Suis-je l'autorité sur l'état du monde ? VRAI EN SOLO — c'est tout l'objet.
## Un client rend `false` et doit demander au lieu d'appliquer.
func is_authority() -> bool:
	return not is_client


## Y a-t-il d'autres joueurs ? Pour l'affichage et les diagnostics UNIQUEMENT :
## aucune décision de gameplay ne doit en dépendre, sinon on recrée les deux
## chemins qu'on vient de supprimer.
func has_peers() -> bool:
	return is_host and not multiplayer.get_peers().is_empty()


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


# --- CE QUE L'AUTRE JOUEUR TIENT ET FAIT (2026-08-08) ----------------------
#
# La pose ne suffisait pas. Un joueur distant était un mannequin DÉSARMÉ, sans
# geste : on ne voyait ni ce qu'il tenait, ni qu'il armait un coup, ni de quel
# côté. Dans un jeu où l'on pare EN LISANT LE CORPS de l'adversaire — c'est la
# règle de Mount & Blade, et c'est ce que tout le combat directionnel suppose —,
# ça ne rend pas le duel imparfait : ça le rend impossible.
#
# DEUX MESSAGES, ET PAS UN SEUL, parce que leurs cadences n'ont rien à voir.
# L'ARME change rarement (on dégaine, on range) : message FIABLE, envoyé au
# changement. Le GESTE change à la frame : message NON FIABLE, envoyé avec la
# pose — un geste perdu est remplacé par le suivant un vingtième de seconde
# plus tard, tandis qu'une arme perdue laisserait les mains vides pour toujours.

@rpc("any_peer", "reliable")
func rpc_broadcast_weapon(item_id: String, materials: Dictionary) -> void:
	var sender := multiplayer.get_remote_sender_id()
	if sender == 0:
		return
	var body := _body_for(sender)
	if body == null:
		return
	if item_id == "":
		body.attach_weapon_model(null, 1.0)
		return
	# L'ASSEMBLAGE EST RECONSTRUIT LOCALEMENT, à partir de l'id et des matériaux
	# — deux chaînes et un petit dictionnaire. Envoyer le modèle serait
	# impensable, et le reconstruire par `WeaponPreview.assemble` garantit que
	# l'arme vue chez l'autre est LA MÊME que celle qu'il voit dans sa main :
	# c'est déjà la fonction que sa propre main appelle.
	var item: Dictionary = GameData.items.get(item_id, {})
	if item.is_empty():
		return
	var model := WeaponPreview.assemble(item, materials)
	if model != null:
		body.attach_weapon_model(model,
			preload("res://scenes/entities/held_item.gd").PART_SCALE)


@rpc("any_peer", "unreliable")
func rpc_broadcast_gesture(direction: int, ratio: float, phase: String) -> void:
	var sender := multiplayer.get_remote_sender_id()
	if sender == 0:
		return
	var body := _body_for(sender)
	# `set_combat_pose` est LA MÊME fonction que celle des créatures : ce qu'on
	# voit d'un joueur distant est ce qu'on voit d'un PNJ, donc ce qu'on a appris
	# à lire sur soi. Un second système d'animation pour les avatars aurait
	# garanti que les deux divergent.
	if body != null and body.has_method("set_combat_pose"):
		body.set_combat_pose(direction, ratio, phase)


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


# --- CRÉATURES (2026-08-08) ------------------------------------------------
#
# HOST AUTORITAIRE, comme le monde voxel. L'hôte seul fait naître, décide et
# blesse ; il DIT ce qui s'est passé. Le client n'exécute aucune IA — sans quoi
# deux simulations indépendantes divergeraient dès la première seconde, la
# créature avançant ici et reculant là, et les dégâts seraient comptés deux fois.
#
# LA POSE EST « UNRELIABLE », le reste est fiable, et ce n'est pas un détail :
# une position perdue est remplacée par la suivante un dixième de seconde plus
# tard, alors qu'une MORT perdue laisserait un cadavre debout pour toujours.

@rpc("authority", "reliable")
func rpc_creature_spawn(net_id: int, creature_id: String, world_position: Vector3,
		dimension: String) -> void:
	CreatureManager.apply_remote_spawn(net_id, creature_id, world_position,
			StringName(dimension))


@rpc("authority", "unreliable")
func rpc_creature_pose(net_id: int, world_position: Vector3, yaw: float) -> void:
	var creature := CreatureManager.by_net_id(net_id)
	if creature == null:
		return
	creature.logical_position = world_position
	creature.rotation.y = yaw


@rpc("authority", "reliable")
func rpc_creature_health(net_id: int, health: float) -> void:
	var creature := CreatureManager.by_net_id(net_id)
	if creature != null:
		creature.set("health", health)


@rpc("authority", "reliable")
func rpc_creature_despawn(net_id: int) -> void:
	var creature := CreatureManager.by_net_id(net_id)
	if creature != null:
		CreatureManager.despawn(creature)


# --- REGISTRES POSITIONNELS (2026-08-08) -----------------------------------
#
# Objets posés, pousses, coffres, caches au sol : quatre registres de MÊME
# FORME — une clé de position, un contenu que le bloc ne sait pas dire. Ils se
# répliquent donc de la même façon, et c'est voulu : quatre mécaniques
# différentes pour quatre registres identiques auraient donné quatre façons de
# se tromper.
#
# CE QU'ON DIFFUSE, C'EST LE RÉSULTAT, jamais le geste. On n'envoie pas « le
# joueur a tourné l'objet », on envoie « voici l'orientation ». Un client qui
# rejouerait le geste devrait connaître l'état d'avant, donc l'avoir reçu, donc
# n'avoir manqué aucun message — une hypothèse qu'aucun réseau ne tient.

@rpc("authority", "reliable")
func rpc_placed_item(position: Vector3i, instance: Dictionary, yaw: int,
		dimension: String) -> void:
	PlacedItemManager.apply_remote_placed(position, instance, yaw, StringName(dimension))


@rpc("authority", "reliable")
func rpc_placed_item_removed(position: Vector3i) -> void:
	PlacedItemManager.apply_remote_removed(position)


@rpc("authority", "reliable")
func rpc_sapling(position: Vector3i, species_id: String, planted_tick: int,
		dimension: String) -> void:
	SaplingManager.apply_remote_sapling(position, species_id, planted_tick,
			StringName(dimension))


@rpc("authority", "reliable")
func rpc_sapling_removed(position: Vector3i) -> void:
	SaplingManager.apply_remote_removed(position)


@rpc("authority", "reliable")
func rpc_chest_contents(position: Vector3i, contents: Dictionary) -> void:
	ContainerManager.apply_remote_contents(position, contents)
