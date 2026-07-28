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

var _spawn_tick_counter := 0
var _spawn_pool: Array[String] = []

## Statistiques de tick (protégées — pas de threads ici, tick unique).
var last_tick_us: int = 0
var _sum_tick_us: int = 0
var _tick_samples: int = 0


func _ready() -> void:
	TickManager.tick_entities.connect(_on_tick)
	# Pool de spawn naturel (12/B.5), extensible sans code. Une créature n'y
	# entre QUE si elle déclare des `world_gen.biome_tags` : les civils
	# (villageois, forgeron...) n'en ont aucun et n'apparaissent donc jamais
	# en pleine nature — ils viendront avec la population de village (3.4/E.25).
	# "sanglier" exclu du spawn naturel (demande explicite 2026-07-20) — reste
	# spawnable manuellement (spawn() direct, ex. le test de combat).
	const NATURAL_SPAWN_EXCLUDED := ["sanglier"]
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
		EventBus.creature_killed.emit(null, creature)
		despawn(creature)

	# Spawn naturel : overworld uniquement (un donjon ne repop pas, 3.5).
	if natural_spawn_enabled and creature_root != null and active_dim == &"overworld":
		_natural_spawn_tick(player_pos)

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
	var armor_malus := int(player.call("armor_malus"))
	var result := CombatResolver.resolve_attack(
		creature.weapon_level, int(creature.stats.get("dexterite", 5)), int(creature.stats.get("force", 5)),
		player.skill_level("esquive"), armor_malus,
		String(functionality.get("degats_des", "1d4")), natural_hardness, 1.0, false, armor_dice)
	var player_skills: Variant = player.get("skills")
	if result["hit"]:
		player.take_damage(result["damage"])
		if player_skills != null and result["damage"] > 0:
			player_skills.gain_xp("encaissement", float(result["damage"]))
	elif not result["fumble"] and player_skills != null:
		player_skills.gain_xp("esquive", DODGE_XP_PER_MISS)


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
		if creatures.size() >= MAX_ACTIVE:
			return
		var ox := x + randi_range(-3, 3)
		var oz := z + randi_range(-3, 3)
		spawn(creature_id, Vector3(ox, WorldManager.generator.height_at(ox, oz) + 0.5, oz))


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
