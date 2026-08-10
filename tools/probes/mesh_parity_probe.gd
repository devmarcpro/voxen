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
	var ctx_mismatches := 0
	for cx in range(-3, 4):
		for cz in range(-3, 4):
			var col := Vector2i(cx, cz)
			# PARITÉ DU CONTEXTE (colonnes natives, 2026-08-09) : les deux
			# chemins de prepare_context doivent rendre les MÊMES tableaux —
			# les hauteurs étant entières, la moindre dérive flottante du
			# terrain C++ se voit ici au bloc près.
			# LE CACHE D'ARBRES DOIT ÊTRE VIDÉ ENTRE LES DEUX PASSES : sans ça,
			# la passe native relirait les arbres GDScript mis en cache par la
			# passe de référence, et la comparaison validerait un miroir qui n'a
			# jamais tourné (2026-08-10, port de TreeGenerator).
			ChunkMesher.use_native = false
			gen._tree_cache_mutex.lock()
			gen._tree_cache.clear()
			gen._tree_cache_mutex.unlock()
			var ctx: Dictionary = gen.prepare_context(col)
			ChunkMesher.use_native = true
			gen._tree_cache_mutex.lock()
			gen._tree_cache.clear()
			gen._tree_cache_mutex.unlock()
			var ctx_nat: Dictionary = gen.prepare_context(col)
			if not _compare_ctx(col, ctx, ctx_nat):
				ctx_mismatches += 1
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
	_expect(ctx_mismatches == 0, "contextes de colonne identiques (49 colonnes)" if ctx_mismatches == 0 else "%d contexte(s) divergent(s)" % ctx_mismatches)
	finish(_ok, TAG)


func _compare_ctx(col: Vector2i, ref: Dictionary, nat: Dictionary) -> bool:
	for key in ["h", "surf", "sub", "trans", "acc", "local_water"]:
		var a: PackedInt32Array = ref[key]
		var b: PackedInt32Array = nat[key]
		if a != b:
			for i in a.size():
				if a[i] != b[i]:
					print("[%s] ctx %s : « %s »[%d] = %d (réf) contre %d (natif)" % [
							TAG, col, key, i, a[i], b[i]])
					break
			return false
	if int(ref["hmin"]) != int(nat["hmin"]) or int(ref["hmax"]) != int(nat["hmax"]):
		print("[%s] ctx %s : hmin/hmax divergents (%d/%d vs %d/%d)" % [TAG, col,
				int(ref["hmin"]), int(ref["hmax"]), int(nat["hmin"]), int(nat["hmax"])])
		return false
	# ARBRES : égalité PROFONDE des Variant (blocs, sous-grilles, ordre des
	# tableaux — l'ordre d'insertion fait partie du contrat, le mesher en
	# dépend pour l'ordre de ses sommets).
	var rt: Array = ref["trees"]
	var nt: Array = nat["trees"]
	if rt.size() != nt.size():
		print("[%s] ctx %s : %d arbre(s) (réf) contre %d (natif)" % [TAG, col, rt.size(), nt.size()])
		return false
	for t in rt.size():
		var a: Dictionary = rt[t]
		var b: Dictionary = nt[t]
		# `wood_positions` d'abord : il ne dépend QUE du squelette — s'il
		# diverge c'est le RNG/tracé, s'il tient c'est le feuillage.
		for key in ["base", "species_id", "wood_positions", "trunk_subdivs", "blocks", "wood_volume"]:
			if a[key] != b[key]:
				print("[%s] ctx %s : arbre %d (%s), champ « %s » divergent (base %s)" % [
						TAG, col, t, a["species_id"], key, a["base"]])
				_detail_diff(a[key], b[key], key)
				return false
	return true


## Premier écart en détail — sans lui on saurait QUE ça diverge, jamais OÙ.
func _detail_diff(a: Variant, b: Variant, key: String) -> void:
	if a is Dictionary and b is Dictionary:
		print("    tailles : %d (réf) contre %d (natif)" % [(a as Dictionary).size(), (b as Dictionary).size()])
		var shown := 0
		for k in (a as Dictionary):
			if not (b as Dictionary).has(k):
				print("    clé %s : présente en réf, absente en natif" % [k])
				shown += 1
			elif (a as Dictionary)[k] != (b as Dictionary)[k]:
				print("    clé %s : %s (réf) contre %s (natif)" % [k, (a as Dictionary)[k], (b as Dictionary)[k]])
				shown += 1
			if shown >= 4:
				return
		for k in (b as Dictionary):
			if not (a as Dictionary).has(k):
				print("    clé %s : absente en réf, présente en natif" % [k])
				shown += 1
			if shown >= 4:
				return
	elif a is Array and b is Array:
		print("    tailles : %d (réf) contre %d (natif)" % [(a as Array).size(), (b as Array).size()])
		for i in mini((a as Array).size(), (b as Array).size()):
			if (a as Array)[i] != (b as Array)[i]:
				print("    indice %d : %s (réf) contre %s (natif)" % [i, (a as Array)[i], (b as Array)[i]])
				return
	else:
		print("    %s (réf) contre %s (natif)" % [a, b])


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
