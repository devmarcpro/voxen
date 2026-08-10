class_name CombatResolver
extends RefCounted
## Pipeline de résolution du combat — RÉVISION HYBRIDE du 2026-07-28.
##
## CE QUI A CHANGÉ ET POURQUOI. E.3 résolvait le toucher par un jet :
##   attaque = 1d20 + N_arme/2 + Dex/4  vs  défense = 10 + N_esquive/2 - malus
## C'est incompatible avec le combat directionnel : deux systèmes décidaient du
## toucher, le dé et la géométrie, et le dé pouvait annuler un coup que le
## joueur avait visé et placé correctement — la faute cardinale d'un combat
## Mount & Blade, où la seule promesse faite au joueur est que ce qu'il voit
## toucher touche.
##
## Le partage retenu :
##   - la GÉOMÉTRIE décide SI et OÙ ça touche (balayage de lame contre les
##     zones de coup, Creature.sweep_segment) — plus aucun 1d20 de toucher,
##     plus aucun verrouillage de cible ;
##   - les DONNÉES décident COMBIEN, et ce pipeline-là est conservé INTACT
##     depuis A.4.1/A.4.2 : dés de la fonctionnalité, dureté de base, qualité,
##     bonus de stat, mitigation à jet. Aucun matériau à recalibrer.
##
## Le critique n'est plus un nat 20 : c'est la ZONE touchée qui récompense la
## visée (`zone_mult` du gabarit — 2.5 à la tête). Un critique n'est donc plus
## une loterie, c'est une intention.
##
##   dégâts bruts = jet(dés_fonctionnalité) * (durete_BASE/20) * qualité
##                  + For/4 (mêlée) ou Dex/4 (distance) + effets des modules
##   dégâts bruts *= zone_mult
##   mitigation   = jet(dés_protection_totale) * (1 - pénétration)
##   dégâts finaux = max(0, bruts - mitigation)
##
## Le host tire les dés de DÉGÂTS (E.11) — ici en solo/debug, RNG local. Le
## toucher, lui, n'est plus un tirage : il est reproductible à partir de la
## géométrie, ce qui simplifiera la validation côté serveur.
##
## armor_dice : "des_protection_totale" au format XdY (vide = pas d'armure).

## Parse "XdY" → [X, Y]. Tolère l'absence de 'd' (valeur fixe, encodée
## [0, valeur] — voir roll_dice, qui traite ce marqueur).
static func _parse_dice(notation: String) -> Vector2i:
	var parts := notation.split("d")
	if parts.size() != 2:
		return Vector2i(0, maxi(1, int(notation)))
	return Vector2i(int(parts[0]), int(parts[1]))


static func roll_dice(notation: String) -> int:
	var d := _parse_dice(notation)
	if d.x == 0:
		return d.y  # Valeur fixe (audit 2026-07-21 : la boucle 0 fois rendait 0).
	var total := 0
	for i in d.x:
		total += randi_range(1, d.y)
	return total


## Seuil de multiplicateur de zone à partir duquel le coup est signalé comme
## CRITIQUE (retour visuel/sonore, XP). 2.0 = les points faibles des gabarits
## (tête à 2.5) ; un torse à 1.0 ou un bras à 0.7 ne le sont jamais.
const CRITICAL_ZONE_MULT := 2.0


## Résout les DÉGÂTS d'un coup dont la géométrie a déjà établi qu'il touche.
## L'appelant a donc déjà fait le travail de toucher (balayage de lame ou, pour
## une créature, contrôle de portée à l'instant de la frappe).
##
## `zone_mult`  : multiplicateur de la zone de coup atteinte (gabarit B.5).
## `penetration`: fraction de la mitigation d'armure ignorée, 0..1.
## `element_mult` : multiplicateur Wu Xing (5.2/A.4.6) — calculé par l'appelant
## via `WuXing.multiplier(élément de l'attaque, élément de la cible)`. Appliqué
## ICI, en étape 3 : après les dés et la zone, avant la mitigation — c'est
## l'emplacement que l'amendement prescrit, orthogonal au directionnel.
##
## Retourne { "damage": int, "critical": bool, "raw": int, "reduction": int }.
static func resolve_hit(
	dexterity: int, strength: int,
	dice_notation: String, base_hardness: float, quality: float,
	is_ranged: bool, armor_dice: String,
	zone_mult: float = 1.0, penetration: float = 0.0, bonus_damage: int = 0,
	element_mult: float = 1.0
) -> Dictionary:
	# JET DE DÉGÂTS (A.4.1) : dureté de BASE (avant qualité), jamais la finale.
	var raw := roll_dice(dice_notation) * (base_hardness / 20.0) * quality
	raw += (dexterity if is_ranged else strength) / 4.0
	raw += bonus_damage
	# La zone multiplie APRÈS les bonus de stat : viser la tête doit valoir le
	# risque quel que soit le personnage, pas seulement pour les gros scores.
	raw *= zone_mult
	raw *= element_mult

	# MITIGATION À JET (armure) : 0 si pas d'armure équipée. La pénétration
	# ronge la réduction plutôt que d'ajouter des dégâts — une masse ne frappe
	# pas plus fort, elle rend l'armure moins pertinente (A.4.2).
	var reduction := 0
	if armor_dice != "":
		reduction = int(round(roll_dice(armor_dice) * (1.0 - clampf(penetration, 0.0, 1.0))))
	var raw_int := int(round(raw))
	return {
		"damage": maxi(0, raw_int - reduction),
		"critical": zone_mult >= CRITICAL_ZONE_MULT,
		"raw": raw_int, "reduction": reduction,
	}
