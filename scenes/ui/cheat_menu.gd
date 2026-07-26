extends CanvasLayer
## Menu de triche (debug/test uniquement, jamais en build release — voir
## OS.is_debug_build(), même garde-fou que le hot-reload F5 de GameData) :
## téléportation par biome choisi, téléportation au village/donjon le plus
## proche, tous les matériaux/objets, compétences maximisées. Touche F1.
##
## Construit entièrement en code (même style que world_map_view.gd) — pas de
## .tscn dédié, juste ce script attaché à un CanvasLayer vide dans main.tscn.

## BUG RÉEL CORRIGÉ (2026-07-21, retour utilisateur : « pas de biome glaciaire
## trouvé ») : la calotte glaciaire n'existe qu'à proximité des "pôles"
## climatiques (température = fonction de Z, période LATITUDE_HALF_PERIOD =
## 12 000 blocs, NoiseGenerator) — un rayon de recherche de 6 400 blocs (ancien
## réglage, hérité de la sonde de diagnostic dont l'usage est différent) ne
## pouvait tout simplement JAMAIS l'atteindre. Élargi pour couvrir plus d'une
## période complète.
const TELEPORT_STEP := 128
const MAX_RING := 250          # ±32 000 blocs — dépasse largement une période climatique.
const MATERIAL_GIVE_AMOUNT := 50
const SKILL_XP_DUMP := 10_000_000.0   # gain_xp boucle déjà les paliers (PlayerSkills).

var _player: Node
var _root: Control
var _list: VBoxContainer
var _status_label: Label
var _creative_cells: Array = []   # Cellules créatives → icône texturée différée.
var is_open := false


func _ready() -> void:
	_player = get_node_or_null("../Player")
	layer = 15  # Au-dessus de la carte du monde (10) et du HUD (0).

	_root = Control.new()
	_root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(_root)

	var bg := ColorRect.new()
	bg.color = Color(0.05, 0.05, 0.08, 0.92)
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(bg)

	var title := Label.new()
	title.text = "MENU DE TRICHE (F1 pour fermer)"
	title.add_theme_font_size_override("font_size", 24)
	title.position = Vector2(24, 16)
	_root.add_child(title)

	_status_label = Label.new()
	_status_label.position = Vector2(24, 52)
	_status_label.add_theme_color_override("font_color", Color(0.6, 1.0, 0.6))
	_root.add_child(_status_label)

	var scroll := ScrollContainer.new()
	scroll.position = Vector2(24, 84)
	scroll.size = Vector2(560, 760)
	_root.add_child(scroll)

	_list = VBoxContainer.new()
	_list.custom_minimum_size = Vector2(540, 0)
	scroll.add_child(_list)

	_build_menu()
	visible = false


