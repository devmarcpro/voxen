class_name FlyCamera
extends Camera3D
## Caméra du joueur — deux modes : MARCHE (défaut, gravité + saut + sol suivi
## via le terrain généré) et VOL libre (bascule avec F, pour le débogage/les
## déplacements rapides — étapes D.3.1-3). Clic gauche pour capturer la
## souris, Échap pour la libérer. Touches physiques WASD (= ZQSD en AZERTY).
## Le déplacement caméra est purement visuel : _process est légitime ici (E.1).

const SPEED := 20.0
const BOOST_SPEED := 80.0
const SENSITIVITY := 0.0025
## Vitesse du vol automatique en mode bench (blocs/s) — « vol rapide » G.8 :
## ~3× la vitesse de sprint prévue, du niveau d'une élytre de Minecraft.
const BENCH_SPEED := 30.0

## Marche (défaut) : valeurs EXACTES de Minecraft (demande explicite
## 2026-07-21 « le mouvement devrait être exactement comme Minecraft ») :
## marche 4,317 blocs/s, sprint 5,612 (Ctrl), sneak 1,295 (Shift — avec
## protection anti-chute au bord, comme MC), gravité 32 blocs/s², saut
## ~1,25 bloc de haut, vitesse terminale ~78 blocs/s.
## Approximations assumées vs MC : pas de traînée d'air ni d'inertie fine
## (vitesses instantanées, MC a un peu de glisse), pas de boost avant du
## sprint-saut, pas de nage (E.22 différé) — le reste est aux valeurs MC.
const WALK_SPEED := 4.317
const SPRINT_SPEED := 5.612
const SNEAK_SPEED := 1.295
const GRAVITY := 32.0
const JUMP_SPEED := 8.95       # sqrt(2×32×1,25) → apex à ~1,25 bloc (MC).
const TERMINAL_VELOCITY := 78.0
## Joueur = 2 blocs de haut (pieds + tête, demande explicite, façon
## Minecraft), bloqué par les blocs pleins devant lui.
## FRANCHISSEMENT AUTOMATIQUE (2026-07-28) : révision assumée de la règle
## précédente (« pas de pas automatique, seul un saut manuel permet de franchir
## un bloc »). Le combat directionnel repose à moitié sur le jeu de jambes
## (reculer pour esquiver, avancer pour punir) ; devoir sauter à chaque marche
## d'un bloc rend ce jeu de jambes impraticable sur un terrain voxel. Le
## terrain, lui, ne change PAS : pas de lissage en sous-voxels (le greedy
## meshing de chunk_mesher.gd et l'éparsité de chunk_data.gd sont préservés) —
## c'est le contrôleur qui s'adapte, pas la géométrie du monde.
## --- JEU DE JAMBES DE COMBAT (2026-08-02) ---
##
## POURQUOI CES CONSTANTES EXISTENT, ET POURQUOI ELLES NE S'APPLIQUENT PAS
## TOUT LE TEMPS. Le déplacement de ce fichier est aux valeurs EXACTES de
## Minecraft, sur demande explicite (2026-07-21) : vitesse identique dans les
## quatre directions, appliquée instantanément, sans inertie. C'est parfait
## pour construire, et c'est incompatible avec un duel.
##
## Le combat de Mount & Blade tient pour moitié au jeu de jambes, et le jeu de
## jambes n'existe QUE par l'asymétrie : reculer doit coûter, se désengager doit
## prendre un instant. Quand avancer, reculer et se déplacer de côté vont à la
## même vitesse et démarrent au quart de tour, l'espacement n'a plus de valeur
## tactique — on entre et on sort de portée gratuitement, et toute la lecture de
## distance s'effondre.
##
## Le compromis retenu : ces règles ne s'appliquent QU'EN POSTURE DE COMBAT
## (garde levée ou coup engagé — voir `combat_stance`). Hors combat, le
## déplacement reste au millième la marche de Minecraft, demande d'origine
## intacte. Lever sa garde devient donc un ENGAGEMENT du corps entier, pas
## seulement des bras : on gagne une défense et on perd sa mobilité. C'est un
## choix qui se fait et se défait à volonté, ce qui en fait une décision de
## joueur plutôt qu'une taxe permanente.
const BACKPEDAL_FACTOR := 0.58   # reculer, garde haute : nettement plus lent
const STRAFE_FACTOR := 0.78      # tourner autour de l'adversaire : un peu plus lent
## Rapidité d'établissement de la vitesse voulue, en fractions par seconde.
## Donne au corps une inertie COURTE : assez pour qu'un changement de direction
## se sente et se lise chez l'adversaire, trop brève pour qu'on se sente patiner.
const FOOTWORK_ACCEL := 14.0

