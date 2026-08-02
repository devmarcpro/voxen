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

## ENCHAÎNEMENT À DEUX ARMES (2026-08-02, demande de l'auteur). Un clic ne
## produit plus forcément UNE frappe : en dual wielding il en produit DEUX, la
## main forte puis la main gauche. C'est ce qui donne à la seconde arme une
## existence offensive — sans cela elle ne servait qu'à parer, et deux armes
## différentes se valaient.
##
## `strike` vaut 0 pour le coup de main forte, 1 pour le retour de main gauche.
## `strikes` est figé au déclenchement : changer d'équipement en plein
## enchaînement ne doit pas ajouter ni retirer un coup déjà engagé.
var strike := 0
var strikes := 1

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
## Répertoire de l'arme en cours, figé au déclenchement comme les durées.
var _allowed: Array = []


func begin(stats: Dictionary, strike_count: int = 1) -> void:
	if is_busy():
		return
	_allowed = stats.get("directions", [])
	strike = 0
	strikes = maxi(1, strike_count)
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
				# Le geste est lu, PUIS reporté sur ce que l'arme sait faire.
				direction = nearest_allowed(_resolve_direction(_gesture), _allowed)
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
				if strike + 1 < strikes:
					# RETOUR DE MAIN GAUCHE : la seconde arme enchaîne sans
					# repasser par le wind-up — c'est un enchaînement, pas une
					# seconde attaque, et le joueur ne peut pas l'interrompre.
					# Il paie donc l'engagement des deux coups d'un seul clic.
					strike += 1
					_elapsed_ms = 0.0
					phase_ratio = 0.0
					can_still_hit = true
					return "release"
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
	strike = 0
	strikes = 1
	_elapsed_ms = 0.0


## Direction du coup COURANT. Le retour de main gauche part en MIROIR : une
## taille droite revient par une taille gauche, ce qu'on fait naturellement en
## croisant deux lames. Conséquence de jeu, et elle est voulue : une garde
## d'arme ne couvre qu'UNE ligne, elle ne peut donc pas arrêter les deux coups —
## il faut un bouclier, qui couvre les directions voisines. Le dual wielding bat
## la défense à l'arme seule, le bouclier bat le dual wielding, la boucle du GDD
## (deux mains / bouclier / deux armes) se referme.
##
## L'estoc et le coup haut sont dans l'AXE : ils n'ont pas de miroir, le second
## coup repart donc du même côté.
func strike_direction() -> int:
	if strike == 0:
		return direction
	match direction:
		Direction.TAILLE_DROITE: return Direction.TAILLE_GAUCHE
		Direction.TAILLE_GAUCHE: return Direction.TAILLE_DROITE
	return direction


## Le coup courant part-il de la main GAUCHE ?
func is_offhand_strike() -> bool:
	return strike > 0


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
	return point_along(direction_id, u, origin, basis, reach, (1.0 - THRUST_START) * reach)


## Retrait de l'estoc au début du geste : la pointe part à 35 % du rayon et file
## jusqu'à 100 %. C'est le BRAS qui se déplie, donc toute l'arme avance de la
## même quantité — d'où une translation, et d'où le fait que le retrait soit un
## paramètre plutôt qu'une fraction du rayon de chaque point. Sans ça, un point
## proche de la main reculerait moins que la pointe et l'arme s'allongerait.
const THRUST_START := 0.35


## Position d'un point situé à `distance` de l'ORIGINE DE L'ARC (la prise), pour
## la progression `u` de la phase de frappe. `thrust_pull` est le recul de
## l'estoc au début du geste, en mètres.
##
## POURQUOI CETTE FONCTION EXISTE (2026-08-02). `tip_position` ne donnait que la
## POINTE, et c'est le seul point qui était testé contre les cibles : une
## hallebarde dont le fer traversait un torse ne touchait pas, parce que sa
## pointe, elle, passait au-dessus, et une épée ne coupait qu'avec son dernier
## centimètre. Une arme n'est pas un point — sa tête est un SEGMENT, et c'est ce
## segment qu'il faut promener. `tip_position` en devient un cas particulier,
## donc l'arc du geste et le placement des mains restent inchangés.
static func point_along(direction_id: int, u: float, origin: Vector3, basis: Basis,
		distance: float, thrust_pull: float = 0.0) -> Vector3:
	var forward := -basis.z
	var right := basis.x
	var up := basis.y
	match direction_id:
		Direction.ESTOC:
			return origin + forward * (distance - thrust_pull * (1.0 - u))
		Direction.TAILLE_DROITE:
			var angle := lerpf(deg_to_rad(55.0), deg_to_rad(-55.0), u)
			return origin + (forward * cos(angle) + right * sin(angle)) * distance
		Direction.TAILLE_GAUCHE:
			var angle_l := lerpf(deg_to_rad(-55.0), deg_to_rad(55.0), u)
			return origin + (forward * cos(angle_l) + right * sin(angle_l)) * distance
		Direction.OVERHEAD:
			var angle_v := lerpf(deg_to_rad(60.0), deg_to_rad(-35.0), u)
			return origin + (forward * cos(angle_v) + up * sin(angle_v)) * distance
	return origin + forward * distance


