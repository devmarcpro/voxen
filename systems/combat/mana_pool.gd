class_name ManaPool
extends RefCounted
## Mana calqué Elin (A.5), formules copiées à la lettre :
##   mana_max = 20 + (Volonté * 3) + (N_meditation * 2)
##   Régénération passive : tous les 10 ticks, chance de 1/8 de regen
##     regen = 1 + N_meditation * 0.2
##   Repos actif : la chance passe à 1/2 par seconde (hors périmètre ici).
##   Surchauffe (A.6/5.1) : lancer sans mana suffisant est permis ; le déficit
##     est infligé en dégâts de santé * 2, réduit par Contrôle du Mana :
##     multiplicateur = 2 / skill_factor(N_controle_mana)

const REGEN_TICK_INTERVAL := 10
const REGEN_CHANCE := 1.0 / 8.0

var current: float = 0.0
var willpower: int = 0
var meditation_level: int = 0

var _tick_counter := 0


func _init(p_willpower: int, p_meditation_level: int) -> void:
	willpower = p_willpower
	meditation_level = p_meditation_level
	current = max_mana()


func max_mana() -> float:
	return 20.0 + willpower * 3.0 + meditation_level * 2.0


## À appeler à chaque tick (E.1) — jamais dans _process.
func on_tick() -> void:
	_tick_counter += 1
	if _tick_counter < REGEN_TICK_INTERVAL:
		return
	_tick_counter = 0
	if randf() < REGEN_CHANCE:
		current = minf(max_mana(), current + (1.0 + meditation_level * 0.2))


## Dépense du mana ; si insuffisant, retourne le déficit à infliger en
## dégâts (déjà multiplié par 2 / skill_factor(N_controle_mana), A.6).
func spend(cost: float, mana_control_level: int) -> float:
	if current >= cost:
		current -= cost
		return 0.0
	var deficit := cost - current
	current = 0.0
	var factor := PlayerSkills.skill_factor(mana_control_level)
	return deficit * 2.0 / factor
