extends Node
## DayNightManager — cycle jour/nuit (E.21). L'horloge existait déjà
## (TickManager : 24 000 ticks = 1 jour in-game, E.1) mais ne pilotait RIEN :
## le soleil était une lumière fixe et l'heure n'était qu'un cadran d'interface.
##
## Ce gestionnaire est la SOURCE DE VÉRITÉ de l'heure pour tout le jeu :
## éclairage, densité de spawn nocturne (E.21), et plus tard les routines de
## PNJ (E.16) et le commerce fermé la nuit. Aucun autre système ne doit
## recalculer l'heure depuis `tick_index` — sinon deux endroits divergeraient
## au premier changement de cadence.
##
## Découpage E.21, copié à la lettre :
##   aube 5h-7h · jour 7h-19h · crépuscule 19h-21h · nuit 21h-5h

const TICKS_PER_DAY := 24000.0
const HOURS_PER_DAY := 24.0

## Bornes des phases, en heures in-game (E.21).
const HOUR_DAWN := 5.0
const HOUR_DAY := 7.0
const HOUR_DUSK := 19.0
const HOUR_NIGHT := 21.0

## Heure de départ d'une PARTIE NEUVE (2026-07-28, demande explicite : 8 h du
## matin, plus minuit). Un monde neuf démarrait à `tick_index = 0`, soit 0 h —
## le joueur apparaissait en pleine nuit, avec la pire visibilité possible pour
## découvrir le monde et sans torche disponible au départ. 8 h tombe en pleine
## phase « jour » (7 h-19 h), avec une longue journée devant soi.
const START_HOUR := 8.0


## Valeur initiale de `TickManager.tick_index` pour une partie neuve.
## Ici et nulle part ailleurs : l'heure est calculée depuis `tick_index`, donc
## c'est ce gestionnaire — seule source de vérité de l'heure — qui doit décider
## de la conversion, pas l'appelant (SaveManager).
static func start_tick() -> int:
	return int(START_HOUR / HOURS_PER_DAY * TICKS_PER_DAY)

## Lumière directionnelle : énergie de plein jour et énergie nocturne (la
## nuit n'est jamais NOIRE — un noir total rendrait le jeu injouable sans
## système d'éclairage local encore implémenté ; E.21 prévoit que les torches
## prennent le relais, elles n'existent pas encore).
const SUN_ENERGY_DAY := 0.75
const SUN_ENERGY_NIGHT := 0.10
## Contribution du ciel à la lumière ambiante, jour et nuit.
const AMBIENT_DAY := 0.35
const AMBIENT_NIGHT := 0.12

## Teintes de la lumière selon la phase (interpolées).
const COLOR_DAWN := Color(1.0, 0.78, 0.62)
const COLOR_DAY := Color(1.0, 0.97, 0.92)
const COLOR_DUSK := Color(1.0, 0.65, 0.45)
const COLOR_NIGHT := Color(0.55, 0.65, 1.0)

## Rafraîchissement de l'éclairage : toutes les N frames. Le soleil bouge de
## 0,015° par tick — inutile de recalculer 60 fois par seconde (G.1).
const UPDATE_INTERVAL := 0.25

var _sun: DirectionalLight3D
var _environment: Environment
var _accumulator := 0.0


func _ready() -> void:
	set_process(true)


## Heure in-game courante, 0.0 à 24.0.
func hour() -> float:
	return fmod(float(TickManager.tick_index), TICKS_PER_DAY) / TICKS_PER_DAY * HOURS_PER_DAY


## Phase courante : "aube", "jour", "crepuscule" ou "nuit" (E.21).
func phase() -> String:
	var h := hour()
	if h < HOUR_DAWN or h >= HOUR_NIGHT:
		return "nuit"
	if h < HOUR_DAY:
		return "aube"
	if h < HOUR_DUSK:
		return "jour"
	return "crepuscule"


## true entre 21h et 5h (E.21 : « la nuit est dangereuse »).
func is_night() -> bool:
	return phase() == "nuit"


## Facteur de lumière du jour, 0 (nuit noire) à 1 (plein jour). Sert aussi
## aux systèmes qui veulent une transition continue plutôt qu'une phase.
func daylight() -> float:
	var h := hour()
	if h >= HOUR_DAY and h < HOUR_DUSK:
		return 1.0
	if h >= HOUR_NIGHT or h < HOUR_DAWN:
		return 0.0
	if h < HOUR_DAY:
		return inverse_lerp(HOUR_DAWN, HOUR_DAY, h)      # aube : 0 → 1
	return 1.0 - inverse_lerp(HOUR_DUSK, HOUR_NIGHT, h)  # crépuscule : 1 → 0


## Couleur de la lumière directionnelle à l'heure courante.
func light_color() -> Color:
	var h := hour()
	if h >= HOUR_DAY and h < HOUR_DUSK:
		return COLOR_DAY
	if h >= HOUR_NIGHT or h < HOUR_DAWN:
		return COLOR_NIGHT
	if h < HOUR_DAY:
		return COLOR_DAWN.lerp(COLOR_DAY, inverse_lerp(HOUR_DAWN, HOUR_DAY, h))
	return COLOR_DUSK.lerp(COLOR_NIGHT, inverse_lerp(HOUR_DUSK, HOUR_NIGHT, h))


## Avance l'horloge jusqu'à `target_hour` (saut de nuit, E.21). Retourne le
## nombre de ticks sautés — l'appelant les fait consommer par les systèmes
## concernés (faim, cultures, boutiques), le saut n'est jamais gratuit.
func ticks_until(target_hour: float) -> int:
	var current := hour()
	var delta := target_hour - current
	if delta <= 0.0:
		delta += HOURS_PER_DAY
	return int(delta / HOURS_PER_DAY * TICKS_PER_DAY)


func _process(delta: float) -> void:
	_accumulator += delta
	if _accumulator < UPDATE_INTERVAL:
		return
	_accumulator = 0.0
	_apply_lighting()


func _apply_lighting() -> void:
	if _sun == null or not is_instance_valid(_sun):
		var main := get_node_or_null("/root/Main")
		if main == null:
			return
		_sun = main.get_node_or_null("Sun") as DirectionalLight3D
		var world_env := main.get_node_or_null("WorldEnvironment") as WorldEnvironment
		if world_env != null:
			_environment = world_env.environment
		if _sun == null:
			return

	# Course du soleil : il se lève à l'est (6h) et se couche à l'ouest (18h).
	# L'angle d'élévation suit l'heure sur un demi-tour complet, ce qui donne
	# des ombres rasantes à l'aube et au crépuscule — gratuit et lisible.
	var h := hour()
	var elevation := (h - 6.0) / 12.0 * 180.0
	_sun.rotation_degrees = Vector3(-elevation, -30.0, 0.0)

	var light := daylight()
	_sun.light_energy = lerpf(SUN_ENERGY_NIGHT, SUN_ENERGY_DAY, light)
	_sun.light_color = light_color()
	if _environment != null:
		_environment.ambient_light_sky_contribution = lerpf(AMBIENT_NIGHT, AMBIENT_DAY, light)

	# LE point qui compte (G.3) : le terrain voxel est rendu UNSHADED, il
	# ignore complètement la lumière directionnelle. Sans cet uniform, le
	# cycle changeait le ciel et l'ambiance mais le monde restait en plein
	# jour — un cycle purement décoratif. G.3 prescrit cette modulation en
	# shader précisément pour que changer l'heure ne coûte rien.
	var terrain: ShaderMaterial = WorldManager.base_material()
	if terrain != null:
		terrain.set_shader_parameter("daylight", light)
