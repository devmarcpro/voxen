extends Node
## Rendu d'ICÔNES DE BLOC texturées (2026-07-26) : un SubViewport rend un cube
## unitaire avec le VRAI matériau voxel (mêmes textures procédurales qu'en jeu ;
## les 3 faces sont déjà ombrées par face_shade). Chaque matériau est rendu une
## fois puis mis en cache (Texture2D). Utilisé par le menu créatif et la hotbar.
## Repli sur une vignette couleur (BlockIcon) tant que le rendu n'est pas prêt.

const ICON_SIZE := 64

var _viewport: SubViewport
var _mesh_instance: MeshInstance3D
var _material: ShaderMaterial
var _cache := {}            # rid (int) -> Texture2D
var _queue: Array[int] = []
var _queued := {}           # rid -> true (évite les doublons en file)
var _ready_setup := false
var _busy := false          # Un seul rendu à la fois (viewport/cube partagés).
var _diag_done := false      # Diagnostic imprimé une seule fois.
var _avatar_tex: Texture2D   # Icône du modèle du joueur (marqueur de carte).
var _avatar_rendering := false


## Icône du MODÈLE 3D du joueur (marqueur de carte). null tant que pas rendu.
func avatar_icon() -> Texture2D:
	if _avatar_tex != null:
		return _avatar_tex
	if not _avatar_rendering:
		_avatar_rendering = true
		_render_avatar()
	return null


func _render_avatar() -> void:
	var vp := SubViewport.new()
	vp.size = Vector2i(96, 96)
	vp.transparent_bg = true
	vp.own_world_3d = true
	vp.render_target_update_mode = SubViewport.UPDATE_DISABLED
	add_child(vp)
	var cam := Camera3D.new()
	cam.projection = Camera3D.PROJECTION_ORTHOGONAL
	cam.size = 2.4
	cam.look_at_from_position(Vector3(0, 1.0, 0) + Vector3(0.6, 0.35, 1.0).normalized() * 5.0,
		Vector3(0, 1.0, 0), Vector3.UP)
	cam.current = true
	vp.add_child(cam)
	vp.add_child(PlayerModel.build_instance())
	vp.render_target_update_mode = SubViewport.UPDATE_ONCE
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	var img := vp.get_texture().get_image()
	if img != null and _has_opaque(img):
		_avatar_tex = ImageTexture.create_from_image(img)
	vp.queue_free()
	_avatar_rendering = false


func _ready() -> void:
	set_process(true)


## Prépare le SubViewport + caméra iso + cube (paresseux : le matériau voxel
## n'existe qu'une fois un monde chargé).
func _setup() -> bool:
	if _ready_setup:
		return true
	var src: ShaderMaterial = WorldManager._material
	if src == null:
		return false
	_viewport = SubViewport.new()
	_viewport.size = Vector2i(ICON_SIZE, ICON_SIZE)
	_viewport.transparent_bg = true
	_viewport.own_world_3d = true
	_viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	add_child(_viewport)
	print("[BLOCKPREVIEW] setup OK (matériau voxel prêt).")

	var cam := Camera3D.new()
	cam.projection = Camera3D.PROJECTION_ORTHOGONAL
	cam.size = 1.75
	# Vue isométrique : regarde le cube (centré en 0.5,0.5,0.5) d'un coin haut.
	# look_at_from_position : ne nécessite PAS d'être dans l'arbre (bug corrigé —
	# l'appel look_at avant add_child échouait → caméra mal orientée → rendu vide).
	var cam_pos := Vector3(0.5, 0.5, 0.5) + Vector3(1.0, 0.82, 1.0).normalized() * 3.0
	cam.look_at_from_position(cam_pos, Vector3(0.5, 0.5, 0.5), Vector3.UP)
	cam.current = true
	_viewport.add_child(cam)

	_material = src.duplicate() as ShaderMaterial
	# Herbe : teinte neutre (blanc) — pas de biome pour une icône.
	var white := Image.create(1, 1, false, Image.FORMAT_RGB8)
	white.fill(Color.WHITE)
	_material.set_shader_parameter("grass_tint_map", ImageTexture.create_from_image(white))
	_material.set_shader_parameter("chunk_origin", Vector3.ZERO)

	_mesh_instance = MeshInstance3D.new()
	_viewport.add_child(_mesh_instance)
	_ready_setup = true
	return true


## Icône texturée du matériau `rid`, ou null si pas encore rendue (le repli
## couleur est géré par l'appelant). Enfile le rendu au besoin.
func icon(rid: int) -> Texture2D:
	if _cache.has(rid):
		return _cache[rid]
	if not _queued.has(rid):
		_queued[rid] = true
		_queue.append(rid)
	return null


