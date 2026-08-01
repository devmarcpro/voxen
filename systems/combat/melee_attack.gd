class_name MeleeAttack
extends RefCounted
## Machine à états d'une attaque de mêlée directionnelle (2026-07-28).
##
## POURQUOI CE FICHIER EXISTE — L'EXCEPTION À LA RÈGLE DU TICK. TickManager
## pose que « aucun système de gameplay n'utilise _process(delta) » : tout
## avance à 10 Hz. Le combat directionnel ne peut pas s'y plier — un tick dure
## 100 ms, or une fenêtre de parade en vaut 80 à 420 et la phase de frappe d'une
## dague à peine plus. Résoudre une parade au tick, c'est la résoudre à ±100 ms
## près : le joueur perdrait des échanges qu'il a visiblement gagnés.
##
## L'exception est donc CADRÉE, pas subie :
##   - CE fichier avance à la frame et ne calcule QUE du temps et de la
##     géométrie. Il ne touche à aucun état de jeu : ni dégâts, ni endurance,
##     ni XP, ni santé. Il produit des ÉVÉNEMENTS et rien d'autre.
##   - Le tick (phase entities) reste la seule autorité : il draine ces
##     événements et applique leurs conséquences. Les dégâts, l'XP, l'aggro et
##     le réseau continuent d'avancer à 10 Hz, inchangés.
##
## Conséquence pratique : ce fichier ne connaît ni Player, ni Creature, ni
## GameData. Il est testable seul et ne peut pas, par construction, faire
## diverger l'état du jeu de ce que le tick a validé.

## Phases du cycle.
##
## ATTAQUE MAINTENUE (2026-07-28, demande explicite). Auparavant le clic
## déclenchait toute la séquence d'un bloc : on ne pouvait ni choisir sa
## direction posément, ni attendre le bon moment. Désormais :
##   BOUTON ENFONCÉ  → LECTURE (échantillonne le geste) → WINDUP (l'arme
##                     s'arme) → ARMEE, où l'on reste AUSSI LONGTEMPS QU'ON
##                     VEUT ;
##   BOUTON RELÂCHÉ  → RELEASE (la lame part) → RECOVERY.
##
## C'est le fonctionnement de Mount & Blade, et il change le combat en
## profondeur : tenir sa garde armée devient une menace lisible par
## l'adversaire, et le joueur choisit l'instant de la frappe.
##
## LA DIRECTION EST VERROUILLÉE À LA FIN DE LA LECTURE (2026-08-01, demande
## explicite de l'auteur). Elle restait auparavant modifiable pendant tout le
## wind-up et toute la garde armée. Deux raisons de fermer cette porte :
##
##   1. C'est le geste de Mount & Blade. Une fois le coup engagé, on ne le
##      redirige pas — on l'annule (feinte : lever sa garde) et on recommence.
##      Sans ce verrou, la feinte perd sa raison d'être : pourquoi payer une
##      annulation quand un mouvement de souris suffit ?
##   2. La télégraphie devient une VRAIE promesse. L'adversaire qui a lu la
##      direction pendant le wind-up sait ce qui arrive ; une direction qui
##      pouvait changer jusqu'au dernier instant rendait cette lecture
##      inutile, et donc tout le système directionnel décoratif.
##
## Conséquence : viser à la souris pendant qu'on tient sa garde armée n'affecte
## plus la frappe. C'est voulu — on vise ET on garde sa direction.
enum State { IDLE, LECTURE, WINDUP, ARMEE, RELEASE, RECOVERY }

## Directions d'attaque. Elles correspondent au geste de souris capturé.
enum Direction { ESTOC, TAILLE_GAUCHE, TAILLE_DROITE, OVERHEAD }

## Durée de la fenêtre de lecture du geste, en ms. Assez longue pour qu'un
## mouvement volontaire soit lisible, assez courte pour rester imperceptible.
const GESTURE_MS := 110.0
## Amplitude de geste (en pixels cumulés) au-delà de laquelle une direction
## latérale/verticale l'emporte sur l'estoc par défaut. Sous ce seuil, un clic
## sans geste donne un estoc — le coup le plus neutre.
const GESTURE_THRESHOLD := 22.0
## Décroissance du geste cumulé, par seconde. N'agit plus que pendant la FENÊTRE
## DE LECTURE (110 ms) : sans cet oubli, les mouvements de souris précédant le
## clic pollueraient la lecture du geste. Une fois la direction verrouillée, le
## geste n'est plus consulté du tout.
const GESTURE_DECAY_PER_SEC := 6.0

