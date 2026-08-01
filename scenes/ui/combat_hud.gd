extends Control
## Indicateur de combat DIRECTIONNEL (2026-07-28).
##
## POURQUOI IL EXISTE. Le combat était mécaniquement complet mais illisible :
## « on n'arrive pas vraiment à voir comment on fait notre attaque, où elle va,
## et on ne sait pas si on fait des dégâts » (retour utilisateur). Un combat
## directionnel dont on ne peut pas LIRE la direction n'est pas un combat
## directionnel — c'est un clic dans le noir.
##
## Quatre chevrons autour du réticule, un par direction :
##   ROUGE qui se remplit  = l'attaque s'arme, et de quel côté ;
##   BLANC vif             = la lame part MAINTENANT ;
##   BLEU                  = la garde, et de quel côté elle couvre.
## Un arc de progression cercle le réticule pendant l'armement : c'est la
## lecture du wind-up, celle-là même que l'adversaire est censé avoir.

## Distance des chevrons au centre du réticule, en pixels.
const RADIUS := 46.0
const CHEVRON := 13.0
const THICKNESS := 3.0

const COLOR_IDLE := Color(1.0, 1.0, 1.0, 0.18)
const COLOR_WINDUP := Color(1.0, 0.55, 0.2, 0.95)
const COLOR_ARMED := Color(1.0, 0.30, 0.2, 1.0)
const COLOR_RELEASE := Color(1.0, 1.0, 1.0, 1.0)
const COLOR_GUARD := Color(0.35, 0.7, 1.0, 0.95)

var _player: Node
## Décalage angulaire des quatre directions, dans l'ordre de MeleeAttack.Direction
## (ESTOC, TAILLE_GAUCHE, TAILLE_DROITE, OVERHEAD). L'estoc pointe vers le BAS :
## c'est le geste « vers soi puis en avant », et cela laisse le haut à l'overhead.
const ANGLES := [PI * 0.5, PI, 0.0, -PI * 0.5]


func setup(player: Node) -> void:
	_player = player
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)


func _process(_delta: float) -> void:
	if _player != null:
		queue_redraw()


func _draw() -> void:
	if _player == null or not _player.has_method("combat_hud_state"):
		return
	var state: Dictionary = _player.combat_hud_state()
	var center := size * 0.5

	var phase: int = int(state["phase"])
	var attacking := phase != MeleeAttack.State.IDLE
	var attack_dir: int = int(state["attack_direction"])
	var guarding: bool = bool(state["guarding"])
	var guard_dir: int = int(state["guard_direction"])

	for direction in 4:
		var color := COLOR_IDLE
		if attacking and direction == attack_dir:
			match phase:
				MeleeAttack.State.LECTURE, MeleeAttack.State.WINDUP:
					color = COLOR_WINDUP
				MeleeAttack.State.ARMEE:
					color = COLOR_ARMED
				MeleeAttack.State.RELEASE:
					color = COLOR_RELEASE
				_:
					color = COLOR_IDLE
		elif guarding and direction == guard_dir:
			color = COLOR_GUARD
		_draw_chevron(center, float(ANGLES[direction]), color)

	# Arc de progression du WIND-UP : la jauge que l'adversaire lit aussi.
	if phase == MeleeAttack.State.WINDUP:
		draw_arc(center, RADIUS + 10.0, -PI * 0.5,
			-PI * 0.5 + TAU * float(state["phase_ratio"]), 32, COLOR_WINDUP, 2.5, true)
	elif phase == MeleeAttack.State.ARMEE:
		# Cercle plein : l'arme est ARMÉE et attend. C'est une menace, elle doit
		# se voir en permanence, pas clignoter.
		draw_arc(center, RADIUS + 10.0, 0.0, TAU, 40, COLOR_ARMED, 2.5, true)


## Un chevron « > » orienté vers l'extérieur, à l'angle donné.
func _draw_chevron(center: Vector2, angle: float, color: Color) -> void:
	var outward := Vector2(cos(angle), sin(angle))
	var side := Vector2(-outward.y, outward.x)
	var tip := center + outward * (RADIUS + CHEVRON * 0.5)
	var a := center + outward * (RADIUS - CHEVRON * 0.5) + side * CHEVRON * 0.7
	var b := center + outward * (RADIUS - CHEVRON * 0.5) - side * CHEVRON * 0.7
	draw_line(a, tip, color, THICKNESS, true)
	draw_line(b, tip, color, THICKNESS, true)
