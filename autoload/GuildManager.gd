extends Node
## GuildManager — quêtes et rangs de guilde (GDD 7.3 / B.7, 2026-08-09).
##
## ---------------------------------------------------------------------------
## LE SOCLE B.7, PAS UNE MAQUETTE
## ---------------------------------------------------------------------------
## Le GDD est précis : les quêtes sont PROCÉDURALES, tirées de GABARITS en
## données (`data/quest_templates/*.json`, schéma B.7), chaque gabarit porte sa
## guilde, et la progression est un système de RANGS (5, figés : Novice à
## Maître) montés à l'XP de guilde. C'est exactement ce qui est construit ici —
## ajouter une guilde ou un type de quête, c'est ajouter un JSON, zéro code,
## comme le veut la règle 10 du projet.
##
## Deux guildes vivent au lancement (décision de l'auteur du 2026-08-09) :
## GUERRIERS (pattern « tuer ») et PROSPECTEURS (pattern « localiser » — on
## prouve le gisement en extrayant N blocs du minerai demandé). Les dix autres
## du GDD attendent leurs gabarits, rien d'autre.
##
## L'ÉTAT EST SUR LE JOUEUR (rangs, XP, quête active) : c'est une progression
## PERSONNELLE, comme les compétences — en multijoueur chaque pair a la sienne,
## et elle voyage avec sa sauvegarde. Ce manager n'est que la mécanique.

## Rangs du GDD (7.3) — « structure de rangs figée : 5 rangs ».
const RANK_NAMES: Array[String] = ["novice", "compagnon", "adepte", "expert", "maitre"]
## XP cumulée exigée pour ATTEINDRE chaque rang. Le premier est gratuit :
## pousser la porte de la guilde suffit à être novice.
const RANK_XP: Array[int] = [0, 100, 300, 700, 1500]

## Une quête refusée ne se retire pas à l'infini : le tirage est journalier.
const SEED_QUEST := 88117


## Guildes existantes : l'ensemble des champs `guild` des gabarits chargés.
## PAS de liste en dur — la liste EST la donnée.
func known_guilds() -> Array:
	var out := {}
	for template: Dictionary in GameData.quest_templates.values():
		out[String(template.get("guild", ""))] = true
	out.erase("")
	return out.keys()


func rank_of(player: Node, guild_id: String) -> int:
	var state: Dictionary = player.guild_state
	return int((state.get(guild_id, {}) as Dictionary).get("rank", 0))


func xp_of(player: Node, guild_id: String) -> int:
	var state: Dictionary = player.guild_state
	return int((state.get(guild_id, {}) as Dictionary).get("xp", 0))


func rank_name(rank: int) -> String:
	return RANK_NAMES[clampi(rank - 1, 0, RANK_NAMES.size() - 1)]


## S'inscrire : rang 1 (novice), gratuit. Sans inscription, pas de quête — la
## guilde ne confie pas de contrat à un inconnu.
func enroll(player: Node, guild_id: String) -> void:
	if not player.guild_state.has(guild_id):
		player.guild_state[guild_id] = {"rank": 1, "xp": 0}


## QUÊTE PROPOSÉE aujourd'hui par une guilde. Déterministe par (jour, guilde,
## rang) : revenir dans une heure ne re-tire pas le contrat, revenir demain si.
func offered_quest(player: Node, guild_id: String) -> Dictionary:
	var candidates: Array = []
	for template: Dictionary in GameData.quest_templates.values():
		if String(template.get("guild", "")) != guild_id:
			continue
		if rank_of(player, guild_id) < int(template.get("rank_min", 1)):
			continue
		candidates.append(template)
	if candidates.is_empty():
		return {}
	var day := TickManager.tick_index / int(DayNightManager.TICKS_PER_DAY)
	var rng := RandomNumberGenerator.new()
	rng.seed = NoiseGenerator.pcg_hash(day, guild_id.hash(),
			WorldManager.world_seed + SEED_QUEST)
	var template: Dictionary = candidates[rng.randi_range(0, candidates.size() - 1)]
	return _instantiate(template, player, rng)


