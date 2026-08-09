extends Probe
## Sonde `--probe-mesh-parite` (2026-08-09) — PARITÉ GDScript ↔ natif.
##
## Le cœur du mesher existe en deux exemplaires (chunk_mesher.gd, référence, et
## native/src/voxen_mesher.cpp, port C++). Cette sonde maille les MÊMES chunks
## réels par les deux chemins et compare les tableaux de surface élément par
## élément. C'est elle qui autorise à faire confiance au chemin natif — sans
## elle, une divergence se verrait en couture ou en face manquante quelque part
## dans le monde, des heures plus tard.
##
## Tolérance : ZÉRO sur les tailles, l'ordre et les indices ; un epsilon d'ulp
## sur les flottants (le GDScript calcule certains produits en float64 avant de
## ranger en float32, le C++ reste en float32 — dernier bit près).

const TAG := "MESHPARITE"
const EPS := 0.0001

var _ok := true


func _expect(condition: bool, message: String) -> void:
	print("[%s] %s — %s" % [TAG, "ok" if condition else "ÉCHEC", message])
	if not condition:
		_ok = false


func run() -> void:
	await wait_frame()
	var gen := WorldManager.generator
	if gen == null:
		print("[%s] aucun générateur." % TAG)
		main.get_tree().quit(1)
		return
	if ChunkMesher._native == null:
		print("[%s] RÉSULTAT : ÉCHEC — extension voxen_native absente (DLL non bâtie ?)." % TAG)
		main.get_tree().quit(1)
		return

	var chunks := 0
	var compared := 0
	var mismatches := 0
	for cx in range(-3, 4):
		for cz in range(-3, 4):
			var col := Vector2i(cx, cz)
			var ctx: Dictionary = gen.prepare_context(col)
			for cy in range(-2, 4):
				var ck := Vector3i(cx, cy, cz)
				var data: ChunkData = WorldManager._get_chunk_sync(ck)
				if data == null:
					continue
				chunks += 1
				ChunkMesher.use_native = false
				var ref: Array = ChunkMesher.mesh_chunk(ck, data, gen, ctx)
				ChunkMesher.use_native = true
				var nat: Array = ChunkMesher.mesh_chunk(ck, data, gen, ctx)
				if not _compare(ck, ref, nat):
					mismatches += 1
				else:
					compared += 1
	ChunkMesher.use_native = true

	_expect(chunks > 50, "assez de chunks pour conclure (%d maillés)" % chunks)
	_expect(mismatches == 0, "aucune divergence GDScript↔natif (%d/%d chunks identiques)" % [compared, chunks])
	finish(_ok, TAG)


func _compare(ck: Vector3i, ref: Array, nat: Array) -> bool:
	if ref.is_empty() != nat.is_empty():
		print("[%s] %s : un chemin rend un mesh, l'autre rien (réf vide=%s, natif vide=%s)" % [
				TAG, ck, ref.is_empty(), nat.is_empty()])
		return false
	if ref.is_empty():
		return true
	var rv: PackedVector3Array = ref[Mesh.ARRAY_VERTEX]
	var nv: PackedVector3Array = nat[Mesh.ARRAY_VERTEX]
	if rv.size() != nv.size():
		print("[%s] %s : %d sommets (réf) contre %d (natif)" % [TAG, ck, rv.size(), nv.size()])
		return false
	var ri: PackedInt32Array = ref[Mesh.ARRAY_INDEX]
	var ni: PackedInt32Array = nat[Mesh.ARRAY_INDEX]
	if ri != ni:
		print("[%s] %s : indices divergents (%d vs %d)" % [TAG, ck, ri.size(), ni.size()])
		return false
	for i in rv.size():
		if (rv[i] - nv[i]).length() > EPS:
			print("[%s] %s : sommet %d diverge %s vs %s" % [TAG, ck, i, rv[i], nv[i]])
			return false
	var ru: PackedVector2Array = ref[Mesh.ARRAY_TEX_UV]
	var nu: PackedVector2Array = nat[Mesh.ARRAY_TEX_UV]
	if ru != nu:
		print("[%s] %s : UV divergents" % [TAG, ck])
		return false
	var rn: PackedVector3Array = ref[Mesh.ARRAY_NORMAL]
	var nn: PackedVector3Array = nat[Mesh.ARRAY_NORMAL]
	if rn != nn:
		print("[%s] %s : normales divergentes" % [TAG, ck])
		return false
	var rc: PackedColorArray = ref[Mesh.ARRAY_COLOR]
	var nc: PackedColorArray = nat[Mesh.ARRAY_COLOR]
	for i in rc.size():
		var d := rc[i] - nc[i]
		if absf(d.r) > EPS or absf(d.g) > EPS or absf(d.b) > EPS or absf(d.a) > EPS:
			print("[%s] %s : couleur %d diverge %s vs %s" % [TAG, ck, i, rc[i], nc[i]])
			return false
	return true