const PLAYER_RADIUS := 0.35
const PLAYER_HEIGHT := 2.0
## Hauteur maximale franchie sans sauter. 1.0 = exactement une marche d'un
## bloc ; au-delà il faut toujours sauter (une falaise de 2 blocs reste un
## obstacle, sinon le relief perd tout sens tactique).
const STEP_HEIGHT := 1.0
## Vue légèrement sous PLAYER_HEIGHT pour que les yeux restent DANS le bloc
## de tête plutôt que pile à sa limite supérieure (évite un clignotement de
## collision contre un plafond) — PLAYER_HEIGHT reste la source de vérité.
const EYE_HEIGHT := PLAYER_HEIGHT - 0.1

var bench := false
## Verrouillage des entrées pendant les benchs (mesures non contaminées).
var input_locked := false
## Vol libre : off par défaut — le joueur marche au sol comme prévu (6.3).
var flying := false
var _yaw := 0.0
var _pitch := 0.0
var _vertical_velocity := 0.0
var _grounded := false
var _jump_requested := false
## Secousse d'impact ACTUELLEMENT ajoutée à `rotation` (tangage, lacet, roulis).
## Mémorisée pour être défalquée partout où l'on relit `rotation` comme si
## c'était la visée : lecture de la souris et diffusion réseau. C'est le prix à
## payer pour que la secousse reste une surcouche et ne contamine jamais l'état
## de visée — voir ImpactFeedback.camera_shake().
var _applied_shake := Vector3.ZERO
## Posture de combat : garde levée ou coup engagé. Poussée par Player à chaque
## frame — la caméra ne connaît ni arme ni endurance, et n'a pas à les
## connaître : elle ne reçoit qu'un booléen de posture.
var combat_stance := false
## Vitesse horizontale courante (blocs/s), pour l'inertie en posture de combat.
## Hors combat elle est TOUJOURS égale à la vitesse voulue : la marche reste
## instantanée, exactement comme dans Minecraft.
var _walk_velocity := Vector3.ZERO
## Réplication réseau (E.11 : non-fiable, 10-20 Hz) — purement visuel/réseau,
## jamais de logique de jeu ici (E.1).
const NETWORK_SYNC_INTERVAL := 1.0 / 15.0
var _network_sync_timer := 0.0


func _unhandled_input(event: InputEvent) -> void:
	if bench or input_locked:
		return
	var button := event as InputEventMouseButton
	if button != null and button.pressed and button.button_index == MOUSE_BUTTON_LEFT \
			and Input.mouse_mode != Input.MOUSE_MODE_CAPTURED:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
		get_viewport().set_input_as_handled()  # Le clic de capture ne mine pas.
	var key := event as InputEventKey
	if key != null and key.pressed and key.physical_keycode == KEY_ESCAPE:
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	if event.is_action_pressed("toggle_fly"):
		flying = not flying
		if flying:
			_vertical_velocity = 0.0
	if event.is_action_pressed("jump") and not flying:
		_jump_requested = true  # Consommé au prochain _process si au sol.
	var motion := event as InputEventMouseMotion
	if motion != null and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		# Repart de la rotation courante (elle peut avoir été posée par main.gd),
		# DÉFALQUÉE de la secousse d'impact : celle-ci est une surcouche
		# décorative, pas un mouvement de visée. Sans cette soustraction, chaque
		# mouvement de souris pendant une secousse en absorberait une bribe dans
		# `_yaw`/`_pitch`, et la caméra ne reviendrait jamais à son point de
		# départ — le joueur verrait sa visée dériver un peu à chaque coup porté.
		var aim := rotation - _applied_shake
		_yaw = aim.y - motion.relative.x * SENSITIVITY
		_pitch = clampf(aim.x - motion.relative.y * SENSITIVITY, -1.5, 1.5)
		rotation = Vector3(_pitch, _yaw, 0.0) + _applied_shake


