extends Node
## Icônes d'ARME rendues depuis le VRAI MODÈLE 3D (2026-08-02, demande de
## l'auteur : « je veux que l'icône des armes soit le modèle de l'arme »).
##
## POURQUOI. Les icônes venaient de PNG peints à la main (`item.sprites`,
## ancien pipeline sprite→3D). Depuis que les armes sont ASSEMBLÉES à partir de
## pièces — manche + tête, teintés par les matériaux du craft —, ces PNG ne
## représentent plus rien : une épée en granit noir et une épée en cuivre
## partageaient la même image, une hallebarde re-coupée gardait l'icône de
## l'ancienne, et le catalogue de pièces pouvait dériver sans que l'inventaire
## le montre. L'icône est désormais RENDUE depuis le modèle réellement porté :
## elle ne peut plus mentir, et une nouvelle arme n'a plus besoin de son PNG.
##
## MÊME MÉTHODE QUE `BlockPreview`, et pour les mêmes raisons : un SubViewport
## partagé, UN rendu par frame, résultat mis en cache. Un readback GPU par frame
## détruit le framerate (constaté le 2026-07-26 sur les icônes de bloc) — d'où
## la file d'attente plutôt qu'un rendu à la demande.
##
## L'appelant passe par `item_icon()` : il obtient le rendu 3D dès qu'il est
## prêt, et le sprite peint en attendant. Aucun écran n'a donc à savoir que le
## rendu est asynchrone.

## Côté du rendu, en pixels. Confortablement au-dessus de la plus grande case
## (52 px dans l'inventaire) : on réduit une icône sans dommage, on ne
## l'agrandit pas.
const ICON_SIZE := 96

## Présentation : l'arme est modélisée vers +Y, donc verticale. Une lame
## verticale dans une case carrée n'occupe qu'un huitième de la surface — on la
## couche en diagonale, et on la tourne légèrement pour que l'épaisseur du fer
## se voie. Sans ce quart de tour, une hache se lit comme un bâton.
const PRESENTATION := Vector3(-10.0, 26.0, -38.0)

var _viewport: SubViewport
var _pivot: Node3D
var _camera: Camera3D
var _cache := {}            # clé -> Texture2D
var _queue: Array[Dictionary] = []
var _queued := {}
var _busy := false
var _ready_setup := false


## Icône de `item`. Retourne le rendu 3D s'il est prêt, sinon le sprite peint
## (et enfile le rendu). Point d'entrée UNIQUE des interfaces : c'est ce qui
## permet de basculer tout le jeu sur les modèles sans toucher chaque écran.
func item_icon(item: Dictionary, material_choices: Dictionary, out_size: int = 48) -> Texture2D:
	if not item.has("parts"):
		# Outil de l'ancien pipeline, ou objet sans pièces : rien à rendre.
		return ToolSprite.item_icon(item, material_choices, out_size)
	var key := "%s|%s" % [item.get("id", ""), str(material_choices)]
	if _cache.has(key):
		return _cache[key]
	if not _queued.has(key):
		_queued[key] = true
		_queue.append({"key": key, "item": item, "materials": material_choices.duplicate()})
	return ToolSprite.item_icon(item, material_choices, out_size)


## Assemblage d'une arme à pièces : manche à l'origine, tête greffée à son
## sommet, le tout descendu du POINT DE PRISE pour que la main tombe au bon
## endroit. Retourne null si les pièces manquent.
##
## STATIQUE ET PARTAGÉE avec l'objet tenu (`held_item.gd`) : l'arme de
## l'inventaire et celle qu'on porte doivent être le même assemblage, sinon
## l'icône cesserait de représenter ce qu'on tient — exactement le défaut qu'on
## corrige ici.
static func assemble(item: Dictionary, material_choices: Dictionary) -> Node3D:
	var parts: Dictionary = item.get("parts", {})
	var handle: Dictionary = GameData.weapon_parts["manches"].get(String(parts.get("manche", "")), {})
	var head: Dictionary = GameData.weapon_parts["tetes"].get(String(parts.get("tete", "")), {})
	if handle.is_empty() and head.is_empty():
		return null
	var tint: Dictionary = item.get("sprite_tint", {})
	var handle_color := _material_color(material_choices, String(tint.get("manche", "bois")))
	var head_color := _material_color(material_choices, String(tint.get("tete", "minerai")))
	var length := float(handle.get("longueur", 0.0))
	var grip_offset := float(handle.get("grip_main", 0.3)) * length

	var root := Node3D.new()
	root.name = "Assemblage"
	var built := false
	if not handle.is_empty():
		built = _add_part(root, String(handle["model"]), Vector3(0.0, -grip_offset, 0.0), handle_color) or built
	if not head.is_empty():
		# La tête est modélisée à partir de y = 0 : c'est ici qu'elle monte au
		# sommet du manche (convention de generate_weapon_parts.py).
		built = _add_part(root, String(head["model"]), Vector3(0.0, length - grip_offset, 0.0), head_color) or built
	if not built:
		root.queue_free()
		return null
	return root