func _process(_delta: float) -> void:
	if _busy or _queue.is_empty():
		return
	if not _setup():
		return
	_busy = true
	_render_next()  # coroutine ; libère _busy à la fin (1 rendu / frame).


func _render_next() -> void:
	var rid: int = _queue.pop_front()
	_queued.erase(rid)
	_mesh_instance.mesh = cube_mesh(rid)
	_mesh_instance.material_override = _material
	# Rendu du SubViewport puis capture. On laisse passer 2 frames pour être sûr
	# que le UPDATE_ONCE a bien été dessiné avant la lecture GPU.
	_viewport.render_target_update_mode = SubViewport.UPDATE_ONCE
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	var img := _viewport.get_texture().get_image()
	var opaque := img != null and _has_opaque(img)
	if not _diag_done:
		_diag_done = true
		var sz := "null" if img == null else "%dx%d" % [img.get_width(), img.get_height()]
		print("[BLOCKPREVIEW] 1er rendu rid=%d image=%s opaque=%s → %s" % [
			rid, sz, opaque, "TEXTURE" if opaque else "repli couleur"])
	# Garde-fou : si le rendu est VIDE, on retombe sur le cube couleur.
	if opaque:
		_cache[rid] = ImageTexture.create_from_image(img)
	else:
		_cache[rid] = _fallback(rid)
	_busy = false


## L'image contient-elle au moins un pixel opaque ? (échantillonnage).
func _has_opaque(img: Image) -> bool:
	var w := img.get_width()
	var h := img.get_height()
	for y in range(0, h, 4):
		for x in range(0, w, 4):
			if img.get_pixel(x, y).a > 0.05:
				return true
	return false


## Cube COULEUR de repli (BlockIcon) pour un matériau.
func _fallback(rid: int) -> Texture2D:
	var col := Color(0.6, 0.6, 0.6)
	if rid > 0 and rid < GameData.material_by_runtime.size():
		var mat: Dictionary = GameData.materials.get(GameData.material_by_runtime[rid], {})
		if mat.has("color"):
			col = Color.html(String(mat["color"]))
	return BlockIcon.cube_texture(col, ICON_SIZE)


## Cube unitaire [0,1]³ (24 sommets) : UV.x = id matériau (lu par le shader),
## UV.y = 0 (pas d'hôte). Chaque face couvre 0..1 en local → une tuile pleine.
static func cube_mesh(rid: int) -> ArrayMesh:
	var v := PackedVector3Array()
	var n := PackedVector3Array()
	var uv := PackedVector2Array()
	var idx := PackedInt32Array()
	var faces := [
		[Vector3(0, 1, 0), Vector3(1, 0, 0), Vector3(0, 0, 1)],   # +Y (dessus)
		[Vector3(1, 0, 0), Vector3(0, 0, 1), Vector3(0, 1, 0)],   # +X
		[Vector3(0, 0, 1), Vector3(1, 0, 0), Vector3(0, 1, 0)],   # +Z
		[Vector3(0, -1, 0), Vector3(1, 0, 0), Vector3(0, 0, 1)],  # -Y
		[Vector3(-1, 0, 0), Vector3(0, 0, 1), Vector3(0, 1, 0)],  # -X
		[Vector3(0, 0, -1), Vector3(1, 0, 0), Vector3(0, 1, 0)],  # -Z
	]
	var uvm := Vector2(float(rid), 0.0)
	for f: Array in faces:
		var nrm: Vector3 = f[0]
		var ta: Vector3 = f[1]
		var tb: Vector3 = f[2]
		# Centre de face + demi-arêtes → 4 coins.
		var center: Vector3 = Vector3(0.5, 0.5, 0.5) + nrm * 0.5
		var a := center - ta * 0.5 - tb * 0.5
		var b := center + ta * 0.5 - tb * 0.5
		var c := center + ta * 0.5 + tb * 0.5
		var d := center - ta * 0.5 + tb * 0.5
		var base := v.size()
		for p: Vector3 in [a, b, c, d]:
			v.append(p)
			n.append(nrm)
			uv.append(uvm)
		# DOUBLE winding (les deux sens) → la face visible n'est jamais cullée,
		# quel que soit l'ordre attendu par le renderer (icône fiable).
		idx.append_array([base, base + 1, base + 2, base, base + 2, base + 3])
		idx.append_array([base, base + 2, base + 1, base, base + 3, base + 2])
	var arr := []
	arr.resize(Mesh.ARRAY_MAX)
	arr[Mesh.ARRAY_VERTEX] = v
	arr[Mesh.ARRAY_NORMAL] = n
	arr[Mesh.ARRAY_TEX_UV] = uv
	arr[Mesh.ARRAY_INDEX] = idx
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
	return mesh
