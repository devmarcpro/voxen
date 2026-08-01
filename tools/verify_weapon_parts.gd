extends SceneTree
## Vérifie que les MODÈLES de pièces d'arme correspondent aux DONNÉES.
##   godot --headless --path . --script tools/verify_weapon_parts.gd
##
## POURQUOI CE GARDE-FOU EXISTE. `longueur` (manche) et `portee_tete` (tête)
## sont à la fois de la GÉOMÉTRIE et du GAMEPLAY : elles décident où la tête se
## greffe, quelle allonge a l'arme, et donc jusqu'où la lame touche. Un manche
## rallongé dans Blockbench sans mise à jour du JSON produirait une arme
## visuellement plus longue que sa portée réelle — elle « toucherait dans le
## vide » sur ses derniers centimètres. C'est exactement le mensonge visuel que
## tout le système de combat s'interdit, et il est indétectable à l'œil.
##
## N'utilise aucun autoload : il tourne même si le jeu ne démarre pas.

## Tolérance, en blocs. Un demi-pixel de la grille 32 px.
const TOLERANCE := 0.016


func _init() -> void:
	var raw: Variant = JSON.parse_string(
		FileAccess.get_file_as_string("res://data/weapon_parts.json"))
	if not (raw is Dictionary):
		print("weapon_parts.json illisible")
		quit(1)
		return
	var data: Dictionary = raw
	var problems := 0
	problems += _check_table(data.get("manches", {}), "longueur", "manche")
	problems += _check_table(data.get("tetes", {}), "portee_tete", "tête")
	print("")
	if problems == 0:
		print("=== COHÉRENT : chaque modèle correspond à sa donnée. ===")
	else:
		print("=== %d ÉCART(S) — voir ci-dessus. ===" % problems)
		print("Corriger soit la table HANDLES/HEADS de tools/generate_weapon_parts.py")
		print("(puis relancer le générateur), soit la valeur dans data/weapon_parts.json.")
	quit(0 if problems == 0 else 1)


## Compare la hauteur RÉELLE de chaque modèle à la valeur déclarée.
func _check_table(table: Dictionary, field: String, label: String) -> int:
	print("=== %sS ===" % label.to_upper())
	var problems := 0
	for part_id: String in table:
		var part: Dictionary = table[part_id]
		var path := String(part.get("model", ""))
		if not ResourceLoader.exists(path):
			print("  %-16s MODÈLE ABSENT (%s)" % [part_id, path])
			problems += 1
			continue
		var scene: PackedScene = load(path)
		var root := scene.instantiate()
		var measured := _height_of(root)
		root.free()
		var declared := float(part.get(field, -1.0))
		var gap := absf(measured - declared)
		var status := "ok" if gap <= TOLERANCE else "ÉCART"
		if gap > TOLERANCE:
			problems += 1
		print("  %-16s modèle %.4f · %s %.4f · écart %.4f  %s" % [
			part_id, measured, field, declared, gap, status])
	return problems


## Hauteur du modèle : sommet le plus haut de ses maillages. C'est bien le
## SOMMET et non l'étendue totale — une tête peut déborder sous y = 0 (crochet,
## contre-poids) sans que cela change ce qu'elle ajoute à l'allonge.
func _height_of(node: Node) -> float:
	var top := 0.0
	for mesh: MeshInstance3D in _meshes(node):
		var box: AABB = mesh.get_aabb()
		top = maxf(top, box.position.y + box.size.y)
	return top


func _meshes(node: Node) -> Array[MeshInstance3D]:
	var out: Array[MeshInstance3D] = []
	if node is MeshInstance3D:
		out.append(node)
	for child in node.get_children():
		out.append_array(_meshes(child))
	return out
