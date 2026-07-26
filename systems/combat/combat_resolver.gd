class_name CombatResolver
extends RefCounted
## Pipeline de résolution du combat à jets de dés (E.3), copié à la lettre :
##   attaque = 1d20 + N_arme/2 + Dex/4
##   défense = 10 + N_esquive/2 - malus_poids_armure
##   attaque >= défense → touché ; nat 20 = CRITIQUE (+50% dégâts) ;
##   nat 1 = échec critique ; battre la défense de 10+ = coup solide (+25%)
##   dégâts bruts = jet(dés_fonctionnalité) * (durete_BASE/20) * qualité
##                  + For/4 (mêlée) ou Dex/4 (distance) + effets des modules
##   mitigation : reduction = jet(dés_protection_totale) (0 si pas d'armure)
##   dégâts finaux = max(0, bruts - reduction)
## Le host tire tous les dés (E.11) — ici en solo/debug, RNG local.

## Contexte minimal d'un combattant pour un jet (attaquant OU défenseur).
## weapon_level : niveau de la compétence d'arme/module utilisée (N_arme).
## dodge_level : niveau de compétence Esquive du défenseur.
## armor_dice : "des_protection_totale" au format XdY (vide = pas d'armure).

## Parse "XdY" → [X, Y]. Tolère l'absence de 'd' (valeur fixe, encodée
## [0, valeur] — voir roll_dice/max_dice qui traitent ce marqueur).
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


## Dégâts MAXIMAUX de la notation (critique E.3 : « dégâts max +50 % »).
static func max_dice(notation: String) -> int:
	var d := _parse_dice(notation)
	return d.y if d.x == 0 else d.x * d.y


## Résout une attaque complète. Retourne :
## { "hit": bool, "critical": bool, "fumble": bool, "damage": int,
##   "attack_roll": int, "defense": int }
static func resolve_attack(
	weapon_level: int, dexterity: int, strength: int,
	dodge_level: int, armor_malus: int,
	dice_notation: String, base_hardness: float, quality: float,
	is_ranged: bool, armor_dice: String, bonus_damage: int = 0
) -> Dictionary:
	var natural := randi_range(1, 20)
	var attack_roll := natural + int(weapon_level / 2.0) + int(dexterity / 4.0)
	var defense := 10 + int(dodge_level / 2.0) - armor_malus

	if natural == 1:
		return {"hit": false, "critical": false, "fumble": true, "damage": 0,
			"attack_roll": attack_roll, "defense": defense}
	var critical := natural == 20
	if not critical and attack_roll < defense:
		return {"hit": false, "critical": false, "fumble": false, "damage": 0,
			"attack_roll": attack_roll, "defense": defense}

	# JET DE DÉGÂTS (A.4.1) : dureté de BASE (avant qualité), jamais la finale.
	# Critique (E.3, à la lettre : « dégâts MAX +50 % ») : les dés sont
	# MAXIMISÉS puis majorés de 50 % — pas un simple ×1.5 sur un jet qui
	# pouvait rouler bas (audit 2026-07-21 : un critique ne peut plus être
	# minable).
	var dice_damage := max_dice(dice_notation) if critical else roll_dice(dice_notation)
	var raw := dice_damage * (base_hardness / 20.0) * quality
	raw += (dexterity if is_ranged else strength) / 4.0
	raw += bonus_damage
	if critical:
		raw *= 1.5
	elif attack_roll - defense >= 10:
		raw *= 1.25  # Degré de réussite : coup solide.

	# MITIGATION À JET (armure) : 0 si pas d'armure équipée.
	var reduction := roll_dice(armor_dice) if armor_dice != "" else 0
	var damage := maxi(0, int(round(raw)) - reduction)
	return {"hit": true, "critical": critical, "fumble": false, "damage": damage,
		"attack_roll": attack_roll, "defense": defense}
