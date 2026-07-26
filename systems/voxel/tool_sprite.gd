class_name ToolSprite
extends RefCounted
## Outils « sprite → 3D » (2026-07-26) : deux calques 2D (MANCHE + TÊTE) teintés
## par les matériaux du craft (manche = bois, tête = minerai), la tête posée
## PAR-DESSUS le manche, puis EXTRUDÉS en un modèle 3D façon Minecraft (chaque
## pixel opaque → une petite dalle de cube, faces latérales sur la silhouette).
##
## Format des PNG fournis par l'utilisateur (assets/tools/) : pixel-art sur fond
## TRANSPARENT ; la couleur du pixel est MULTIPLIÉE par la couleur du matériau
## (blanc = teinte pure du matériau, gris = ombrage conservé). Résolution libre
## (16×16 ou 32×32), manche et tête de MÊME taille.

const PIXEL := 0.03   # Taille monde d'un pixel de sprite.
const DEPTH := 0.03   # Épaisseur d'extrusion.
const SIDE_SHADE := 0.8  # Assombrissement des faces latérales (volume).

static var _img_cache := {}


## Icône 2D d'un OUTIL (2026-07-26) : composite manche+tête teintés par les
## matériaux du craft, agrandi à `out_size` (nearest). Pour inventaire/hotbar/
## créatif → l'outil a l'apparence d'un outil, pas d'un bloc. null si pas de
## sprites définis.
static var _icon_cache := {}
static func item_icon(item: Dictionary, material_choices: Dictionary, out_size: int = 48) -> Texture2D:
	var sprites: Dictionary = item.get("sprites", {})
	if sprites.is_empty():
		return null
	var key := "%s|%s|%d" % [item.get("id", ""), str(material_choices), out_size]
	if _icon_cache.has(key):
		return _icon_cache[key]
	var handle := load_sprite(String(sprites.get("manche", "")))
	var head := load_sprite(String(sprites.get("tete", "")))
	if handle == null and head == null:
		return null
	var tint: Dictionary = item.get("sprite_tint", {})
	var hc := _mat_color(material_choices, String(tint.get("manche", "bois")))
	var tc := _mat_color(material_choices, String(tint.get("tete", "minerai")))
	var w := 0
	var h := 0
	for img in [handle, head]:
		if img != null:
			w = maxi(w, img.get_width())
			h = maxi(h, img.get_height())
	var src := Image.create(w, h, false, Image.FORMAT_RGBA8)
	for y in h:
		for x in w:
			var c := _tinted(handle, x, y, hc)
			var ch := _tinted(head, x, y, tc)
			if ch.a > 0.0:
				c = ch
			src.set_pixel(x, y, c)
	src.resize(out_size, out_size, Image.INTERPOLATE_NEAREST)
	var tex := ImageTexture.create_from_image(src)
	_icon_cache[key] = tex
	return tex


static func _mat_color(material_choices: Dictionary, category: String) -> Color:
	var mat_id: String = material_choices.get(category, "")
	var mat: Variant = GameData.materials.get(mat_id)
	if mat != null:
		return Color.html(mat["color"])
	return Color(0.6, 0.6, 0.6)


## Charge un PNG de sprite (cache). Retourne null si absent.
static func load_sprite(path: String) -> Image:
	if _img_cache.has(path):
		return _img_cache[path]
	var img: Image = null
	if path != "" and ResourceLoader.exists(path):
		var tex: Texture2D = load(path)
		if tex != null:
			img = tex.get_image()
	elif path != "" and FileAccess.file_exists(path):
		img = Image.load_from_file(path)
	if img != null and img.get_format() != Image.FORMAT_RGBA8:
		img.convert(Image.FORMAT_RGBA8)
	_img_cache[path] = img
	return img


