extends Node
## CreatureManager — gestion des créatures actives (12/D.1). Tick unique par
## frame de tick (E.1), jamais dans _process. Budget E.14 : ~64 entités
## niveau 1 (plein) par zone ; au-delà, les spawns s'arrêtent (pas de
## despawn brutal, G.5).

const MAX_ACTIVE := 64
const CREATURE_SCENE := preload("res://scenes/entities/creature.tscn")

## Spawn naturel autour du joueur en exploration (hors bench, désactivable).
const SPAWN_INTERVAL_TICKS := 50   # ~5 s en temps réel (E.1 : 10 ticks/s).
const SPAWN_MIN_DIST := 14.0
const SPAWN_MAX_DIST := 28.0
const SPAWN_NEARBY_RADIUS := 40.0
const SPAWN_NEARBY_CAP := 10       # Densité locale max avant d'arrêter de spawn.
const DESPAWN_DIST := 80.0         # Nettoyage des créatures laissées loin derrière.

var creature_root: Node3D
var creatures: Array[Node] = []
## Désactivé pendant les benchs qui gèrent leur propre population.
var natural_spawn_enabled := true

## Derniere position connue du joueur, rafraichie a chaque tick. Publiee
## pour que les creatures s'en servent en _process (barre de vie, culling
## d'IK) sans refaire une recherche de noeud par creature et par frame.
var last_player_position := Vector3.ZERO

var _spawn_tick_counter := 0
var _spawn_pool: Array[String] = []

## FILE DE SPAWN ÉTALÉE (2026-07-28). Instancier une créature coûte ~7 ms :
## un modèle riggé de 18 maillages, ce n'est plus la capsule d'avant. Une
## MEUTE (F.3 : « Loup, 1d4+1 ») en faisait apparaître jusqu'à cinq DANS LE
## MÊME TICK, soit ~37 ms — d'où les alertes « [TICK] 27.8 ms » relevées en
## jeu sur la machine cible. Les compagnons sont donc mis en file et sortent
## un par tick : la meute arrive en une demi-seconde au lieu d'une frame, ce
## que personne ne remarque, et aucun tick ne dépasse le coût d'UN spawn.
const SPAWNS_PER_TICK := 1
var _spawn_queue: Array[Dictionary] = []

## Statistiques de tick (protégées — pas de threads ici, tick unique).
var last_tick_us: int = 0
var _sum_tick_us: int = 0
var _tick_samples: int = 0


## Modèles de créature PRÉCHARGÉS au démarrage (2026-07-28). Le tout premier
## spawn payait sinon la lecture disque + le parsing du `.glb` EN PLEIN TICK :
## 163,8 ms mesurées en jeu sur la machine cible, sur un budget de 16. Un coût
## unique reste un coût — mais au chargement, où il ne fait rater aucune frame
## de jeu. Godot met les ressources en cache, `load()` au spawn devient gratuit.
func _preload_creature_models() -> void:
	var seen := {}
	for id: String in GameData.creatures:
		var path := String((GameData.creatures[id] as Dictionary).get("model", ""))
		if path == "" or seen.has(path) or not ResourceLoader.exists(path):
			continue
		seen[path] = true
		load(path)
	# Préchauffe AUSSI le cache de matériaux de peau : la première créature de
	# chaque espèce paierait sinon ses 4 uploads de texture en plein tick.
	# Une palette par race, 4 textures 8×8 chacune — négligeable au chargement.
	var warmed := {}
	for id: String in GameData.creatures:
		var data: Dictionary = GameData.creatures[id]
		var race := String(data.get("race", id))
		if warmed.has(race):
			continue
		warmed[race] = true
		PlayerBody.warm_skin_cache(PlayerBody.palette_for_species(race))


