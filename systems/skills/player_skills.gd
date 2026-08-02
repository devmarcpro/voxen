class_name PlayerSkills
extends RefCounted
## Progression des compétences par l'usage (A.1/A.1.1) — sans plafond.
## Les formules sont copiées de l'Annexe A, jamais réécrites de mémoire :
##   xp_next(N) = base_xp * (N + 1)^1.6, base_xp = 100          (A.1)
##   skill_factor(N) = 1 + N * 0.02                             (A.1)
##   xp_effective = xp_gagnée * (potentiel / 100)               (A.1.1)
##   au level up : potentiel = max(potentiel_base, potentiel - (10 + niveau/10))
## S'appliquera tel quel aux PNJ/compagnons (même système, section 12).

const BASE_XP := 100.0
## Potentiel de base par défaut (A.1.1) quand ni la race ni la classe ne
## spécifient de plancher pour cette compétence.
const DEFAULT_BASE_POTENTIAL := 80.0
const POTENTIAL_CAP := 200.0

## L'entité porteuse (joueur pour l'instant), transmise aux signaux EventBus.
var owner_entity: Object = null
## Multiplicateur d'XP global (bonus de race, C.2 — ex. Humain +10 %,
## Échomorphe -10 %). 1.0 par défaut.
var xp_modifier := 1.0

## id compétence -> { "level": int, "xp": float, "potential": float,
##                    "base_potential": float }
##
## `base_potential` est le PLANCHER PERMANENT de 6.4, posé par la race et la
## classe (C.2/C.3) — corrigé le 2026-08-02. Il était auparavant absent : le
## level up ramenait tout le monde à la constante 80, si bien que le potentiel
## de Forge 120 d'un nain n'était qu'une avance de départ qui s'évaporait aux
## premiers niveaux. 6.4 est explicite sur le contraire — « le potentiel ne
## descend jamais sous ce plancher [...] un nain garde toujours un bon
## potentiel de Forge, même sans l'entretenir » : c'est ce plancher, et lui
## seul, qui donne son identité mécanique DURABLE à une combinaison
## race/classe. Sans lui, race et classe n'étaient qu'un kit de départ.
var skills := {}


func _init() -> void:
	for id in GameData.skills:
		skills[id] = {"level": 0, "xp": 0.0,
			"potential": DEFAULT_BASE_POTENTIAL,
			"base_potential": DEFAULT_BASE_POTENTIAL}


## Pose le plancher permanent d'une compétence (6.4) et y aligne le potentiel
## courant. Appelé à la création de personnage pour la race PUIS la classe —
## la classe l'emporte donc sur la race en cas de recouvrement, comme les
## bonus de stats.
func set_base_potential(skill_id: String, value: float) -> void:
	var s: Variant = skills.get(skill_id)
	if s == null:
		push_warning("PlayerSkills : plancher de potentiel pour une compétence inconnue « %s »." % skill_id)
		return
	var floor_value := clampf(value, 0.0, POTENTIAL_CAP)
	s["base_potential"] = floor_value
	# Le potentiel courant ne descend jamais sous son plancher : un personnage
	# fraîchement créé démarre AU plancher, jamais en dessous.
	s["potential"] = maxf(float(s["potential"]), floor_value)


## Plancher permanent d'une compétence (défaut si jamais posé).
func base_potential(skill_id: String) -> float:
	var s: Variant = skills.get(skill_id)
	return float(s["base_potential"]) if s != null else DEFAULT_BASE_POTENTIAL


func level(skill_id: String) -> int:
	var s: Variant = skills.get(skill_id)
	return int(s["level"]) if s != null else 0


## XP requise pour passer du niveau N au niveau N+1 (A.1).
static func xp_next(level_value: int) -> float:
	return BASE_XP * pow(level_value + 1, 1.6)


## Bonus d'efficacité : +2 % par niveau, sans plafond (A.1).
static func skill_factor(level_value: int) -> float:
	return 1.0 + level_value * 0.02


# --- Sauvegarde (E.10, via SaveManager) ---

func save_state() -> Dictionary:
	return skills.duplicate(true)


## Ne restaure que les compétences encore présentes en données (une
## compétence supprimée de data/skills disparaît silencieusement — même
## politique que le remap des matériaux).
func restore_state(data: Dictionary) -> void:
	for id: String in data:
		if not skills.has(id) or not (data[id] is Dictionary):
			continue
		var s: Dictionary = data[id]
		# `base_potential` absent = sauvegarde antérieure au 2026-08-02 : on
		# retombe sur la constante, ce qui reproduit exactement l'ancien
		# comportement. Le plancher de race sera reposé au prochain
		# apply_character ; une partie en cours ne le récupère pas, mais elle
		# ne perd rien non plus.
		skills[id] = {
			"level": int(s.get("level", 0)),
			"xp": float(s.get("xp", 0.0)),
			"potential": float(s.get("potential", DEFAULT_BASE_POTENTIAL)),
			"base_potential": float(s.get("base_potential", DEFAULT_BASE_POTENTIAL)),
		}


## Gagne de l'XP par l'usage. Le potentiel module le gain (A.1.1) et se
## consomme à chaque level up. Émet EventBus.skill_level_up.
## Modificateur d'XP dû à l'ÉTAT du personnage (repos, fatigue — E.21).
## Porté par le propriétaire (le joueur), jamais par les compétences.
func _rested_multiplier() -> float:
	if owner_entity != null and owner_entity.has_method("xp_state_multiplier"):
		return float(owner_entity.xp_state_multiplier())
	return 1.0


func gain_xp(skill_id: String, xp: float) -> void:
	xp *= _rested_multiplier()
	var s: Variant = skills.get(skill_id)
	if s == null:
		push_warning("PlayerSkills : compétence inconnue « %s »." % skill_id)
		return
	var effective: float = xp * (float(s["potential"]) / 100.0) * xp_modifier
	s["xp"] = float(s["xp"]) + effective
	while float(s["xp"]) >= xp_next(int(s["level"])):
		s["xp"] = float(s["xp"]) - xp_next(int(s["level"]))
		s["level"] = int(s["level"]) + 1
		# Le plancher est celui de la RACE/CLASSE (6.4), pas la constante par
		# défaut — voir le commentaire de `skills`.
		s["potential"] = maxf(float(s.get("base_potential", DEFAULT_BASE_POTENTIAL)),
			float(s["potential"]) - (10.0 + int(s["level"]) / 10.0))
		EventBus.skill_level_up.emit(skill_id, int(s["level"]), owner_entity)
