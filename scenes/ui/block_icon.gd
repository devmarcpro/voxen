class_name BlockIcon
extends RefCounted
## Icône de bloc en CUBE isométrique (2026-07-26) : 3 faces visibles (dessus
## clair, gauche moyen, droite sombre) façon inventaire Minecraft, à partir de
## la couleur d'un matériau. Rendu procédural en Image (pas de viewport).
## NOTE : approxime le bloc par sa COULEUR ombrée par face ; le détail de
## texture procédurale (pépites/grain) n'est pas reproduit ici (il faudrait un
## rendu par SubViewport — piste d'amélioration).
##
## -----------------------------------------------------------------------------
## UN MASQUE PAR TAILLE, TEINTÉ À L'AFFICHAGE (2026-08-07)
## -----------------------------------------------------------------------------
## Ces vignettes étaient dessinées PIXEL PAR PIXEL EN GDSCRIPT, une image par
## COULEUR : 48×48 pixels, trois tests d'appartenance à un quadrilatère chacun.
## Mesuré sur l'inventaire : **1735 ms pour 210 lignes**, soit 8 ms la vignette,
## et les trois quarts du gel à l'ouverture de l'inventaire.
##
## Et la cache ne servait pas : `if _cache.size() < _CACHE_MAX` avec un plafond
## de 512 et AUCUNE ÉVICTION. Avec 507 matériaux déclinés en plusieurs tailles,
## le plafond était atteint aussitôt et plus rien n'était jamais mis en cache —
## second passage mesuré à 1562 ms. **Une cache qui cesse silencieusement de
## cacher est pire que pas de cache : elle a l'air de marcher.**
##
## La forme ne dépend PAS de la couleur. On dessine donc le cube UNE FOIS par
## taille, en blanc ombré par face, et la couleur est appliquée à l'affichage
## (`modulate` d'un TextureRect, couleurs d'icône d'un Button). Le nombre de
## textures passe de « une par matériau et par taille » à « une par taille » —
## une poignée — et le coût par ligne tombe à zéro. La multiplication par
## `modulate` conserve l'ombrage des faces, puisqu'il est encodé en niveaux de
## gris.

## Masques par taille. Bornés par le nombre de tailles employées dans
## l'interface, soit une poignée : aucun plafond n'est nécessaire, et c'est
## justement ce qui rend cette cache honnête.
static var _cube_masks := {}
static var _item_masks := {}


## Cube isométrique BLANC ombré par face, pour la taille demandée. À teinter par
## l'appelant (voir `tint_texture_rect` / `tint_button`).
static func cube_mask(size: int = 22) -> ImageTexture:
	if _cube_masks.has(size):
		return _cube_masks[size]
	var tex := _build_cube(Color.WHITE, size)
	_cube_masks[size] = tex
	return tex


## Applique la couleur d'un matériau à une vignette. Passe par `modulate` :
## aucune image n'est produite, c'est une multiplication faite par le GPU.
static func tint_texture_rect(rect: TextureRect, color: Color) -> void:
	rect.modulate = color


## Même chose pour l'icône d'un bouton. LES CINQ ÉTATS, et pas seulement
## `normal` : n'en teinter qu'un fait blanchir l'icône au survol et au clic,
## ce qui se lit comme un bug d'affichage.
static func tint_button(button: Button, color: Color) -> void:
	for state in ["icon_normal_color", "icon_hover_color", "icon_pressed_color",
			"icon_focus_color", "icon_disabled_color"]:
		button.add_theme_color_override(state, color)


## Vignette COLORÉE, pour les rares endroits qui ont besoin d'une texture déjà
## teintée (en-tête de recette, cellule de collection) plutôt que d'un nœud à
## moduler. Quelques-unes par panneau, jamais des centaines : les listes longues
## passent par le masque.
static func cube_texture(color: Color, size: int = 22) -> ImageTexture:
	return _tinted("%d_%d" % [color.to_rgba32(), size], color, size, true)


static func item_texture(color: Color, size: int = 22) -> ImageTexture:
	return _tinted("i%d_%d" % [color.to_rgba32(), size], color, size, false)


## Cache des vignettes colorées. **ELLE ÉVICTE, elle ne s'arrête pas.** La
## version précédente cessait purement et simplement d'enregistrer une fois son
## plafond atteint : à partir de là, chaque appel redessinait l'image entière,
## pour toujours, sans que rien ne le signale. Une cache pleine doit oublier la
## plus ancienne, jamais renoncer à son métier.
const _COLOURED_MAX := 256
static var _coloured_cache := {}