func _ready() -> void:
	TickManager.tick_entities.connect(_on_tick)
	_preload_creature_models.call_deferred()
	# Pool de spawn naturel (12/B.5), extensible sans code. Une créature n'y
	# entre QUE si elle déclare des `world_gen.biome_tags` : les civils
	# (villageois, forgeron...) n'en ont aucun et n'apparaissent donc jamais
	# en pleine nature — ils viendront avec la population de village (3.4/E.25).
	# Exclusion manuelle : une espèce peut porter des `biome_tags` (donc être
	# cohérente avec un biome) sans pour autant devoir apparaître seule en
	# pleine nature. Vide depuis le 2026-08-02 — la seule entrée était
	# "sanglier", supprimé avec le reste de la faune animale. Le mécanisme
	# reste : c'est le seul moyen de retirer une espèce du spawn sans lui
	# effacer ses tags de biome.
	const NATURAL_SPAWN_EXCLUDED: Array[String] = []
	for id in GameData.creatures:
		var data: Dictionary = GameData.creatures[id]
		if id in NATURAL_SPAWN_EXCLUDED:
			continue
		var tags: Array = (data.get("world_gen", {}) as Dictionary).get("biome_tags", [])
		if tags.is_empty():
			continue
		_spawn_pool.append(id)


func spawn(creature_id: String, world_position: Vector3) -> Node:
	if creature_root == null or creatures.size() >= MAX_ACTIVE:
		return null
	if not GameData.creatures.has(creature_id):
		push_error("CreatureManager : créature inconnue « %s »." % creature_id)
		return null
	var instance := CREATURE_SCENE.instantiate()
	creature_root.add_child(instance)
	instance.setup(creature_id, world_position)
	# Dimension d'appartenance (3.5) : celle active au moment du spawn — un
	# boss spawné pendant la construction d'un donjon appartient au donjon.
	instance.dimension = WorldManager.active_dimension
	creatures.append(instance)
	return instance


## Bascule de dimension (WorldManager.set_active_dimension) : les créatures
## hors de la dimension active sont cachées ET gelées (voir _on_tick) — deux
## dimensions partagent le même espace 3D, sans ça les créatures overworld
## apparaîtraient dans le donjon aux mêmes coordonnées locales.
func on_dimension_changed(dim: StringName) -> void:
	for creature in creatures:
		if is_instance_valid(creature):
			creature.visible = creature.dimension == dim


## Retire toutes les créatures d'une dimension (sortie de donjon : le boss
## restant est libéré — il renaîtra à la reconstruction, simplification 3.5).
func despawn_dimension(dim: StringName) -> void:
	for creature in creatures.duplicate():
		if is_instance_valid(creature) and creature.dimension == dim:
			despawn(creature)


func despawn(creature: Node) -> void:
	creatures.erase(creature)
	creature.queue_free()


func _on_tick(_tick_index: int) -> void:
	if WorldManager.generator == null:
		return  # Aucun monde actif (menu de démarrage) : ni IA ni spawn.
	var player := get_node_or_null("/root/Main/Player")
	if player == null:
		return
	var player_pos: Vector3 = player.get_position_for_ai() if player.has_method("get_position_for_ai") else Vector3.ZERO
	last_player_position = player_pos
	var start := Time.get_ticks_usec()

	var active_dim := WorldManager.active_dimension
	var dead: Array[Node] = []
	for creature in creatures:
		if creature.dimension != active_dim:
			continue  # Gelée hors de sa dimension (3.5) — ni IA ni mort résolue.
		if creature.is_dead():
			dead.append(creature)
			continue
		var event: Dictionary = creature.tick_step(player_pos, player)
		if not event.is_empty():
			_resolve_creature_attack(creature, player)

	for creature in dead:
		_note_resident_death(creature)
		EventBus.creature_killed.emit(null, creature)
		despawn(creature)

	# Population des villages : indépendante du spawn naturel, et volontairement.
	# Couper le spawn naturel (menu de triche, sondes de combat) ne doit pas
	# vider les villages — ce sont deux phénomènes distincts, l'un est la faune
	# qui rôde, l'autre des gens qui habitent là.
	if creature_root != null and active_dim == &"overworld":
		_village_population_tick(player_pos)

	# Spawn naturel : overworld uniquement (un donjon ne repop pas, 3.5).
	if natural_spawn_enabled and creature_root != null and active_dim == &"overworld":
		_natural_spawn_tick(player_pos)
		# Puis au plus UNE créature en attente : c'est ce qui borne le coût
		# d'un tick au prix d'un seul modèle instancié.
		_drain_spawn_queue()

	last_tick_us = Time.get_ticks_usec() - start
	_sum_tick_us += last_tick_us
	_tick_samples += 1