## --- Voyage rapide GRADUEL (carte, 2026-07-26) : téléporte progressivement
## vers la cible pendant que le TEMPS DE JEU s'écoule (ticks réellement simulés
## → mana régénère, faim, etc.). Accéléré (quelques secondes réelles), on reste
## sur la carte. `total_ticks` = coût de temps du trajet (fourni par le joueur).
const TRAVEL_MAX_SECONDS := 6.0     # durée réelle max de l'animation de voyage.
const TRAVEL_MIN_TICKS_PER_SEC := 1000.0
var _travel_active := false
var _travel_from := Vector2.ZERO
var _travel_target := Vector2.ZERO
var _travel_total := 0
var _travel_done := 0
var _travel_rate := 0.0
func travel_to(wx: int, wz: int, total_ticks: int) -> void:
	_travel_from = Vector2(position.x, position.z)
	_travel_target = Vector2(float(wx), float(wz))
	_travel_total = maxi(total_ticks, 1)
	_travel_done = 0
	_travel_rate = maxf(TRAVEL_MIN_TICKS_PER_SEC, float(_travel_total) / TRAVEL_MAX_SECONDS)
	_travel_active = true


func is_traveling() -> bool:
	return _travel_active


func _process_travel(delta: float) -> void:
	var k := mini(int(ceil(_travel_rate * delta)), _travel_total - _travel_done)
	if k > 0:
		TickManager.push_ticks(k)  # simule vraiment le temps (mana/faim/IA…).
		_travel_done += k
	var frac := float(_travel_done) / float(_travel_total)
	var xz := _travel_from.lerp(_travel_target, frac)
	var h := 24.0
	if WorldManager.generator != null:
		h = float(WorldManager.generator.height_at(int(xz.x), int(xz.y)))
	position = Vector3(xz.x + 0.5, h + 2.9, xz.y + 0.5)
	_vertical_velocity = 0.0
	_grounded = true
	if _travel_done >= _travel_total:
		_travel_active = false


func _process(delta: float) -> void:
	if _travel_active:
		_process_travel(delta)
		WorldManager.update_center(global_position)
		return
	if bench:
		# Vol automatique rectiligne horizontal, altitude asservie au relief
		# (suit les montagnes/vallées — traversée continue de nouveaux chunks).
		var forward := -global_basis.z
		forward.y = 0.0
		position += forward.normalized() * BENCH_SPEED * delta
		if WorldManager.generator != null:
			var h := float(WorldManager.generator.height_at(int(position.x), int(position.z)))
			position.y = lerpf(position.y, h + 32.0, minf(delta * 1.5, 1.0))
	elif not input_locked:
		if flying:
			_process_flight(delta)
		else:
			_process_walk(delta)
	WorldManager.update_center(global_position)
	_apply_impact_shake()

	# Attend une connexion ÉTABLIE (pas seulement "active") : sinon l'appel
	# RPC échoue en boucle pendant la poignée de main ENet.
	if NetworkManager.is_multiplayer_active() and multiplayer.multiplayer_peer.get_connection_status() == MultiplayerPeer.CONNECTION_CONNECTED:
		_network_sync_timer += delta
		if _network_sync_timer >= NETWORK_SYNC_INTERVAL:
			_network_sync_timer = 0.0
			# Position de l'oeil + REGARD : sans le lacet et le tangage, on ne
			# voit pas ou l'autre joueur vise, ce qui rend un combat
			# directionnel illisible.
			# La secousse d'impact est retirée : elle est propre à CE client
			# (et désactivable dans les réglages). La diffuser ferait tressauter
			# notre avatar chez les autres pour une raison qu'ils ne voient pas.
			NetworkManager.rpc_broadcast_pose.rpc(global_position,
				rotation.y - _applied_shake.y, rotation.x - _applied_shake.x)