## Compose (tête sur manche) + teinte + extrude → ArrayMesh centré. `handle` et
## `head` peuvent être null (calque absent). Couleurs = matériaux du craft.
static func build_mesh(handle: Image, head: Image, handle_col: Color, head_col: Color) -> ArrayMesh:
	var w := 0
	var h := 0
	for img in [handle, head]:
		if img != null:
			w = maxi(w, img.get_width())
			h = maxi(h, img.get_height())
	if w == 0 or h == 0:
		return null

	# Grille composée : couleur finale par pixel (la tête gagne si opaque).
	var cols := PackedColorArray()
	cols.resize(w * h)
	for y in h:
		for x in w:
			var c := _tinted(handle, x, y, handle_col)
			var ch := _tinted(head, x, y, head_col)
			if ch.a > 0.0:
				c = ch
			cols[y * w + x] = c

	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var hz := DEPTH * 0.5
	var ox := -w * PIXEL * 0.5
	var oy := h * PIXEL * 0.5
	for y in h:
		for x in w:
			var col := cols[y * w + x]
			if col.a <= 0.0:
				continue
			var x0 := ox + x * PIXEL
			var x1 := x0 + PIXEL
			var y0 := oy - y * PIXEL      # haut du pixel
			var y1 := y0 - PIXEL          # bas du pixel
			# Faces avant (+Z) et arrière (−Z).
			_quad(st, col, Vector3(0, 0, 1),
				Vector3(x0, y0, hz), Vector3(x1, y0, hz), Vector3(x1, y1, hz), Vector3(x0, y1, hz))
			_quad(st, col, Vector3(0, 0, -1),
				Vector3(x1, y0, -hz), Vector3(x0, y0, -hz), Vector3(x0, y1, -hz), Vector3(x1, y1, -hz))
			# Faces latérales seulement sur les bords de silhouette (voisin vide).
			var side := Color(col.r * SIDE_SHADE, col.g * SIDE_SHADE, col.b * SIDE_SHADE, 1.0)
			if _empty(cols, w, h, x - 1, y):  # gauche (−X)
				_quad(st, side, Vector3(-1, 0, 0),
					Vector3(x0, y0, -hz), Vector3(x0, y0, hz), Vector3(x0, y1, hz), Vector3(x0, y1, -hz))
			if _empty(cols, w, h, x + 1, y):  # droite (+X)
				_quad(st, side, Vector3(1, 0, 0),
					Vector3(x1, y0, hz), Vector3(x1, y0, -hz), Vector3(x1, y1, -hz), Vector3(x1, y1, hz))
			if _empty(cols, w, h, x, y - 1):  # haut (+Y)
				_quad(st, side, Vector3(0, 1, 0),
					Vector3(x0, y0, -hz), Vector3(x1, y0, -hz), Vector3(x1, y0, hz), Vector3(x0, y0, hz))
			if _empty(cols, w, h, x, y + 1):  # bas (−Y)
				_quad(st, side, Vector3(0, -1, 0),
					Vector3(x0, y1, hz), Vector3(x1, y1, hz), Vector3(x1, y1, -hz), Vector3(x0, y1, -hz))
	return st.commit()


## Pixel teinté (couleur du sprite × couleur du matériau), ou transparent.
static func _tinted(img: Image, x: int, y: int, tint: Color) -> Color:
	if img == null or x >= img.get_width() or y >= img.get_height():
		return Color(0, 0, 0, 0)
	var p := img.get_pixel(x, y)
	if p.a <= 0.0:
		return Color(0, 0, 0, 0)
	return Color(p.r * tint.r, p.g * tint.g, p.b * tint.b, 1.0)


static func _empty(cols: PackedColorArray, w: int, h: int, x: int, y: int) -> bool:
	if x < 0 or y < 0 or x >= w or y >= h:
		return true
	return cols[y * w + x].a <= 0.0


## Ajoute un quad (2 triangles) avec une couleur et une normale uniformes.
static func _quad(st: SurfaceTool, col: Color, n: Vector3, a: Vector3, b: Vector3, c: Vector3, d: Vector3) -> void:
	for v in [a, b, c, a, c, d]:
		st.set_color(col)
		st.set_normal(n)
		st.add_vertex(v)