func _build_menu() -> void:
	_add_section("Téléportation — biome")
	var biome_ids := GameData.biomes.keys()
	biome_ids.sort()
	for biome_id: String in biome_ids:
		var biome: Dictionary = GameData.biomes[biome_id]
		_add_button(tr(biome.get("name_key", biome_id)), _teleport_to_biome.bind(biome_id))

	_add_section("Téléportation — point d'intérêt")
	_add_button("Village le plus proche", _teleport_to_poi.bind("village"))
	_add_button("Donjon le plus proche", _teleport_to_poi.bind("donjon"))
	_add_button("Camp le plus proche", _teleport_to_poi.bind("camp"))
	_add_button("Sanctuaire le plus proche", _teleport_to_poi.bind("sanctuaire"))

	_add_section("Objets")
	_add_button("Tous les matériaux (x%d)" % MATERIAL_GIVE_AMOUNT, _give_all_materials)
	_add_button("Tous les objets craftés", _give_all_items)

	_add_section("Compétences")
	_add_button("Maximiser toutes les compétences", _max_all_skills)

	# --- Inventaire créatif (2026-07-24) : grille de TOUS les blocs + objets ;
	# clic = ajout à l'inventaire (apparaît dans la hotbar). Façon Minecraft. ---
	_add_section("Créatif — clic = ajouter à la hotbar")
	var mat_grid := GridContainer.new()
	mat_grid.columns = 14
	var mat_ids: Array = GameData.materials.keys()
	mat_ids.sort()
	for mat_id: String in mat_ids:
		var mat: Dictionary = GameData.materials[mat_id]
		var rid: int = GameData.material_runtime_ids.get(mat_id, -1)
		mat_grid.add_child(_creative_cell(rid, Color.html(mat["color"]), tr(mat["name_key"]),
			func() -> void:
				_player.inventory.add_material(mat_id, MATERIAL_GIVE_AMOUNT)
				_set_status("+%d %s" % [MATERIAL_GIVE_AMOUNT, tr(mat["name_key"])])))
	_list.add_child(mat_grid)
	# Rafraîchit les icônes en cube couleur → texture voxel dès qu'elles sont
	# rendues par BlockPreview (quelques-unes par frame).
	var icon_timer := Timer.new()
	icon_timer.wait_time = 0.2
	icon_timer.autostart = true
	icon_timer.timeout.connect(_refresh_creative_icons)
	add_child(icon_timer)

	_add_section("Créatif — objets")
	var item_grid := GridContainer.new()
	item_grid.columns = 14
	var item_ids: Array = GameData.items.keys()
	item_ids.sort()
	for item_id: String in item_ids:
		var item: Dictionary = GameData.items[item_id]
		var swatch := _item_color(item)
		var cell := _creative_cell(-1, swatch, tr(item["name_key"]),
			func() -> void:
				_give_item(item_id)
				_set_status("+ %s" % tr(item["name_key"])))
		# Apparence d'OUTIL (sprite teinté) plutôt qu'un cube couleur.
		var tool_tex: Texture2D = ToolSprite.item_icon(item, {"bois": "chene", "minerai": "fer"}, 28)
		if tool_tex != null:
			cell.icon = tool_tex
		item_grid.add_child(cell)
	_list.add_child(item_grid)


## Cellule créative : bouton avec icône de bloc TEXTURÉE (rendu voxel) si prête,
## sinon cube couleur ; infobulle nom. `rid` = id matériau (-1 = objet, pas de
## rendu voxel).
func _creative_cell(rid: int, color: Color, name_text: String, callback: Callable) -> Button:
	var b := Button.new()
	b.custom_minimum_size = Vector2(34, 34)
	b.tooltip_text = name_text
	b.icon = BlockIcon.cube_texture(color, 28)
	b.expand_icon = true
	b.pressed.connect(callback)
	if rid >= 0:
		_creative_cells.append({"button": b, "rid": rid})
	return b


## Remplace les vignettes couleur par les icônes texturées prêtes.
func _refresh_creative_icons() -> void:
	var pending := 0
	for cell: Dictionary in _creative_cells:
		if cell.get("done", false):
			continue
		var tex: Texture2D = BlockPreview.icon(cell["rid"])
		if tex != null:
			(cell["button"] as Button).icon = tex
			cell["done"] = true
		else:
			pending += 1
	if pending == 0:
		_creative_cells.clear()


## Couleur de vignette d'un objet : celle de son matériau .vox principal, sinon gris.
func _item_color(item: Dictionary) -> Color:
	var inputs: Array = item.get("recipe", {}).get("inputs", [])
	for input: Dictionary in inputs:
		var mat_id := _any_material_of_category(input.get("category", ""))
		if mat_id != "":
			return Color.html(GameData.materials[mat_id]["color"])
	return Color(0.6, 0.6, 0.6)