static func _add_part(root: Node3D, model_path: String, offset: Vector3, color: Color) -> bool:
	if model_path == "" or not ResourceLoader.exists(model_path):
		return false
	var scene: PackedScene = load(model_path)
	if scene == null:
		return false
	var instance := scene.instantiate()
	root.add_child(instance)
	instance.position = offset
	for node in mesh_children(instance):
		node.material_override = PlayerBody.tinted_material(color)
	return true


static func mesh_children(node: Node) -> Array[MeshInstance3D]:
	var out: Array[MeshInstance3D] = []
	if node is MeshInstance3D:
		out.append(node)
	for child in node.get_children():
		out.append_array(mesh_children(child))
	return out


static func _material_color(material_choices: Dictionary, category: String) -> Color:
	var mat_id: String = material_choices.get(category, "")
	var mat: Variant = GameData.materials.get(mat_id)
	if mat != null:
		return Color.html(mat["color"])
	return Color(0.6, 0.6, 0.6)


func _ready() -> void:
	set_process(true)


func _setup() -> bool:
	if _ready_setup:
		return true
	_viewport = SubViewport.new()
	_viewport.size = Vector2i(ICON_SIZE, ICON_SIZE)
	_viewport.transparent_bg = true
	_viewport.own_world_3d = true
	_viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	add_child(_viewport)

	# ÉCLAIRAGE PROPRE À L'ICÔNE. Les pièces portent un matériau à grain
	# (`PlayerBody.tinted_material`) qui réagit à la lumière : sans source, elles
	# sortiraient NOIRES. Une lumière rasante plus un fond ambiant donnent le
	# relief qui distingue une hache d'un bâton, ce qu'un rendu non éclairé
	# aplatirait en silhouette.
	var environment := WorldEnvironment.new()
	var env := Environment.new()
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.72, 0.74, 0.80)
	env.ambient_light_energy = 1.0
	environment.environment = env
	_viewport.add_child(environment)
	var sun := DirectionalLight3D.new()
	sun.light_energy = 1.1
	sun.rotation_degrees = Vector3(-38.0, -35.0, 0.0)
	_viewport.add_child(sun)

	_camera = Camera3D.new()
	_camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	_camera.current = true
	_viewport.add_child(_camera)

	_pivot = Node3D.new()
	_pivot.rotation_degrees = PRESENTATION
	_viewport.add_child(_pivot)
	_ready_setup = true
	return true


func _process(_delta: float) -> void:
	if _busy or _queue.is_empty():
		return
	if not _setup():
		return
	_busy = true
	_render_next()   # coroutine : libère _busy à la fin (1 rendu par frame)


func _render_next() -> void:
	var job: Dictionary = _queue.pop_front()
	_queued.erase(job["key"])
	for child in _pivot.get_children():
		_pivot.remove_child(child)
		child.queue_free()
	var assembly := assemble(job["item"], job["materials"])
	if assembly == null:
		_cache[job["key"]] = null
		_busy = false
		return
	_pivot.add_child(assembly)
	_frame_camera()
	_viewport.render_target_update_mode = SubViewport.UPDATE_ONCE
	# Deux frames, comme pour les icônes de bloc : la première dessine, la
	# seconde garantit que le UPDATE_ONCE est bien passé avant la lecture GPU.
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	var img := _viewport.get_texture().get_image()
	# GARDE-FOU : un rendu VIDE (modèle absent, caméra mal cadrée) ne doit pas
	# être mis en cache — l'arme deviendrait invisible dans tout le jeu et pour
	# toujours. On retombe alors sur le sprite peint.
	if img != null and _has_opaque(img):
		_cache[job["key"]] = ImageTexture.create_from_image(img)
	else:
		_cache[job["key"]] = null
	_busy = false


## Cadre la caméra sur l'arme RÉELLEMENT assemblée : chaque arme remplit sa
## case. Calculer l'étendue plutôt que de fixer une distance est ce qui permet
## à une dague de 38 cm et à une hallebarde de 2,12 m de rester lisibles dans la
## même vignette — et ce qui fait que re-couper une pièce ne dérègle rien.
func _frame_camera() -> void:
	var bounds := AABB()
	var first := true
	for mesh: MeshInstance3D in mesh_children(_pivot):
		var box := mesh.global_transform * mesh.get_aabb()
		bounds = box if first else bounds.merge(box)
		first = false
	if first:
		return
	var center := bounds.position + bounds.size * 0.5
	# 1,12 : une marge fine, juste assez pour que la pointe ne touche pas le
	# bord de la case.
	_camera.size = maxf(maxf(bounds.size.x, bounds.size.y), 0.05) * 1.12
	_camera.look_at_from_position(center + Vector3(0.0, 0.0, 4.0), center, Vector3.UP)


func _has_opaque(img: Image) -> bool:
	for y in range(0, img.get_height(), 4):
		for x in range(0, img.get_width(), 4):
			if img.get_pixel(x, y).a > 0.05:
				return true
	return false
