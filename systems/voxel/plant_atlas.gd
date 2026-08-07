class_name PlantAtlas
extends RefCounted
## SPRITES DE PLANTES : de vrais pixels, à l'échelle des blocs (2026-08-04).
##
## ---------------------------------------------------------------------------
## POURQUOI UNE IMAGE ET NON DE LA GÉOMÉTRIE
## ---------------------------------------------------------------------------
## Demande de l'auteur : « il faut que les plantes soient composées de pixels et
## à la même échelle que les textures des blocs ».
##
## La version d'avant fabriquait la silhouette en assemblant des quads penchés.
## Trois tours de retouche ont montré que ça ne marche pas : un assemblage de
## rectangles ressemble à un assemblage de rectangles — des cure-dents, puis des
## guéridons, puis des petites tables. Une plante se reconnaît à son DESSIN, pas
## à son volume.
##
## Ici, chaque espèce a un sprite tracé pixel par pixel, et la plante n'est plus
## qu'UN quad plat qui le porte. La lisibilité vient de l'image ; la géométrie ne
## fait que la tenir droite.
##
## ---------------------------------------------------------------------------
## L'ÉCHELLE EST CELLE DES BLOCS, ET CE N'EST PAS NÉGOCIABLE
## ---------------------------------------------------------------------------
## `voxel_material.gdshader` texture les faces de bloc sur une grille de
## `PIXELS = 16` par bloc. Un sprite de plante fait donc 16 pixels de côté pour
## un bloc de haut : posé à côté d'un bloc de terre, le grain est EXACTEMENT le
## même. Une plante dessinée plus fin trahirait immédiatement qu'elle n'est pas
## faite de la même matière que le monde.
##
## Les espèces plus hautes qu'un bloc (maïs, tournesol) ont un sprite plus HAUT,
## jamais plus fin : la hauteur se paie en pixels, pas en résolution.
const PIXELS_PER_BLOCK := 16

## Colonnes de l'atlas. Les cellules font toutes la même taille — une cellule
## par espèce, quitte à laisser du vide au-dessus des plantes basses : un atlas
## à cellules variables demanderait de transporter la taille de chacune jusque
## dans le shader, pour économiser quelques kilooctets.
const COLUMNS := 8
## Hauteur d'une cellule : deux blocs, ce qui couvre le maïs et le tournesol.
const CELL_H := PIXELS_PER_BLOCK * 2


## Construit l'atlas de toutes les espèces en croix.
##
## Retourne { "texture": ImageTexture, "index": { id runtime → cellule },
## "columns": int, "rows": int }.
static func build(species_by_runtime: Dictionary) -> Dictionary:
	var ids: Array = species_by_runtime.keys()
	ids.sort()
	var rows := int(ceil(float(ids.size()) / float(COLUMNS)))
	rows = maxi(rows, 1)
	var image := Image.create_empty(COLUMNS * PIXELS_PER_BLOCK, rows * CELL_H,
			false, Image.FORMAT_RGBA8)
	image.fill(Color(0, 0, 0, 0))

	var index := {}
	var cell := 0
	for rid: int in ids:
		var species: Dictionary = species_by_runtime[rid]
		_draw(image, species, (cell % COLUMNS) * PIXELS_PER_BLOCK, (cell / COLUMNS) * CELL_H)
		index[rid] = cell
		cell += 1
	return {
		"texture": ImageTexture.create_from_image(image),
		"index": index, "columns": COLUMNS, "rows": rows,
	}


## Dessine une espèce dans sa cellule. Le PORT décide du tracé — c'est la même
## clé que la génération employait pour la géométrie, elle pilote maintenant le
## dessin. Ajouter une espèce reste une affaire de JSON.
static func _draw(image: Image, species: Dictionary, ox: int, oy: int) -> void:
	var base := Color.html(String(species.get("color", "#4E8B3C")))
	# DEUX TONS, et c'est le minimum vital. Un aplat d'une seule couleur se lit
	# comme une découpe de papier ; une ombre d'un ton plus sombre suffit à
	# donner du relief à seize pixels de côté. C'est la règle des textures de
	# blocs de ce projet, appliquée aux plantes.
	var dark := base.darkened(0.28)
	var light := base.lightened(0.16)
	var rng := RandomNumberGenerator.new()
	# Le tracé est DÉTERMINISTE par espèce : la même fiche redonne le même
	# sprite d'un lancement à l'autre, sinon les captures de sonde ne
	# voudraient rien dire.
	rng.seed = hash(String(species.get("id", "?")))

	var port := String(species.get("port", "touffe"))
	# Hauteur du dessin, en pixels, depuis le bas de la cellule.
	var h := int(clampf(float(species.get("hauteur_image", 0.9)), 0.15, 2.0)
			* float(PIXELS_PER_BLOCK))
	h = clampi(h, 4, CELL_H - 1)
	match port:
		"epi":
			_draw_grain(image, ox, oy, h, base, dark, light, rng)
		"buisson":
			_draw_bush(image, ox, oy, h, base, dark, light, rng)
		"rampante":
			_draw_creeper(image, ox, oy, h, base, dark, rng)
		"fleur":
			_draw_flower(image, ox, oy, h, base, dark, light, rng)
		_:
			_draw_tuft(image, ox, oy, h, base, dark, light, rng)


## Repère : x de 0 à 15 dans la cellule, y compté DEPUIS LE BAS (0 = sol).
static func _put(image: Image, ox: int, oy: int, x: int, y: int, c: Color) -> void:
	if x < 0 or x >= PIXELS_PER_BLOCK or y < 0 or y >= CELL_H:
		return
	image.set_pixel(ox + x, oy + CELL_H - 1 - y, c)


