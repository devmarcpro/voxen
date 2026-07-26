class_name ChunkMesher
extends RefCounted
## Greedy meshing d'un chunk (G.2) : uniquement les faces visibles, quads
## fusionnés par matériau. Exécuté HORS thread principal (G.1).
## Optimisé GDScript typé : le chunk + une coquille de 1 bloc de voisinage
## sont copiés dans un tableau aplati 18³ (indices entiers, aucun Vector3i ni
## appel de fonction dans les boucles chaudes), avec rejets rapides :
## - chunk uniforme solide entouré de solide → aucune face, sortie immédiate ;
## - frontières/colonnes dont le niveau Y ne contient aucun bloc → sautées.
## Tableaux de sortie pré-alloués + curseurs — jamais d'append par sommet.
## L'id matériau est encodé dans UV.x ; le bruit par voxel est généré en
## shader depuis (position monde, id matériau, graine) — G.2.

const WATER_DROP := 0.14     # Abaissement de la surface des liquides (2026-07-24).
const T := 16                # Taille de chunk (ChunkData.SIZE).
const P := 18                # Taille du tableau padded (T + 2).
# Strides du tableau padded : indice = (x+1) + (z+1)*18 + (y+1)*324.
const SX := 1
const SY := 324
const SZ := 18


## Maille un chunk. Retourne les arrays de surface (Mesh.ARRAY_MAX) ou un
## tableau vide si aucune face n'est visible. Sommets en coordonnées locales
## au chunk (le MeshInstance3D est positionné à cpos*16).
## `ctx` : contexte de colonne préparé par le générateur (G.4).
## `generator` : NoiseGenerator de l'overworld, ou NULL pour une dimension
## VIDE (donjon, 3.5/2026-07-21) — la coquille est alors de l'air pur et
## seuls les `neighbor_edits` la peuplent (dans une dimension donjon, tous
## les blocs voisins sont fournis ainsi).
## `neighbor_edits` : modifications de blocs des chunks voisins (clé chunk →
## {indice → id}) à surimposer à la coquille générée — sans elles, un bloc
## posé/cassé en bordure par le joueur créerait des coutures.
## `fine` : true = les blocs subdivisés sont meshés par leurs sous-grilles
## (passe fine) ; false = variante LOD où ils sont rendus comme blocs pleins
## de leur id dominant (G.2 : la subdivision n'est jamais meshée au loin).
static func mesh_chunk(cpos: Vector3i, data: ChunkData, generator: NoiseGenerator, ctx: Dictionary, neighbor_edits: Dictionary = {}, fine: bool = true) -> Array:
	var uniform := data.is_uniform()
	if uniform and data.uniform_id == 0:
		return []

	# --- 1. Copie padded : coquille de voisinage D'ABORD ---
	# (permet de rejeter un chunk uniforme enterré sans remplir l'intérieur)
	var pad := PackedInt32Array()
	pad.resize(P * P * P)
	var shell_air := true  # Dimension vide : la coquille (pad zéroé) est d'air.
	if generator != null:
		shell_air = generator.fill_shell(cpos, pad, ctx)
	if not neighbor_edits.is_empty():
		# Les modifications voisines peuvent creuser de l'air dans la
		# coquille : le OU est conservateur (jamais de face manquée).
		shell_air = _apply_shell_edits(pad, cpos, neighbor_edits) or shell_air

	# Rejet rapide : chunk uniforme solide entièrement enterré → aucune face,
	# l'intérieur n'est même pas copié (cas majoritaire du sous-sol).
	if uniform and not shell_air:
		return []

	# Intérieur + nombre de blocs solides par niveau Y (pour les sauts rapides).
	var level_solid := PackedInt32Array()
	level_solid.resize(T)
	if uniform:
		var id_u := data.uniform_id
		for y in T:
			var off_y := (y + 1) * SY
			for z in T:
				var off := off_y + (z + 1) * SZ + 1
				for x in T:
					pad[off + x] = id_u
			level_solid[y] = T * T
	else:
		var blocks := data.blocks
		# En passe FINE, les blocs subdivisés comptent comme de l'air au
		# niveau bloc (leurs sous-grilles sont meshées en passe 3) ; en passe
		# LOD (coarse), leur id dominant — déjà dans `blocks` — fait foi.
		var exclude_subdivs := fine and not data.subdivs.is_empty()
		var src := 0
		for y in T:
			var off_y := (y + 1) * SY
			var count := 0
			for z in T:
				var off := off_y + (z + 1) * SZ + 1
				for x in T:
					var id := blocks.decode_u16(src << 1)
					if id != 0 and not (exclude_subdivs and data.subdivs.has(src)):
						pad[off + x] = id
						count += 1
					src += 1
			level_solid[y] = count

	# --- 2. Balayage greedy par axe ---
	# Tableaux pré-alloués + curseurs (vc/ic) — jamais d'append par sommet.
	var vertices := PackedVector3Array()
	var normals := PackedVector3Array()
	var uvs := PackedVector2Array()
	var indices := PackedInt32Array()
	vertices.resize(1024)
	normals.resize(1024)
	uvs.resize(1024)
	indices.resize(1536)
	var vc := 0
	var ic := 0
	var mask := PackedInt32Array()
	mask.resize(T * T)
	var strides := [SX, SY, SZ]

	for d in 3:
		var u := (d + 1) % 3
		var v := (d + 2) % 3
		var sd: int = strides[d]
		var su: int = strides[u]
		var sv: int = strides[v]

		# `cut` est la frontière entre les cellules locales cut et cut+1.
		for cut in range(-1, T):
			# Saut rapide sur l'axe Y : une face ne peut être portée que par
			# un bloc intérieur des niveaux cut ou cut+1.
			if d == 1:
				var solid_below := cut >= 0 and level_solid[cut] > 0
				var solid_above := cut + 1 <= T - 1 and level_solid[cut + 1] > 0
				if not solid_below and not solid_above:
					continue

			# Remplissage du masque des faces visibles sur cette frontière.
			var base_d := (cut + 1) * sd
			var visible := false
			var n := 0
			for j in T:
				# Axe Z : les deux cellules comparées sont au niveau Y = j.
				if d == 2 and level_solid[j] == 0 and cut >= 0 and cut + 1 <= T - 1:
					for i in T:
						mask[n] = 0
						n += 1
					continue
				var base_j := base_d + (j + 1) * sv + su
				for i in T:
					# Axe X : les deux cellules comparées sont au niveau Y = i.
					if d == 0 and level_solid[i] == 0 and cut >= 0 and cut + 1 <= T - 1:
						mask[n] = 0
						n += 1
						continue
					var idx := base_j + i * su
					var a := pad[idx]
					var b := pad[idx + sd]
					var value := 0
					# Une face n'est émise que si son bloc propriétaire est
					# DANS ce chunk (sinon le chunk voisin l'émettra).
					if a != 0 and b == 0 and cut >= 0:
						value = a          # face orientée +d, portée par a
					elif b != 0 and a == 0 and cut + 1 <= T - 1:
						value = -b         # face orientée -d, portée par b
					mask[n] = value
					if value != 0:
						visible = true
					n += 1
			if not visible:
				continue

			# Fusion gloutonne des rectangles de même valeur.
			for j in T:
				var i := 0
				while i < T:
					var c := mask[j * T + i]
					if c == 0:
						i += 1
						continue
					var w := 1
					while i + w < T and mask[j * T + i + w] == c:
						w += 1
					var h := 1
					var extendable := true
					while j + h < T and extendable:
						for k in w:
							if mask[(j + h) * T + i + k] != c:
								extendable = false
								break
						if extendable:
							h += 1
					# Émission du quad fusionné, inline avec curseur (les
					# gros chunks émettent des dizaines de milliers de
					# sommets : append par sommet = coût dominant mesuré).
					if vc + 4 > vertices.size():
						var new_size := maxi(vertices.size() * 2, 1024)
						vertices.resize(new_size)
						normals.resize(new_size)
						uvs.resize(new_size)
					if ic + 6 > indices.size():
						indices.resize(maxi(indices.size() * 2, 1536))
					var normal := Vector3.ZERO
					normal[d] = 1.0 if c > 0 else -1.0
					var origin := Vector3.ZERO
					origin[d] = float(cut + 1)
					origin[u] = float(i)
					origin[v] = float(j)
					var du := Vector3.ZERO
					du[u] = float(w)
					var dv := Vector3.ZERO
					dv[v] = float(h)
					# Enroulement horaire vu de face (convention Godot) :
					# cross(du, dv) doit pointer à l'OPPOSÉ de la normale.
					if du.cross(dv).dot(normal) > 0.0:
						var tmp := du
						du = dv
						dv = tmp
					vertices[vc] = origin
					vertices[vc + 1] = origin + du
					vertices[vc + 2] = origin + du + dv
					vertices[vc + 3] = origin + dv
					# Liquides « moins grands » (2026-07-24) : abaisse l'arête supérieure
					# (surface) — face du dessus entière, arête haute des faces latérales.
					if GameData.liquid_mask[absi(c)] == 1 and not (d == 1 and c < 0):
						var top_y := vertices[vc].y
						for k in 4:
							top_y = maxf(top_y, vertices[vc + k].y)
						for k in 4:
							if vertices[vc + k].y >= top_y - 0.001:
								vertices[vc + k].y -= WATER_DROP
					# UV.y = roche/terre HÔTE (masque minerai/herbe, shader) — le bloc
					# propriétaire de cette face (2026-07-24).
					var host := 0
					if not data.block_host.is_empty():
						var owner := Vector3i.ZERO
						owner[d] = cut if c > 0 else cut + 1
						owner[u] = i
						owner[v] = j
						host = int(data.block_host.get(ChunkData.index_of(owner.x, owner.y, owner.z), 0))
					var uv := Vector2(float(absi(c)), float(host))
					for k in 4:
						normals[vc + k] = normal
						uvs[vc + k] = uv
					indices[ic] = vc
					indices[ic + 1] = vc + 1
					indices[ic + 2] = vc + 2
					indices[ic + 3] = vc
					indices[ic + 4] = vc + 2
					indices[ic + 5] = vc + 3
					vc += 4
					ic += 6
					for jj in h:
						for kk in w:
							mask[(j + jj) * T + i + kk] = 0
					i += w

	# --- 3. Passe FINE : sous-grilles des blocs subdivisés (4.1/G.2) ---
	# Greedy meshing par sous-grille 8×8×8 (cellules de 4 px = 1/8 bloc).
	# Culling aux bords : une face bordière est cachée si le bloc voisin est
	# PLEIN au niveau bloc ; face à un voisin subdivisé (= air dans le pad),
	# les deux surfaces se dessinent — normales opposées, jamais de z-fight.
	if fine and not data.subdivs.is_empty():
		var sub_mask := PackedInt32Array()
		sub_mask.resize(64)
		var grid_strides := [1, 64, 8]  # strides sous-grille : x, y, z
		for block_index: int in data.subdivs:
			var grid: PackedInt32Array = data.subdivs[block_index]
			var bx := block_index & 15
			var bz := (block_index >> 4) & 15
			var by := block_index >> 8
			var block_base := Vector3(bx, by, bz)
			var pad_center := (bx + 1) * SX + (bz + 1) * SZ + (by + 1) * SY
			for d in 3:
				var u := (d + 1) % 3
				var v := (d + 2) % 3
				var gd: int = grid_strides[d]
				var gu: int = grid_strides[u]
				var gv: int = grid_strides[v]
				var pad_stride: int = strides[d]
				for cut in range(-1, 8):
					# Bord contre un bloc voisin plein : faces cachées.
					if cut == -1 and pad[pad_center - pad_stride] != 0:
						continue
					if cut == 7 and pad[pad_center + pad_stride] != 0:
						continue
					var visible := false
					var n := 0
					for j in 8:
						for i in 8:
							var a := grid[cut * gd + i * gu + j * gv] if cut >= 0 else 0
							var b := grid[(cut + 1) * gd + i * gu + j * gv] if cut <= 6 else 0
							var value := 0
							if a != 0 and b == 0:
								value = a
							elif b != 0 and a == 0:
								value = -b
							sub_mask[n] = value
							if value != 0:
								visible = true
							n += 1
					if not visible:
						continue
					# Fusion gloutonne (identique à la passe bloc, T = 8).
					for j in 8:
						var i := 0
						while i < 8:
							var c := sub_mask[j * 8 + i]
							if c == 0:
								i += 1
								continue
							var w := 1
							while i + w < 8 and sub_mask[j * 8 + i + w] == c:
								w += 1
							var h := 1
							var extendable := true
							while j + h < 8 and extendable:
								for k in w:
									if sub_mask[(j + h) * 8 + i + k] != c:
										extendable = false
										break
								if extendable:
									h += 1
							if vc + 4 > vertices.size():
								var new_size := maxi(vertices.size() * 2, 1024)
								vertices.resize(new_size)
								normals.resize(new_size)
								uvs.resize(new_size)
							if ic + 6 > indices.size():
								indices.resize(maxi(indices.size() * 2, 1536))
							var normal := Vector3.ZERO
							normal[d] = 1.0 if c > 0 else -1.0
							var origin := block_base
							origin[d] += (cut + 1) * SubdivGrid.CELL_UNIT
							origin[u] += i * SubdivGrid.CELL_UNIT
							origin[v] += j * SubdivGrid.CELL_UNIT
							var du := Vector3.ZERO
							du[u] = w * SubdivGrid.CELL_UNIT
							var dv := Vector3.ZERO
							dv[v] = h * SubdivGrid.CELL_UNIT
							if du.cross(dv).dot(normal) > 0.0:
								var tmp := du
								du = dv
								dv = tmp
							vertices[vc] = origin
							vertices[vc + 1] = origin + du
							vertices[vc + 2] = origin + du + dv
							vertices[vc + 3] = origin + dv
							var uv := Vector2(float(absi(c)), 0.0)
							for k in 4:
								normals[vc + k] = normal
								uvs[vc + k] = uv
							indices[ic] = vc
							indices[ic + 1] = vc + 1
							indices[ic + 2] = vc + 2
							indices[ic + 3] = vc
							indices[ic + 4] = vc + 2
							indices[ic + 5] = vc + 3
							vc += 4
							ic += 6
							for jj in h:
								for kk in w:
									sub_mask[(j + jj) * 8 + i + kk] = 0
							i += w

	if ic == 0:
		return []

	vertices.resize(vc)
	normals.resize(vc)
	uvs.resize(vc)
	indices.resize(ic)
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_INDEX] = indices
	return arrays


