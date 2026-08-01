extends SceneTree
## Diagnostic d'orientation du gabarit humanoïde.
##   godot --headless --path . --script tools/diag_model.gd
## Répond à trois questions que le rendu seul ne permet pas de départager :
## la tête est-elle EN HAUT ? le maillage est-il à l'endroit une fois posé
## dans la scène ? les faces sont-elles tournées vers l'EXTÉRIEUR ?


func _init() -> void:
	var scene: PackedScene = load("res://models/creatures/humanoide.glb")
	var root := scene.instantiate()
	get_root().add_child(root)

	var skeleton := _find_skeleton(root)
	print("=== OS (repos, espace squelette) ===")
	for bone_name in ["racine", "bassin", "colonne_2", "tete", "main_droite", "pied_droite"]:
		var index := skeleton.find_bone(bone_name)
		if index < 0:
			print("  %-14s ABSENT" % bone_name)
			continue
		var origin := skeleton.get_bone_global_rest(index).origin
		print("  %-14s y=%+.3f  (x=%+.3f z=%+.3f)" % [bone_name, origin.y, origin.x, origin.z])
	var head := skeleton.get_bone_global_rest(skeleton.find_bone("tete")).origin.y
	var foot := skeleton.get_bone_global_rest(skeleton.find_bone("pied_droite")).origin.y
	print("  --> tete au-dessus du pied : %s" % (head > foot))

	print("=== MAILLAGES (AABB en espace du modèle) ===")
	var lowest := 1e9
	var highest := -1e9
	for mesh in _meshes(root):
		var box: AABB = mesh.get_aabb()
		lowest = minf(lowest, box.position.y)
		highest = maxf(highest, box.position.y + box.size.y)
	print("  étendue verticale : %.3f -> %.3f" % [lowest, highest])
	print("  --> pieds au sol (bas ≈ 0) : %s" % (absf(lowest) < 0.05))

	print("=== SENS DES FACES (winding vs normale déclarée) ===")
	# Une face est correcte si la normale calculée depuis l'ordre des sommets
	# pointe DANS LE MÊME SENS que la normale stockée. Sinon les faces sont
	# retournées : avec l'élimination des faces arrière, on voit l'INTÉRIEUR
	# du modèle — ce qui donne exactement l'impression d'un corps « à l'envers ».
	var checked := 0
	var agreeing := 0
	for mesh in _meshes(root):
		var array_mesh := mesh.mesh as ArrayMesh
		if array_mesh == null:
			continue
		var arrays := array_mesh.surface_get_arrays(0)
		var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
		var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
		for t in range(0, indices.size(), 3):
			var a := vertices[indices[t]]
			var b := vertices[indices[t + 1]]
			var c := vertices[indices[t + 2]]
			var geometric := (b - a).cross(c - a)
			if geometric.length_squared() < 1e-12:
				continue
			checked += 1
			if geometric.normalized().dot(normals[indices[t]]) > 0.0:
				agreeing += 1
	print("  triangles cohérents : %d / %d" % [agreeing, checked])
	print("  --> faces vers l'extérieur : %s" % (agreeing == checked))
	quit(0)


func _find_skeleton(node: Node) -> Skeleton3D:
	if node is Skeleton3D:
		return node
	for child in node.get_children():
		var found := _find_skeleton(child)
		if found != null:
			return found
	return null


func _meshes(node: Node) -> Array[MeshInstance3D]:
	var out: Array[MeshInstance3D] = []
	if node is MeshInstance3D:
		out.append(node)
	for child in node.get_children():
		out.append_array(_meshes(child))
	return out
