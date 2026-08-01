extends SceneTree
## Verifie que les pieces d'arme generees s'instancient avec de la geometrie.
##   godot --headless --path . --script tools/diag_weapon_parts.gd


func _init() -> void:
	var paths := [
		"res://models/weapons/manche_moyen.glb",
		"res://models/weapons/tete_lame_moyenne.glb",
		"res://models/weapons/manche_tres_long.glb",
		"res://models/weapons/tete_hache.glb",
	]
	for path: String in paths:
		if not ResourceLoader.exists(path):
			print("%-44s ABSENT DU CACHE D'IMPORT" % path)
			continue
		var scene: PackedScene = load(path)
		if scene == null:
			print("%-44s ILLISIBLE" % path)
			continue
		var root := scene.instantiate()
		var meshes: Array[MeshInstance3D] = []
		_collect(root, meshes)
		var info := "racine=%s, %d maillage(s)" % [root.get_class(), meshes.size()]
		for m in meshes:
			var box: AABB = m.get_aabb()
			info += " | %s aabb=%.2f..%.2f (y)" % [m.name, box.position.y, box.position.y + box.size.y]
			info += " surfaces=%d" % (m.mesh.get_surface_count() if m.mesh != null else -1)
		print("%-44s %s" % [path.get_file(), info])
		root.free()
	quit(0)


func _collect(node: Node, out: Array[MeshInstance3D]) -> void:
	if node is MeshInstance3D:
		out.append(node)
	for child in node.get_children():
		_collect(child, out)