## Une créature hostile attaque le joueur (E.3) — l'inverse (joueur attaque
## créature) est résolu côté Player (systems/combat, appelé depuis l'input).
## XP du défenseur (E.3 étape 6) : Encaissement sur coup subi (XP = dégâts,
## symétrique de l'XP d'arme de l'attaquant), Esquive sur attaque évitée
## (XP fixe par esquive — le GDD ne chiffre pas cette valeur, interprétation
## signalée). L'échec critique (fumble) ne donne rien : l'attaque s'est
## sabordée seule, le défenseur n'a rien fait.
const DODGE_XP_PER_MISS := 5.0
## Part des dégâts qui passe malgré une garde tenue. Non nulle volontairement :
## bloquer doit être une réponse coûteuse, pas une invulnérabilité — c'est ce
## qui oblige à reculer plutôt qu'à camper derrière son arme.
const GUARD_DAMAGE_FACTOR := 0.25
## XP d'Esquive d'un chambering reussi. Superieur au simple evitement : le
## geste demande une lecture de direction ET un timing.
const CHAMBER_XP := 20.0

func _resolve_creature_attack(creature: Node, player: Node) -> void:
	var functionality: Dictionary = creature.combat_functionality()
	# Dureté de l'arme naturelle : donnée B.5 (`combat.durete_naturelle`),
	# 10 (étalon demi-fer, A.4.1) par défaut — plus de valeur en dur unique
	# pour toutes les créatures (audit 2026-07-21).
	var natural_hardness := float((creature.combat as Dictionary).get("durete_naturelle", 10.0))
	# Armure du joueur (6.2/A.4.2, 2026-07-26) : jusqu'ici la mitigation d'E.3
	# était TOUJOURS nulle faute d'emplacements d'équipement — les dés de
	# réduction et le malus de défense au poids sont maintenant réels.
	var armor_dice := String(player.call("armor_dice"))
	# Efficacité de l'armure SELON le type de dégât reçu (2026-07-28) : une
	# plaque arrête l'épée et subit la masse. La mitigation est modulée, pas
	# les dégâts — voir data/armor_type_modifiers.json.
	var damage_type := String(functionality.get("type_degats", "contondant"))
	var armor_category := String(player.call("armor_category"))
	var type_modifier := WeaponStats.armor_type_modifier(armor_category, damage_type)

	# ESQUIVE GÉOMÉTRIQUE (2026-07-28) : le 1d20 de toucher a disparu, donc
	# esquiver n'est plus un jet — c'est avoir quitté la portée entre la
	# déclaration du coup et son impact. Le contrôle de portée est refait ICI,
	# à la résolution, et non à la décision : c'est très exactement le jeu de
	# jambes que le combat directionnel cherche à récompenser.
	var player_skills: Variant = player.get("skills")
	# CHAMBERING : attaquer DANS LA MEME DIRECTION que le coup qui arrive,
	# au bon moment, entrechoque les armes. L'attaque adverse est annulee et
	# celle du joueur continue — elle n'est pas interrompue ici, elle suit
	# simplement son cours. Le geste le plus exigeant de Mount & Blade.
	if bool(player.call("is_chambering", creature.attack_direction)):
		EventBus.ui_notification.emit("ui.combat.chambering")
		if player_skills != null:
			player_skills.gain_xp("esquive", CHAMBER_XP)
		return
	var reach := float(functionality.get("portee", 1.5))
	var body: Vector3 = player.get_position_for_ai() + Vector3(0.0, -0.9, 0.0)
	if creature.logical_position.distance_to(body) > reach + 0.5:
		if player_skills != null:
			player_skills.gain_xp("esquive", DODGE_XP_PER_MISS)
		return

	# La garde du joueur absorbe le coup : les dégâts sont fortement réduits,
	# mais l'endurance encaisse le drain de l'arme adverse. Sans endurance, la
	# garde casse et le coup passe en entier (stagger).
	var guard: Dictionary = player.call("guard_state")
	var creature_stats := WeaponStats.derive(functionality, {})
	var zone_mult := 1.0
	var penetration := float(creature_stats["penetration"])
	var guarded := false
	# BLOCAGE DIRECTIONNEL : la garde ne protege que si elle est orientee
	# du bon cote. Une garde tenue dans la mauvaise direction ne sert a
	# RIEN — c'est ce qui fait du duel un echange de lectures plutot qu'un
	# bouton de defense maintenu.
	var covered: bool = player.call("guard_covers", creature.attack_direction)
	if covered:
		guarded = player.call("absorb_on_guard", float(creature_stats["stamina_drain"]),
				bool(guard.get("parry", false)))

	var result := CombatResolver.resolve_hit(
		int(creature.stats.get("dexterite", 5)), int(creature.stats.get("force", 5)),
		String(functionality.get("degats_des", "1d4")), natural_hardness, 1.0, false,
		armor_dice, zone_mult, penetration)
	var damage := int(result["damage"])
	if armor_dice != "" and type_modifier != 1.0:
		# Ré-application du modificateur de type : resolve_hit ne connaît pas
		# les matériaux, il ne fait que soustraire une mitigation déjà tirée.
		damage = maxi(0, int(result["raw"]) - int(round(float(result["reduction"]) * type_modifier)))
	if guarded:
		damage = int(round(damage * GUARD_DAMAGE_FACTOR))

	player.take_damage(damage)
	if player_skills != null and damage > 0:
		player_skills.gain_xp("encaissement", float(damage))


