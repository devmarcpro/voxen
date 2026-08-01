extends Node3D
## Chiffres de dégâts flottants (2026-07-28).
##
## POURQUOI. « On ne sait pas si on fait des dégâts » — et c'était exact : le
## seul retour existant était la barre de vie de la créature, minuscule et
## souvent hors champ pendant qu'on regarde sa lame. Un combat où l'on ne
## perçoit pas l'effet de son coup ne peut pas s'apprendre : le joueur ne peut
## corriger ni sa distance, ni sa visée, ni son timing.
##
## Le chiffre est affiché AU POINT D'IMPACT, pas au-dessus de la cible : c'est
## ce qui apprend le sweet spot et les zones de coup — on voit littéralement OÙ
## on a touché.

## Durée de vie et montée d'un chiffre.
const LIFETIME := 0.9
const RISE := 1.1
## Taille de base ; un critique et un coup glissant s'en écartent nettement.
const FONT_SIZE := 44

const COLOR_NORMAL := Color(1.0, 0.95, 0.85)
const COLOR_CRIT := Color(1.0, 0.75, 0.2)
const COLOR_GLANCE := Color(0.65, 0.7, 0.75)

var _active: Array[Dictionary] = []


func _ready() -> void:
	EventBus.damage_dealt.connect(_on_damage)


func _on_damage(world_position: Vector3, amount: int, critical: bool, glancing: bool) -> void:
	var label := Label3D.new()
	if glancing:
		# Un coup glissant DOIT se distinguer d'un coup faible : ce n'est pas
		# « peu de dégâts », c'est « mauvaise distance ». Le joueur ne peut
		# corriger que ce qu'il sait avoir raté.
		label.text = "TROP PRÈS"
		label.modulate = COLOR_GLANCE
		label.font_size = int(FONT_SIZE * 0.55)
	else:
		label.text = str(amount)
		label.modulate = COLOR_CRIT if critical else COLOR_NORMAL
		label.font_size = int(FONT_SIZE * (1.35 if critical else 1.0))
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	label.no_depth_test = false
	label.outline_size = 8
	label.outline_modulate = Color(0.0, 0.0, 0.0, 0.85)
	# Léger éparpillement : deux coups au même endroit doivent rester lisibles
	# au lieu de se superposer exactement.
	label.position = world_position + Vector3(
		randf_range(-0.12, 0.12), 0.0, randf_range(-0.12, 0.12))
	add_child(label)
	_active.append({"node": label, "age": 0.0, "origin": label.position})


func _process(delta: float) -> void:
	if _active.is_empty():
		return
	var survivors: Array[Dictionary] = []
	for entry: Dictionary in _active:
		var label: Label3D = entry["node"]
		if not is_instance_valid(label):
			continue
		entry["age"] = float(entry["age"]) + delta
		var t := float(entry["age"]) / LIFETIME
		if t >= 1.0:
			label.queue_free()
			continue
		# Montée qui RALENTIT : le chiffre s'élève vite puis se pose, ce qui
		# laisse le temps de le lire au moment où il est le plus lisible.
		label.position = (entry["origin"] as Vector3) + Vector3.UP * (RISE * sqrt(t))
		label.modulate.a = 1.0 - t * t
		survivors.append(entry)
	_active = survivors
