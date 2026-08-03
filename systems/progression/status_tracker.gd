class_name StatusTracker
extends RefCounted
## Statuts temporaires (GDD F.4) — 2026-08-03.
##
## POURQUOI CE FICHIER EXISTE. Une bonne moitié du catalogue de modules
## (protections, postures, entraves, régénération) compilait, coûtait sa mana et
## ne produisait RIEN : il n'y avait aucun endroit où poser « +30 % d'armure
## pendant 20 secondes ». Le GDD le prévoyait depuis toujours (F.4, 14 statuts)
## et les potions (F.9), la nourriture avariée (F.5) et les échecs de lecture
## (A.7) l'attendent aussi. C'est donc une brique partagée, pas une annexe du
## système de sorts.
##
## IL NE RÉINVENTE RIEN. Un statut qui altère une valeur de jeu passe par
## `StatModifiers` (E.4 : « aucun système ne modifie jamais une valeur en dur »),
## en s'enregistrant sous une source à son nom. Expirer, c'est retirer sa source.
## Ce fichier n'apporte que la DURÉE, le CUMUL et le PÉRIODIQUE — le reste
## existait déjà.
##
## TOUT EST EN TICKS, jamais en secondes réelles (E.1). Un statut posé avant une
## sauvegarde doit expirer correctement au rechargement, exactement comme les
## caches au sol.

## Statuts actifs : id → { "ticks", "power", "stacks", "periodic_counter" }.
var active := {}

## Intervalle des effets périodiques, en ticks. Le GDD raisonne « par tour » ;
## un tour vaut 10 ticks dans ce projet (E.1, régénération de mana A.5).
const PERIODIC_INTERVAL := 10

## Entité porteuse (joueur ou créature) et son résolveur de modificateurs.
var _owner: Object
var _modifiers: StatModifiers


func setup(owner: Object, modifiers: StatModifiers) -> void:
	_owner = owner
	_modifiers = modifiers


## Applique un statut. `duration_ticks` à 0 reprend la durée par défaut de la
## fiche. `power` module l'intensité (dégâts périodiques, force du modificateur).
##
## CUMUL : une fiche marquée `stacks` empile ses effets ; sinon un nouvel apport
## RAFRAÎCHIT la durée sans doubler la puissance. Sans cette distinction, lancer
## deux fois sa protection la rendrait deux fois plus forte, et le choix
## d'assemblage se réduirait à spammer le même sort.
func apply(status_id: String, duration_ticks: int = 0, power: float = 1.0) -> bool:
	var definition: Dictionary = GameData.status_effects.get(status_id, {})
	if definition.is_empty():
		return false
	var duration := duration_ticks if duration_ticks > 0 else int(definition.get("duration_ticks", 60))
	var stacking := bool(definition.get("stacks", false))
	if active.has(status_id):
		var entry: Dictionary = active[status_id]
		entry["ticks"] = maxi(int(entry["ticks"]), duration)
		if stacking:
			entry["stacks"] = int(entry["stacks"]) + 1
			entry["power"] = float(entry["power"]) + power
	else:
		active[status_id] = {"ticks": duration, "power": power,
			"stacks": 1, "periodic_counter": 0}
	_register_modifiers(status_id)
	return true


## Retire un statut (purge : antidote, bandage, eau sur une brûlure…).
func remove(status_id: String) -> void:
	if not active.has(status_id):
		return
	active.erase(status_id)
	if _modifiers != null:
		_modifiers.clear_source_everywhere(_source_of(status_id))


## Retire tous les statuts portant `tag` — c'est ainsi que « l'eau retire la
## brûlure » (F.4) se dit sans coder chaque paire à la main.
func remove_by_tag(tag: String) -> void:
	for status_id: String in active.keys():
		var definition: Dictionary = GameData.status_effects.get(status_id, {})
		if tag in (definition.get("tags", []) as Array):
			remove(status_id)


func has(status_id: String) -> bool:
	return active.has(status_id)


## Multiplicateur cumulé d'une grandeur de jeu, statuts compris (E.4). Sert aux
## grandeurs qui ne sont pas des STATS et n'ont donc pas de valeur de base à
## résoudre : vitesse de déplacement, réduction de dégâts…
func multiplier(key: String) -> float:
	return _modifiers.apply(1.0, key) if _modifiers != null else 1.0


## Fait vieillir les statuts d'un tick. Retourne les dégâts périodiques totaux
## à infliger au porteur (positifs = blessure, négatifs = soin) : le tracker ne
## touche jamais lui-même à la santé, c'est le porteur qui l'applique par son
## propre chemin de dégâts — sinon un statut contournerait le stagger, les
## armures et la mort.
func tick() -> float:
	if active.is_empty():
		return 0.0
	var total := 0.0
	for status_id: String in active.keys():
		var entry: Dictionary = active[status_id]
		var definition: Dictionary = GameData.status_effects.get(status_id, {})
		var periodic: Dictionary = definition.get("periodic", {})
		if not periodic.is_empty():
			entry["periodic_counter"] = int(entry["periodic_counter"]) + 1
			if int(entry["periodic_counter"]) >= PERIODIC_INTERVAL:
				entry["periodic_counter"] = 0
				var dice := String(periodic.get("degats_des", ""))
				var amount := float(CombatResolver.roll_dice(dice)) if dice != "" else 0.0
				amount *= float(entry["power"])
				total += amount if not bool(periodic.get("soin", false)) else -amount
		entry["ticks"] = int(entry["ticks"]) - 1
		if int(entry["ticks"]) <= 0:
			remove(status_id)
	return total


## (Ré)enregistre les modificateurs d'un statut auprès du résolveur E.4.
## Refait à chaque application : la puissance a pu changer avec un cumul.
func _register_modifiers(status_id: String) -> void:
	if _modifiers == null:
		return
	var definition: Dictionary = GameData.status_effects.get(status_id, {})
	var entry: Dictionary = active.get(status_id, {})
	var power := float(entry.get("power", 1.0))
	var source := _source_of(status_id)
	for stat_id: String in (definition.get("modifiers", {}) as Dictionary):
		var spec: Dictionary = definition["modifiers"][stat_id]
		# `add` monte avec la puissance, `mult` NON : multiplier un
		# multiplicateur par la puissance ferait exploser les cumuls
		# (deux fois 0,7 doit donner 0,49, pas 0,7 × 2).
		_modifiers.set_modifier(stat_id, source,
				float(spec.get("add", 0.0)) * power,
				pow(float(spec.get("mult", 1.0)), float(entry.get("stacks", 1))))


## Nom de source dans le résolveur. Préfixé : un statut ne doit jamais entrer en
## collision avec la faim, la fatigue ou un effet d'équipement.
func _source_of(status_id: String) -> String:
	return "statut:" + status_id


# --- Sauvegarde (E.10) ---

func save_state() -> Dictionary:
	return active.duplicate(true)


func restore_state(data: Dictionary) -> void:
	active.clear()
	if _modifiers != null:
		for status_id: String in GameData.status_effects:
			_modifiers.clear_source_everywhere(_source_of(status_id))
	for status_id: String in data:
		if not GameData.status_effects.has(status_id):
			continue   # Statut retiré des données : disparaît silencieusement.
		active[status_id] = (data[status_id] as Dictionary).duplicate()
		_register_modifiers(status_id)