## Surimpose au pad les blocs modifiés des 6 chunks voisins qui touchent la
## coquille. Retourne true si au moins un bloc d'air a été écrit.
static func _apply_shell_edits(pad: PackedInt32Array, cpos: Vector3i, edits: Dictionary) -> bool:
	var air := false
	# Pour chaque direction : voisin, condition de bordure côté voisin, et
	# fonction de projection vers l'indice pad.
	for dir_index in 6:
		var dir := [
			Vector3i(-1, 0, 0), Vector3i(1, 0, 0),
			Vector3i(0, -1, 0), Vector3i(0, 1, 0),
			Vector3i(0, 0, -1), Vector3i(0, 0, 1),
		][dir_index] as Vector3i
		var neighbor_key := cpos + dir
		if not edits.has(neighbor_key):
			continue
		var neighbor_edits: Dictionary = edits[neighbor_key]
		for index: int in neighbor_edits:
			var x := index & 15
			var z := (index >> 4) & 15
			var y := index >> 8
			# Le bloc voisin doit toucher NOTRE chunk (face partagée).
			var px: int
			var py: int
			var pz: int
			match dir_index:
				0:
					if x != T - 1:
						continue
					px = -1; py = y; pz = z
				1:
					if x != 0:
						continue
					px = T; py = y; pz = z
				2:
					if y != T - 1:
						continue
					px = x; py = -1; pz = z
				3:
					if y != 0:
						continue
					px = x; py = T; pz = z
				4:
					if z != T - 1:
						continue
					px = x; py = y; pz = -1
				_:
					if z != 0:
						continue
					px = x; py = y; pz = T
			var id: int = neighbor_edits[index]
			pad[(px + 1) + (pz + 1) * SZ + (py + 1) * SY] = id
			if id == 0:
				air = true
	return air
