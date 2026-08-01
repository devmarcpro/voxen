class_name WeaponStats
extends RefCounted
## Statistiques DÉRIVÉES d'une arme assemblée (combat directionnel, 2026-07-28).
##
## SÉPARATION DES RESPONSABILITÉS — c'est le point d'architecture de ce fichier.
## Les JSON ne contiennent que des propriétés INTRINSÈQUES, que rien ne permet
## de calculer : la forme de la tête (`degats_des`, `type_degats`,
## `penetration`, `windup_ratio`), la longueur de référence (`portee`), le
## poids étalon (`poids_reference`). Tout ce qui découle d'une COMBINAISON
## (manche + tête + matériaux + qualité) est calculé ici, et nulle part
## ailleurs — pas de valeur de wind-up ni de fenêtre de parade écrite à la main
## dans une fiche, sinon deux sources de vérité finiraient par diverger.
##
## COÛT : `derive()` est appelé au changement d'arme, PAS à la frappe et encore
## moins à la frame. Le résultat est un petit dictionnaire figé que la machine
## à états d'attaque relit sans rien recalculer — la contrainte annoncée quand
## le combat est passé à la frame (60 Hz) plutôt qu'au tick (10 Hz).

## Fenêtre de parade de référence, en ms, pour une arme au poids étalon. Une
## arme légère l'allonge, une arme lourde la resserre : parer à la masse
## demande un timing que l'épée pardonne.
const PARRY_BASE_MS := 300.0
const PARRY_MIN_MS := 80.0
const PARRY_MAX_MS := 420.0
## Part du cycle d'attaque passée en FRAPPE (l'arc pendant lequel la lame est
## dangereuse). Le reste, après le wind-up, est la récupération.
const RELEASE_RATIO := 0.2
## Bornes de la vitesse d'attaque dérivée du poids (A.4.1, déjà appliquées
## avant cette refonte dans player.gd — déplacées ici pour n'avoir qu'un seul
## endroit qui sait dériver la vitesse).
const SPEED_MIN_FACTOR := 0.4
const SPEED_MAX_FACTOR := 1.8


## Dérive toutes les stats de combat d'une arme.
## `functionality` : fiche data/functionalities/<id>.json.
## `instance`      : instance d'objet (ItemFactory) — {} pour une arme
##                   naturelle (mains nues, morsure) qui n'a ni poids ni
##                   qualité propres.
## Retourne un dictionnaire figé, à conserver tel quel par l'appelant.
static func derive(functionality: Dictionary, instance: Dictionary) -> Dictionary:
	var base_speed := float(functionality.get("vitesse_base", 1.0))
	var reference_weight := maxf(float(functionality.get("poids_reference", 1.0)), 0.1)
	var weight := reference_weight
	if not instance.is_empty():
		weight = maxf(float(instance.get("weight", reference_weight)), 0.1)

	# VITESSE (A.4.1) : « la densité pilote la vitesse » — une épée en granit
	# noir frappe lentement, un manche en pin accélère.
	var speed := clampf(
		base_speed * pow(reference_weight / weight, 0.75),
		SPEED_MIN_FACTOR * base_speed, SPEED_MAX_FACTOR * base_speed)

	# CYCLE D'ATTAQUE. `speed` est en attaques par seconde (c'est déjà la
	# convention du cooldown E.1 : 10 ticks / speed). Le cycle se découpe en
	# préparation → frappe → récupération ; seul le ratio de préparation est
	# une donnée (c'est une propriété de la forme : une arbalète se recharge
	# longtemps, un poing part instantanément).
	var cycle_ms := 1000.0 / maxf(speed, 0.01)
	var windup_ratio := clampf(float(functionality.get("windup_ratio", 0.45)), 0.05, 0.9)
	var windup_ms := cycle_ms * windup_ratio
	var release_ms := cycle_ms * RELEASE_RATIO
	var recovery_ms := maxf(cycle_ms - windup_ms - release_ms, 0.0)

	# FENÊTRE DE PARADE : dérivée du poids RELATIF. Une arme lourde est
	# difficile à manœuvrer, donc pardonne moins.
	var parry_ms := clampf(
		PARRY_BASE_MS * sqrt(reference_weight / weight), PARRY_MIN_MS, PARRY_MAX_MS)

	# ENDURANCE. Coût du coup et drain infligé à qui le bloque : tous deux
	# suivent le poids (énergie cinétique), le drain étant majoré pour le
	# contondant — c'est précisément le rôle d'une masse de vider une garde.
	var damage_type := String(functionality.get("type_degats", "contondant"))
	var stamina_cost := 2.0 + weight * 0.25
	var stamina_drain := weight * 0.4
	if damage_type == "contondant":
		stamina_drain *= 1.5

	# PIÈCES : manche + tête. L'allonge et les POINTS DE PRISE en découlent —
	# c'est « la magie de la longueur du manche » du design : rien n'est animé
	# ni écrit à la main, la posture se déduit de l'arme tenue. Une dague garde
	# les mains collées ; une pique projette la main avant à plus d'un mètre.
	var parts: Dictionary = functionality.get("parts", {})
	var handle: Dictionary = GameData.weapon_parts["manches"].get(String(parts.get("manche", "")), {})
	var head: Dictionary = GameData.weapon_parts["tetes"].get(String(parts.get("tete", "")), {})
	var handle_length := float(handle.get("longueur", 0.0))
	var grip_main := float(handle.get("grip_main", 0.3))
	var grip_offhand: Variant = handle.get("grip_offhand")
	# Écart entre les deux mains LE LONG du manche, en blocs. 0 = arme à une
	# main : la seconde main ne sera pas placée du tout.
	var hand_separation := 0.0
	if grip_offhand != null and int(functionality.get("hands", 1)) >= 2:
		hand_separation = maxf(0.0, (float(grip_offhand) - grip_main) * handle_length)
	# Allonge : longueur du manche + ce que la tête ajoute, moins la portion de
	# manche située DERRIÈRE la main (on ne frappe pas avec le pommeau).
	var derived_reach := handle_length * (1.0 - grip_main) + float(head.get("portee_tete", 0.0))
	var reach := derived_reach if derived_reach > 0.01 else float(functionality.get("portee", 1.5))

	# INERTIE (2026-07-28). La main ne se téléporte pas sur sa cible : elle y est
	# tirée par un ressort amorti, et la MASSE de l'arme décide de la mollesse
	# du ressort. Une dague colle au regard ; un marteau traîne, dépasse sa
	# cible et se replace en oscillant — c'est ce qui donne le poids à l'écran.
	#
	# `damping_ratio < 1` est VOLONTAIRE : à 1 (amortissement critique) le
	# mouvement serait propre et mort. C'est ce léger sous-amortissement qui
	# produit le ballant des bras demandé, et il augmente avec le poids.
	var stiffness := clampf(3000.0 / weight, 45.0, 260.0)
	var damping_ratio := clampf(0.75 - weight / 300.0, 0.30, 0.70)

	return {
		"inertia_stiffness": stiffness,
		"inertia_damping": 2.0 * damping_ratio * sqrt(stiffness),
		"handle_length": handle_length,
		"hand_separation": hand_separation,
		"speed": speed,
		"weight": weight,
		"cycle_ms": cycle_ms,
		"windup_ms": windup_ms,
		"release_ms": release_ms,
		"recovery_ms": recovery_ms,
		"parry_window_ms": parry_ms,
		"reach": reach,
		"damage_type": damage_type,
		"penetration": clampf(float(functionality.get("penetration", 0.0)), 0.0, 1.0),
		"stamina_cost": stamina_cost,
		"stamina_drain": stamina_drain,
		"dice": String(functionality.get("degats_des", "1d4")),
		"skill": String(functionality.get("combat_skill", "mains_nues")),
		"hands": int(functionality.get("hands", 1)),
	}


