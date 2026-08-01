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

## Profilage par PHASE (2026-07-27) — désactivé par défaut : le budget E.14
## est « < 4 ms par chunk » et le bench global ne dit que le total, pas OÙ il
## part. Activé par la sonde --probe-mesh, coût nul sinon (un booléen testé
## quatre fois par chunk).
static var profiling := false
static var phase_us := {"coquille": 0, "interieur": 0, "greedy": 0, "subdiv": 0}
static var profiled_chunks := 0


static func reset_profile() -> void:
	phase_us = {"coquille": 0, "interieur": 0, "greedy": 0, "subdiv": 0}
	profiled_chunks = 0


const WATER_DROP := 0.14     # Abaissement de la surface des liquides (2026-07-24).
const T := 16                # Taille de chunk (ChunkData.SIZE).
const P := 18                # Taille du tableau padded (T + 2).
# Strides du tableau padded : indice = (x+1) + (z+1)*18 + (y+1)*324.
const SX := 1
const SY := 324
const SZ := 18
## Strides indexés par axe (0=x, 1=y, 2=z) et strides d'une sous-grille 8³.
## MESURÉ le 2026-07-28 : ces tableaux sont RECOPIÉS EN LOCALES en tête de
## mesh_chunk, jamais lus directement. Un accès à une `static var` passe par le
## stockage statique du script et coûte sensiblement plus qu'une locale — les
## lire dans le balayage greedy (des dizaines de milliers d'itérations par
## chunk) avait fait passer la sonde subdiv de 59 à 83 ms. La copie est
## gratuite (PackedInt32Array est copie-sur-écriture) et rend l'accès local.
static var STRIDES := PackedInt32Array([SX, SY, SZ])
static var GRID_STRIDES := PackedInt32Array([1, 64, 8])
## Strides du tableau de blocs d'un chunk (16³), indexés par axe. Même rôle que
## STRIDES pour le tableau paddé : retrouver un indice de bloc par arithmétique
## plutôt qu'en construisant un Vector3i pour ChunkData.index_of.
static var CHUNK_STRIDES := PackedInt32Array([1, 256, 16])
## Les 6 directions de voisinage de la coquille. Étaient allouées comme Array
## littéral À L'INTÉRIEUR de la boucle de _apply_shell_edits — 6 allocations de
## 6 Vector3i par appel, pour une donnée constante.
const SHELL_DIRS: Array[Vector3i] = [
	Vector3i(-1, 0, 0), Vector3i(1, 0, 0),
	Vector3i(0, -1, 0), Vector3i(0, 1, 0),
	Vector3i(0, 0, -1), Vector3i(0, 0, 1),
]


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
## `light` : champ de lumière du chunk (G.3), 4 096 niveaux 0-15, ou vide
## (obscurité). Cuit dans la COULEUR DE SOMMET — G.3 : « la lumière est
## cuite dans les vertex ». Le shader n'a plus qu'à lire COLOR.r, sans
## aucune boucle de lumière (le terrain est unshaded).
static func mesh_chunk(cpos: Vector3i, data: ChunkData, generator: NoiseGenerator, ctx: Dictionary, neighbor_edits: Dictionary = {}, fine: bool = true) -> Array:
	var uniform := data.is_uniform()
	if uniform and data.uniform_id == 0:
		return []

	# --- 1. Copie padded : coquille de voisinage D'ABORD ---
	# (permet de rejeter un chunk uniforme enterré sans remplir l'intérieur)
	var pad := PackedInt32Array()
	pad.resize(P * P * P)
	var t_phase := Time.get_ticks_usec() if profiling else 0
	var shell_air := true  # Dimension vide : la coquille (pad zéroé) est d'air.
	if generator != null:
		shell_air = generator.fill_shell(cpos, pad, ctx)
	if not neighbor_edits.is_empty():
		# Les modifications voisines peuvent creuser de l'air dans la
		# coquille : le OU est conservateur (jamais de face manquée).
		shell_air = _apply_shell_edits(pad, cpos, neighbor_edits) or shell_air

	if profiling:
		phase_us["coquille"] += Time.get_ticks_usec() - t_phase
		t_phase = Time.get_ticks_usec()

	# Rejet rapide : chunk uniforme solide entièrement enterré → aucune face,
	# l'intérieur n'est même pas copié (cas majoritaire du sous-sol).
	if uniform and not shell_air:
		if profiling:
			profiled_chunks += 1
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

	# Lumière de bloc (G.3), calculée depuis le pad : il porte exactement le
	# chunk + son voisinage immédiat, soit toute l'occlusion nécessaire.
	# Retourne un tableau vide (donc gratuit) pour les chunks sans source.
	var light := LightField.compute_from_pad(pad)

	if profiling:
		phase_us["interieur"] += Time.get_ticks_usec() - t_phase
		t_phase = Time.get_ticks_usec()

	# --- 2. Balayage greedy par axe ---
	# Tableaux pré-alloués + curseurs (vc/ic) — jamais d'append par sommet.
	var vertices := PackedVector3Array()
	var normals := PackedVector3Array()
	var uvs := PackedVector2Array()
	var colors := PackedColorArray()
	var indices := PackedInt32Array()
	vertices.resize(1024)
	normals.resize(1024)
	uvs.resize(1024)
	colors.resize(1024)
	indices.resize(1536)
	var vc := 0
	var ic := 0
	var mask := PackedInt32Array()
	mask.resize(T * T)
	# Copies LOCALES des tables de strides (voir leur commentaire) : une seule
	# par chunk, puis tous les accès des boucles chaudes sont des locales.
	var strides := STRIDES
	var grid_strides := GRID_STRIDES
	# Masque des liquides hissé en LOCALE : il était lu par `GameData.liquid_mask`
	# À CHAQUE QUAD ÉMIS, soit un accès autoload (résolution de singleton +
	# propriété) des dizaines de milliers de fois par chunk. Une seule résolution
	# par chunk suffit — GameData est en lecture seule une fois chargé, et
	# wait_for_in_flight() garantit qu'aucun thread ne tourne pendant un reload.
	var liquid_mask := GameData.liquid_mask
	var liquid_count := liquid_mask.size()
	# Tout ce qui suit était relu À CHAQUE QUAD depuis `data`, un objet, ou via
	# un appel statique. Un chunk dense émet des dizaines de milliers de quads :
	# c'est le seul endroit du moteur où une résolution de propriété se paie au
	# millier près.
	var block_host := data.block_host
	var has_host := not block_host.is_empty()
	var light_empty := light.is_empty()
	var inv_light := 1.0 / float(LightField.MAX_LEVEL)

	for d in 3:
		var u := (d + 1) % 3
		var v := (d + 2) % 3
		var sd := strides[d]
		var su := strides[u]
		var sv := strides[v]
		# Vecteurs unitaires des trois axes, construits UNE FOIS par axe. Ils
		# étaient refabriqués par quad à coups de `Vector3.ZERO` puis d'écriture
		# indexée `normal[d] = ...` : en GDScript, indexer un Vector3 par une
		# variable passe par le chemin dynamique et coûte bien plus qu'une
		# multiplication.
		var e_d := Vector3.ZERO
		e_d[d] = 1.0
		var e_u := Vector3.ZERO
		e_u[u] = 1.0
		var e_v := Vector3.ZERO
		e_v[v] = 1.0
		# Sens d'enroulement : il ne dépend QUE de l'axe et du signe de la face,
		# jamais des dimensions du rectangle. Le produit vectoriel et le produit
		# scalaire étaient pourtant recalculés à chaque quad pour retomber
		# invariablement sur le même verdict.
		var swap_when_positive := e_u.cross(e_v).dot(e_d) > 0.0
		# Strides du tableau de blocs DU CHUNK (non paddé) par axe, pour
		# retrouver le bloc hôte sans construire de Vector3i ni appeler
		# ChunkData.index_of.
		var hd := CHUNK_STRIDES[d]
		var hu := CHUNK_STRIDES[u]
		var hv := CHUNK_STRIDES[v]

		# `cut` est la frontière entre les cellules locales cut et cut+1.
		for cut in range(-1, T):
			# Saut rapide sur l'axe Y : une face ne peut être portée que par
			# un bloc intérieur des niveaux cut ou cut+1.
			if d == 1:
				var solid_below := cut >= 0 and level_solid[cut] > 0
				var solid_above := cut + 1 <= T - 1 and level_solid[cut + 1] > 0
				if not solid_below and not solid_above:
					continue
				# Symétrique du saut ci-dessus (2026-07-27) : deux niveaux
				# ENTIÈREMENT pleins ne portent aucune face entre eux (tout
				# a != 0 ET tout b != 0 → valeur toujours nulle). Cas très
				# fréquent sous terre, où l'ancien code balayait quand même
				# les 256 cellules du masque pour n'y trouver que des zéros.
				if cut >= 0 and cut + 1 <= T - 1 and level_solid[cut] == T * T and level_solid[cut + 1] == T * T:
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
						colors.resize(new_size)
					if ic + 6 > indices.size():
						indices.resize(maxi(indices.size() * 2, 1536))
					var positive := c > 0
					var normal := e_d if positive else -e_d
					var origin := e_d * float(cut + 1) + e_u * float(i) + e_v * float(j)
					var du := e_u * float(w)
					var dv := e_v * float(h)
					# Enroulement horaire vu de face (convention Godot) :
					# cross(du, dv) doit pointer à l'OPPOSÉ de la normale.
					if positive == swap_when_positive:
						var tmp := du
						du = dv
						dv = tmp
					vertices[vc] = origin
					vertices[vc + 1] = origin + du
					vertices[vc + 2] = origin + du + dv
					vertices[vc + 3] = origin + dv
					# Liquides « moins grands » (2026-07-24) : abaisse l'arête supérieure
					# (surface) — face du dessus entière, arête haute des faces latérales.
					# Borne explicite : `c` vient du pad, donc de données pouvant
					# provenir d'une sauvegarde antérieure ou d'un catalogue
					# modifié. Un dépassement ici planterait un THREAD worker,
					# le pire endroit pour diagnostiquer (2026-07-27).
					var cid := absi(c)
					if cid < liquid_count and liquid_mask[cid] == 1 and not (d == 1 and not positive):
						var top_y := vertices[vc].y
						for k in 4:
							top_y = maxf(top_y, vertices[vc + k].y)
						for k in 4:
							if vertices[vc + k].y >= top_y - 0.001:
								vertices[vc + k].y -= WATER_DROP
					# UV.y = roche/terre HÔTE (masque minerai/herbe, shader) — le bloc
					# propriétaire de cette face (2026-07-24).
					var host := 0
					if has_host:
						host = int(block_host.get(
							(cut if positive else cut + 1) * hd + i * hu + j * hv, 0))
					var uv := Vector2(float(absi(c)), float(host))
					# Lumière de bloc (G.3) : échantillonnée du côté AIR de la
					# face — c'est la cellule éclairée, le bloc porteur étant
					# opaque. Cuite dans la couleur de sommet, le shader n'a
					# plus qu'à la lire (terrain unshaded, aucune boucle).
					# Indice de lumière calculé DIRECTEMENT : le champ de
					# lumière partage exactement les strides du pad, donc la
					# cellule côté air est `idx` décalé d'un cran sur l'axe.
					# L'ancien code construisait un Vector3i et passait par
					# LightField.level_at, qui refaisait des tests de bornes
					# déjà garantis par les boucles.
					var level := 0.0
					if not light_empty:
						var lit_index := (cut + 1) * sd + (i + 1) * su + (j + 1) * sv
						if positive:
							lit_index += sd
						level = float(light[lit_index]) * inv_light
					var vertex_color := Color(level, level, level, 1.0)
					for k in 4:
						normals[vc + k] = normal
						uvs[vc + k] = uv
						colors[vc + k] = vertex_color
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

	if profiling:
		phase_us["greedy"] += Time.get_ticks_usec() - t_phase
		t_phase = Time.get_ticks_usec()

	# --- 3. Passe FINE : sous-grilles des blocs subdivisés (4.1/G.2) ---
	# Greedy meshing par sous-grille 8×8×8 (cellules de 4 px = 1/8 bloc).
	# Culling aux bords : une face bordière est cachée si le bloc voisin est
	# PLEIN au niveau bloc ; face à un voisin subdivisé (= air dans le pad),
	# les deux surfaces se dessinent — normales opposées, jamais de z-fight.
	if fine and not data.subdivs.is_empty():
		var sub_mask := PackedInt32Array()
		sub_mask.resize(64)
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
				var gd := grid_strides[d]
				var gu := grid_strides[u]
				var gv := grid_strides[v]
				var pad_stride := strides[d]
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
								colors.resize(new_size)
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
							# Lumière du BLOC hôte (G.3) : une sous-grille est
							# contenue dans un bloc, elle prend son éclairage.
							# Sans cette écriture, les sommets garderaient la
							# couleur par défaut (noir) et toute sculpture
							# apparaîtrait dans le noir absolu.
							var sub_level := float(LightField.level_at(light, Vector3i(bx, by, bz))) 									/ float(LightField.MAX_LEVEL)
							var sub_color := Color(sub_level, sub_level, sub_level, 1.0)
							for k in 4:
								normals[vc + k] = normal
								uvs[vc + k] = uv
								colors[vc + k] = sub_color
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

	if profiling:
		phase_us["subdiv"] += Time.get_ticks_usec() - t_phase
		profiled_chunks += 1

	if ic == 0:
		return []

	vertices.resize(vc)
	normals.resize(vc)
	uvs.resize(vc)
	colors.resize(vc)
	indices.resize(ic)
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_COLOR] = colors
	arrays[Mesh.ARRAY_INDEX] = indices
	return arrays


## Surimpose au pad les blocs modifiés des 6 chunks voisins qui touchent la
## coquille. Retourne true si au moins un bloc d'air a été écrit.
static func _apply_shell_edits(pad: PackedInt32Array, cpos: Vector3i, edits: Dictionary) -> bool:
	var air := false
	# Pour chaque direction : voisin, condition de bordure côté voisin, et
	# fonction de projection vers l'indice pad.
	for dir_index in 6:
		var neighbor_key := cpos + SHELL_DIRS[dir_index]
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
