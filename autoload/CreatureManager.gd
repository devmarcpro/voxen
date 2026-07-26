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
	TickManager.tick.connect(_on_tick)
	# Pool de spawn naturel : toute créature hostile des données (12/B.5),
	# extensible sans code. "sanglier" exclu du spawn naturel (demande
	# explicite 2026-07-20) — reste spawnable manuellement (spawn() direct,
	# ex. le test de combat), seul le peuplement automatique du monde est coupé.
	const NATURAL_SPAWN_EXCLUDED := ["sanglier"]
	for id in GameData.creatures:
		var data: Dictionary = GameData.creatures[id]
		if data.get("ai_profile", "") == "hostile" and id not in NATURAL_SPAWN_EXCLUDED:
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
	var result := CombatResolver.resolve_attack(
		creature.weapon_level, int(creature.stats.get("dexterite", 5)), int(creature.stats.get("force", 5)),
		player.skill_level("esquive"), 0,
		String(functionality.get("degats_des", "1d4")), natural_hardness, 1.0, false, "")
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

	if creatures.size() >= MAX_ACTIVE or nearby >= SPAWN_NEARBY_CAP:
		return
	var angle := randf() * TAU
	var spawn_dist := randf_range(SPAWN_MIN_DIST, SPAWN_MAX_DIST)
	var x := int(player_pos.x + cos(angle) * spawn_dist)
	var z := int(player_pos.z + sin(angle) * spawn_dist)
	var h := WorldManager.generator.height_at(x, z)
	var creature_id: String = _spawn_pool[randi() % _spawn_pool.size()]
	spawn(creature_id, Vector3(x, h + 0.5, z))


## Statistiques pour le HUD/bench (critère G.8 : 50 créatures, tick < 8 ms).
func stats() -> Dictionary:
	var avg_us := _sum_tick_us / maxi(_tick_samples, 1)
	return {"active": creatures.size(), "last_tick_ms": last_tick_us / 1000.0, "avg_tick_ms": avg_us / 1000.0}