## Crée et donne un objet (matériaux quelconques valides pour la recette).
func _give_item(item_id: String) -> void:
	var item: Dictionary = GameData.items[item_id]
	var choices := {}
	for input: Dictionary in item.get("recipe", {}).get("inputs", []):
		var mat_id := _any_material_of_category(input.get("category", ""))
		if mat_id == "":
			return
		choices[input["category"]] = mat_id
	_player.inventory.add_object(ItemFactory.craft(item_id, choices, 1.0))


func _add_section(title_text: String) -> void:
	var label := Label.new()
	label.text = title_text
	label.add_theme_font_size_override("font_size", 18)
	label.add_theme_color_override("font_color", Color(1.0, 0.85, 0.4))
	_list.add_child(label)


func _add_button(text_value: String, callback: Callable) -> void:
	var button := Button.new()
	button.text = text_value
	button.pressed.connect(callback)
	_list.add_child(button)


func _unhandled_key_input(event: InputEvent) -> void:
	if not OS.is_debug_build():
		return
	var key := event as InputEventKey
	if key == null or not key.pressed or key.echo:
		return
	if key.physical_keycode == KEY_F1:
		if is_open:
			_close()
		else:
			_open()


func _open() -> void:
	if _player == null or WorldManager.generator == null:
		return  # Pas de triche sans monde actif (menu de démarrage).
	is_open = true
	visible = true
	_status_label.text = ""
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	_player.input_locked = true
	var fly_camera := get_node_or_null("../FlyCamera")
	if fly_camera != null:
		fly_camera.input_locked = true


func _close() -> void:
	is_open = false
	visible = false
	var fly_camera := get_node_or_null("../FlyCamera")
	if fly_camera != null:
		fly_camera.input_locked = false
	_player.input_locked = false
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


func _set_status(text_value: String) -> void:
	_status_label.text = text_value


## Recherche en anneaux carrés croissants (même granularité que la sonde de
## diagnostic, scenes/main.gd::_diagnostic_probe) — bon marché, s'arrête au
## premier point trouvé (pas nécessairement LE plus proche à l'échantillon
## près, mais au premier anneau qui en contient un — suffisant pour un outil
## de debug).
func _find_biome_near(origin_wx: int, origin_wz: int, biome_id: String) -> Vector2i:
	var g := WorldManager.generator
	var origin_gx := origin_wx / TELEPORT_STEP
	var origin_gz := origin_wz / TELEPORT_STEP
	if g.biome_at(origin_wx, origin_wz).get("id", "") == biome_id:
		return Vector2i(origin_wx, origin_wz)
	for ring in range(1, MAX_RING + 1):
		for gx in range(-ring, ring + 1):
			for gz: int in [-ring, ring]:
				var wx: int = (origin_gx + gx) * TELEPORT_STEP
				var wz: int = (origin_gz + gz) * TELEPORT_STEP
				if g.biome_at(wx, wz).get("id", "") == biome_id:
					return Vector2i(wx, wz)
		for gz in range(-ring + 1, ring):
			for gx: int in [-ring, ring]:
				var wx: int = (origin_gx + gx) * TELEPORT_STEP
				var wz: int = (origin_gz + gz) * TELEPORT_STEP
				if g.biome_at(wx, wz).get("id", "") == biome_id:
					return Vector2i(wx, wz)
	return Vector2i(1 << 30, 0)


func _teleport_to_biome(biome_id: String) -> void:
	if WorldManager.generator == null:
		return
	var pos: Vector3 = _player.get_position_for_ai()
	var found := _find_biome_near(int(pos.x), int(pos.z), biome_id)
	if found.x == (1 << 30):
		_set_status("Biome « %s » introuvable dans le rayon de recherche." % biome_id)
		return
	_player.fast_travel_to_world(found.x, found.y)
	_set_status("Téléporté sur « %s » à %s." % [biome_id, found])
	_close()


