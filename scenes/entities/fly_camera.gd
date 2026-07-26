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
## Minecraft), bloqué par les blocs pleins devant lui — pas de pas
## automatique, seul un saut manuel (Espace) permet de franchir un bloc.
const PLAYER_RADIUS := 0.35
const PLAYER_HEIGHT := 2.0
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
	if key != null and key.pressed and not key.echo and key.physical_keycode == KEY_F:
		flying = not flying
		if flying:
			_vertical_velocity = 0.0
	if key != null and key.pressed and not key.echo and key.physical_keycode == KEY_SPACE and not flying:
		_jump_requested = true  # Consommé au prochain _process si au sol.
	var motion := event as InputEventMouseMotion
	if motion != null and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		# Repart de la rotation courante (elle peut avoir été posée par main.gd).
		_yaw = rotation.y - motion.relative.x * SENSITIVITY
		_pitch = clampf(rotation.x - motion.relative.y * SENSITIVITY, -1.5, 1.5)
		rotation = Vector3(_pitch, _yaw, 0.0)


func _process(delta: float) -> void:
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

	# Attend une connexion ÉTABLIE (pas seulement "active") : sinon l'appel
	# RPC échoue en boucle pendant la poignée de main ENet.
	if NetworkManager.is_multiplayer_active() and multiplayer.multiplayer_peer.get_connection_status() == MultiplayerPeer.CONNECTION_CONNECTED:
		_network_sync_timer += delta
		if _network_sync_timer >= NETWORK_SYNC_INTERVAL:
			_network_sync_timer = 0.0
			NetworkManager.rpc_broadcast_position.rpc(global_position)


func _process_flight(delta: float) -> void:
	var direction := Vector3.ZERO
	if Input.is_physical_key_pressed(KEY_W):
		direction -= Vector3(global_basis.z.x, 0, global_basis.z.z).normalized()
	if Input.is_physical_key_pressed(KEY_S):
		direction += Vector3(global_basis.z.x, 0, global_basis.z.z).normalized()
	if Input.is_physical_key_pressed(KEY_A):
		direction -= global_basis.x
	if Input.is_physical_key_pressed(KEY_D):
		direction += global_basis.x
	if Input.is_physical_key_pressed(KEY_SPACE):
		direction += Vector3.UP
	if Input.is_physical_key_pressed(KEY_C):
		direction += Vector3.DOWN
	if direction != Vector3.ZERO:
		var speed := BOOST_SPEED if Input.is_physical_key_pressed(KEY_SHIFT) else SPEED
		position += direction.normalized() * speed * delta


## Téléportation (voyage rapide, entrée/sortie de donjon — DungeonManager) :
## réinitialise l'état de chute pour éviter tout comportement bizarre (chute
## résiduelle, faux plafond) après un saut de position instantané.
func teleport_to(pos: Vector3) -> void:
	position = pos
	_vertical_velocity = 0.0
	_grounded = false
	_travel_active = false  # une téléportation (donjon…) annule le voyage carte.


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
## Voyage progressif (carte) : marche automatique vers (wx,wz) à mi-vitesse.
var _travel_active := false
var _travel_target := Vector2.ZERO
func travel_to(wx: int, wz: int) -> void:
	_travel_target = Vector2(float(wx), float(wz))
	_travel_active = true


func _process_walk(delta: float) -> void:
	var forward := Vector3(global_basis.z.x, 0, global_basis.z.z).normalized()
	var right := Vector3(global_basis.x.x, 0, global_basis.x.z).normalized()
	var direction := Vector3.ZERO
	if Input.is_physical_key_pressed(KEY_W):
		direction -= forward
	if Input.is_physical_key_pressed(KEY_S):
		direction += forward
	if Input.is_physical_key_pressed(KEY_A):
		direction -= right
	if Input.is_physical_key_pressed(KEY_D):
		direction += right
	# Vitesse façon Minecraft : Shift = sneak (lent + anti-chute au bord),
	# Ctrl = sprint, sinon marche. (Shift n'est plus « courir » : MC réserve
	# Shift au sneak — le sprint vit sur Ctrl comme dans MC.)
	var sneaking := Input.is_physical_key_pressed(KEY_SHIFT)
	var speed := WALK_SPEED
	if sneaking:
		speed = SNEAK_SPEED
	elif Input.is_physical_key_pressed(KEY_CTRL):
		speed = SPRINT_SPEED
	if direction != Vector3.ZERO and WorldManager.generator != null:
		var move := direction.normalized() * speed * delta
		var feet_y := position.y - EYE_HEIGHT
		# Résolution par axe (glissement le long des murs plutôt que blocage
		# net). En sneak au sol, un pas qui perdrait tout appui est refusé
		# (protection anti-chute au bord, comportement Minecraft).
		if not _body_blocked_at(position.x + move.x, position.z, feet_y) \
				and (not sneaking or not _grounded or _has_support_at(position.x + move.x, position.z, feet_y)):
			position.x += move.x
		if not _body_blocked_at(position.x, position.z + move.z, feet_y) \
				and (not sneaking or not _grounded or _has_support_at(position.x, position.z + move.z, feet_y)):
			position.z += move.z
	elif direction != Vector3.ZERO:
		position += direction.normalized() * speed * delta

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
