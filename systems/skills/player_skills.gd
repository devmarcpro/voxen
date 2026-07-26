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
## Potentiel de base par défaut (A.1.1 : défaut 80 ; les valeurs par
## race/classe C.2/C.3 arriveront avec la création de personnage, 6.3).
const DEFAULT_BASE_POTENTIAL := 80.0
const POTENTIAL_CAP := 200.0

## L'entité porteuse (joueur pour l'instant), transmise aux signaux EventBus.
var owner_entity: Object = null
## Multiplicateur d'XP global (bonus de race, C.2 — ex. Humain +10 %,
## Échomorphe -10 %). 1.0 par défaut.
var xp_modifier := 1.0

## id compétence -> { "level": int, "xp": float, "potential": float }
var skills := {}


func _init() -> void:
	for id in GameData.skills:
		skills[id] = {"level": 0, "xp": 0.0, "potential": DEFAULT_BASE_POTENTIAL}


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
		skills[id] = {
			"level": int(s.get("level", 0)),
			"xp": float(s.get("xp", 0.0)),
			"potential": float(s.get("potential", DEFAULT_BASE_POTENTIAL)),
		}


## Gagne de l'XP par l'usage. Le potentiel module le gain (A.1.1) et se
## consomme à chaque level up. Émet EventBus.skill_level_up.
func gain_xp(skill_id: String, xp: float) -> void:
	var s: Variant = skills.get(skill_id)
	if s == null:
		push_warning("PlayerSkills : compétence inconnue « %s »." % skill_id)
		return
	var effective: float = xp * (float(s["potential"]) / 100.0) * xp_modifier
	s["xp"] = float(s["xp"]) + effective
	while float(s["xp"]) >= xp_next(int(s["level"])):
		s["xp"] = float(s["xp"]) - xp_next(int(s["level"]))
		s["level"] = int(s["level"]) + 1
		s["potential"] = maxf(DEFAULT_BASE_POTENTIAL,
			float(s["potential"]) - (10.0 + int(s["level"]) / 10.0))
		EventBus.skill_level_up.emit(skill_id, int(s["level"]), owner_entity)