var state: int = State.IDLE
var direction: int = Direction.ESTOC
## Progression 0..1 dans la phase courante — le balayage de lame s'en sert
## pour placer la pointe de l'arme.
var phase_ratio := 0.0
## Vrai tant que l'attaque courante n'a encore touché personne : une frappe ne
## touche qu'une fois, même si la lame reste dans la cible plusieurs frames.
var can_still_hit := false

var _elapsed_ms := 0.0
var _gesture := Vector2.ZERO
## Le bouton d'attaque est-il encore enfoncé ? Tant qu'il l'est, l'arme reste
## armée au lieu de partir toute seule.
var _input_held := true


## Durées de la frappe en cours, figées au déclenchement : changer d'arme en
## plein swing ne doit pas réécrire le timing du coup déjà lancé.
var _windup_ms := 0.0
var _release_ms := 0.0
var _recovery_ms := 0.0


func is_busy() -> bool:
	return state != State.IDLE


## Le joueur vient de cliquer : on entre en lecture de geste. `stats` est le
## dictionnaire produit par WeaponStats.derive().
func begin(stats: Dictionary) -> void:
	if is_busy():
		return
	state = State.LECTURE
	_elapsed_ms = 0.0
	_gesture = Vector2.ZERO
	_input_held = true
	_windup_ms = float(stats.get("windup_ms", 200.0))
	_release_ms = float(stats.get("release_ms", 80.0))
	_recovery_ms = float(stats.get("recovery_ms", 200.0))
	phase_ratio = 0.0
	can_still_hit = false


## Mouvement de souris à cumuler (appelé depuis _unhandled_input). Pris en compte
## PENDANT LA SEULE FENÊTRE DE LECTURE : passé ce cap, la direction est
## verrouillée et bouger la souris ne fait plus que viser.
func feed_gesture(relative: Vector2) -> void:
	if state == State.LECTURE:
		_gesture += relative


## Le joueur a RELÂCHÉ le bouton d'attaque : la frappe part (à la fin du
## wind-up si celui-ci est encore en cours).
func release_input() -> void:
	_input_held = false


## Avance d'une frame. Retourne l'événement franchi pendant cette frame :
##   "locked"    — direction verrouillée, le wind-up commence (télégraphie IA) ;
##   "release"   — la lame devient dangereuse ;
##   "done"      — fin de la récupération, le joueur peut réattaquer ;
##   ""          — rien de notable.
func advance(delta: float) -> String:
	if state == State.IDLE:
		return ""
	_elapsed_ms += delta * 1000.0
	# Oubli progressif du geste : seul le mouvement RÉCENT oriente la frappe.
	_gesture = _gesture.move_toward(Vector2.ZERO, _gesture.length() * minf(GESTURE_DECAY_PER_SEC * delta, 1.0))
	match state:
		State.LECTURE:
			if _elapsed_ms >= GESTURE_MS:
				direction = _resolve_direction(_gesture)
				state = State.WINDUP
				_elapsed_ms = 0.0
				phase_ratio = 0.0
				return "locked"
		State.WINDUP:
			phase_ratio = clampf(_elapsed_ms / maxf(_windup_ms, 1.0), 0.0, 1.0)
			if _elapsed_ms >= _windup_ms:
				_elapsed_ms = 0.0
				phase_ratio = 1.0
				if _input_held:
					# Arme ARMÉE : on attend le joueur, indéfiniment.
					state = State.ARMEE
					return "locked"
				state = State.RELEASE
				can_still_hit = true
				return "release"
		State.ARMEE:
			# Garde armée tenue : rien ne part tant que le bouton n'est pas
			# relâché, et la DIRECTION NE BOUGE PLUS (voir en tête de fichier).
			phase_ratio = 1.0
			if not _input_held:
				state = State.RELEASE
				_elapsed_ms = 0.0
				phase_ratio = 0.0
				can_still_hit = true
				return "release"
		State.RELEASE:
			phase_ratio = clampf(_elapsed_ms / maxf(_release_ms, 1.0), 0.0, 1.0)
			if _elapsed_ms >= _release_ms:
				state = State.RECOVERY
				_elapsed_ms = 0.0
				phase_ratio = 0.0
				can_still_hit = false
		State.RECOVERY:
			phase_ratio = clampf(_elapsed_ms / maxf(_recovery_ms, 1.0), 0.0, 1.0)
			if _elapsed_ms >= _recovery_ms:
				state = State.IDLE
				phase_ratio = 0.0
				return "done"
	return ""


## Interrompt la frappe (stagger, démembrement du bras armé, mort).
func interrupt() -> void:
	state = State.IDLE
	phase_ratio = 0.0
	can_still_hit = false
	_elapsed_ms = 0.0