## Repli quand une direction n'est pas au répertoire de l'arme : le premier
## choix possible, dans l'ordre. Ce n'est PAS arbitraire — une masse à qui l'on
## demande un estoc doit abattre (le geste le plus proche du poussé, avec le
## poids devant), une rapière à qui l'on demande un coup haut doit piquer.
const DIRECTION_FALLBACK := {
	Direction.ESTOC: [Direction.ESTOC, Direction.OVERHEAD, Direction.TAILLE_DROITE, Direction.TAILLE_GAUCHE],
	Direction.OVERHEAD: [Direction.OVERHEAD, Direction.ESTOC, Direction.TAILLE_DROITE, Direction.TAILLE_GAUCHE],
	Direction.TAILLE_DROITE: [Direction.TAILLE_DROITE, Direction.TAILLE_GAUCHE, Direction.OVERHEAD, Direction.ESTOC],
	Direction.TAILLE_GAUCHE: [Direction.TAILLE_GAUCHE, Direction.TAILLE_DROITE, Direction.OVERHEAD, Direction.ESTOC],
}


## Direction RÉELLEMENT jouable la plus proche de `wanted`, selon le répertoire
## de l'arme. Une liste vide veut dire « tout est permis ».
##
## POURQUOI LES ARMES ONT UN RÉPERTOIRE (2026-08-02). Toutes faisaient les quatre
## directions : une pique taillait latéralement comme une dague, une masse
## piquait de la pointe. C'est ce qui rendait le choix d'une arme purement
## chiffré — allonge, dés, vitesse — alors que dans Mount & Blade on choisit une
## arme pour son JEU. Une lance qui ne fait qu'estoquer devient une arme de
## contrôle de distance ; une hache qui ne pique pas doit se rapprocher.
##
## Le geste du joueur n'est jamais REFUSÉ, il est REPORTÉ sur le coup le plus
## proche : un clic doit toujours produire une attaque, sinon l'arme paraît
## cassée. C'est la même règle pour l'IA, qui tire sa direction dans le même
## répertoire.
static func nearest_allowed(wanted: int, allowed: Array) -> int:
	if allowed.is_empty() or wanted in allowed:
		return wanted
	for candidate: int in DIRECTION_FALLBACK.get(wanted, []):
		if candidate in allowed:
			return candidate
	return allowed[0]


## Nom d'une direction vers sa valeur d'énumération (lecture des données).
static func direction_from_name(name: String) -> int:
	match name:
		"estoc": return Direction.ESTOC
		"taille_gauche": return Direction.TAILLE_GAUCHE
		"taille_droite": return Direction.TAILLE_DROITE
		"overhead": return Direction.OVERHEAD
	return Direction.ESTOC


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