## TOUFFE : des brins d'un pixel de large, de hauteurs inégales, qui s'écartent
## en montant. C'est la forme de l'herbe, et c'est celle qu'on voit le plus.
static func _draw_tuft(image: Image, ox: int, oy: int, h: int, base: Color,
		dark: Color, light: Color, rng: RandomNumberGenerator) -> void:
	var blades := rng.randi_range(5, 7)
	for i in blades:
		var x := 2 + int(round(float(i) / float(blades - 1) * 11.0))
		var top := int(h * rng.randf_range(0.55, 1.0))
		# Le brin s'incline en montant : un brin droit est un trait, un brin
		# penché est une herbe.
		var lean := rng.randi_range(-1, 1)
		for y in top:
			var bx := x + int(round(float(lean) * float(y) / float(maxi(top, 1)) * 2.0))
			# Le bord du brin est plus sombre : deux tons sur un pixel de large,
			# c'est l'alternance qui le donne.
			_put(image, ox, oy, bx, y, dark if y % 3 == 0 else base)
		_put(image, ox, oy, x + int(round(float(lean) * 2.0)), top, light)


## ÉPI : une tige nette, et des grains en épi sur le tiers haut. Ce sont les
## GRAINS qui disent « céréale » — la tige seule est un brin d'herbe.
static func _draw_grain(image: Image, ox: int, oy: int, h: int, base: Color,
		dark: Color, light: Color, rng: RandomNumberGenerator) -> void:
	var stalks := rng.randi_range(2, 3)
	for i in stalks:
		var x := 4 + i * rng.randi_range(3, 4)
		var top := int(h * rng.randf_range(0.85, 1.0))
		var head := int(float(top) * 0.62)
		for y in head:
			_put(image, ox, oy, x, y, dark if y % 4 == 0 else base)
		# Les grains : deux pixels de part et d'autre de l'axe, en quinconce.
		for y in range(head, top):
			_put(image, ox, oy, x, y, light)
			if (y - head) % 2 == 0:
				_put(image, ox, oy, x - 1, y, base)
			else:
				_put(image, ox, oy, x + 1, y, base)
		_put(image, ox, oy, x, top, light)


## BUISSON : une masse pleine et arrondie, plus large que haute, avec quelques
## trous pour qu'elle ne soit pas un pâté.
static func _draw_bush(image: Image, ox: int, oy: int, h: int, base: Color,
		dark: Color, light: Color, rng: RandomNumberGenerator) -> void:
	var cx := 7.5
	var rx := 6.0
	var ry := float(h) * 0.55
	for y in h:
		for x in PIXELS_PER_BLOCK:
			var dx := (float(x) - cx) / rx
			var dy := (float(y) - ry) / ry
			if dx * dx + dy * dy > 1.0:
				continue
			if rng.randf() < 0.12:
				continue   # Trouée : une masse pleine se lit comme un rocher.
			var c := base
			if float(y) > ry * 1.2:
				c = light      # Le dessus prend la lumière.
			elif float(y) < ry * 0.5:
				c = dark       # Le dessous reste dans l'ombre.
			_put(image, ox, oy, x, y, c)
	# Un pied visible, sinon le buisson flotte.
	for y in maxi(int(ry * 0.4), 1):
		_put(image, ox, oy, 7, y, dark)


## RAMPANTE : une nappe basse et large. Elle se lit d'en haut, pas de profil —
## sur un sprite vertical, c'est donc une bande épaisse au ras du sol.
static func _draw_creeper(image: Image, ox: int, oy: int, h: int, base: Color,
		dark: Color, rng: RandomNumberGenerator) -> void:
	var top := maxi(int(float(h) * 0.6), 2)
	for x in PIXELS_PER_BLOCK:
		var thickness := top - absi(x - 8) / 3
		for y in maxi(thickness, 0):
			if rng.randf() < 0.10:
				continue
			_put(image, ox, oy, x, y, dark if y == 0 else base)


## FLEUR : une tige fine, deux feuilles au pied, une corolle au sommet. La
## corolle est un motif COMPACT et clair — c'est ce qui se voit de loin, et
## c'est ce qui distingue un coquelicot d'un brin d'herbe rouge.
static func _draw_flower(image: Image, ox: int, oy: int, h: int, base: Color,
		dark: Color, light: Color, rng: RandomNumberGenerator) -> void:
	# La TIGE est verte, pas de la couleur de la fleur : une tige rouge ferait
	# un bâton de sucre d'orge. La couleur de la fiche est celle des pétales.
	var stem := Color(0.30, 0.52, 0.24)
	var stems := rng.randi_range(1, 2)
	for i in stems:
		var x := 6 + i * 4
		var top := int(h * rng.randf_range(0.8, 1.0))
		for y in top - 2:
			_put(image, ox, oy, x, y, stem if y % 3 != 0 else stem.darkened(0.25))
		# Deux feuilles au pied.
		var leaf := int(float(top) * 0.35)
		_put(image, ox, oy, x - 1, leaf, stem)
		_put(image, ox, oy, x + 1, leaf - 1, stem)
		# La corolle : une croix pleine de 3×3 avec un cœur clair.
		var cy := top - 1
		for dx in range(-1, 2):
			for dy in range(-1, 2):
				if absi(dx) == 1 and absi(dy) == 1:
					continue   # Coins vides : une corolle ronde, pas un carré.
				_put(image, ox, oy, x + dx, cy + dy, base)
		_put(image, ox, oy, x, cy, light)
		_put(image, ox, oy, x, cy - 1, dark)