## L'IMAGE N'EST CONSTRUITE QU'EN CAS DE DÉFAUT DE CACHE. Une première version
## la passait en ARGUMENT : GDScript évalue les arguments avant l'appel, si bien
## que la vignette était redessinée à chaque fois et que le test de cache ne
## servait plus à rien. Le symptôme aurait été exactement celui qu'on corrige.
static func _tinted(key: String, color: Color, size: int, is_cube: bool) -> ImageTexture:
	if _coloured_cache.has(key):
		return _coloured_cache[key]
	var tex := _build_cube(color, size) if is_cube else _build_item(color, size)
	if _coloured_cache.size() >= _COLOURED_MAX:
		_coloured_cache.erase(_coloured_cache.keys()[0])
	_coloured_cache[key] = tex
	return tex


static func _build_cube(color: Color, size: int) -> ImageTexture:
	var img := Image.create(size, size, false, Image.FORMAT_RGBA8)
	var s := float(size)
	# Sommets d'un cube iso (projection 2:1 simplifiée).
	var vt := Vector2(s * 0.5, s * 0.04)      # sommet haut
	var vl := Vector2(s * 0.03, s * 0.29)     # coin gauche
	var vr := Vector2(s * 0.97, s * 0.29)     # coin droit
	var vc := Vector2(s * 0.5, s * 0.54)      # centre (jonction des 3 faces)
	var vbl := Vector2(s * 0.03, s * 0.71)    # bas gauche
	var vbr := Vector2(s * 0.97, s * 0.71)    # bas droite
	var vb := Vector2(s * 0.5, s * 0.96)      # bas
	var top := PackedVector2Array([vt, vr, vc, vl])
	var left := PackedVector2Array([vl, vc, vb, vbl])
	var right := PackedVector2Array([vc, vr, vbr, vb])
	var c_top := _shade(color, 1.0)
	var c_left := _shade(color, 0.72)
	var c_right := _shade(color, 0.52)
	for y in size:
		for x in size:
			var p := Vector2(float(x) + 0.5, float(y) + 0.5)
			if _in_quad(p, top):
				img.set_pixel(x, y, c_top)
			elif _in_quad(p, left):
				img.set_pixel(x, y, c_left)
			elif _in_quad(p, right):
				img.set_pixel(x, y, c_right)
	return ImageTexture.create_from_image(img)


static func _shade(c: Color, f: float) -> Color:
	return Color(c.r * f, c.g * f, c.b * f, 1.0)


## Point dans un quadrilatère CONVEXE (sommets ordonnés) : tous les produits
## vectoriels des arêtes vers p doivent avoir le même signe.
static func _in_quad(p: Vector2, q: PackedVector2Array) -> bool:
	var sign := 0.0
	for i in 4:
		var a := q[i]
		var b := q[(i + 1) % 4]
		var cross := (b.x - a.x) * (p.y - a.y) - (b.y - a.y) * (p.x - a.x)
		if absf(cross) < 0.0001:
			continue
		if sign == 0.0:
			sign = cross
		elif (cross > 0.0) != (sign > 0.0):
			return false
	return true


## Icône d'OBJET (2026-07-27) : pastille arrondie teintée, visuellement
## distincte du cube isométrique des blocs — une viande ou une peau ne se
## pose pas, elle ne doit pas ressembler à un bloc de construction. Sert de
## visuel par défaut à toute instance sans sprite dédié.
## Pastille BLANCHE ombrée pour la taille demandée, même principe que le cube.
static func item_mask(size: int = 22) -> ImageTexture:
	if _item_masks.has(size):
		return _item_masks[size]
	var tex := _build_item(Color.WHITE, size)
	_item_masks[size] = tex
	return tex


static func _build_item(color: Color, size: int) -> ImageTexture:
	var img := Image.create(size, size, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	var center := Vector2(size * 0.5, size * 0.5)
	var radius := size * 0.42
	for y in size:
		for x in size:
			var p := Vector2(float(x) + 0.5, float(y) + 0.5)
			var d := p.distance_to(center)
			if d > radius:
				continue
			# Dégradé sphérique : clair en haut à gauche, sombre en bas.
			var shade := 1.15 - 0.5 * (p.y - center.y + radius) / (radius * 2.0)
			shade -= 0.15 * (p.x - center.x) / radius
			var col := _shade(color, clampf(shade, 0.45, 1.3))
			# Bord assombri pour détacher la pastille du fond.
			if d > radius - 1.2:
				col = _shade(col, 0.6)
			img.set_pixel(x, y, col)
	return ImageTexture.create_from_image(img)