## Spawn périodique autour du joueur pendant l'exploration (hors bench) :
## budget global (MAX_ACTIVE) + densité locale (SPAWN_NEARBY_CAP) — cohérent
## avec E.14 (les spawns s'arrêtent au-delà du budget, pas de despawn brutal).
func _natural_spawn_tick(player_pos: Vector3) -> void:
	_spawn_tick_counter += 1
	if _spawn_tick_counter < SPAWN_INTERVAL_TICKS or _spawn_pool.is_empty():
		return
	_spawn_tick_counter = 0

	var nearby := 0
	var to_despawn: Array[Node] = []
	for creature: Node3D in creatures:
		if creature.get("dimension") != &"overworld":
			continue  # Jamais de despawn de distance inter-dimensions (boss de donjon).
		var dist: float = creature.position.distance_to(player_pos)
		if dist <= SPAWN_NEARBY_RADIUS:
			nearby += 1
		elif dist > DESPAWN_DIST:
			to_despawn.append(creature)
	for creature in to_despawn:
		despawn(creature)

	# Nuit : densité de spawn hostile DOUBLÉE (E.21 « la nuit est dangereuse »).
	# On relève le plafond local plutôt que d'accélérer la cadence : ça donne
	# une nuit plus peuplée sans multiplier le coût par tick.
	var local_cap := SPAWN_NEARBY_CAP * 2 if DayNightManager.is_night() else SPAWN_NEARBY_CAP
	if creatures.size() >= MAX_ACTIVE or nearby >= local_cap:
		return
	var angle := randf() * TAU
	var spawn_dist := randf_range(SPAWN_MIN_DIST, SPAWN_MAX_DIST)
	var x := int(player_pos.x + cos(angle) * spawn_dist)
	var z := int(player_pos.z + sin(angle) * spawn_dist)
	var h := WorldManager.generator.height_at(x, z)
	# Cohérence de faune : la créature doit appartenir au BIOME du point de
	# spawn (sinon un ours polaire apparaît en plein désert). Même convention
	# que les plantes et les arbres : intersection des `biome_tags`.
	var creature_id := _pick_for_biome(x, z)
	if creature_id == "":
		return
	var spawned := spawn(creature_id, Vector3(x, h + 0.5, z))
	if spawned == null:
		return
	# Meutes (F.3 : « Loup, meutes 1d4+1 ») : compagnons serrés autour du
	# premier, dans la limite des budgets globaux/locaux déjà vérifiés.
	var pack: Array = (GameData.creatures[creature_id].get("world_gen", {}) as Dictionary).get("pack_size", [])
	if pack.size() != 2:
		return
	var extra := randi_range(int(pack[0]), int(pack[1])) - 1
	for i in extra:
		var ox := x + randi_range(-3, 3)
		var oz := z + randi_range(-3, 3)
		# MISE EN FILE, pas de spawn immédiat : cinq instanciations dans le
		# même tick le faisaient exploser (voir _spawn_queue).
		_spawn_queue.append({
			"id": creature_id,
			"position": Vector3(ox, WorldManager.generator.height_at(ox, oz) + 0.5, oz),
		})