# --- Piliers Mount & Blade : sweet spot et bonus de vitesse --------------

## En deçà de cette fraction de l'allonge, on frappe avec le MANCHE : le coup
## GLISSE et ne fait rien. C'est ce qui punit d'être trop près avec une arme
## longue, et donc ce qui donne aux armes courtes leur raison d'être — entrer
## dans la garde. Sans ça l'allonge n'aurait que des avantages.
const SWEET_MIN := 0.30
## À partir d'ici, dégâts pleins. Entre les deux, montée progressive.
const SWEET_FULL := 0.62


## Multiplicateur de « sweet spot » : 0 près de la garde, 1 sur la portion
## tranchante. `distance` = distance de l'impact au point de prise.
static func sweet_spot_factor(distance: float, reach: float) -> float:
	if reach <= 0.001:
		return 1.0
	var ratio := distance / reach
	if ratio >= SWEET_FULL:
		return 1.0
	if ratio <= SWEET_MIN:
		return 0.0
	# Interpolation douce (smoothstep) plutôt que linéaire : la frontière entre
	# « ça glisse » et « ça coupe » ne doit pas être un mur d'un millimètre.
	var t := (ratio - SWEET_MIN) / (SWEET_FULL - SWEET_MIN)
	return t * t * (3.0 - 2.0 * t)


## Bornes du bonus de vitesse. Reculer en frappant ne doit pas annuler le coup
## (0.55 au pire), charger ne doit pas le doubler (1.5 au mieux) — M&B reste
## un jeu de placement, pas une course.
const SPEED_BONUS_MIN := 0.55
const SPEED_BONUS_MAX := 1.50


## Bonus de vitesse : les dégâts suivent la vitesse RELATIVE de l'arme et de la
## cible. C'est la mécanique signature de Mount & Blade — elle transforme le jeu
## de jambes en système de dégâts au lieu d'un simple placement. Avancer en
## frappant fait mal ; frapper en reculant fait peu.
##
## Normalisé par la vitesse NOMINALE de l'arme : une arme lente ne doit pas
## être pénalisée d'être lente (son poids lui donne déjà ses dés), seul l'apport
## du DÉPLACEMENT compte.
static func speed_factor(nominal_tip_speed: float, closing_speed: float) -> float:
	if nominal_tip_speed <= 0.01:
		return 1.0
	return clampf((nominal_tip_speed + closing_speed) / nominal_tip_speed,
		SPEED_BONUS_MIN, SPEED_BONUS_MAX)


## Efficacité de l'armure `armor_category` face à `damage_type` — multiplie la
## MITIGATION, pas les dégâts (voir data/armor_type_modifiers.json).
static func armor_type_modifier(armor_category: String, damage_type: String) -> float:
	var table: Dictionary = GameData.armor_type_modifiers
	var row: Dictionary = table.get(armor_category, table.get("_defaut", {}))
	return float(row.get(damage_type, 1.0))