## Le gabarit devient un CONTRAT : cible concrète, compte, récompense chiffrée.
func _instantiate(template: Dictionary, player: Node, rng: RandomNumberGenerator) -> Dictionary:
	var selector: Dictionary = template.get("target_selector", {})
	var count_range: Array = template.get("count_range", [3, 6])
	var count := rng.randi_range(int(count_range[0]), int(count_range[1]))
	var reward: Dictionary = template.get("reward", {})
	var target_id := ""
	var target_level := 1
	match String(template.get("pattern", "")):
		"tuer":
			# CIBLE AU NIVEAU DU JOUEUR (B.7 : combat_level_range_around_player).
			# La guilde n'envoie pas un novice sur un chef de bande.
			var pool: Array = []
			var wanted: Array = selector.get("tags_any", [])
			var level_range: Array = selector.get(
				"combat_level_range_around_player", [0.5, 2.0])
			var player_level := maxi(1, int(player.call("combat_level")) 					if player.has_method("combat_level") else 10)
			for id: String in GameData.creatures:
				var fiche: Dictionary = GameData.creatures[id]
				var tags: Array = fiche.get("tags", [])
				var tagged := false
				for tag: String in wanted:
					if tag in tags:
						tagged = true
				if not tagged:
					continue
				var level := int(fiche.get("niveau_combat", 1))
				if level < player_level * float(level_range[0]) 						or level > player_level * float(level_range[1]):
					continue
				pool.append(id)
			if pool.is_empty():
				# Personne dans la fourchette : on élargit plutôt que de ne rien
				# proposer — une guilde sans contrat est une guilde morte.
				for id: String in GameData.creatures:
					var tags: Array = (GameData.creatures[id] as Dictionary).get("tags", [])
					for tag: String in wanted:
						if tag in tags:
							pool.append(id)
			if pool.is_empty():
				return {}
			target_id = String(pool[rng.randi_range(0, pool.size() - 1)])
			target_level = int((GameData.creatures[target_id] as Dictionary).get("niveau_combat", 1))
		"localiser":
			var categories: Array = selector.get("category_any", ["minerai"])
			var pool: Array = []
			for id: String in GameData.materials:
				if String((GameData.materials[id] as Dictionary).get("category", "")) in categories:
					pool.append(id)
			if pool.is_empty():
				return {}
			target_id = String(pool[rng.randi_range(0, pool.size() - 1)])
	var gold := int(reward.get("gold_flat", 0)) 			+ int(reward.get("gold_per_target_level", 0)) * target_level * count
	return {
		"template": String(template.get("id", "")),
		"guild": String(template.get("guild", "")),
		"pattern": String(template.get("pattern", "")),
		"target": target_id,
		"count": count,
		"done": 0,
		"gold": gold,
		"guild_xp": int(reward.get("guild_xp", 10)),
		"text_key": String(template.get("text_key", "")),
	}


func accept(player: Node, guild_id: String, quest: Dictionary) -> void:
	enroll(player, guild_id)
	player.active_quests[guild_id] = quest.duplicate(true)


func active_quest(player: Node, guild_id: String) -> Dictionary:
	# Passage par une variable TYPEE : sur un Node non type, le parseur resout
	# `.get(a, b)` vers Object.get (1 argument) et refuse de compiler.
	var quests: Dictionary = player.active_quests
	return quests.get(guild_id, {})


## RENDRE un contrat accompli : l'or et l'XP tombent, le rang monte aux seuils.
## L'or de quête est un ROBINET du GDD (7.6 : « l'or circule et fuit ») — il ne
## sort pas du portefeuille du maître de guilde, les taxes hebdomadaires feront
## l'évier plus tard.
func turn_in(player: Node, guild_id: String) -> Dictionary:
	var quest: Dictionary = active_quest(player, guild_id)
	if quest.is_empty() or int(quest["done"]) < int(quest["count"]):
		return {}
	player.active_quests.erase(guild_id)
	player.gold += int(quest["gold"])
	var all_states: Dictionary = player.guild_state
	var state: Dictionary = all_states.get(guild_id, {"rank": 1, "xp": 0})
	state["xp"] = int(state["xp"]) + int(quest["guild_xp"])
	while int(state["rank"]) < RANK_NAMES.size() 			and int(state["xp"]) >= RANK_XP[int(state["rank"])]:
		state["rank"] = int(state["rank"]) + 1
	player.guild_state[guild_id] = state
	return quest


func _ready() -> void:
	EventBus.creature_killed.connect(_on_creature_killed)
	EventBus.block_destroyed.connect(_on_block_destroyed)


## PROGRESSION « TUER ». Le tueur doit être LE JOUEUR LOCAL : chaque pair suit
## ses propres contrats, un loup abattu par un autre joueur ne compte pas.
func _on_creature_killed(killer: Object, victim: Object) -> void:
	var player := _local_player()
	if player == null or killer != player or victim == null:
		return
	var quests: Dictionary = player.active_quests
	for guild_id: String in quests.keys():
		var quest: Dictionary = quests[guild_id]
		if String(quest.get("pattern", "")) != "tuer":
			continue
		if String(victim.get("creature_id")) != String(quest["target"]):
			continue
		quest["done"] = mini(int(quest["done"]) + 1, int(quest["count"]))
		player.active_quests[guild_id] = quest
		EventBus.ui_notification.emit(tr("ui.guilde.progression").format({
			"fait": str(quest["done"]), "total": str(quest["count"])}))


## PROGRESSION « LOCALISER » : on prouve le gisement en extrayant le minerai.
## Interprétation assumée du pattern des Prospecteurs (B.7 : « localiser ») —
## le jeu n'a pas encore de geste « signaler un filon », miner EST la preuve.
func _on_block_destroyed(_pos: Vector3i, material_id: int) -> void:
	var player := _local_player()
	if player == null:
		return
	# `material_by_runtime` est un TABLEAU indexe par id runtime, pas un
	# dictionnaire : on borne, on n indexe pas a l aveugle.
	if material_id < 0 or material_id >= GameData.material_by_runtime.size():
		return
	var name_id := String(GameData.material_by_runtime[material_id])
	var quests: Dictionary = player.active_quests
	for guild_id: String in quests.keys():
		var quest: Dictionary = quests[guild_id]
		if String(quest.get("pattern", "")) != "localiser":
			continue
		if name_id != String(quest["target"]):
			continue
		quest["done"] = mini(int(quest["done"]) + 1, int(quest["count"]))
		player.active_quests[guild_id] = quest
		EventBus.ui_notification.emit(tr("ui.guilde.progression").format({
			"fait": str(quest["done"]), "total": str(quest["count"])}))


func _local_player() -> Node:
	return get_tree().root.get_node_or_null("Main/Player")
