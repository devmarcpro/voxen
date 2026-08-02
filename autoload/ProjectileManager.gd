extends Node
## Projectiles en vol (2026-08-02) — flèches et carreaux.
##
## MÊME CONTRAT QUE LE RESTE DU COMBAT : la GÉOMÉTRIE avance à la frame, le TICK
## applique. Un projectile parcourt plusieurs mètres entre deux ticks ; le
## résoudre à 10 Hz le ferait traverser une cible sur deux. Il avance donc à la
## frame et ne fait que CONSTATER ses impacts, que le tick transforme en dégâts.
##
## Il n'y a aucun corps physique ici, comme partout ailleurs dans ce projet : le
## segment parcouru pendant la frame est testé contre les zones de coup des
## créatures et contre les blocs. C'est le même test que celui d'une lame, donc
## une flèche touche exactement là où une épée toucherait.

## Gravité appliquée aux projectiles. VOLONTAIREMENT plus faible que celle du
## joueur (32) : à 32, une flèche tirée à 46 m/s tombe de trois mètres en vingt,
## ce qui rend toute visée illisible. À 14 elle chute d'environ 1,3 m sur la même
## distance — assez pour qu'on doive viser haut au loin, pas assez pour que le
## tir devienne un jeu de mortier. VALEUR DE RESSENTI.
const GRAVITY := 14.0
## Au-delà, le projectile disparaît : il a fini sa course. Sans cette borne, un
## tir vers le ciel resterait en vol indéfiniment.
const MAX_LIFETIME := 6.0
## Vitesse sous laquelle un projectile est considéré comme épuisé.
const MIN_SPEED := 4.0

## Projectiles en vol. Chacun : { "position", "velocity", "shooter", "stats",
## "hardness", "quality", "skill", "age", "node" }.
var _flying: Array[Dictionary] = []
## Impacts constatés à la frame, drainés par le tick.
var _pending: Array[Dictionary] = []


## Dimension dans laquelle volent les projectiles courants. Un changement de
## dimension (entrée en donjon, retour en surface) les efface : une flèche tirée
## en surface n'a rien à faire dans une salle de donjon, et elle y toucherait
## des créatures que le tireur n'a jamais vues.
var _flying_dimension: StringName = &"overworld"


func _ready() -> void:
	TickManager.tick_entities.connect(_on_tick)


func _clear_all() -> void:
	for shot: Dictionary in _flying:
		if shot["node"] != null:
			(shot["node"] as Node3D).queue_free()
	_flying.clear()
	_pending.clear()


## Lance un projectile. `stats` vient de `WeaponStats.derive` (dés, pénétration,
## type de dégâts) ; `hardness` et `quality` sont ceux de l'arme, figés au
## départ comme pour une frappe de mêlée.
func launch(origin: Vector3, direction: Vector3, stats: Dictionary,
		hardness: float, quality: float, shooter: Node) -> void:
	var speed := float(stats.get("vitesse_projectile", 46.0))
	_flying_dimension = WorldManager.active_dimension
	var arrow := _build_arrow()
	_flying.append({
		"position": origin,
		"velocity": direction.normalized() * speed,
		"initial_speed": speed,
		"stats": stats,
		"hardness": hardness,
		"quality": quality,
		"shooter": shooter,
		"age": 0.0,
		"node": arrow,
	})
	if arrow != null:
		arrow.global_position = origin


func _process(delta: float) -> void:
	if _flying.is_empty():
		return
	if WorldManager.active_dimension != _flying_dimension:
		_clear_all()
		return
	var still_flying: Array[Dictionary] = []
	for shot: Dictionary in _flying:
		if _advance(shot, delta):
			still_flying.append(shot)
		elif shot["node"] != null:
			(shot["node"] as Node3D).queue_free()
	_flying = still_flying


