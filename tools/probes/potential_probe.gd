extends Probe
## Sonde `--probe-potentiel` — le PLANCHER de potentiel de race/classe (6.4).
##
## Ce que cette sonde défend : le potentiel de base d'une race ou d'une classe
## est un **plancher permanent**, pas une avance de départ. 6.4 est explicite —
## « le potentiel ne descend jamais sous ce plancher [...] un nain garde
## toujours un bon potentiel de Forge, même sans l'entretenir ». C'est ce
## plancher, et lui seul, qui donne son identité mécanique DURABLE à une
## combinaison race/classe ; sans lui, race et classe ne sont qu'un kit de
## départ que dix niveaux effacent.
##
## Le défaut corrigé le 2026-08-02 était exactement celui-là, et il était
## INVISIBLE : les données étaient bonnes, la création de personnage les
## appliquait bien, mais le level up ramenait le potentiel à la constante 80
## pour tout le monde. Un nain démarrait à 120 en Forge et se retrouvait
## banalisé après quelques montées — sans message, sans symptôme, et sans que
## rien dans la fiche de personnage ne le montre. C'est le genre de régression
## qu'une refonte de la progression réintroduira sans le savoir.
##
## Elle vérifie aussi la persistance : un plancher qui ne survit pas au
## rechargement rend l'identité de race dépendante du fait de ne jamais quitter
## la partie.

const TAG := "POTENTIEL"

## Race et compétence témoins : le cas nommé par le GDD lui-même.
const WITNESS_RACE := "nain"
const WITNESS_SKILL := "forge"

var _ok := true


func _check(label: String, condition: bool, detail: String = "") -> void:
	if not condition:
		_ok = false
	print("[%s] %s%s : %s" % [TAG, label, "" if detail == "" else " (" + detail + ")",
		"OK" if condition else "ÉCHEC"])


func run() -> void:
	await main.get_tree().process_frame
	_check_data()
	_check_floor_applied()
	_check_floor_survives_levelling()
	_check_default_unchanged()
	_check_class_overrides_race()
	_check_persistence()
	finish(_ok, TAG)


## Le plancher témoin doit exister en données : si quelqu'un vide
## `base_potentials`, le reste de la sonde passerait en testant du vide.
func _check_data() -> void:
	var race: Dictionary = GameData.races.get(WITNESS_RACE, {})
	var potentials: Dictionary = race.get("base_potentials", {})
	_check("la race témoin porte ses base_potentials",
		potentials.has(WITNESS_SKILL),
		"%s.%s" % [WITNESS_RACE, WITNESS_SKILL])
	_check("le plancher témoin est au-dessus du défaut",
		float(potentials.get(WITNESS_SKILL, 0.0)) > PlayerSkills.DEFAULT_BASE_POTENTIAL,
		"%.0f > %.0f" % [float(potentials.get(WITNESS_SKILL, 0.0)),
			PlayerSkills.DEFAULT_BASE_POTENTIAL])


func _fresh_skills(race_id: String) -> PlayerSkills:
	var skills := PlayerSkills.new()
	var race: Dictionary = GameData.races.get(race_id, {})
	for skill_id: String in (race.get("base_potentials", {}) as Dictionary):
		skills.set_base_potential(skill_id, float(race["base_potentials"][skill_id]))
	return skills


func _check_floor_applied() -> void:
	var skills := _fresh_skills(WITNESS_RACE)
	var expected: float = float(GameData.races[WITNESS_RACE]["base_potentials"][WITNESS_SKILL])
	_check("le plancher est posé à la création",
		is_equal_approx(skills.base_potential(WITNESS_SKILL), expected),
		"%.0f" % skills.base_potential(WITNESS_SKILL))
	_check("le potentiel courant démarre AU plancher",
		is_equal_approx(float(skills.skills[WITNESS_SKILL]["potential"]), expected),
		"%.0f" % float(skills.skills[WITNESS_SKILL]["potential"]))


## LE POINT CENTRAL. Assez d'XP pour enchaîner largement de quoi user le
## potentiel : chaque level up en retire 10 et plus, donc une dizaine de
## niveaux suffirait à retomber à 80 si le plancher n'était pas respecté.
func _check_floor_survives_levelling() -> void:
	var skills := _fresh_skills(WITNESS_RACE)
	var floor_value := skills.base_potential(WITNESS_SKILL)
	for i in 40:
		skills.gain_xp(WITNESS_SKILL, 50_000.0)

	var level := skills.level(WITNESS_SKILL)
	var potential := float(skills.skills[WITNESS_SKILL]["potential"])
	_check("la compétence a bien monté (sinon le test ne prouve rien)",
		level >= 10, "niveau %d" % level)
	_check("LE POTENTIEL NE DESCEND PAS SOUS LE PLANCHER DE RACE",
		potential >= floor_value - 0.001,
		"%.1f >= %.0f" % [potential, floor_value])
	# La formulation inverse : sans le correctif, on retombait exactement à 80.
	_check("il n'est pas retombé au défaut générique",
		potential > PlayerSkills.DEFAULT_BASE_POTENTIAL,
		"%.1f > %.0f" % [potential, PlayerSkills.DEFAULT_BASE_POTENTIAL])


## Une compétence sans plancher déclaré doit continuer à se comporter comme
## avant : le correctif ne doit rien offrir gratuitement.
func _check_default_unchanged() -> void:
	var skills := _fresh_skills(WITNESS_RACE)
	var plain := "athletisme"
	if not skills.skills.has(plain):
		_check("compétence témoin sans plancher disponible", false, plain)
		return
	for i in 40:
		skills.gain_xp(plain, 50_000.0)
	var potential := float(skills.skills[plain]["potential"])
	_check("une compétence sans plancher retombe bien au défaut",
		is_equal_approx(potential, PlayerSkills.DEFAULT_BASE_POTENTIAL),
		"%.1f" % potential)


## Race PUIS classe : la classe l'emporte en cas de recouvrement, comme les
## bonus de stats. Vérifié sur la classe qui recouvre effectivement la race.
func _check_class_overrides_race() -> void:
	var skills := _fresh_skills(WITNESS_RACE)
	var cls: Dictionary = GameData.classes.get("artisan", {})
	var potentials: Dictionary = cls.get("base_potentials", {})
	if not potentials.has(WITNESS_SKILL):
		_check("classe témoin recouvrant la race disponible", false, "artisan.forge")
		return
	skills.set_base_potential(WITNESS_SKILL, float(potentials[WITNESS_SKILL]))
	_check("la classe l'emporte sur la race",
		is_equal_approx(skills.base_potential(WITNESS_SKILL), float(potentials[WITNESS_SKILL])),
		"%.0f" % skills.base_potential(WITNESS_SKILL))


func _check_persistence() -> void:
	var skills := _fresh_skills(WITNESS_RACE)
	var expected := skills.base_potential(WITNESS_SKILL)
	var restored := PlayerSkills.new()
	restored.restore_state(skills.save_state())
	_check("le plancher survit à une sauvegarde/relecture",
		is_equal_approx(restored.base_potential(WITNESS_SKILL), expected),
		"%.0f" % restored.base_potential(WITNESS_SKILL))
	# Et il doit encore TENIR après relecture, pas seulement être stocké.
	for i in 40:
		restored.gain_xp(WITNESS_SKILL, 50_000.0)
	_check("il tient encore après relecture",
		float(restored.skills[WITNESS_SKILL]["potential"]) >= expected - 0.001,
		"%.1f" % float(restored.skills[WITNESS_SKILL]["potential"]))
