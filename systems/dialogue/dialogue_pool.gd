class_name DialoguePool
extends RefCounted
## Répliques d'ambiance des PNJ (GDD E.23).
##
## PAS D'ARBRE DE DIALOGUE, PAS DE GÉNÉRATIF. Le GDD tranche explicitement :
## interagir ouvre un MENU CONTEXTUEL, et la réplique affichée en haut est tirée
## d'un pool de gabarits filtrés par leurs conditions. « La profondeur vient du
## nombre de gabarits et de la finesse des conditions », pas d'une machine à
## états qu'il faudrait écrire à la main pour chaque personnage.
##
## Conséquence directe sur ce fichier : il ne connaît AUCUN texte. Ajouter une
## réplique, c'est ajouter une entrée dans `data/dialogue/ambiance.json` et deux
## lignes de langue. C'est la règle du projet (11.1), et c'est ce qui rend
## crédible l'objectif du GDD d'en absorber des centaines.
##
## ANTI-RÉPÉTITION. Un PNJ qui resservirait la même phrase à chaque clic
## détruirait l'illusion plus sûrement qu'un pool pauvre. On mémorise les
## dernières répliques servies PAR PERSONNE, et on les écarte du tirage tant
## qu'il reste autre chose à dire.

## Nombre de répliques récentes écartées par interlocuteur.
const MEMORY := 3

## Répliques récemment servies : clé sociale → Array[String] d'ids.
static var _recent := {}


## Choisit une réplique pour ce PNJ. Retourne la clé de langue à afficher, ou
## "" si aucun gabarit ne correspond (le menu s'ouvre alors sans réplique
## plutôt que d'inventer quelque chose).
static func pick(context: Dictionary) -> String:
	var pool: Array = GameData.dialogue_lines
	var candidates: Array[Dictionary] = []
	var total := 0.0
	var memory: Array = _recent.get(String(context.get("key", "")), [])

	for line: Dictionary in pool:
		if not _matches(line.get("conditions", {}), context):
			continue
		if String(line["id"]) in memory:
			continue
		candidates.append(line)
		total += float(line.get("weight", 1.0))

	# Tout a été dit récemment : on oublie et on recommence, plutôt que de se
	# taire. Un PNJ muet se lit comme un bug, un PNJ qui se répète comme un PNJ.
	if candidates.is_empty():
		_recent.erase(String(context.get("key", "")))
		for line: Dictionary in pool:
			if _matches(line.get("conditions", {}), context):
				candidates.append(line)
				total += float(line.get("weight", 1.0))
	if candidates.is_empty():
		return ""

	var roll := randf() * total
	for line: Dictionary in candidates:
		roll -= float(line.get("weight", 1.0))
		if roll <= 0.0:
			_remember(String(context.get("key", "")), String(line["id"]))
			return String(line["text_key"])
	_remember(String(context.get("key", "")), String(candidates[0]["id"]))
	return String(candidates[0]["text_key"])


static func _remember(key: String, line_id: String) -> void:
	var memory: Array = _recent.get(key, [])
	memory.append(line_id)
	while memory.size() > MEMORY:
		memory.pop_front()
	_recent[key] = memory


## Une condition ABSENTE ne contraint rien. C'est ce qui permet d'écrire un
## gabarit générique sans énumérer tout ce qu'il ne demande pas.
static func _matches(conditions: Dictionary, context: Dictionary) -> bool:
	if conditions.has("job") and String(conditions["job"]) != String(context.get("job", "")):
		return false
	var relation := float(context.get("relation", 0.0))
	if conditions.has("relation_min") and relation < float(conditions["relation_min"]):
		return false
	if conditions.has("relation_max") and relation > float(conditions["relation_max"]):
		return false
	if conditions.has("hour_min") or conditions.has("hour_max"):
		var hour := float(context.get("hour", 12.0))
		var low := float(conditions.get("hour_min", 0.0))
		var high := float(conditions.get("hour_max", 24.0))
		# Fenêtre qui FRANCHIT MINUIT (22 h → 4 h) : sans ce cas, une réplique
		# nocturne ne sortirait jamais, et l'erreur serait invisible puisque le
		# pool générique prendrait le relais sans rien signaler.
		if low <= high:
			if hour < low or hour > high:
				return false
		elif hour < low and hour > high:
			return false
	return true


## Contexte d'un PNJ, tel que l'attend `pick`. Rassemblé ici pour que l'UI et
## les sondes construisent exactement le même — deux constructions parallèles
## finiraient par diverger sur l'heure ou sur le calcul de relation.
static func context_for(creature: Node, reputation: Reputation) -> Dictionary:
	var relation := 0.0
	if reputation != null:
		relation = reputation.standing_with(String(creature.social_key),
			creature.village_cell, String(creature.race_id),
			String(creature.kingdom_id))
	return {
		"key": String(creature.social_key),
		"job": String(creature.job),
		"relation": relation,
		"hour": fmod(float(TickManager.tick_index), DayNightManager.TICKS_PER_DAY)
			/ DayNightManager.TICKS_PER_DAY * DayNightManager.HOURS_PER_DAY,
	}