## Sort au plus SPAWNS_PER_TICK créatures de la file. Les budgets (global et
## local) sont re-vérifiés ICI : entre la mise en file et la sortie, le joueur
## a pu s'éloigner ou la population atteindre son plafond.
func _drain_spawn_queue() -> void:
	var produced := 0
	while not _spawn_queue.is_empty() and produced < SPAWNS_PER_TICK:
		var entry: Dictionary = _spawn_queue.pop_front()
		if creatures.size() >= MAX_ACTIVE:
			_spawn_queue.clear()   # Plafond atteint : la file entière est caduque.
			return
		spawn(String(entry["id"]), entry["position"])
		produced += 1


## Créature du pool compatible avec le biome en (x, z), ou "" si aucune.
## Tirage uniforme parmi les compatibles (le GDD ne pondère pas les créatures
## par biome — F.3 les range par milieu, sans densité).
func _pick_for_biome(x: int, z: int) -> String:
	var biome: Dictionary = WorldManager.generator.biome_at(x, z)
	if biome.is_empty():
		return ""
	var candidates := _candidates_for_tags(biome.get("tags", []))
	if candidates.is_empty():
		return ""
	return candidates[randi() % candidates.size()]

## Créatures du pool compatibles avec un jeu de tags de biome — extrait de
## _pick_for_biome pour être testable sans passer par des coordonnées.
func _candidates_for_tags(biome_tags: Array) -> Array[String]:
	# Volet NOCTURNE des tables de spawn (E.21) : chaque espèce déclare son
	# `activite` (jour / nuit / toujours). Sans ce filtre, les loups en chasse
	# et les maraudeurs apparaissaient en plein midi et les herbivores
	# broutaient à 3 h du matin — la nuit n'avait aucune identité propre.
	var night := DayNightManager.is_night()
	var candidates: Array[String] = []
	for id in _spawn_pool:
		var world_gen: Dictionary = GameData.creatures[id].get("world_gen", {})
		var activite := String(world_gen.get("activite", "toujours"))
		if activite == "nuit" and not night:
			continue
		if activite == "jour" and night:
			continue
		for tag: String in (world_gen.get("biome_tags", []) as Array):
			if tag in biome_tags:
				candidates.append(id)
				break
	return candidates


## Statistiques pour le HUD/bench (critère G.8 : 50 créatures, tick < 8 ms).
func stats() -> Dictionary:
	var avg_us := _sum_tick_us / maxi(_tick_samples, 1)
	return {"active": creatures.size(), "last_tick_ms": last_tick_us / 1000.0, "avg_tick_ms": avg_us / 1000.0}


# --- Population des villages (3.4/8.4) ---------------------------------------
#
# Les habitants ne sont pas des créatures de spawn naturel : ils ne rôdent pas,
# ils HABITENT. On les fait donc exister quand le joueur approche du village et
# disparaître quand il s'en éloigne, sans jamais les tirer au hasard — leur
# composition est dérivée de la cellule et de la graine (VillagePopulation).
#
# Ce sont des `Creature` comme les autres, spawnées par le même `spawn()`. Le
# GDD (12.1) l'exige et l'auteur l'a rappelé : un marchand et un sanglier sont
# faits de la même façon. La seule chose qui les distingue ici, c'est qu'on leur
# renseigne un métier et un domicile après le spawn.

## Distance à laquelle un village se peuple. Généreuse : on doit voir la vie du
## village en approchant, pas la voir apparaître une fois dedans.
const VILLAGE_POPULATE_DIST := 110.0
## Distance à laquelle on renvoie les habitants au néant. Nettement plus grande
## que le seuil de peuplement : sans cette hystérésis, marcher sur la limite
## ferait clignoter tout le village.
const VILLAGE_RELEASE_DIST := 180.0
## Un village par tick au maximum, comme pour le spawn naturel : peupler
## vingt habitants d'un coup ferait un pic de tick très visible.
var _populated_villages := {}


