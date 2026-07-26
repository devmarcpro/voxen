class_name BlockIcon
extends RefCounted
## Icône de bloc en CUBE isométrique (2026-07-26) : 3 faces visibles (dessus
## clair, gauche moyen, droite sombre) façon inventaire Minecraft, à partir de
## la couleur d'un matériau. Rendu procédural en Image (pas de viewport).
## NOTE : approxime le bloc par sa COULEUR ombrée par face ; le détail de
## texture procédurale (pépites/grain) n'est pas reproduit ici (il faudrait un
## rendu par SubViewport — piste d'amélioration).

const _CACHE_MAX := 512
static var _cache := {}


static func cube_texture(color: Color, size: int = 22) -> ImageTexture:
	var key := "%d_%d" % [color.to_rgba32(), size]
	if _cache.has(key):
		return _cache[key]
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
	var tex := ImageTexture.create_from_image(img)
	if _cache.size() < _CACHE_MAX:
		_cache[key] = tex
	return tex


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