## Vitesse horizontale voulue (blocs/s) à partir des touches enfoncées.
##
## HORS POSTURE DE COMBAT, cette fonction est l'identité : elle rend exactement
## `direction.normalized() * speed`, la marche Minecraft d'origine, sans
## pondération ni inertie. C'est délibéré et c'est la première chose à vérifier
## si le déplacement change de sensation hors duel — la demande de 2026-07-21
## tient toujours.
##
## EN POSTURE DE COMBAT, deux règles s'ajoutent :
##
##   1. LA PONDÉRATION DIRECTIONNELLE. Le geste est décomposé dans le repère du
##      REGARD (ce qu'on a devant soi, ce qu'on a sur les côtés) et non dans
##      celui du monde : c'est l'adversaire qu'on regarde, donc c'est par rapport
##      à lui que reculer doit coûter. Reculer en diagonale coûte à proportion de
##      sa part de recul — il n'y a pas de biais d'angle à exploiter.
##   2. L'INERTIE. La vitesse s'établit en une fraction de seconde au lieu
##      d'apparaître d'un coup. C'est ce qui rend un désengagement LISIBLE :
##      l'adversaire voit le corps partir en arrière avant qu'il soit hors de
##      portée, et peut décider de punir. Sans elle, on se téléporte hors
##      d'allonge à la frame près et aucune lecture n'est possible.
func _footwork_velocity(direction: Vector3, forward: Vector3, right: Vector3,
		speed: float, delta: float) -> Vector3:
	var wish := direction.normalized() if direction != Vector3.ZERO else Vector3.ZERO
	if not combat_stance:
		# Marche Minecraft : la vitesse voulue EST la vitesse, immédiatement.
		_walk_velocity = wish * speed
		return _walk_velocity
	if wish != Vector3.ZERO:
		# `forward` pointe vers l'ARRIÈRE (c'est +Z de la base, et `move_forward`
		# le soustrait) : l'avant du joueur est donc son opposé.
		var ahead := -forward
		var along := wish.dot(ahead)
		var lateral := wish.dot(right)
		if along < 0.0:
			along *= BACKPEDAL_FACTOR
		wish = ahead * along + right * (lateral * STRAFE_FACTOR)
	_walk_velocity = _walk_velocity.move_toward(
		wish * speed, FOOTWORK_ACCEL * speed * delta)
	return _walk_velocity


## Remplace la secousse d'impact de la frame précédente par celle de cette
## frame. Le REMPLACEMENT (et non l'addition) est ce qui garantit le retour
## exact à zéro quand la secousse s'éteint : on retire toujours précisément ce
## qu'on avait ajouté, sans accumulation d'erreur au fil des coups.
func _apply_impact_shake() -> void:
	var shake := ImpactFeedback.camera_shake()
	if shake == _applied_shake:
		return
	rotation = rotation - _applied_shake + shake
	_applied_shake = shake


func _process_flight(delta: float) -> void:
	var direction := Vector3.ZERO
	if Input.is_action_pressed("move_forward"):
		direction -= Vector3(global_basis.z.x, 0, global_basis.z.z).normalized()
	if Input.is_action_pressed("move_back"):
		direction += Vector3(global_basis.z.x, 0, global_basis.z.z).normalized()
	if Input.is_action_pressed("move_left"):
		direction -= global_basis.x
	if Input.is_action_pressed("move_right"):
		direction += global_basis.x
	if Input.is_action_pressed("jump"):
		direction += Vector3.UP
	if Input.is_action_pressed("descend"):
		direction += Vector3.DOWN
	if direction != Vector3.ZERO:
		var speed := BOOST_SPEED if Input.is_action_pressed("sneak") else SPEED
		position += direction.normalized() * speed * delta