func _village_population_tick(player_pos: Vector3) -> void:
	var generator := WorldManager.generator
	if generator == null:
		return
	var cell_size: int = ClaimManager.CELL_SIZE
	var player_cell := ClaimManager.cell_of_block(int(player_pos.x), int(player_pos.z))

	# Relâche d'abord : c'est ce qui libère des places dans MAX_ACTIVE avant
	# d'en demander de nouvelles.
	for cell: Vector2i in _populated_villages.keys():
		var center := POIGenerator.cell_center_world(cell)
		if player_pos.distance_to(Vector3(center.x, player_pos.y, center.y)) > VILLAGE_RELEASE_DIST:
			_release_village(cell)

	for dz in range(-1, 2):
		for dx in range(-1, 2):
			var cell := player_cell + Vector2i(dx, dz)
			if _populated_villages.has(cell):
				continue
			var center := POIGenerator.cell_center_world(cell)
			if player_pos.distance_to(Vector3(center.x, player_pos.y, center.y)) > VILLAGE_POPULATE_DIST:
				continue
			var plan: Dictionary = generator.city_at_cell(cell)
			if plan.is_empty():
				continue
			_populate_village(cell, plan)
			return  # Un seul village par tick.


func _populate_village(cell: Vector2i, plan: Dictionary) -> void:
	var residents: Array[Node] = []
	var roster := VillagePopulation.roster(cell, WorldManager.world_seed, plan)
	# UNE seule requête de royaume par village, pas une par habitant : elle est
	# mise en cache, mais la faire vingt fois resterait vingt fois trop.
	var kingdom: Dictionary = WorldManager.generator.kingdom_at_cell(cell)
	var kingdom_id := String(kingdom.get("id", ""))
	for index in roster.size():
		# UN MORT NE REVIENT PAS. Sans ce saut, s'éloigner puis revenir
		# ressusciterait tout le village et le meurtre serait gratuit.
		if VillageManager.is_dead(cell, index):
			continue
		var entry: Dictionary = roster[index]
		if creatures.size() >= MAX_ACTIVE:
			break
		var home := VillagePopulation.home_position(cell, plan, int(entry["plot"]))
		var creature := spawn(String(entry["creature_id"]), Vector3(home))
		if creature == null:
			continue
		creature.village_cell = cell
		creature.job = String(entry["job"])
		# La clé vient du RANG dans le roster, qui est déterministe : c'est ce
		# qui permet de retrouver la relation nouée avec cette personne après
		# être parti à l'autre bout du monde et revenu.
		creature.social_key = Reputation.resident_key(cell, index)
		creature.roster_index = index
		creature.kingdom_id = kingdom_id
		creature.home_building = Vector3(home)
		creature.work_place = Vector3(VillagePopulation.work_position(cell, plan))
		residents.append(creature)
	_populated_villages[cell] = residents


## Retire les habitants d'un village dont le joueur s'est éloigné.
##
## Les MORTS ne sont pas ressuscités : une créature déjà retirée de `creatures`
## ne réapparaîtra pas au prochain passage tant que la décimation (3.4) n'aura
## pas de mémoire persistante. C'est une limite connue et assumée à ce stade —
## mieux vaut un village qui se repeuple qu'un village qui ne se peuple jamais.
func _release_village(cell: Vector2i) -> void:
	for creature: Node in _populated_villages.get(cell, [] as Array[Node]):
		if creature != null and is_instance_valid(creature):
			despawn(creature)
	_populated_villages.erase(cell)


## Inscrit la mort d'un HABITANT au registre des villages. Sans effet sur une
## bête ou un civil errant : seuls les résidents ont un rang de roster, et c'est
## ce rang qui doit rester vide au prochain passage.
func _note_resident_death(creature: Node) -> void:
	if creature == null or not is_instance_valid(creature):
		return
	if int(creature.roster_index) < 0:
		return
	VillageManager.record_death(creature.village_cell, int(creature.roster_index))
