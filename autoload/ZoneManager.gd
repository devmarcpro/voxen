extends Node
## Zones d'effet persistantes (nappe de flammes, emprise du gel — GDD 5.1/F.4)
## — 2026-08-03.
##
## POURQUOI. Les modules marqués `zone` étaient les derniers du catalogue à ne
## rien produire : leur effet s'appliquait à l'instant du lancer et disparaissait
## aussitôt. Or une nappe de flammes qui ne dure pas n'est pas une nappe, c'est
## une explosion — et son paramètre `duree` ne voulait rien dire.
##
## MODÈLE. Une zone est un disque au sol, de rayon et de durée finis, qui pose un
## STATUT sur les créatures qui s'y trouvent et/ou leur inflige des dégâts
## périodiques. Elle ne réinvente ni l'un ni l'autre : les statuts viennent de
## `StatusTracker` (F.4), les dégâts passent par le chemin de dégâts normal de
## la créature.
##
## TOUT EST EN TICKS (E.1), jamais en secondes réelles, et la DIMENSION est
## mémorisée : un donjon partage les coordonnées de l'overworld, une zone posée
## dans une salle ne doit pas brûler le joueur revenu à la surface — c'est
## exactement le bug qu'avaient les caches au sol avant le 2026-08-02.

## Intervalle entre deux applications, en ticks. Même cadence que les statuts
## périodiques (StatusTracker.PERIODIC_INTERVAL) : une zone et une brûlure
## doivent battre au même rythme, sinon rester dans le feu fait plus mal que
## brûler pour une raison que rien n'explique.
const PULSE_INTERVAL := 10
## Garde-fou : au-delà, les plus anciennes sont retirées. Une zone est bon
## marché, mais rien n'empêche un joueur d'en poser en boucle.
const MAX_ZONES := 24

## Zones actives : [{ "position", "radius", "ticks", "pulse", "status",
##                    "status_ticks", "degats_des", "power", "dimension",
##                    "owner", "node" }]
var zones: Array[Dictionary] = []

var _root: Node3D


func _ready() -> void:
	TickManager.tick_world.connect(_on_tick)


## Pose une zone. `duration_ticks` et `status_ticks` en TICKS ; `radius` en blocs.
## `status_id` vide = zone purement offensive ; `degats_des` vide = zone
## purement d'entrave.
func spawn(position: Vector3, radius: float, duration_ticks: int,
		status_id: String = "", degats_des: String = "", power: float = 1.0,
		color: Color = Color(1.0, 0.5, 0.15, 0.35), owner: Node = null) -> void:
	if radius <= 0.0 or duration_ticks <= 0:
		return
	if zones.size() >= MAX_ZONES:
		_despawn(0)
	zones.append({
		"position": position,
		"radius": radius,
		"ticks": duration_ticks,
		"pulse": 0,
		"status": status_id,
		# La durée du statut posé est courte À DESSEIN : il doit s'éteindre peu
		# après qu'on soit sorti de la zone, sinon marcher une seconde dans le
		# feu vaudrait y rester. C'est la zone qui le RENOUVELLE tant qu'on y est.
		"status_ticks": PULSE_INTERVAL * 2,
		"degats_des": degats_des,
		"power": power,
		"dimension": WorldManager.active_dimension,
		"owner": owner,
		"node": _build_marker(position, radius, color),
	})


func _on_tick(_tick_index: int) -> void:
	if zones.is_empty():
		return
	for index in range(zones.size() - 1, -1, -1):
		var zone: Dictionary = zones[index]
		zone["ticks"] = int(zone["ticks"]) - 1
		if int(zone["ticks"]) <= 0:
			_despawn(index)
			continue
		zone["pulse"] = int(zone["pulse"]) + 1
		if int(zone["pulse"]) < PULSE_INTERVAL:
			continue
		zone["pulse"] = 0
		_pulse(zone)


## Applique la zone à ce qui s'y trouve.
func _pulse(zone: Dictionary) -> void:
	# Une zone d'une AUTRE dimension ne touche rien : le donjon partage les
	# coordonnées de l'overworld (voir l'en-tête).
	if StringName(zone["dimension"]) != WorldManager.active_dimension:
		return
	var centre: Vector3 = zone["position"]
	var radius := float(zone["radius"])
	var dice := String(zone["degats_des"])
	var status_id := String(zone["status"])
	for creature in CreatureManager.creatures:
		if not is_instance_valid(creature) or creature.is_dead():
			continue
		if creature.dimension != WorldManager.active_dimension:
			continue
		if creature.logical_position.distance_to(centre) > radius:
			continue
		if status_id != "" and creature.has_method("apply_status"):
			creature.apply_status(status_id, int(zone["status_ticks"]), float(zone["power"]))
		if dice == "":
			continue
		var damage := float(CombatResolver.roll_dice(dice)) * float(zone["power"])
		creature.take_damage(damage)
		creature.provoke()
		EventBus.damage_dealt.emit(creature.logical_position, int(damage), false, false)
		var owner_node: Node = zone["owner"]
		if creature.is_dead() and owner_node != null and owner_node.has_method("note_zone_kill"):
			owner_node.note_zone_kill(creature)


func _despawn(index: int) -> void:
	if index < 0 or index >= zones.size():
		return
	var node: Node3D = zones[index]["node"]
	if node != null and is_instance_valid(node):
		node.queue_free()
	zones.remove_at(index)


## Vide toutes les zones — bascule de dimension, hot-reload, nouveau monde.
func clear_all() -> void:
	for index in range(zones.size() - 1, -1, -1):
		_despawn(index)


## Disque translucide au sol. Volontairement plat et sans relief : une zone doit
## se lire d'un coup d'œil et ne jamais masquer ce qui se bat dedans.
func _build_marker(position: Vector3, radius: float, color: Color) -> Node3D:
	var scene := get_tree().current_scene
	if scene == null:
		return null
	if _root == null or not is_instance_valid(_root):
		_root = Node3D.new()
		_root.name = "ZoneMarkers"
		scene.add_child(_root)
	var marker := MeshInstance3D.new()
	var disc := CylinderMesh.new()
	disc.top_radius = radius
	disc.bottom_radius = radius
	disc.height = 0.12
	marker.mesh = disc
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	marker.material_override = mat
	marker.position = position + Vector3(0.0, 0.06, 0.0)
	_root.add_child(marker)
	return marker


## Nombre de zones actives — diagnostic et sondes.
func zone_count() -> int:
	return zones.size()