## Téléportation (voyage rapide, entrée/sortie de donjon — DungeonManager) :
## réinitialise l'état de chute pour éviter tout comportement bizarre (chute
## résiduelle, faux plafond) après un saut de position instantané.
## `yaw_degrees` : orientation horizontale imposée à l'arrivée, ou NAN pour
## conserver celle du joueur (défaut — une téléportation ne doit pas lui faire
## tourner la tête sans raison). Utilisé par l'entrée en donjon, qui dépose le
## joueur DOS à l'orifice de remontée (2026-07-28).
func teleport_to(pos: Vector3, yaw_degrees: float = NAN) -> void:
	position = pos
	_vertical_velocity = 0.0
	_grounded = false
	if not is_nan(yaw_degrees):
		_yaw = deg_to_rad(yaw_degrees)
		_pitch = 0.0
		rotation = Vector3(_pitch, _yaw, 0.0)


## Un bloc plein bloque le joueur (l'eau ne bloque pas — traversable/nageable).
## Blocs SUBDIVISÉS (4.1) : règle E.22 — solide seulement si >= 50 % du
## volume est plein (compte précalculé, O(1)). Audit 2026-07-21 : sans ça,
## l'id DOMINANT d'un bloc de culture (blé en sous-voxels rempli à ~5 %)
## comptait comme un bloc plein — traverser un champ obligeait à sauter sur
## chaque touffe.
func _is_blocking(wx: int, wy: int, wz: int) -> bool:
	if WorldManager.generator == null:
		return false
	var pos := Vector3i(wx, wy, wz)
	# Bloc SUBDIVISÉ : tester les sous-cellules AVANT l'id dominant (un bloc
	# majoritairement air a un dominant=0 mais peut contenir une construction
	# fine solide — bug de collision corrigé 2026-07-26). Seuil abaissé à 1/8
	# pour que les murs/structures fins bloquent le joueur.
	var solid := WorldManager.subdiv_solid_count(pos)
	if solid >= 0:
		return solid >= SubdivGrid.CELLS / 8
	var id := WorldManager.block_at_world(pos)
	return id != 0 and id != GameData.material_runtime_ids.get("eau", -1)


## Un bloc plein occupe-t-il l'un des 4 coins de l'emprise horizontale du
## joueur (PLAYER_RADIUS) au niveau `by` (indice de bloc, PAS une coordonnée
## flottante) ? Fonction de base réutilisée pour le sol, le plafond ET le
## corps (2026-07-20, réécriture collision — demande explicite « bouger
## exactement comme dans Minecraft »).
func _solid_at_level(x: float, z: float, by: int) -> bool:
	for corner_x in [-PLAYER_RADIUS, PLAYER_RADIUS]:
		for corner_z in [-PLAYER_RADIUS, PLAYER_RADIUS]:
			if _is_blocking(floori(x + corner_x), by, floori(z + corner_z)):
				return true
	return false


## Y a-t-il un appui solide sous l'emprise du joueur à cette position (au
## moins un coin au-dessus d'un bloc plein) ? Sert à la protection anti-chute
## du sneak (Minecraft) : un pas qui perdrait TOUT appui est refusé. Même
## epsilon anti-dérive flottante que _body_blocked_at.
func _has_support_at(x: float, z: float, feet_y: float) -> bool:
	return _solid_at_level(x, z, floori(feet_y + 0.001) - 1)


