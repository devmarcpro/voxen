extends MeshInstance3D
## Objet en main (première personne, étape D.3.5) : outil = modèle .vox avec
## couleurs stand-in remappées vers les matériaux du craft (9.1) ; matériau =
## petit cube à la couleur du bloc. Purement visuel (enfant de la caméra).

const TOOL_POSITION := Vector3(0.38, -0.32, -0.6)
const BLOCK_POSITION := Vector3(0.52, -0.42, -0.72)  # bloc : plus à DROITE et bas.
const HELD_SCALE := 0.6
const BLOCK_HELD_SCALE := 0.24                        # cube [0,1] → petit (avant : trop gros).

var _player: Node
var _current_key := ""
var _shader: Shader = preload("res://scenes/world/vox_item.gdshader")


func _ready() -> void:
	_player = get_node_or_null("../../Player")
	cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	rotation_degrees = Vector3(0.0, -100.0, -8.0)
	scale = Vector3.ONE * HELD_SCALE


func _process(_delta: float) -> void:
	if _player == null:
		return
	var entry: Dictionary = _player.held_entry()
	var key := ""
	match entry.get("kind", ""):
		"object":
			var obj: Dictionary = entry["object"]
			key = "obj:%s:%s" % [obj["item_id"], obj["materials"]]
		"material":
			key = "mat:" + String(entry["id"])
	if key == _current_key:
		return
	_current_key = key
	_rebuild(entry)


func _rebuild(entry: Dictionary) -> void:
	scale = Vector3.ONE * HELD_SCALE  # défaut (la branche bloc réduit ensuite).
	match entry.get("kind", ""):
		"object":
			var obj: Dictionary = entry["object"]
			var item: Dictionary = GameData.items.get(obj["item_id"], {})
			# Nouveau pipeline sprite→3D (2026-07-26) si l'objet définit `sprites`
			# (manche + tête teintés par bois/minerai, extrudés) ; sinon .vox.
			if item.has("sprites") and _build_sprite_tool(item, obj["materials"]):
				position = TOOL_POSITION
				visible = true
				return
			var model := VoxLoader.load_model(String(item.get("vox_model", "")))
			if model.is_empty():
				visible = false
				return
			mesh = VoxLoader.build_mesh(model)
			var vox_slots: Dictionary = item.get("vox_slots", {})
			material_override = _build_remapped_material(model, obj["materials"], vox_slots)
			position = TOOL_POSITION
			visible = true
		"material":
			# Bloc en main TEXTURÉ (2026-07-26) : cube avec le vrai matériau voxel
			# (mêmes textures procédurales qu'en jeu, 3 faces ombrées par face_shade).
			var rid: int = GameData.material_runtime_ids.get(entry["id"], 0)
			mesh = BlockPreview.cube_mesh(rid)
			material_override = _block_material()
			scale = Vector3.ONE * BLOCK_HELD_SCALE
			# Cube [0,1] → recentré sur BLOCK_POSITION (compense le décalage du
			# coin d'origine via la base locale, rotation+échelle incluses).
			position = BLOCK_POSITION - basis * Vector3(0.5, 0.5, 0.5)
			visible = true
		_:
			visible = false


## Construit l'outil par extrusion de sprites (manche + tête). Retourne false
## si les PNG sont absents (repli .vox). `sprite_tint` associe chaque calque à
## la CATÉGORIE de matériau qui le teinte (manche=bois, tête=minerai).
func _build_sprite_tool(item: Dictionary, material_choices: Dictionary) -> bool:
	var sprites: Dictionary = item["sprites"]
	var tint: Dictionary = item.get("sprite_tint", {})
	var handle := ToolSprite.load_sprite(String(sprites.get("manche", "")))
	var head := ToolSprite.load_sprite(String(sprites.get("tete", "")))
	if handle == null and head == null:
		return false
	var handle_col := _material_color(material_choices, String(tint.get("manche", "bois")))
	var head_col := _material_color(material_choices, String(tint.get("tete", "minerai")))
	var built := ToolSprite.build_mesh(handle, head, handle_col, head_col)
	if built == null:
		return false
	mesh = built
	var std := StandardMaterial3D.new()
	std.vertex_color_use_as_albedo = true
	std.roughness = 1.0
	std.cull_mode = BaseMaterial3D.CULL_DISABLED
	material_override = std
	return true


## Matériau voxel pour le bloc en main (dupliqué une fois, teinte d'herbe
## neutre + origine de chunk 0 pour une tuile propre).
var _cached_block_material: ShaderMaterial
func _block_material() -> ShaderMaterial:
	if _cached_block_material != null:
		return _cached_block_material
	if WorldManager._material == null:
		return null
	_cached_block_material = WorldManager._material.duplicate() as ShaderMaterial
	var white := Image.create(1, 1, false, Image.FORMAT_RGB8)
	white.fill(Color.WHITE)
	_cached_block_material.set_shader_parameter("grass_tint_map", ImageTexture.create_from_image(white))
	_cached_block_material.set_shader_parameter("chunk_origin", Vector3.ZERO)
	return _cached_block_material


## Couleur du matériau choisi au craft pour une catégorie (défaut gris).
func _material_color(material_choices: Dictionary, category: String) -> Color:
	var mat_id: String = material_choices.get(category, "")
	var mat: Variant = GameData.materials.get(mat_id)
	if mat != null:
		return Color.html(mat["color"])
	return Color(0.6, 0.6, 0.6)


## Palette 256 de l'instance : couleurs du .vox, avec les index stand-in
## remplacés par la couleur du matériau choisi au craft (9.1) — et leur bruit
## (amplitude/seed du matériau) pour le grain 2×2 px par voxel.
## `vox_slots` (B.3, propre à l'objet) associe chaque hex stand-in à la
## CATÉGORIE de matériau qu'il représente pour CET objet (ex. "#00FF00" →
## "bois" pour une pioche) — les couleurs elles-mêmes ne sont que des slots
## génériques 1-4 réutilisables par tout objet (12.1/9.1).
func _build_remapped_material(model: Dictionary, material_choices: Dictionary, vox_slots: Dictionary) -> ShaderMaterial:
	var palette: PackedColorArray = model["palette"]
	var stand_ins: Dictionary = model["stand_ins"]  # index -> hex
	var palette_img := Image.create_empty(256, 1, false, Image.FORMAT_RGBA8)
	var noise_img := Image.create_empty(256, 1, false, Image.FORMAT_RGBAF)
	for index in range(1, 257):
		var color := palette[index]
		var noise := Color(0, 0, 0, 0)
		if stand_ins.has(index):
			var hex: String = stand_ins[index]
			var category: String = String(vox_slots.get(hex, ""))
			var mat_id: String = material_choices.get(category, "")
			var mat: Variant = GameData.materials.get(mat_id)
			if mat != null:
				color = Color.html(mat["color"])
				noise = Color(float(mat["noise"]["amplitude"]), 0.0, float(mat["noise"]["seed_offset"]), 0.0)
		if index <= 255:
			palette_img.set_pixel(index, 0, color)
			noise_img.set_pixel(index, 0, noise)
	var shader_mat := ShaderMaterial.new()
	shader_mat.shader = _shader
	shader_mat.set_shader_parameter("palette", ImageTexture.create_from_image(palette_img))
	shader_mat.set_shader_parameter("noise_params", ImageTexture.create_from_image(noise_img))
	return shader_mat
