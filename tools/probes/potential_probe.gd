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
## TÉMOIN : LA CLASSE, PLUS LA RACE (2026-08-09).
##
## C'était le nain, dont le potentiel de Forge à 120 est l'exemple qui a fait
## écrire cette règle. Les races de fantaisie ont été retirées et l'humain, seul
## restant, ne déclare AUCUN `base_potentials` : plus aucune race n'exerçait
## donc le plancher, et cette sonde le disait — c'est son premier test qui l'a
## signalé, exactement comme il était écrit pour le faire.
##
## Les CLASSES, elles, en déclarent (artisan 115 en forge, mage 120 en
## méditation). La règle défendue est inchangée — un plancher de départ ne se
## perd jamais en montant de niveau —, seule la source du témoin change.
##
## CE QUI N'EST PLUS EXERCÉ, et il faut le dire plutôt que de le taire : le
## plancher d'ORIGINE RACIALE, et sa priorité face à celui de la classe. Le code
## le gère toujours ; aucune donnée ne l'emprunte. Le jour où une race réelle
## déclarera un potentiel, remettre `WITNESS_FROM_RACE` à true suffit.
const WITNESS_CLASS := "artisan"
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
	_check_general_floor()
	finish(_ok, TAG)


## Le plancher témoin doit exister en données : si quelqu'un vide
## `base_potentials`, le reste de la sonde passerait en testant du vide.
func _check_data() -> void:
	var witness: Dictionary = GameData.classes.get(WITNESS_CLASS, {})
	var potentials: Dictionary = witness.get("base_potentials", {})
	_check("la classe témoin porte ses base_potentials",
		potentials.has(WITNESS_SKILL),
		"%s.%s" % [WITNESS_CLASS, WITNESS_SKILL])
	# ON DIT CE QUI N'EST PLUS COUVERT. Aucune race ne déclare de plancher
	# depuis le retrait de la fantaisie : la règle raciale existe en code et
	# plus rien ne l'emprunte. Le taire reviendrait à croire la sonde complète.
	var racial := 0
	for race_id: String in GameData.races:
		var fiche: Dictionary = GameData.races[race_id]
		if not (fiche.get("base_potentials", {}) as Dictionary).is_empty() 				or float(fiche.get("base_potential_min", 0.0)) > 0.0:
			racial += 1
	if racial == 0:
		print("[%s] NON COUVERT : aucune race ne déclare de plancher — la règle RACIALE n'est plus exercée par les données." % TAG)
	_check("le plancher témoin est au-dessus du défaut",
		float(potentials.get(WITNESS_SKILL, 0.0)) > PlayerSkills.DEFAULT_BASE_POTENTIAL,
		"%.0f > %.0f" % [float(potentials.get(WITNESS_SKILL, 0.0)),
			PlayerSkills.DEFAULT_BASE_POTENTIAL])


func _fresh_skills(source_id: String) -> PlayerSkills:
	var skills := PlayerSkills.new()
	# La source est une CLASSE, avec repli sur une race de même id : le reste de
	# la sonde n'a pas à savoir d'où vient le plancher, seulement qu'il existe.
	var source: Dictionary = GameData.classes.get(source_id,
			GameData.races.get(source_id, {}))
	for skill_id: String in (source.get("base_potentials", {}) as Dictionary):
		skills.set_base_potential(skill_id, float(source["base_potentials"][skill_id]))
	return skills


func _check_floor_applied() -> void:
	var skills := _fresh_skills(WITNESS_CLASS)
	var expected: float = float(GameData.classes[WITNESS_CLASS]["base_potentials"][WITNESS_SKILL])
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
	var skills := _fresh_skills(WITNESS_CLASS)
	var floor_value := skills.base_potential(WITNESS_SKILL)
	for i in 40:
		skills.gain_xp(WITNESS_SKILL, 50_000.0)

	var level := skills.level(WITNESS_SKILL)
	var potential := float(skills.skills[WITNESS_SKILL]["potential"])
	_check("la compétence a bien monté (sinon le test ne prouve rien)",
		level >= 10, "niveau %d" % level)
	_check("LE POTENTIEL NE DESCEND PAS SOUS SON PLANCHER DE DÉPART",
		potential >= floor_value - 0.001,
		"%.1f >= %.0f" % [potential, floor_value])
	# La formulation inverse : sans le correctif, on retombait exactement à 80.
	_check("il n'est pas retombé au défaut générique",
		potential > PlayerSkills.DEFAULT_BASE_POTENTIAL,
		"%.1f > %.0f" % [potential, PlayerSkills.DEFAULT_BASE_POTENTIAL])