## Le corps du joueur (2 blocs de haut) peut-il occuper la colonne (wx,wz) à
## la hauteur de pieds `feet_y` (coordonnée MONDE : `feet_y` = la SURFACE sur
## laquelle le joueur se tient, PAS l'indice du bloc de sol — au repos sur un
## bloc de sol solide d'indice g, feet_y == g+1, exactement le sommet visuel
## de ce bloc, cohérent avec le rendu : un bloc d'indice g occupe l'espace
## monde [g, g+1). Les pieds/tête occupent donc floori(feet_y) et +1, les 2
## blocs D'AIR juste au-dessus du sol — voir BUG RÉEL corrigé le 2026-07-21).
## BUG RÉEL CORRIGÉ le 2026-07-21 (retour utilisateur : « le joueur se
## bloque, il faut constamment sauter ») : `floori(feet_y)` SANS epsilon
## souffrait exactement de la même dérive flottante que le bug de chute déjà
## corrigé (position.y → feet_y → position.y via EYE_HEIGHT ne fait pas un
## aller-retour EXACT en virgule flottante). Au repos EXACT sur un sol entier
## (feet_y == g+1), une dérive de quelques ulps en dessous faisait tomber
## `floori(feet_y)` sur `g` — LE BLOC DE SOL SOLIDE lui-même, pas le bloc
## d'air juste au-dessus — donc `_body_blocked_at` retournait « bloqué »
## EN PERMANENCE tant que le joueur restait immobile au sol pile sur un
## entier, remarche impossible sans sauter d'abord (le saut perturbe assez
## la position verticale pour éviter la dérive). Même correctif que la
## chute : un epsilon vers le haut avant floori().
func _body_blocked_at(x: float, z: float, feet_y: float) -> bool:
	var foot_by := floori(feet_y + 0.001)
	return _solid_at_level(x, z, foot_by) or _solid_at_level(x, z, foot_by + 1)


## FRANCHISSEMENT AUTOMATIQUE (auto-step) : le pas vers (nx, nz) est bloqué au
## niveau des PIEDS — peut-on le franchir en montant d'un bloc au lieu de
## s'arrêter ? Retourne le nouveau `feet_y` si oui, NAN sinon.
##
## Montée INSTANTANÉE, pas de lissage (lerp) : `position.y` est l'unique
## source de vérité de la hauteur (la caméra EST le joueur) et sert d'entrée
## aux tests de collision de la frame suivante. Un offset visuel qui décale
## position.y sans décaler la collision rouvrirait précisément la classe de
## bugs de dérive corrigée le 2026-07-21. Minecraft franchit d'ailleurs ses
## marches instantanément lui aussi, et personne ne le remarque.
##
## Aucun raycast et aucun collider : les blocs font une unité, donc la seule
## hauteur d'arrivée candidate est le SOMMET du bloc qui bloque, soit
## `foot_by + 1`. Tout se ramène à trois tests `_solid_at_level` déjà écrits —
## coût nul, et surtout aucune dépendance à PhysicsServer (le projet n'a aucun
## collider : la collision du joueur est analytique contre la grille).
##
## ATTENTION — MÊME PIÈGE QUE LES BUGS DU 2026-07-21 : `floori(feet_y)` est
## calculé ici avec le MÊME epsilon `+ 0.001` que `_body_blocked_at` et
## `_has_support_at`. L'aller-retour position.y ↔ feet_y via EYE_HEIGHT n'est
## pas exact en virgule flottante ; au repos pile sur un entier, un floori()
## nu tombe sur le bloc de sol SOLIDE au lieu du bloc d'air au-dessus, et
## reproduit très exactement le « le joueur se bloque, il faut constamment
## sauter » — ce qui serait comique pour la fonction censée le supprimer.
func _try_step_up(nx: float, nz: float, feet_y: float) -> float:
	var foot_by := floori(feet_y + 0.001)
	# Obstacle à hauteur de TÊTE : ce n'est pas une marche, c'est un mur.
	if _solid_at_level(nx, nz, foot_by + 1):
		return NAN
	# Rien de solide au niveau des pieds : le pas était bloqué pour une autre
	# raison (ou plus du tout) — l'auto-step n'a rien à faire ici.
	if not _solid_at_level(nx, nz, foot_by):
		return NAN
	var stepped := float(foot_by + 1)
	if stepped - feet_y > STEP_HEIGHT + 0.001:
		return NAN
	# Le corps doit TENIR à l'arrivée (pieds et tête libres à la nouvelle
	# hauteur) : sinon on monterait dans un boyau d'un bloc de haut.
	if _body_blocked_at(nx, nz, stepped):
		return NAN
	# ...et le plafond au-dessus de la position ACTUELLE doit laisser monter :
	# franchir une marche sous une corniche basse enfoncerait la tête dedans.
	if _solid_at_level(position.x, position.z, foot_by + 2):
		return NAN
	return stepped