## Geste cumulé → direction. Le geste dominant l'emporte ; un geste trop faible
## donne l'estoc, qui est le coup neutre (et le seul possible dans un couloir
## étroit, ce qui tombe bien : c'est là qu'on ne bouge pas la souris).
static func _resolve_direction(gesture: Vector2) -> int:
	if gesture.length() < GESTURE_THRESHOLD:
		return Direction.ESTOC
	if absf(gesture.x) >= absf(gesture.y):
		return Direction.TAILLE_DROITE if gesture.x > 0.0 else Direction.TAILLE_GAUCHE
	# SOURIS VERS LE HAUT = OVERHEAD (corrigé le 2026-07-28 : « les attaques du
	# haut vers le bas ne marchent pas »). C'était inversé, et de deux façons à
	# la fois : contraire à la convention de Mount & Blade (on ARME vers le haut
	# pour frapper vers le bas), et contraire à mon propre HUD, qui place le
	# chevron overhead EN HAUT et l'estoc en bas. Le joueur levait la souris,
	# voyait le chevron du haut s'allumer dans sa tête, et déclenchait un estoc.
	# `gesture.y` est en coordonnées ÉCRAN : négatif = vers le haut.
	return Direction.OVERHEAD if gesture.y < 0.0 else Direction.ESTOC


## Position de la POINTE de l'arme pour la progression `u` ∈ [0,1] de la phase
## de frappe, en espace monde. `basis` est celle de la caméra (le buste suit le
## regard), `origin` le point de prise (la main).
##
## C'est ici que la « hitbox » vit : il n'y a aucun collider d'arme, seulement
## une pointe dont on connaît la position à chaque frame. Le segment entre deux
## frames consécutives est ce qu'on teste contre les zones de coup.
static func tip_position(direction_id: int, u: float, origin: Vector3, basis: Basis, reach: float) -> Vector3:
	var forward := -basis.z
	var right := basis.x
	var up := basis.y
	match direction_id:
		Direction.ESTOC:
			# Poussée droite : la pointe part de la garde et file vers l'avant.
			return origin + forward * lerpf(reach * 0.35, reach, u)
		Direction.TAILLE_DROITE:
			var angle := lerpf(deg_to_rad(55.0), deg_to_rad(-55.0), u)
			return origin + (forward * cos(angle) + right * sin(angle)) * reach
		Direction.TAILLE_GAUCHE:
			var angle_l := lerpf(deg_to_rad(-55.0), deg_to_rad(55.0), u)
			return origin + (forward * cos(angle_l) + right * sin(angle_l)) * reach
		Direction.OVERHEAD:
			var angle_v := lerpf(deg_to_rad(60.0), deg_to_rad(-35.0), u)
			return origin + (forward * cos(angle_v) + up * sin(angle_v)) * reach
	return origin + forward * reach


## Direction de GARDE qui pare une attaque venant de `attack_direction`.
##
## Les tailles sont MIROIR : un adversaire qui frappe de sa droite envoie sa
## lame sur VOTRE gauche, c'est donc à gauche qu'il faut parer. Estoc et
## overhead arrivent dans l'axe et se parent dans la même direction.
##
## C'est le pilier défensif de Mount & Blade : on ne « lève pas sa garde », on
## pare DANS LA BONNE DIRECTION, et se tromper coûte le coup entier. Sans
## cette règle il n'y a aucun duel de lecture.
## Gardes VOISINES d'une garde donnée : celles qu'un bouclier couvre en plus de
## la sienne. Le voisinage est celui du geste, pas de l'énumération — une garde
## haute jouxte les deux tailles, une garde basse (estoc) aussi ; les deux
## tailles ne se jouxtent PAS entre elles, sans quoi un bouclier couvrirait tout
## et la garde directionnelle n'aurait plus d'objet.
static func adjacent_guards(guard_direction: int) -> Array[int]:
	match guard_direction:
		Direction.OVERHEAD, Direction.ESTOC:
			return [Direction.TAILLE_GAUCHE, Direction.TAILLE_DROITE]
		Direction.TAILLE_GAUCHE, Direction.TAILLE_DROITE:
			return [Direction.OVERHEAD, Direction.ESTOC]
	return []


static func guard_for(attack_direction: int) -> int:
	match attack_direction:
		Direction.TAILLE_DROITE: return Direction.TAILLE_GAUCHE
		Direction.TAILLE_GAUCHE: return Direction.TAILLE_DROITE
	return attack_direction


## Nom lisible d'une direction (journal de debug, télégraphie, UI).
static func direction_name(direction_id: int) -> String:
	match direction_id:
		Direction.ESTOC: return "estoc"
		Direction.TAILLE_GAUCHE: return "taille_gauche"
		Direction.TAILLE_DROITE: return "taille_droite"
		Direction.OVERHEAD: return "overhead"
	return "inconnu"
