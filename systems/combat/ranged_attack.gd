class_name RangedAttack
extends RefCounted
## Cycle de TIR (2026-08-02) — bander, viser, décocher, recharger.
##
## POURQUOI UNE MACHINE À ÉTATS SÉPARÉE DE `MeleeAttack`. Les deux se
## ressemblent de loin — une préparation, un instant décisif, une récupération —
## mais ce qu'elles mesurent n'a rien de commun. En mêlée la préparation ARME un
## geste dont la direction est le pari ; au tir elle TEND une corde, et le pari
## est la précision, qui monte puis se dégrade si l'on tient trop longtemps. Les
## fondre aurait donné une machine avec deux jeux de règles et un test d'arme à
## chaque transition.
##
## Comme `MeleeAttack`, ce fichier ne connaît ni Player, ni GameData, ni monde :
## il ne calcule que du temps et une dispersion. Il ne tire rien lui-même — il
## dit QUAND et AVEC QUELLE précision, l'appelant crée le projectile.

## BANDE     : la corde se tend, la précision monte ;
## VISE      : tension pleine, on vise aussi longtemps qu'on veut — mais le bras
##             fatigue et la précision REDESCEND ;
## RECHARGE  : après le tir, l'arme est inutilisable (déterminant à l'arbalète).
enum State { IDLE, BANDE, VISE, RECHARGE }

## Dispersion angulaire, en degrés, d'un tir décoché à tension NULLE. Un arc
## relâché aussitôt n'atteint rien : c'est ce qui interdit le clic frénétique et
## rend la tension obligatoire.
const SPREAD_MAX := 9.0
## Dispersion à tension pleine, avant fatigue. Jamais zéro : une arme parfaite
## supprimerait la compétence, et le talent du tireur n'aurait plus d'objet.
const SPREAD_MIN := 0.35
## Au-delà de cette durée de visée (en ms), le bras FATIGUE et la dispersion
## remonte. C'est la contrepartie du maintien : viser est gratuit un instant,
## coûteux ensuite.
const AIM_STEADY_MS := 1200.0
const AIM_FATIGUE_MS := 2600.0
## Dispersion atteinte à fatigue complète — pire qu'un tir à mi-tension, pour
## que tenir indéfiniment soit une vraie erreur.
const SPREAD_TIRED := 5.0

var state: int = State.IDLE
## Progression 0..1 de la tension, pour l'affichage et la pose du corps.
var draw_ratio := 0.0

var _elapsed_ms := 0.0
var _draw_ms := 900.0
var _reload_ms := 0.0
var _aim_ms := 0.0
var _input_held := true


func is_busy() -> bool:
	return state != State.IDLE


## Peut-on décocher ? Une arme en rechargement ne tire pas, même si le joueur
## clique — c'est tout l'arbitrage entre l'arc et l'arbalète.
func can_fire() -> bool:
	return state == State.BANDE or state == State.VISE


## Le joueur commence à bander. `stats` vient de `WeaponStats.derive`.
func begin(stats: Dictionary) -> void:
	if is_busy():
		return
	state = State.BANDE
	_elapsed_ms = 0.0
	_aim_ms = 0.0
	_input_held = true
	_draw_ms = maxf(float(stats.get("tension_ms", 900.0)), 1.0)
	# La récupération de l'arme SERT de rechargement : une arbalète lente à
	# manœuvrer est lente à recharger, sans qu'il faille une seconde donnée.
	_reload_ms = float(stats.get("recovery_ms", 400.0)) + _draw_ms * 0.5
	draw_ratio = 0.0


func release_input() -> void:
	_input_held = false


## Abandonne le tir (garde levée, arme changée, stagger). La corde se détend
## sans rien décocher.
func interrupt() -> void:
	state = State.IDLE
	_elapsed_ms = 0.0
	_aim_ms = 0.0
	draw_ratio = 0.0


## Avance d'une frame. Retourne "arme" quand la tension est pleine, "recharge"
## quand l'arme redevient prête, "" sinon. Le TIR n'est pas décidé ici : c'est
## l'appelant qui appelle `fire()` au relâchement.
func advance(delta: float) -> String:
	if state == State.IDLE:
		return ""
	_elapsed_ms += delta * 1000.0
	match state:
		State.BANDE:
			draw_ratio = clampf(_elapsed_ms / _draw_ms, 0.0, 1.0)
			if _elapsed_ms >= _draw_ms:
				state = State.VISE
				_elapsed_ms = 0.0
				_aim_ms = 0.0
				draw_ratio = 1.0
				return "arme"
		State.VISE:
			_aim_ms += delta * 1000.0
		State.RECHARGE:
			if _elapsed_ms >= _reload_ms:
				state = State.IDLE
				_elapsed_ms = 0.0
				draw_ratio = 0.0
				return "recharge"
	return ""


## Dispersion COURANTE, en degrés. C'est la seule chose que cette machine
## produit d'utile au tir : l'appelant en fait un cône autour de l'axe de visée.
##
## La courbe a trois temps, et chacun porte une décision de jeu :
##   tension incomplète → très dispersé (on ne décoche pas à moitié tendu) ;
##   tension pleine     → au meilleur, brièvement ;
##   visée prolongée    → dégradation (tenir en joue coûte).
func spread_degrees(skill_factor: float) -> float:
	var base := SPREAD_MAX
	if state == State.BANDE:
		base = lerpf(SPREAD_MAX, SPREAD_MIN, draw_ratio * draw_ratio)
	elif state == State.VISE:
		if _aim_ms <= AIM_STEADY_MS:
			base = SPREAD_MIN
		else:
			var fatigue := clampf(
				(_aim_ms - AIM_STEADY_MS) / maxf(AIM_FATIGUE_MS - AIM_STEADY_MS, 1.0), 0.0, 1.0)
			base = lerpf(SPREAD_MIN, SPREAD_TIRED, fatigue)
	# La COMPÉTENCE resserre le cône sans jamais l'annuler : un débutant touche
	# une silhouette à dix mètres, un maître la vise à cinquante.
	return base / maxf(skill_factor, 0.2)


## Décoche. Retourne la dispersion du tir qui part, et passe en rechargement.
func fire(skill_factor: float) -> float:
	var spread := spread_degrees(skill_factor)
	state = State.RECHARGE
	_elapsed_ms = 0.0
	draw_ratio = 0.0
	return spread


## Direction du tir : l'axe de visée DÉVIÉ dans un cône de `spread` degrés.
## Tirée au hasard dans le cône — la dispersion est une incertitude, pas un
## biais : deux tirs identiques ne doivent pas partir au même endroit.
static func scatter(aim: Vector3, spread_deg: float, rng: RandomNumberGenerator) -> Vector3:
	if spread_deg <= 0.001:
		return aim.normalized()
	var axis := aim.normalized()
	var reference := Vector3.UP if absf(axis.dot(Vector3.UP)) < 0.95 else Vector3.RIGHT
	var side := reference.cross(axis).normalized()
	# Racine carrée du tirage : sans elle, les tirs se concentreraient au centre
	# du disque et le cône ne se sentirait pas.
	var angle := deg_to_rad(spread_deg) * sqrt(rng.randf())
	var roll := rng.randf() * TAU
	var offset := (side * cos(roll) + axis.cross(side) * sin(roll)) * tan(angle)
	return (axis + offset).normalized()
