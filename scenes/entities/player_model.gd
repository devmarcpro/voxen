class_name PlayerModel
extends RefCounted
## Apparence 3D du joueur (2026-07-26) : humanoïde « blocky » simple (tête,
## torse, bras, jambes) en boîtes colorées (couleur de sommet). Sert de MARQUEUR
## sur la carte (rendu en icône) et de base pour le multi/3e personne + la
## personnalisation d'apparence future (section 12). 2 blocs de haut.

## Palette d'apparence par défaut (peau/cheveux/haut/bas) — la création de
## personnage pourra la surcharger plus tard.
const DEFAULT := {
	"peau": Color(0.85, 0.68, 0.52), "cheveux": Color(0.35, 0.22, 0.12),
	"haut": Color(0.30, 0.45, 0.75), "bas": Color(0.35, 0.28, 0.22),
}


static func build_mesh(colors: Dictionary = {}) -> ArrayMesh:
	var c := DEFAULT.duplicate()
	c.merge(colors, true)
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	# Jambes.
	_box(st, Vector3(-0.22, 0.0, -0.12), Vector3(-0.02, 0.85, 0.12), c["bas"])
	_box(st, Vector3(0.02, 0.0, -0.12), Vector3(0.22, 0.85, 0.12), c["bas"])
	# Torse.
	_box(st, Vector3(-0.26, 0.85, -0.14), Vector3(0.26, 1.5, 0.14), c["haut"])
	# Bras.
	_box(st, Vector3(-0.42, 0.85, -0.11), Vector3(-0.26, 1.48, 0.11), c["haut"])
	_box(st, Vector3(0.26, 0.85, -0.11), Vector3(0.42, 1.48, 0.11), c["haut"])
	# Tête + cheveux.
	_box(st, Vector3(-0.24, 1.5, -0.24), Vector3(0.24, 1.98, 0.24), c["peau"])
	_box(st, Vector3(-0.25, 1.88, -0.25), Vector3(0.25, 2.02, 0.25), c["cheveux"])
	return st.commit()


## Instance 3D prête (MeshInstance3D, non ombrée par lumière — couleur pleine).
static func build_instance(colors: Dictionary = {}) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.mesh = build_mesh(colors)
	var mat := StandardMaterial3D.new()
	mat.vertex_color_use_as_albedo = true
	mat.roughness = 1.0
	mi.material_override = mat
	return mi


static func _box(st: SurfaceTool, a: Vector3, b: Vector3, col: Color) -> void:
	var v := [
		Vector3(a.x, a.y, a.z), Vector3(b.x, a.y, a.z), Vector3(b.x, b.y, a.z), Vector3(a.x, b.y, a.z),
		Vector3(a.x, a.y, b.z), Vector3(b.x, a.y, b.z), Vector3(b.x, b.y, b.z), Vector3(a.x, b.y, b.z),
	]
	# 6 faces (indices sur les 8 coins), normales par face, couleur uniforme.
	var faces := [
		[0, 1, 2, 3, Vector3(0, 0, -1)], [5, 4, 7, 6, Vector3(0, 0, 1)],
		[4, 0, 3, 7, Vector3(-1, 0, 0)], [1, 5, 6, 2, Vector3(1, 0, 0)],
		[3, 2, 6, 7, Vector3(0, 1, 0)], [4, 5, 1, 0, Vector3(0, -1, 0)],
	]
	for f: Array in faces:
		var n: Vector3 = f[4]
		for tri: Array in [[f[0], f[1], f[2]], [f[0], f[2], f[3]]]:
			for i: int in tri:
				st.set_color(col)
				st.set_normal(n)
				st.add_vertex(v[i])