## Recherche du POI le plus proche par anneaux de CELLULES (128 blocs), même
## principe que _find_biome_near mais à l'échelle cellule (E.2).
func _find_poi_near(origin_wx: int, origin_wz: int, poi_type: String) -> Vector2i:
	var g := WorldManager.generator
	var cs := ClaimManager.CELL_SIZE
	var origin_cell := ClaimManager.cell_of_block(origin_wx, origin_wz)

	var check := func(cell: Vector2i) -> bool:
		var center := POIGenerator.cell_center_world(cell)
		var biome: Dictionary = g.biome_at(center.x, center.y)
		if biome.is_empty():
			return false
		return poi_type in POIGenerator.pois_at_cell(cell, WorldManager.world_seed, biome)

	if check.call(origin_cell):
		return origin_cell
	for ring in range(1, MAX_RING + 1):
		for dx in range(-ring, ring + 1):
			for dz in [-ring, ring]:
				var cell := origin_cell + Vector2i(dx, dz)
				if check.call(cell):
					return cell
		for dz in range(-ring + 1, ring):
			for dx in [-ring, ring]:
				var cell := origin_cell + Vector2i(dx, dz)
				if check.call(cell):
					return cell
	return Vector2i((1 << 30) / maxi(cs, 1), 0)


func _teleport_to_poi(poi_type: String) -> void:
	if WorldManager.generator == null:
		return
	var pos: Vector3 = _player.get_position_for_ai()
	var cell := _find_poi_near(int(pos.x), int(pos.z), poi_type)
	if cell.x == (1 << 30) / maxi(ClaimManager.CELL_SIZE, 1):
		_set_status("Aucun « %s » trouvé dans le rayon de recherche." % poi_type)
		return
	var cs := ClaimManager.CELL_SIZE
	if poi_type == "donjon":
		# Téléporte au BORD de la cellule (pas son centre) : l'entrée du
		# donjon se déclenche par proximité du PÉRIMÈTRE (DungeonManager),
		# jamais en arrivant directement au centre (bien trop loin de tout
		# bord pour une cellule de 128 blocs).
		_player.fast_travel_to_world(cell.x * cs + 2, cell.y * cs + cs / 2)
		_set_status("Téléporté au bord du donjon, cellule %s — avance pour entrer." % cell)
	else:
		_player.fast_travel_to_world(cell.x * cs + cs / 2, cell.y * cs + cs / 2)
		_set_status("Téléporté sur « %s », cellule %s." % [poi_type, cell])
	_close()


func _give_all_materials() -> void:
	for material_id in GameData.materials:
		_player.inventory.add_material(material_id, MATERIAL_GIVE_AMOUNT)
	_set_status("%d matériaux ajoutés (x%d chacun)." % [GameData.materials.size(), MATERIAL_GIVE_AMOUNT])


## Un matériau QUELCONQUE de la catégorie demandée (premier trouvé) — pour
## fournir un choix de matériau valide à ItemFactory.craft sans avoir à
## deviner un id précis par catégorie.
func _any_material_of_category(category: String) -> String:
	for material_id in GameData.materials:
		if GameData.materials[material_id].get("category", "") == category:
			return material_id
	return ""


func _give_all_items() -> void:
	var count := 0
	for item_id in GameData.items:
		var item: Dictionary = GameData.items[item_id]
		var inputs: Array = item.get("recipe", {}).get("inputs", [])
		var material_choices := {}
		var ok := true
		for input: Dictionary in inputs:
			var category: String = input["category"]
			var mat_id := _any_material_of_category(category)
			if mat_id == "":
				ok = false
				break
			material_choices[category] = mat_id
		if not ok:
			continue
		_player.inventory.add_object(ItemFactory.craft(item_id, material_choices, 1.0))
		count += 1
	_set_status("%d objet(s) crafté(s) et ajoutés (qualité 1.0)." % count)


func _max_all_skills() -> void:
	for skill_id in GameData.skills:
		_player.skills.gain_xp(skill_id, SKILL_XP_DUMP)
	_set_status("Toutes les compétences ont reçu %.0f XP." % SKILL_XP_DUMP)