## Avance un projectile d'une frame. Retourne false quand il a fini sa course
## (touché, planté dans le décor, épuisé).
func _advance(shot: Dictionary, delta: float) -> bool:
	shot["age"] = float(shot["age"]) + delta
	if float(shot["age"]) > MAX_LIFETIME:
		return false
	var from: Vector3 = shot["position"]
	var velocity: Vector3 = shot["velocity"]
	velocity.y -= GRAVITY * delta
	var to := from + velocity * delta
	shot["velocity"] = velocity
	if velocity.length() < MIN_SPEED:
		return false

	# LA CIBLE D'ABORD, LE DÉCOR ENSUITE : une flèche qui traverse un ennemi
	# devant un mur doit le toucher, LUI. On retient le contact le plus proche.
	var best_t := 2.0
	var best_hit: Dictionary = {}
	var victim: Node = null
	for creature in CreatureManager.creatures:
		if not is_instance_valid(creature) or creature.is_dead():
			continue
		if creature.dimension != WorldManager.active_dimension:
			continue
		# Rejet grossier : un projectile ne parcourt que quelques mètres par
		# frame, inutile de tester toute la faune de la carte.
		if creature.logical_position.distance_squared_to(from) > 900.0:
			continue
		var hit: Dictionary = creature.sweep_segment(from, to)
		if hit.is_empty() or float(hit["t"]) >= best_t:
			continue
		best_t = float(hit["t"])
		best_hit = hit
		victim = creature

	# LA GARDE ARRÊTE AUSSI LES FLÈCHES (2026-08-02). Un projectile ignorait
	# complètement la défense : on encaissait une flèche bouclier levé. Dans
	# Mount & Blade un bouclier est justement ce qui protège du tir — c'est même
	# sa fonction première en bataille rangée.
	#
	# Une garde à l'ARME ne dévie rien : on ne pare pas une flèche à l'épée. Il
	# faut une plaque, donc un bouclier — ce qui donne enfin au bouclier un rôle
	# que la mêlée seule ne lui donnait pas.
	if victim != null and victim.has_method("blocks_projectiles") and victim.blocks_projectiles():
		if victim.has_method("wear_from_projectile"):
			victim.wear_from_projectile()
		return false

	var span := to - from
	var distance := span.length()
	if distance > 0.0001 and WorldManager.line_blocked(from, to):
		# Le décor arrête la flèche. On ne cherche pas le point exact : à cette
		# vitesse la frame entière fait moins d'un mètre, et une flèche plantée
		# à dix centimètres près ne se discute pas.
		if victim != null and best_t < 1.0:
			_note_impact(shot, victim, best_hit)
		return false
	if victim != null:
		_note_impact(shot, victim, best_hit)
		return false

	shot["position"] = to
	var node: Node3D = shot["node"]
	if node != null:
		node.global_position = to
		# La flèche pointe où elle va : c'est ce qui rend sa chute lisible.
		if velocity.length_squared() > 0.0001:
			node.look_at(to + velocity, Vector3.UP)
	return true


## CONSTATE un impact. Aucun dégât ici — le tick est la seule autorité, comme
## pour la mêlée.
func _note_impact(shot: Dictionary, victim: Node, hit: Dictionary) -> void:
	var stats: Dictionary = shot["stats"]
	# LA VITESSE À L'IMPACT DÉCIDE. Une flèche ralentit ; touchée à bout portant
	# elle porte toute son énergie, à quatre-vingts mètres elle est molle. C'est
	# le pendant du bonus de vitesse de la mêlée, et ce qui donne un sens à la
	# distance sans avoir à inventer une courbe de dégâts.
	var ratio := clampf((shot["velocity"] as Vector3).length()
		/ maxf(float(shot["initial_speed"]), 0.01), 0.0, 1.0)
	_pending.append({
		"victim": victim,
		"zone": hit["id"],
		"mult": float(hit["mult"]) * ratio,
		"point": hit["point"],
		"stats": stats,
		"hardness": shot["hardness"],
		"quality": shot["quality"],
		"shooter": shot["shooter"],
	})


## `tick_entities` transmet l'indice du tick : sans le paramètre, Godot refuse
## l'appel et le signal ne fait RIEN — les projectiles n'infligeaient donc aucun
## dégât, silencieusement. Trouvé à l'audit du 2026-08-02.
func _on_tick(_tick_index: int) -> void:
	if _pending.is_empty():
		return
	for impact: Dictionary in _pending:
		var victim: Node = impact["victim"]
		if not is_instance_valid(victim) or victim.is_dead():
			continue
		var shooter: Node = impact["shooter"]
		var stats: Dictionary = impact["stats"]
		# `is_ranged` : la DEXTÉRITÉ porte le tir là où la force porte la mêlée
		# (CombatResolver le prévoyait déjà, personne ne s'en servait).
		var result := CombatResolver.resolve_hit(
			int(shooter.effective_stat("dexterite")) if shooter != null else 5,
			int(shooter.effective_stat("force")) if shooter != null else 5,
			String(stats.get("dice", "1d6")),
			float(impact["hardness"]), float(impact["quality"]), true, "",
			float(impact["mult"]), float(stats.get("penetration", 0.0)))
		victim.take_damage(float(result["damage"]))
		EventBus.damage_dealt.emit(impact["point"], int(result["damage"]),
			bool(result["critical"]), false)
		victim.provoke()
		if shooter != null and shooter.has_method("note_ranged_hit"):
			shooter.note_ranged_hit(stats, float(result["damage"]), victim)
	_pending.clear()


## Flèche visible : une aiguille, pas un modèle. Elle passe trop vite pour qu'on
## en voie autre chose que la direction — et il en vole potentiellement plusieurs
## par seconde, donc elle doit être bon marché.
func _build_arrow() -> Node3D:
	var scene := get_tree().current_scene
	if scene == null:
		return null
	var arrow := MeshInstance3D.new()
	var shaft := BoxMesh.new()
	shaft.size = Vector3(0.03, 0.03, 0.7)
	arrow.mesh = shaft
	arrow.material_override = PlayerBody.tinted_material(Color(0.55, 0.42, 0.25))
	scene.add_child(arrow)
	return arrow


## Nombre de projectiles en vol — diagnostic et sondes.
func flying_count() -> int:
	return _flying.size()
