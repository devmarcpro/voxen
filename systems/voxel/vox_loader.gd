class_name VoxLoader
extends RefCounted
## Lecture DIRECTE du format MagicaVoxel .vox (9.1/D.2) : préserve l'index de
## couleur par voxel (jamais d'export intermédiaire qui fige le RGB), détecte
## les couleurs réservées (data/reserved_colors.json) :
## - stand-in matériaux (#00FF00 bois...) → remappées au craft (9.1) ;
## - marqueurs d'attache (12.1) → retirés du mesh, exportés en points typés.
## NOTE : parseur runtime plutôt qu'EditorImportPlugin (D.2) — même résultat
## (positions + index), utilisable headless ; le plugin d'éditeur pourra
## l'envelopper plus tard pour la prévisualisation.

const VOXEL_SIZE := 1.0 / 32.0  # 1 voxel de modèle = 1 pixel de bloc (32/face).

## Cache des modèles chargés (les meshes sont partagés, G.5).
static var _cache := {}


## Charge un .vox. Retourne {} en cas d'échec, sinon :
## { "size": Vector3i, "voxels": [[x,y,z,index], ...], "palette": PackedColorArray(257),
##   "attachments": [{ "type": String, "position": Vector3i }],
##   "stand_ins": { index -> hex couleur } } — la CATÉGORIE de matériau que
## représente chaque hex est propre à l'objet (`vox_slots` de B.3), pas une
## propriété globale des couleurs réservées (qui ne sont que des SLOTS
## génériques 1-4, 12.1/9.1).
static func load_model(raw_path: String) -> Dictionary:
	# Les chemins de données (B.3) sont relatifs à la racine du projet.
	var path := raw_path if raw_path.begins_with("res://") or raw_path.contains(":/") else "res://" + raw_path
	if _cache.has(path):
		return _cache[path]
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		push_error("VoxLoader : fichier introuvable « %s »." % path)
		return {}
	if f.get_buffer(4).get_string_from_ascii() != "VOX ":
		push_error("VoxLoader : « %s » n'est pas un fichier VOX." % path)
		return {}
	f.get_32()  # version

	var size := Vector3i.ZERO
	var raw_voxels: Array = []
	var palette := PackedColorArray()
	palette.resize(257)  # L'index VOX est 1-based ; [0] inutilisé.
	# Palette par défaut MagicaVoxel : gris (suffisant tant que RGBA est écrit).
	for i in 257:
		palette[i] = Color(0.5, 0.5, 0.5)

	# Parcours des chunks (MAIN > SIZE/XYZI/RGBA ; les chunks inconnus sont
	# sautés — seuls le premier modèle et la palette nous intéressent).
	while f.get_position() < f.get_length():
		var chunk_id := f.get_buffer(4).get_string_from_ascii()
		var content_size := f.get_32()
		f.get_32()  # children size
		match chunk_id:
			"MAIN":
				pass  # Contenu vide, les enfants suivent.
			"SIZE":
				if size == Vector3i.ZERO:
					size = Vector3i(f.get_32(), f.get_32(), f.get_32())
				else:
					f.seek(f.get_position() + content_size)
			"XYZI":
				if raw_voxels.is_empty():
					var count := f.get_32()
					for i in count:
						var b := f.get_buffer(4)
						raw_voxels.append([b[0], b[1], b[2], b[3]])
				else:
					f.seek(f.get_position() + content_size)
			"RGBA":
				for i in 256:
					var b := f.get_buffer(4)
					palette[i + 1] = Color8(b[0], b[1], b[2], b[3])
			_:
				f.seek(f.get_position() + content_size)
	f.close()

	# Couleurs réservées : stand-in matériaux et marqueurs d'attache (12.1).
	var stand_ins := {}
	var markers := {}
	var reserved: Dictionary = GameData.reserved_colors
	for index in range(1, 257):
		var hex := "#" + palette[index].to_html(false).to_upper()
		if (reserved.get("stand_in_materiaux", {}) as Dictionary).has(hex):
			stand_ins[index] = hex
		var marker: Variant = (reserved.get("marqueurs_attache", {}) as Dictionary).get(hex)
		if marker != null:
			markers[index] = String(marker)

	# Les voxels-marqueurs sortent du mesh visible → points d'attache typés.
	var voxels: Array = []
	var attachments: Array = []
	for v: Array in raw_voxels:
		if markers.has(v[3]):
			attachments.append({"type": markers[v[3]], "position": Vector3i(v[0], v[1], v[2])})
		else:
			voxels.append(v)

	var model := {
		"size": size, "voxels": voxels, "palette": palette,
		"attachments": attachments, "stand_ins": stand_ins,
	}
	_cache[path] = model
	return model


## Construit un ArrayMesh depuis un modèle chargé : faces visibles seulement,
## index de palette dans UV.x (remap en shader, 9.1), centré-X/Y et posé sur
## z=0, axes VOX (x, y, z) → Godot (x, z, y). Mesh partagé via le cache G.5.
static func build_mesh(model: Dictionary) -> ArrayMesh:
	var occupancy := {}
	for v: Array in model["voxels"]:
		occupancy[Vector3i(v[0], v[1], v[2])] = true
	var size: Vector3i = model["size"]
	var center := Vector3(size.x * 0.5, size.y * 0.5, 0.0)

	var vertices := PackedVector3Array()
	var normals := PackedVector3Array()
	var uvs := PackedVector2Array()
	var indices := PackedInt32Array()
	const DIRS: Array[Vector3i] = [
		Vector3i(1, 0, 0), Vector3i(-1, 0, 0), Vector3i(0, 1, 0),
		Vector3i(0, -1, 0), Vector3i(0, 0, 1), Vector3i(0, 0, -1),
	]
	for v: Array in model["voxels"]:
		var pos := Vector3i(v[0], v[1], v[2])
		var index: int = v[3]
		for dir in DIRS:
			if occupancy.has(pos + dir):
				continue
			# Quad de la face : base = coin du voxel, du/dv dans le plan.
			var normal := Vector3(dir)
			var axis := 0
			if dir.y != 0:
				axis = 1
			elif dir.z != 0:
				axis = 2
			var u_axis := (axis + 1) % 3
			var v_axis := (axis + 2) % 3
			var origin := Vector3(pos)
			if dir[axis] > 0:
				origin[axis] += 1.0
			var du := Vector3.ZERO
			du[u_axis] = 1.0
			var dv := Vector3.ZERO
			dv[v_axis] = 1.0
			if du.cross(dv).dot(normal) > 0.0:
				var tmp := du
				du = dv
				dv = tmp
			var start := vertices.size()
			for corner: Vector3 in [origin, origin + du, origin + du + dv, origin + dv]:
				# Axes VOX → Godot : (x, y, z) modèle = (x, -y, z) sol vers +Y.
				var p := (corner - center) * VOXEL_SIZE
				vertices.append(Vector3(p.x, p.z, -p.y))
				normals.append(Vector3(normal.x, normal.z, -normal.y))
				uvs.append(Vector2(float(index), 0.0))
			indices.append(start)
			indices.append(start + 1)
			indices.append(start + 2)
			indices.append(start)
			indices.append(start + 2)
			indices.append(start + 3)

	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_INDEX] = indices
	var mesh := ArrayMesh.new()
	if not vertices.is_empty():
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh