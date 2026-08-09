extends MeshInstance3D
## Objet en main (première personne, étape D.3.5) : outil = modèle .vox avec
## couleurs stand-in remappées vers les matériaux du craft (9.1) ; matériau =
## petit cube à la couleur du bloc. Purement visuel (enfant de la caméra).

const TOOL_POSITION := Vector3(0.38, -0.32, -0.6)
const BLOCK_POSITION := Vector3(0.52, -0.42, -0.72)  # bloc : plus à DROITE et bas.
const HELD_SCALE := 0.6
const BLOCK_HELD_SCALE := 0.24                        # cube [0,1] → petit (avant : trop gros).

## PORTÉ PAR LA MAIN (2026-07-28) : depuis que le joueur a un corps visible,
## cet objet est reparenté sur le BoneAttachment3D de l'os `attach_arme` au
## lieu d'être un viewmodel accroché à la caméra. Un objet flottant devant
## l'objectif se verrait immédiatement comme faux à côté d'un vrai bras.
## Les offsets ci-dessous sont donc exprimés en espace MAIN, pas en espace
## caméra — d'où deux jeux de constantes plutôt qu'un.
const HAND_TOOL_POSITION := Vector3(0.0, 0.06, 0.0)
const HAND_BLOCK_POSITION := Vector3(0.0, 0.04, 0.0)
const HAND_ROTATION := Vector3(0.0, -90.0, 0.0)
const CAMERA_ROTATION := Vector3(0.0, -100.0, -8.0)
## Échelle en MAIN. `HELD_SCALE` avait été calibrée pour un viewmodel posé à
## 60 cm de l'objectif : réutilisée telle quelle sur l'os de la main, l'outil
## apparaissait démesuré (constaté en jeu le 2026-07-28). Une main mesure
## ~6 px du gabarit, l'outil doit rester à sa taille d'objet du monde.
## VALEUR À AFFINER À L'ŒIL — aucune sonde ne peut juger d'un cadrage.
## ToolSprite construit deja l'outil A SA TAILLE REELLE : PIXEL = 0.03 unite
## par pixel de sprite, donc un sprite 32 px ~ 1 bloc. L'echelle en main doit
## donc rester proche de 1 — 0.26 rapetissait l'outil a 25 cm (corrige le
## 2026-07-28). `HELD_SCALE` 0.6 restait coherent pour un VIEWMODEL, ou un
## objet plus petit parait grand parce qu'il est colle a l'objectif.
## AGRANDIE FORTEMENT (demande explicite du 2026-07-28). A l'echelle 1 —
## la taille reelle produite par ToolSprite — l'arme paraissait maigre a
## l'ecran : tenue au bout d'un bras, elle est loin de l'oeil et occupe peu
## de champ. Le rendu prime ici sur le realisme metrique.
## Echelle des OUTILS A SPRITE en main (ancien pipeline) : agrandie a la
## demande de l'auteur, un sprite extrude paraissant maigre au bout du bras.
const HAND_SCALE := 2.4
const HAND_BLOCK_SCALE := 0.9
## Echelle des ARMES A PIECES. Elles sont modelisees A TAILLE REELLE (un
## manche de pique fait 2,19 blocs) : leur appliquer le x2,4 des sprites
## produisait une arme de plus de 5 blocs, hors cadre et coupee par le plan
## rapproche de la camera — d'ou une arme INVISIBLE en jeu (2026-07-28).
## Legerement au-dessus de 1 pour la lisibilite, pas davantage.
const PART_SCALE := 1.15
## Les pieces sont modelisees vers +Y (pointe en haut), mais les OS du
## gabarit pointent vers -Y : greffee telle quelle sur la main, la lame
## repartait dans le bras et l'arme etait INVISIBLE a l'ecran
## (2026-07-28). Ce demi-tour la fait prolonger la main vers l'avant.
const PART_ROTATION := Vector3(180.0, 0.0, 0.0)
## Posé par main.gd juste après le reparentage. Faux = ancien viewmodel
## (aucun corps disponible : le modèle manque, ou vue sans corps).
var in_hand := false
## Vrai si l'objet tenu est une arme ASSEMBLEE (manche + tete). Seules
## celles-la sont orientees par l'axe de visee : les outils a sprite sont
## construits sur un autre axe et seraient mis de travers.
var is_part_weapon := false

## D'OÙ vient l'objet à afficher. La hotbar par défaut ; « main_gauche » pour
## l'exemplaire accroché à la main gauche, qui suit l'ÉQUIPEMENT et non
## l'emplacement sélectionné. Sans cette distinction, le bouclier se serait
## reconstruit à chaque changement d'objet en main et aurait clignoté.
##
## « explicite » (2026-08-02) : l'entrée est POSÉE par l'appelant dans
## `explicit_entry` au lieu d'être lue sur le joueur. C'est ce qui permet aux
## OBJETS AU SOL (DropManager) de réutiliser tel quel tout le pipeline de rendu
## d'objet — pièces d'arme assemblées, extrusion de sprites, .vox remappé, cube
## de matériau — au lieu d'en écrire une seconde version qui divergerait au
## premier ajout de type d'objet.
var source := "hotbar"
## Entrée affichée quand `source == "explicite"`. Voir ci-dessus.
var explicit_entry := {}

var _player: Node
var _current_key := ""
var _shader: Shader = preload("res://scenes/world/vox_item.gdshader")


func _ready() -> void:
	# Recherche ROBUSTE au parent : ce nœud change de parent au démarrage
	# (caméra -> os de la main), donc un chemin relatif en dur devenait faux.
	_player = get_tree().current_scene.get_node_or_null("Player")
	# Porte par la main : l'outil projette son ombre comme tout objet du
	# monde ; en viewmodel elle etait coupee (l'objet n'existait pas vraiment).
	if in_hand:
		cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	else:
		cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	rotation_degrees = HAND_ROTATION if in_hand else CAMERA_ROTATION
	scale = Vector3.ONE * (HAND_SCALE if in_hand else HELD_SCALE)


func _process(_delta: float) -> void:
	# La source explicite n'a PAS besoin du joueur : un objet au sol existe
	# indépendamment de lui (et peut vivre dans une dimension où il n'est pas).
	if _player == null and source != "explicite":
		return
	var entry: Dictionary = _source_entry()
	var key := ""
	match entry.get("kind", ""):
		"object":
			var obj: Dictionary = entry["object"]
			# `get` et non l'accès direct : une RESSOURCE (viande, peau) est une
			# instance sans matériaux de craft — l'accès brut plantait dès
			# qu'on en prenait une en main (2026-07-27).
			key = "obj:%s:%s" % [obj.get("item_id", ""), obj.get("materials", obj.get("resource_id", ""))]
		"material":
			key = "mat:" + String(entry["id"])
	if key == _current_key:
		return
	_current_key = key
	_rebuild(entry)


## Entrée à afficher selon la source. Une main gauche sans bouclier reçoit une
## entrée VIDE, que `_rebuild` traduit déjà en « rien à montrer ».
func _source_entry() -> Dictionary:
	if source == "explicite":
		return explicit_entry
	if source == "main_gauche":
		# La main gauche porte un BOUCLIER ou une SECONDE ARME (dual wielding,
		# 2026-08-02) — jamais les deux, l'emplacement est le même. Elle suit
		# l'ÉQUIPEMENT et non la hotbar : c'est ce qui permet de garder au
		# bouclier tout en changeant d'outil en main forte.
		var shield: Dictionary = _player.equipped_shield()
		if not shield.is_empty():
			return {"kind": "object", "object": shield}
		var offhand: Dictionary = _player.offhand_weapon()
		return {} if offhand.is_empty() else {"kind": "object", "object": offhand}
	var entry: Dictionary = _player.held_entry()
	# L'ENTRÉE DE COMBAT MONTRE L'ARME ÉQUIPÉE (2026-08-09, signalé en jeu : « le
	# slot combat est toujours à mains nues même quand on a une arme équipée »).
	#
	# Le genre "combat" ne tombait dans AUCUNE branche d'affichage : ni le calcul
	# de clé ni `_rebuild` ne le connaissaient, si bien que la main restait vide
	# et que la clé valait "" — la même que « rien en main ». Deux conséquences,
	# et la seconde est la pire : non seulement l'arme ne s'affichait pas, mais
	# passer du combat à une case vide ne changeait pas la clé, donc ne
	# reconstruisait rien. La mécanique, elle, tenait bon — portée et dégâts
	# venaient bien de l'arme équipée. Seul le MODÈLE manquait, ce qui est
	# exactement le genre de panne qui ne se voit qu'en jouant.
	#
	# On traduit ICI et pas dans `held_entry()` : le reste du jeu a besoin de
	# savoir qu'on est en POSTURE de combat, ce que « un objet en main » ne dit
	# pas. Seul l'affichage veut voir une arme.
	if String(entry.get("kind", "")) == "combat":
		var armed: Dictionary = entry.get("object", {})
		# Mains nues : rien à dessiner. Ce sont les bras du corps qui parlent.
		return {} if armed.is_empty() else {"kind": "object", "object": armed}
	return entry


func _rebuild(entry: Dictionary) -> void:
	scale = Vector3.ONE * (HAND_SCALE if in_hand else HELD_SCALE)  # défaut (la branche bloc réduit ensuite).
	match entry.get("kind", ""):
		"object":
			var obj: Dictionary = entry["object"]
			var item: Dictionary = GameData.items.get(obj.get("item_id", ""), {})
			var obj_materials: Dictionary = obj.get("materials", {})
			# Ressource tenue en main : aucun modèle 3D (ce n'est ni un outil
			# ni un bloc). Rien à afficher tant qu'il n'y a pas de visuel dédié.
			if obj.has("resource_id"):
				visible = false
				return
			# PIÈCES 3D (2026-07-28) : manche + tête, deux vrais modèles
			# assemblés. Prioritaire sur l'extrusion de sprites, qui reste le
			# repli des outils n'ayant pas encore de pièces.
			is_part_weapon = false
			if item.has("parts") and _build_part_weapon(item, obj_materials, obj):
				is_part_weapon = true
				scale = Vector3.ONE * (PART_SCALE if in_hand else HELD_SCALE)
				rotation_degrees = PART_ROTATION if in_hand else CAMERA_ROTATION
				position = HAND_TOOL_POSITION if in_hand else TOOL_POSITION
				visible = true
				return
			# Ancien pipeline sprite→3D (2026-07-26) si l'objet définit `sprites`
			# (manche + tête teintés par bois/minerai, extrudés) ; sinon .vox.
			if item.has("sprites") and _build_sprite_tool(item, obj_materials):
				position = HAND_TOOL_POSITION if in_hand else TOOL_POSITION
				visible = true
				return
			# LIVRES (5.1) : ni pièces, ni sprites, ni .vox — ils n'ont pas de
			# modèle et n'en auront pas tant qu'un asset n'existe pas. Une forme
			# procédurale suffit à les rendre reconnaissables au sol, ce qui est
			# tout ce qu'on leur demande.
			if BookFactory.is_book(obj):
				_build_book(obj)
				position = HAND_TOOL_POSITION if in_hand else TOOL_POSITION
				visible = true
				return
			# CHEMIN VIDE = PAS DE MODÈLE, et surtout pas un appel au chargeur.
			# `item.get("vox_model", "")` rend "" pour tout objet sans modèle ;
			# VoxLoader préfixe alors "res://" et pousse une erreur « fichier
			# introuvable « res:// » » — à CHAQUE reconstruction, donc en boucle
			# pour un objet posé au sol. Constaté en jeu réel le 2026-08-03.
			var vox_path := String(item.get("vox_model", ""))
			if vox_path.is_empty():
				visible = false
				return
			var model := VoxLoader.load_model(vox_path)
			if model.is_empty():
				visible = false
				return
			mesh = VoxLoader.build_mesh(model)
			var vox_slots: Dictionary = item.get("vox_slots", {})
			material_override = _build_remapped_material(model, obj_materials, vox_slots)
			position = HAND_TOOL_POSITION if in_hand else TOOL_POSITION
			visible = true
		"material":
			# Bloc en main TEXTURÉ (2026-07-26) : cube avec le vrai matériau voxel
			# (mêmes textures procédurales qu'en jeu, 3 faces ombrées par face_shade).
			var rid: int = GameData.material_runtime_ids.get(entry["id"], 0)
			mesh = BlockPreview.cube_mesh(rid)
			material_override = _block_material()
			scale = Vector3.ONE * (HAND_BLOCK_SCALE if in_hand else BLOCK_HELD_SCALE)
			# Cube [0,1] → recentré sur BLOCK_POSITION (compense le décalage du
			# coin d'origine via la base locale, rotation+échelle incluses).
			var anchor := HAND_BLOCK_POSITION if in_hand else BLOCK_POSITION
			position = anchor - basis * Vector3(0.5, 0.5, 0.5)
			visible = true
		_:
			visible = false


## Forme procédurale d'un LIVRE : un parallélépipède aplati, teinté selon son
## type. Pas d'asset à produire, et le grimoire se distingue du manuel au premier
## coup d'œil — ce qui est la seule chose qui compte pour du butin au sol.
func _build_book(obj: Dictionary) -> void:
	for child in get_children():
		child.queue_free()
	var box := BoxMesh.new()
	box.size = Vector3(0.22, 0.05, 0.30)   # proportions d'un livre fermé
	mesh = box
	var mat := StandardMaterial3D.new()
	# Grimoire : bleu arcane. Manuel de combat : cuir fauve. Les deux teintes
	# viennent des mêmes familles que les modules qu'ils contiennent.
	var grimoire := String(obj.get("book_type", "grimoire")) == "grimoire"
	mat.albedo_color = Color(0.28, 0.32, 0.62) if grimoire else Color(0.46, 0.30, 0.17)
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material_override = mat
	scale = Vector3.ONE * (HAND_SCALE if in_hand else HELD_SCALE)


## Assemble l'arme à partir de ses PIÈCES 3D : le manche à l'origine, la tête
## greffée à son sommet. Les deux sont teintés par les matériaux choisis au
## craft — le modèle lui-même ne porte aucune couleur, sinon tout le système de
## matériaux s'effondrerait.
##
## Deux nœuds enfants plutôt qu'un maillage fusionné : chaque pièce garde son
## matériau (bois vs métal), et une tête sectionnée ou lâchée pourra plus tard
## être détachée sans reconstruire quoi que ce soit.
func _build_part_weapon(item: Dictionary, material_choices: Dictionary,
		instance: Dictionary = {}) -> bool:
	var parts: Dictionary = item["parts"]
	var handle: Dictionary = GameData.weapon_parts["manches"].get(String(parts.get("manche", "")), {})
	var head: Dictionary = GameData.weapon_parts["tetes"].get(String(parts.get("tete", "")), {})
	if handle.is_empty() and head.is_empty():
		return false
	mesh = null
	for child in get_children():
		child.queue_free()

	var length := float(handle.get("longueur", 0.0))
	# L'arme est tenue par son POINT DE PRISE, pas par le bout du manche :
	# l'assemblage est descendu de cette hauteur pour que la main tombe au bon
	# endroit. Sur une pique (prise à 12 % de la base) le manche dépasse donc
	# largement derrière la main — ce qui est exactement le geste réel.
	var grip_offset := float(handle.get("grip_main", 0.3)) * length
	# ASSEMBLAGE PARTAGÉ avec l'icône d'inventaire (2026-08-02). L'arme qu'on
	# VOIT dans sa case et celle qu'on TIENT sortent de la même fonction : c'est
	# la seule façon que l'icône ne puisse pas mentir sur ce qu'on porte.
	var assembly := WeaponPreview.assemble(item, material_choices)
	var built := assembly != null
	if built:
		add_child(assembly)
		for node in _mesh_children(assembly):
			node.cast_shadow = cast_shadow
	# GEMME SERTIE : à la jonction manche/tête, là où une vraie arme place son
	# pommeau ou sa garde ornée. C'est aussi le seul point commun à toutes les
	# armes, quelle que soit la pièce montée — pas besoin d'un point d'ancrage
	# par modèle.
	if built:
		_add_gem(instance, length - grip_offset)
	return built


## Taille de la pierre taillée, en blocs (32 px = 1 bloc, donc ~2,5 px de côté).
## Assez grosse pour se voir au bout du bras, assez petite pour ne pas ressembler
## à un caillou collé sur l'arme.
## 0,11 : à 0,08 la pierre se voyait sur la capture mais restait un détail qu'on
## rate en jeu. Elle doit se lire d'un coup d'œil, c'est tout son intérêt.
const GEM_SIZE := 0.11


func _add_gem(instance: Dictionary, junction_y: float) -> void:
	var gem_id := String(instance.get("gem", ""))
	if gem_id == "":
		return
	var gem := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = Vector3.ONE * GEM_SIZE
	gem.mesh = box
	# Pivotée sur deux axes : une pierre TAILLÉE présente une pointe, pas une
	# face. Un cube aligné se lirait comme un bloc du monde posé sur l'arme.
	gem.rotation = Vector3(deg_to_rad(45.0), 0.0, deg_to_rad(45.0))
	gem.position = Vector3(0.0, junction_y, 0.0)
	gem.cast_shadow = cast_shadow
	gem.material_override = _gem_material(Color.html(String(instance.get("gem_color", "#FFFFFF"))))
	add_child(gem)


## La gemme est le SEUL élément émissif de l'arme. C'est délibéré : le joueur
## doit repérer d'un coup d'œil qu'une arme est sertie, y compris de nuit, et le
## rendu du jeu est non éclairé (`unshaded`) — sans émission, la pierre serait
## une facette mate indiscernable du métal.
static var _gem_materials := {}


static func _gem_material(color: Color) -> StandardMaterial3D:
	var key := color.to_html(false)
	if _gem_materials.has(key):
		return _gem_materials[key]
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.emission_enabled = true
	mat.emission = color
	mat.emission_energy_multiplier = 1.6
	_gem_materials[key] = mat
	return mat




func _mesh_children(node: Node) -> Array[MeshInstance3D]:
	var out: Array[MeshInstance3D] = []
	if node is MeshInstance3D:
		out.append(node)
	for child in node.get_children():
		out.append_array(_mesh_children(child))
	return out


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
