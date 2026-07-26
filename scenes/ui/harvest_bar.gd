extends ProgressBar
## Barre de progression de récolte, sous le réticule — visible uniquement
## pendant le minage (la valeur vient du joueur ; purement visuel → frame).


var _player: Node


func _ready() -> void:
	_player = get_node_or_null("../../Player")
	min_value = 0.0
	max_value = 1.0
	show_percentage = false
	visible = false


func _process(_delta: float) -> void:
	if _player == null:
		return
	var progress: float = _player.harvest_progress()
	visible = progress > 0.0
	value = progress