## Marche au sol : gravité + saut, collision RÉELLE contre les blocs du monde
## (2026-07-20, réécriture — l'ancienne version calait le sol sur la hauteur
## PROCÉDURALE pure, `generator.height_at()`, ignorant totalement les blocs
## réellement minés/posés/les grottes/rivières — le joueur flottait au-dessus
## des trous et traversait le terrain modifié. Corrigé en collisionnant
## contre le monde RÉEL, `WorldManager.block_at_world`, comme l'horizontal.)
## BUG RÉEL CORRIGÉ le 2026-07-21 (retour utilisateur : « la caméra passe à
## travers les blocs, la vue est au niveau d'1 bloc et non 2, le joueur se
## bloque et doit sauter en permanence ») : le code posait `feet_y` À
## L'INDICE MÊME du bloc de sol solide (`new_feet_y = float(by)`) au lieu de
## SUR SON SOMMET (`by + 1`) — la caméra/les pieds étaient donc enfoncés de
## près d'un bloc entier DANS le sol à chaque atterrissage (le bloc `by`
## occupe l'espace monde [by, by+1), donc `feet_y == by` est à l'intérieur du
## solide, pas dessus). Ça expliquait TOUT à la fois : caméra qui clippe dans
## les blocs, hauteur de vue perçue comme "1 bloc" au lieu de 2 (les yeux
## n'étaient qu'à ~0.9 bloc au-dessus de la vraie surface visible), et le
## joueur qui semblait "coincé" contre des marches d'à peine 0.1 bloc de trop
## (le corps testé pour le mouvement horizontal utilisait le MÊME feet_y
## décalé, donc chaque bordure de bloc voisine touchait le corps trop tôt).
## Balayage vertical (pas un seul test au point d'arrivée) pour ne jamais
## traverser un bloc en un seul pas si la chute est rapide (façon Minecraft).
func _process_walk(delta: float) -> void:
	var forward := Vector3(global_basis.z.x, 0, global_basis.z.z).normalized()
	var right := Vector3(global_basis.x.x, 0, global_basis.x.z).normalized()
	var direction := Vector3.ZERO
	if Input.is_action_pressed("move_forward"):
		direction -= forward
	if Input.is_action_pressed("move_back"):
		direction += forward
	if Input.is_action_pressed("move_left"):
		direction -= right
	if Input.is_action_pressed("move_right"):
		direction += right
	# Vitesse façon Minecraft : Shift = sneak (lent + anti-chute au bord),
	# Ctrl = sprint, sinon marche. (Shift n'est plus « courir » : MC réserve
	# Shift au sneak — le sprint vit sur Ctrl comme dans MC.)
	var sneaking := Input.is_action_pressed("sneak")
	var speed := WALK_SPEED
	if sneaking:
		speed = SNEAK_SPEED
	elif Input.is_action_pressed("sprint"):
		speed = SPRINT_SPEED
	# JEU DE JAMBES : hors posture de combat, ceci rend exactement
	# `direction.normalized() * speed` — la marche Minecraft d'origine, au
	# millième. En posture de combat, le recul et le pas de côté sont pondérés et
	# la vitesse s'établit avec une brève inertie.
	var velocity := _footwork_velocity(direction, forward, right, speed, delta)
	if velocity.length_squared() > 0.000001 and WorldManager.generator != null:
		var move := velocity * delta
		var feet_y := position.y - EYE_HEIGHT
		# Franchissement automatique seulement AU SOL et hors sneak : en l'air
		# il transformerait le saut en escalade, et le sneak est le mode
		# « placement précis » (sa protection anti-chute au bord suppose que le
		# joueur maîtrise exactement où il pose les pieds).
		var can_step := _grounded and not sneaking
		# Résolution par axe (glissement le long des murs plutôt que blocage
		# net). En sneak au sol, un pas qui perdrait tout appui est refusé
		# (protection anti-chute au bord, comportement Minecraft).
		if not _body_blocked_at(position.x + move.x, position.z, feet_y) \
				and (not sneaking or not _grounded or _has_support_at(position.x + move.x, position.z, feet_y)):
			position.x += move.x
		elif can_step:
			var stepped := _try_step_up(position.x + move.x, position.z, feet_y)
			if not is_nan(stepped):
				position.x += move.x
				feet_y = stepped   # l'axe Z suivant doit tester à la NOUVELLE hauteur.
				position.y = stepped + EYE_HEIGHT
				_vertical_velocity = 0.0
		if not _body_blocked_at(position.x, position.z + move.z, feet_y) \
				and (not sneaking or not _grounded or _has_support_at(position.x, position.z + move.z, feet_y)):
			position.z += move.z
		elif can_step:
			var stepped := _try_step_up(position.x, position.z + move.z, feet_y)
			if not is_nan(stepped):
				position.z += move.z
				feet_y = stepped
				position.y = stepped + EYE_HEIGHT
				_vertical_velocity = 0.0
	elif velocity.length_squared() > 0.000001:
		position += velocity * delta

	if WorldManager.generator == null:
		return
	if _jump_requested and _grounded:
		_vertical_velocity = JUMP_SPEED
	_jump_requested = false
	_vertical_velocity = maxf(_vertical_velocity - GRAVITY * delta, -TERMINAL_VELOCITY)
	var old_feet_y := position.y - EYE_HEIGHT
	var new_feet_y := old_feet_y + _vertical_velocity * delta

	if _vertical_velocity > 0.0:
		# Monte (saut) : balaie les niveaux de tête traversés (floori(feet_y)+1
		# = bloc occupé par la tête ; le bloc juste au-dessus, +2, est un
		# plafond potentiel), s'arrête juste EN DESSOUS du bloc plein touché.
		var start_by := floori(old_feet_y) + 2
		var end_by := floori(new_feet_y) + 2
		for by in range(start_by, end_by + 1):
			if _solid_at_level(position.x, position.z, by):
				new_feet_y = old_feet_y
				_vertical_velocity = 0.0
				break
	else:
		# Descend (ou stationnaire) : balaie le bloc SOUS les pieds vers le
		# bas, s'arrête sur le PREMIER bloc solide rencontré (jamais de
		# tunneling à travers plusieurs blocs en une frame lors d'une chute
		# rapide). `feet_y` REPOSE SUR LE SOMMET du bloc solide trouvé
		# (`by + 1`), jamais à son indice propre (voir le commentaire au-
		# dessus de `_body_blocked_at` — bug réel du 2026-07-21). Le bloc
		# sous les pieds à la position `feet_y` est `floori(feet_y) - 1` ;
		# epsilon vers le haut pour la même raison que précédemment (dérive
		# flottante du aller-retour position.y ↔ feet_y au repos exact).
		var start_by := floori(old_feet_y - 1.0 + 0.001)
		var end_by := floori(new_feet_y - 1.0)
		var landed := false
		for by in range(start_by, end_by - 1, -1):
			if _solid_at_level(position.x, position.z, by):
				# On n'ATTERRIT que si les pieds ont réellement atteint le sommet
				# du bloc (by+1). Si le bloc solide le plus haut est encore SOUS
				# les pieds (on vient de marcher au-dessus du vide en descendant
				# d'une marche), on ne snappe PAS : on se laisse TOMBER (la gravité
				# continue). Corrige le « snap direct au bloc du dessous »
				# (2026-07-26).
				if new_feet_y <= float(by + 1):
					new_feet_y = float(by + 1)
					_vertical_velocity = 0.0
					landed = true
				break
		_grounded = landed

	position.y = new_feet_y + EYE_HEIGHT