## Axe de la LAME en garde : de la main vers la pointe, en espace monde.
##
## POURQUOI CE N'EST PAS L'ARC D'ATTAQUE (2026-08-02). L'arme était orientée par
## la direction main → cible, la même que pendant un coup : en garde haute elle
## pointait donc VERS LE HAUT, dans l'axe du coup qu'elle prétendait arrêter.
## Une lame parallèle à l'attaque ne l'intercepte pas — visuellement, le coup
## adverse passait à côté de l'arme et le joueur ne comprenait pas ce qu'il
## bloquait.
##
## On PARE EN TRAVERS. Une garde haute tient la lame à plat au-dessus de la
## tête, une garde latérale la dresse verticalement du côté couvert, et l'estoc
## se dévie en barrant la ligne médiane. Chaque axe est donc À PEU PRÈS
## PERPENDICULAIRE à la trajectoire qu'il coupe — c'est ce qui rend la parade
## lisible, chez soi comme chez l'adversaire.
##
## `guard_direction` est la garde CHOISIE (pas l'attaque couverte) : elle est
## déjà exprimée du point de vue du défenseur.
static func guard_blade_axis(guard_direction: int, basis: Basis) -> Vector3:
	var forward := -basis.z
	var right := basis.x
	var up := basis.y
	var axis := up
	match guard_direction:
		Direction.OVERHEAD:
			# Lame À PLAT au-dessus de la tête, pointe vers la gauche et
			# légèrement relevée : le toit qui arrête un coup descendant.
			axis = -right * 0.92 + up * 0.30 + forward * 0.20
		Direction.ESTOC:
			# Barre la ligne médiane en diagonale : c'est ainsi qu'on écarte une
			# pointe, en la faisant glisser sur le côté plutôt qu'en l'arrêtant.
			axis = up * 0.62 - right * 0.70 + forward * 0.32
		Direction.TAILLE_GAUCHE:
			# Lame DRESSÉE du côté couvert, pointe en l'air.
			axis = up * 0.90 - right * 0.38 + forward * 0.20
		Direction.TAILLE_DROITE:
			axis = up * 0.90 + right * 0.38 + forward * 0.20
	return axis.normalized() if axis.length_squared() > 0.000001 else up


## Décalage de la MAIN en garde, en repère caméra (droite, haut, avant), en
## fraction du rayon de bras. La main se place du côté qu'elle protège et à la
## hauteur de la ligne parée — sans quoi la lame serait bien orientée mais au
## mauvais endroit, ce qui se lit tout aussi mal.
static func guard_hand_offset(guard_direction: int) -> Vector3:
	match guard_direction:
		Direction.OVERHEAD:
			return Vector3(0.34, 0.62, 0.42)    # haute et à droite : on tient le toit
		Direction.ESTOC:
			return Vector3(0.18, 0.10, 0.72)    # au centre, à hauteur de poitrine
		Direction.TAILLE_GAUCHE:
			return Vector3(-0.34, 0.24, 0.62)
		Direction.TAILLE_DROITE:
			return Vector3(0.42, 0.24, 0.62)
	return Vector3(0.2, 0.0, 0.7)


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

## Slab test segment↔AABB. PARTAGÉ PAR LES DEUX CAMPS (2026-08-02) : il vivait
## sur la créature, mais le joueur a désormais ses propres zones de coup et doit
## être touché par exactement la même règle. Deux implémentations auraient fini
## par juger différemment le même coup selon qui le donne.
## Retourne le paramètre t ∈ [0, 1] de la première
## intersection, ou -1.0 si le segment manque la boîte. `direction` n'est PAS
## normalisée : t est donc directement la fraction du segment parcourue.
static func segment_aabb(from: Vector3, direction: Vector3, box_min: Vector3, box_max: Vector3) -> float:
	var t_near := 0.0
	var t_far := 1.0
	for axis in 3:
		var d: float = direction[axis]
		var origin: float = from[axis]
		var lo: float = box_min[axis]
		var hi: float = box_max[axis]
		if absf(d) < 0.000001:
			# Segment parallèle à cette paire de plans : il ne peut toucher que
			# s'il est DÉJÀ entre les deux.
			if origin < lo or origin > hi:
				return -1.0
			continue
		var t1 := (lo - origin) / d
		var t2 := (hi - origin) / d
		if t1 > t2:
			var swap := t1
			t1 = t2
			t2 = swap
		t_near = maxf(t_near, t1)
		t_far = minf(t_far, t2)
		if t_near > t_far:
			return -1.0
	return t_near


## Pré-parse des zones de coup JSON en `min`/`max` Vector3. PARTAGÉ PAR LES DEUX
## CAMPS (2026-08-02) : les créatures lisent leur gabarit, le joueur lit le sien,
## et tous deux doivent produire exactement la même structure — sinon le test
## d'intersection gérerait deux formats et finirait par en juger un de travers.
static func parse_zones(source: Array) -> Array:
	var out: Array = []
	for zone: Variant in source:
		var z: Dictionary = zone
		var mn: Array = z["min"]
		var sz: Array = z["size"]
		out.append({
			"id": String(z["id"]),
			"min": Vector3(mn[0], mn[1], mn[2]),
			"max": Vector3(mn[0] + sz[0], mn[1] + sz[1], mn[2] + sz[2]),
			"mult": float(z["mult"]),
		})
	return out