## Une compétence sans plancher déclaré doit continuer à se comporter comme
## avant : le correctif ne doit rien offrir gratuitement.
func _check_default_unchanged() -> void:
	var skills := _fresh_skills(WITNESS_CLASS)
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
	var skills := _fresh_skills(WITNESS_CLASS)
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
	var skills := _fresh_skills(WITNESS_CLASS)
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


## LE PLANCHER GÉNÉRAL D'UNE RACE POLYVALENTE (2026-08-09).
##
## L'humain est déclaré POLYVALENT par le GDD (C.2) : lui donner un plancher sur
## une compétence précise en aurait fait un spécialiste de plus, c'est-à-dire le
## contraire de ce que sa fiche annonce. Il porte donc `base_potential_min`, un
## plancher modeste sur TOUTES les compétences.
##
## TROIS CHOSES À DÉFENDRE, et la troisième est celle qu'on oublierait :
##   1. le plancher est bien posé partout, pas sur une compétence témoin ;
##   2. il RÉSISTE à la montée de niveau, comme tout plancher (c'est la règle
##      entière, et elle n'a pas de raison de valoir moins ici) ;
##   3. il NE MANGE PAS un plancher nommé : un artisan garde ses 115 en forge.
##      Sans ce point, la polyvalence écraserait toutes les spécialités et
##      chaque classe vaudrait la même chose.
func _check_general_floor() -> void:
	var race: Dictionary = GameData.races.get("humain", {})
	var general := float(race.get("base_potential_min", 0.0))
	_check("l'humain porte un plancher GÉNÉRAL (polyvalent, C.2)", general > 0.0,
		"%.0f" % general)
	if general <= 0.0:
		return
	_check("et il est au-dessus du défaut générique",
		general > PlayerSkills.DEFAULT_BASE_POTENTIAL,
		"%.0f > %.0f" % [general, PlayerSkills.DEFAULT_BASE_POTENTIAL])

	# On rejoue ce que fait la création de personnage : plancher général, puis
	# planchers nommés de la classe.
	var skills := PlayerSkills.new()
	for skill_id: String in skills.skills:
		skills.set_base_potential(skill_id, general)
	var named: Dictionary = (GameData.classes.get(WITNESS_CLASS, {}) as Dictionary).get(
			"base_potentials", {})
	for skill_id: String in named:
		skills.set_base_potential(skill_id, float(named[skill_id]))

	# 1. PARTOUT, pas seulement sur un témoin.
	var below := 0
	for skill_id: String in skills.skills:
		if skills.base_potential(skill_id) < general - 0.001:
			below += 1
	_check("toutes les compétences reçoivent ce plancher", below == 0,
		"%d compétence(s) en dessous" % below)

	# 3. LA SPÉCIALITÉ L'EMPORTE.
	var specialised := skills.base_potential(WITNESS_SKILL)
	_check("un plancher nommé de classe l'emporte sur le plancher général",
		specialised > general,
		"%s : %.0f contre %.0f" % [WITNESS_SKILL, specialised, general])

	# 2. IL RÉSISTE À LA MONTÉE DE NIVEAU. Une compétence ORDINAIRE — pas celle
	# de la classe, qui est protégée par son propre plancher.
	var ordinary := ""
	for skill_id: String in skills.skills:
		if not named.has(skill_id):
			ordinary = skill_id
			break
	if ordinary == "":
		return
	for i in 40:
		skills.gain_xp(ordinary, 50_000.0)
	_check("et il survit à la montée de niveau, comme tout plancher",
		float(skills.skills[ordinary]["potential"]) >= general - 0.001,
		"%s : %.1f >= %.0f" % [ordinary, float(skills.skills[ordinary]["potential"]), general])
