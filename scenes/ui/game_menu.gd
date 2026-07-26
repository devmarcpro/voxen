extends CanvasLayer
## Menu de jeu à ONGLETS (2026-07-21, demande explicite) — ouvert par Tab,
## fermé par Tab/Échap. Remplace l'ancien panneau d'inventaire texte. Onglets :
##   Personnage · Inventaire · Carte · Royaume · Monde
## Construit en code (comme le reste de l'UI du projet), textes via tr() (10.1).
## Verrouille l'input joueur/caméra + souris visible pendant l'ouverture
## (même contrat que la carte). L'onglet Inventaire est une LISTE TRIABLE
## (nom/catégorie/quantité + toute stat de matériau) : vignette de couleur à
## gauche, nom + infos à droite (demande explicite).

const REFRESH_INTERVAL := 0.35
const SWATCH_SIZE := 44.0

## Clés de tri disponibles (libellé localisé → champ interne de `sort`).
const SORT_KEYS: Array = [
	["ui.menu.tri.nom", "nom"],
	["ui.menu.tri.categorie", "categorie"],
	["ui.menu.tri.quantite", "quantite"],
	["ui.menu.tri.durete", "durete"],
	["ui.menu.tri.densite", "densite"],
	["ui.menu.tri.valeur", "valeur"],
	["ui.menu.tri.poids", "poids"],
]
const TABS: Array = ["personnage", "inventaire", "craft", "carte", "royaume", "monde"]

var is_open := false

var _player: Node
var _bg: ColorRect
var _tab_buttons := {}
var _panels := {}
var _current_tab := "inventaire"
## Inventaire.
var _inv_sort_option: OptionButton
var _inv_desc := false
var _inv_list: VBoxContainer
## Onglets à contenu simple (labels rafraîchis).
var _perso_label: Label
var _royaume_label: Label
## Craft.
var _craft_list: VBoxContainer
## Craft refondu (2026-07-26) : recettes GROUPÉES PAR TABLE (station) scrollables
## à gauche + panneau détail à droite.
var _craft_sections: VBoxContainer
var _craft_detail: VBoxContainer
var _selected_recipe := {}   # {"type": "item"/"transform", "id": String}
## Choix de matériau par (item_id, catégorie) — persistant entre rafraîchis.
var _craft_choices := {}


func _ready() -> void:
	layer = 90
	visible = false
	_player = get_node_or_null("/root/Main/Player")
	_build()
	var timer := Timer.new()
	timer.wait_time = REFRESH_INTERVAL
	timer.autostart = true
	timer.timeout.connect(_refresh)
	add_child(timer)


func _unhandled_key_input(event: InputEvent) -> void:
	var key := event as InputEventKey
	if key == null or not key.pressed or key.echo:
		return
	if key.physical_keycode == KEY_TAB:
		_toggle()
		get_viewport().set_input_as_handled()
	elif key.physical_keycode == KEY_ESCAPE and is_open:
		_close()


func _toggle() -> void:
	if is_open:
		_close()
	else:
		_open()


func _open() -> void:
	if WorldManager.generator == null or _player == null:
		return
	is_open = true
	visible = true
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	_player.input_locked = true
	var fly := get_node_or_null("/root/Main/FlyCamera")
	if fly != null:
		fly.input_locked = true
	_select_tab(_current_tab)
	_refresh()


func _close() -> void:
	is_open = false
	visible = false
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	_player.input_locked = false
	var fly := get_node_or_null("/root/Main/FlyCamera")
	if fly != null:
		fly.input_locked = false


# --- Construction ---

func _build() -> void:
	_bg = ColorRect.new()
	_bg.color = Color(0.06, 0.07, 0.09)  # Opaque : menu plein écran, pas de HUD qui transparaît.
	_bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(_bg)

	var root := MarginContainer.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	for side in ["margin_left", "margin_top", "margin_right", "margin_bottom"]:
		root.add_theme_constant_override(side, 40)
	_bg.add_child(root)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 12)
	root.add_child(vbox)

	# Barre d'onglets.
	var tab_bar := HBoxContainer.new()
	tab_bar.add_theme_constant_override("separation", 6)
	vbox.add_child(tab_bar)
	for tab: String in TABS:
		var b := Button.new()
		b.text = tr("ui.menu.onglet." + tab)
		b.toggle_mode = true
		b.pressed.connect(_select_tab.bind(tab))
		tab_bar.add_child(b)
		_tab_buttons[tab] = b

	var content := PanelContainer.new()
	content.size_flags_vertical = Control.SIZE_EXPAND_FILL
	vbox.add_child(content)

	_panels["personnage"] = _build_personnage()
	_panels["inventaire"] = _build_inventaire()
	_panels["craft"] = _build_craft()
	_panels["carte"] = _build_carte()
	_panels["royaume"] = _build_royaume()
	_panels["monde"] = _build_monde()
	for tab: String in _panels:
		content.add_child(_panels[tab])


func _select_tab(tab: String) -> void:
	_current_tab = tab
	for t: String in _panels:
		(_panels[t] as Control).visible = t == tab
		(_tab_buttons[t] as Button).button_pressed = t == tab
	_refresh()


func _scroll_with(child: Control) -> ScrollContainer:
	var scroll := ScrollContainer.new()
	scroll.visible = false
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	child.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(child)
	return scroll


func _build_personnage() -> Control:
	_perso_label = Label.new()
	return _scroll_with(_perso_label)


func _build_royaume() -> Control:
	_royaume_label = Label.new()
	return _scroll_with(_royaume_label)


func _build_carte() -> Control:
	var box := VBoxContainer.new()
	box.visible = false
	box.alignment = BoxContainer.ALIGNMENT_CENTER
	var label := Label.new()
	label.text = tr("ui.menu.carte_aide")
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(label)
	# Carte EMBARQUÉE (2026-07-26) : joueur au centre, clic = voyage progressif.
	var center := HBoxContainer.new()
	center.alignment = BoxContainer.ALIGNMENT_CENTER
	var map: Control = preload("res://scenes/ui/menu_map.gd").new()
	map.setup(_player)
	map.travel_requested.connect(func(wx: int, wz: int) -> void:
		_player.fast_travel_to_world(wx, wz)
		_close())
	center.add_child(map)
	box.add_child(center)
	return box


func _open_map() -> void:
	_close()
	var map := get_node_or_null("/root/Main/WorldMapView")
	if map != null and map.has_method("open"):
		map.open()


func _build_monde() -> Control:
	# Encyclopédie : construite une fois (le contenu des données ne bouge pas
	# en jeu). Factions/autres royaumes : à venir (E.27 non implémenté).
	var box := VBoxContainer.new()
	box.visible = false
	box.add_theme_constant_override("separation", 4)
	var header := Label.new()
	header.text = tr("ui.menu.encyclopedie")
	header.add_theme_font_size_override("font_size", 22)
	box.add_child(header)
	box.add_child(_encyclo_section("ui.menu.enc.biomes", GameData.biomes))
	box.add_child(_encyclo_section("ui.menu.enc.creatures", GameData.creatures))
	box.add_child(_encyclo_section("ui.menu.enc.arbres", GameData.trees))
	var counts := Label.new()
	counts.text = tr("ui.menu.enc.compte").format({
		"materiaux": str(GameData.materials.size()),
		"plantes": str(GameData.plants.size())})
	box.add_child(counts)
	var factions := Label.new()
	factions.text = tr("ui.menu.enc.factions")
	box.add_child(factions)
	return _scroll_with(box)


func _encyclo_section(title_key: String, collection: Dictionary) -> VBoxContainer:
	var section := VBoxContainer.new()
	var title := Label.new()
	title.text = "%s (%d)" % [tr(title_key), collection.size()]
	title.add_theme_font_size_override("font_size", 17)
	section.add_child(title)
	var names: Array[String] = []
	for id in collection:
		names.append(tr(collection[id]["name_key"]))
	names.sort()
	var body := Label.new()
	body.autowrap_mode = TextServer.AUTOWRAP_WORD
	body.text = "   ".join(names)
	body.modulate = Color(0.8, 0.82, 0.85)
	section.add_child(body)
	return section


func _build_inventaire() -> Control:
	var box := VBoxContainer.new()
	box.visible = false
	box.add_theme_constant_override("separation", 8)

	# Barre de tri.
	var controls := HBoxContainer.new()
	var sort_label := Label.new()
	sort_label.text = tr("ui.menu.trier_par")
	controls.add_child(sort_label)
	_inv_sort_option = OptionButton.new()
	for entry: Array in SORT_KEYS:
		_inv_sort_option.add_item(tr(entry[0]))
	_inv_sort_option.item_selected.connect(func(_i: int) -> void: _refresh_inventory())
	controls.add_child(_inv_sort_option)
	var order_btn := Button.new()
	order_btn.text = tr("ui.menu.ordre_desc")
	order_btn.toggle_mode = true
	order_btn.toggled.connect(func(pressed: bool) -> void:
		_inv_desc = pressed
		_refresh_inventory())
	controls.add_child(order_btn)
	box.add_child(controls)

	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_inv_list = VBoxContainer.new()
	_inv_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_inv_list.add_theme_constant_override("separation", 2)
	scroll.add_child(_inv_list)
	box.add_child(scroll)
	return box


# --- Rafraîchissement ---

func _refresh() -> void:
	if not is_open or _player == null:
		return
	match _current_tab:
		"personnage": _refresh_personnage()
		"inventaire": _refresh_inventory()
		"craft": _refresh_craft()
		"royaume": _refresh_royaume()


func _refresh_personnage() -> void:
	var lines: Array[String] = [tr("ui.menu.onglet.personnage"), ""]
	const STAT_IDS: Array = ["force", "dexterite", "endurance", "volonte", "perception", "charisme"]
	for stat_id: String in STAT_IDS:
		lines.append("%s : %d" % [tr("stat." + stat_id + ".name"), int(_player.stats[stat_id])])
	lines.append("")
	lines.append(tr("ui.hud.sante").format({"pv": str(int(_player.health)), "pv_max": str(int(_player.health_max))}))
	lines.append(tr("ui.hud.mana").format({"mana": str(int(_player.mana.current)), "mana_max": str(int(_player.mana.max_mana()))}))
	lines.append(tr("ui.hud.or").format({"or": str(_player.gold)}))
	# Niveaux dérivés (6.0 : moyenne des 5 meilleures par catégorie).
	lines.append("")
	lines.append(tr("ui.menu.niveau_combat").format({"niveau": str(_derived_level("combat"))}))
	lines.append(tr("ui.menu.niveau_general").format({"niveau": str(_derived_level("general"))}))
	# Compétences progressées.
	lines.append("")
	lines.append(tr("ui.inv.competences"))
	var skills: PlayerSkills = _player.skills
	var skill_ids: Array = skills.skills.keys()
	skill_ids.sort()
	var any := false
	for id: String in skill_ids:
		var s: Dictionary = skills.skills[id]
		if int(s["level"]) <= 0:
			continue
		any = true
		lines.append(tr("ui.inv.competence_ligne").format({
			"nom": tr(GameData.skills[id]["name_key"]),
			"niveau": str(s["level"]),
			"xp": "%.0f" % float(s["xp"]),
			"xp_max": "%.0f" % PlayerSkills.xp_next(int(s["level"])),
			"potentiel": "%.0f" % float(s["potential"]),
		}))
	if not any:
		lines.append(tr("ui.menu.aucune_competence"))
	_perso_label.text = "\n".join(lines)


## Niveau dérivé (6.0/A.1) : moyenne des 5 meilleures compétences de la
## catégorie (champ `category` des données, anti-dilution).
func _derived_level(category: String) -> int:
	var levels: Array[int] = []
	for id: String in _player.skills.skills:
		if GameData.skills.get(id, {}).get("category", "") == category:
			levels.append(int(_player.skills.skills[id]["level"]))
	levels.sort()
	levels.reverse()
	var top := levels.slice(0, 5)
	if top.is_empty():
		return 0
	var sum := 0
	for v in top:
		sum += v
	return int(round(float(sum) / top.size()))


func _refresh_royaume() -> void:
	var lines: Array[String] = [tr("ui.menu.onglet.royaume"), ""]
	var claims: Dictionary = ClaimManager.claims
	lines.append(tr("ui.menu.royaume_total").format({"total": str(claims.size())}))
	# Décompte par rôle.
	var by_role := {}
	for cell: Vector2i in claims:
		var role: String = claims[cell]
		by_role[role] = int(by_role.get(role, 0)) + 1
	for role: String in ClaimManager.ROLES:
		if by_role.has(role):
			lines.append("  %s : %d" % [tr("ui.role_name." + role), by_role[role]])
	lines.append("")
	if claims.is_empty():
		lines.append(tr("ui.menu.royaume_vide"))
	else:
		lines.append(tr("ui.menu.royaume_cases"))
		var cells: Array = claims.keys()
		cells.sort_custom(func(a: Vector2i, b: Vector2i) -> bool:
			return a.x < b.x if a.x != b.x else a.y < b.y)
		for cell: Vector2i in cells:
			lines.append("  (%d, %d) — %s" % [cell.x, cell.y, tr("ui.role_name." + String(claims[cell]))])
	_royaume_label.text = "\n".join(lines)


func _refresh_inventory() -> void:
	if _inv_list == null:
		return
	for child in _inv_list.get_children():
		child.queue_free()

	var entries := _build_inventory_entries()
	var sort_field: String = SORT_KEYS[_inv_sort_option.selected][1] if _inv_sort_option.selected >= 0 else "nom"
	entries.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		var va: Variant = a["sort"][sort_field]
		var vb: Variant = b["sort"][sort_field]
		if va == vb:
			return String(a["sort"]["nom"]) < String(b["sort"]["nom"])
		var less: bool = va < vb
		return (not less) if _inv_desc else less)

	if entries.is_empty():
		var empty := Label.new()
		empty.text = tr("ui.inv.vide")
		_inv_list.add_child(empty)
		return
	for entry: Dictionary in entries:
		_inv_list.add_child(_inventory_row(entry))


## Ligne d'inventaire : icône de bloc en CUBE (texturée si prête, sinon couleur)
## à gauche + nom/infos à droite (2026-07-26).
func _inventory_row(entry: Dictionary) -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	var swatch := TextureRect.new()
	var rid: int = entry.get("rid", -1)
	var tex: Texture2D = null
	if rid >= 0:
		tex = BlockPreview.icon(rid)                     # bloc : cube texturé
	elif entry.has("obj"):
		var obj: Dictionary = entry["obj"]                # outil : sprite teinté
		var item: Dictionary = GameData.items.get(obj.get("item_id", ""), {})
		tex = ToolSprite.item_icon(item, obj.get("materials", {}), SWATCH_SIZE)
	swatch.texture = tex if tex != null else BlockIcon.cube_texture(entry["swatch"], SWATCH_SIZE)
	swatch.custom_minimum_size = Vector2(SWATCH_SIZE, SWATCH_SIZE)
	swatch.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	swatch.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	swatch.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	swatch.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(swatch)
	var texts := VBoxContainer.new()
	texts.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var name_label := Label.new()
	name_label.text = entry["name"]
	name_label.add_theme_font_size_override("font_size", 16)
	texts.add_child(name_label)
	var info_label := Label.new()
	info_label.text = entry["info"]
	info_label.modulate = Color(0.72, 0.75, 0.8)
	texts.add_child(info_label)
	row.add_child(texts)
	return row


## Construit les entrées unifiées (objets + piles de matériaux) avec valeurs
## de tri sur toutes les caractéristiques.
func _build_inventory_entries() -> Array[Dictionary]:
	var entries: Array[Dictionary] = []
	var inv: Inventory = _player.inventory

	for obj: Dictionary in inv.objects:
		var item: Dictionary = GameData.items.get(obj.get("item_id", ""), {})
		var type_key: String = item.get("type", "objet")
		var swatch := _object_color(obj)
		entries.append({
			"kind": "object",
			"rid": -1,
			"obj": obj,
			"name": tr(obj.get("name_key", "?")),
			"swatch": swatch,
			"info": tr("ui.menu.inv_objet_info").format({
				"categorie": tr("ui.type." + type_key),
				"qualite": "%.2f" % float(obj.get("quality", 1.0)),
				"durete": "%.1f" % float(obj.get("base_hardness", 0.0)),
				"poids": "%.1f" % float(obj.get("weight", 0.0)),
			}),
			"sort": {
				"nom": tr(obj.get("name_key", "?")),
				"categorie": tr("ui.type." + type_key),
				"quantite": 1,
				"durete": float(obj.get("base_hardness", 0.0)),
				"densite": 0.0,
				"valeur": 0.0,
				"poids": float(obj.get("weight", 0.0)),
			},
		})

	for id: String in inv.material_ids():
		var mat: Dictionary = GameData.materials.get(id, {})
		if mat.is_empty():
			continue
		var stats: Dictionary = mat["stats"]
		# Volume FRACTIONNAIRE (blocs entiers + fraction, ex. 13.27) — on
		# mine/construit en sous-voxels (2026-07-26).
		var count: float = inv.total_volume(id)
		if count <= 0.0001:
			continue
		var densite := float(stats["densite"])
		entries.append({
			"kind": "material",
			"rid": GameData.material_runtime_ids.get(id, -1),
			"name": "%s × %s" % [tr(mat["name_key"]), Inventory.format_volume(count)],
			"swatch": Color.html(mat["color"]),
			"info": tr("ui.menu.inv_mat_info").format({
				"categorie": tr("category." + String(mat["category"]) + ".name"),
				"durete": "%.0f" % float(stats["durete"]),
				"densite": "%.0f" % densite,
				"valeur": "%.0f" % float(stats["valeur_base"]),
			}),
			"sort": {
				"nom": tr(mat["name_key"]),
				"categorie": tr("category." + String(mat["category"]) + ".name"),
				"quantite": count,
				"durete": float(stats["durete"]),
				"densite": densite,
				"valeur": float(stats["valeur_base"]),
				"poids": densite * count,
			},
		})
	return entries


# --- Craft (4.2 « voie de base » : craft simple par recette B.3 ; qualité
# A.3 selon la compétence d'artisanat ; stats A.4 = moyenne pondérée × qualité,
# ItemFactory) ---

## Ordre d'affichage des tables de craft (sections). « aucune » = à la main.
const STATION_ORDER := ["aucune", "etabli", "forge", "scierie", "tailleur", "tissage", "alambic", "enclume"]


func _build_craft() -> Control:
	var root := HBoxContainer.new()
	root.visible = false
	root.add_theme_constant_override("separation", 10)
	# GAUCHE : recettes groupées par TABLE (station), scrollable.
	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(320, 0)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_craft_sections = VBoxContainer.new()
	_craft_sections.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_craft_sections.add_theme_constant_override("separation", 6)
	scroll.add_child(_craft_sections)
	root.add_child(scroll)
	# DROITE : panneau de détail de la recette sélectionnée.
	_craft_detail = VBoxContainer.new()
	_craft_detail.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_craft_detail.add_theme_constant_override("separation", 8)
	root.add_child(_craft_detail)
	return root


## Le joueur peut-il fabriquer cette recette MAINTENANT (table dispo + matériaux
## suffisants dans une catégorie possédée) ? Pour le ✓/✗ sur l'icône.
func _recipe_craftable(recipe: Dictionary) -> bool:
	if not _station_available(_recipe_station(recipe)):
		return false
	if recipe["type"] == "item":
		for inp: Dictionary in (GameData.items[recipe["id"]].get("recipe", {}).get("inputs", []) as Array):
			if not _has_category_amount(String(inp["category"]), int(inp["amount"])):
				return false
		return true
	for inp: Dictionary in _tf_inputs(GameData.transformations[recipe["id"]]):
		var amt := int(inp["amount"])
		if inp.has("category"):
			if not _has_category_amount(String(inp["category"]), amt):
				return false
		elif int(_player.inventory.material_stacks.get(inp["material"], 0)) < amt:
			return false
	return true


## Possède-t-on ≥ `amount` blocs d'AU MOINS un matériau de la catégorie ?
func _has_category_amount(category: String, amount: int) -> bool:
	for mid: String in _owned_of_category(category):
		if int(_player.inventory.material_stacks.get(mid, 0)) >= amount:
			return true
	return false


## Station requise par une recette (item ou transformation).
func _recipe_station(recipe: Dictionary) -> String:
	if recipe["type"] == "item":
		return GameData.items[recipe["id"]].get("recipe", {}).get("station", "aucune")
	return GameData.transformations[recipe["id"]].get("station", "forge")


## Toutes les recettes : objets (à recette) + transformations (fonderie).
func _all_recipes() -> Array:
	var recipes := []
	var item_ids: Array = GameData.items.keys()
	item_ids.sort()
	for item_id: String in item_ids:
		if not (GameData.items[item_id].get("recipe", {}).get("inputs", []) as Array).is_empty():
			recipes.append({"type": "item", "id": item_id})
	var tr_ids: Array = GameData.transformations.keys()
	tr_ids.sort()
	for tid: String in tr_ids:
		recipes.append({"type": "transform", "id": tid})
	return recipes


## Stations disponibles à la position du joueur : « aucune » toujours ; établi/
## forge si un bloc correspondant est posé dans la MÊME cellule (2026-07-26).
## Station id (des recettes) → bloc posable qui la fournit (2026-07-26).
const STATION_BLOCK := {
	"etabli": "etabli", "forge": "four", "scierie": "scierie",
	"tailleur": "tailleur", "tissage": "metier_tisser",
	"alambic": "alambic", "enclume": "enclume",
}
func _station_available(station: String) -> bool:
	if station == "" or station == "aucune":
		return true
	var mat_id: String = STATION_BLOCK.get(station, "")
	if mat_id == "":
		return true
	var pos: Vector3 = _player.get_position_for_ai()
	var rid: int = GameData.material_runtime_ids.get(mat_id, 0)
	return WorldManager.station_in_cell(int(pos.x), int(pos.z), rid)


func _refresh_craft() -> void:
	if _craft_sections == null:
		return
	for child in _craft_sections.get_children():
		child.queue_free()
	# Regroupe les recettes par table (station).
	var by_station := {}
	for recipe: Dictionary in _all_recipes():
		var st := _recipe_station(recipe)
		by_station.get_or_add(st, []).append(recipe)
	# Une SECTION par table, dans l'ordre, seulement si non vide.
	for station: String in STATION_ORDER:
		if not by_station.has(station):
			continue
		var avail := _station_available(station)
		var header := Label.new()
		var name := tr("ui.menu.craft_a_la_main") if station == "aucune" else tr("ui.station." + station)
		header.text = name if avail else "%s  (%s)" % [name, tr("ui.menu.station_absente")]
		header.add_theme_font_size_override("font_size", 18)
		header.modulate = Color(0.9, 0.9, 0.95) if avail else Color(0.7, 0.55, 0.55)
		_craft_sections.add_child(header)
		var grid := GridContainer.new()
		grid.columns = 6
		for recipe: Dictionary in by_station[station]:
			var btn := Button.new()
			btn.custom_minimum_size = Vector2(44, 44)
			btn.icon = _recipe_icon(recipe)
			btn.expand_icon = true
			btn.tooltip_text = _recipe_name(recipe)
			btn.modulate = Color.WHITE if avail else Color(0.7, 0.7, 0.7)
			var r := recipe
			btn.pressed.connect(func() -> void: _select_recipe(r))
			# Pastille ✓ (vert) / ✗ (rouge) : fabricable maintenant ?
			var ok := _recipe_craftable(recipe)
			var mark := Label.new()
			mark.text = "✓" if ok else "✗"
			mark.add_theme_font_size_override("font_size", 15)
			mark.add_theme_color_override("font_color", Color(0.3, 1.0, 0.35) if ok else Color(1.0, 0.3, 0.3))
			mark.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.9))
			mark.add_theme_constant_override("outline_size", 4)
			mark.position = Vector2(30, -3)
			mark.mouse_filter = Control.MOUSE_FILTER_IGNORE
			btn.add_child(mark)
			grid.add_child(btn)
		_craft_sections.add_child(grid)
	if _selected_recipe.is_empty():
		var recipes := _all_recipes()
		if not recipes.is_empty():
			_selected_recipe = recipes[0]
	_build_craft_detail()


func _recipe_name(recipe: Dictionary) -> String:
	if recipe["type"] == "item":
		return tr(GameData.items[recipe["id"]]["name_key"])
	var out_mat: String = (GameData.transformations[recipe["id"]]["output"] as Dictionary)["material"]
	return tr(GameData.materials[out_mat]["name_key"])


## Icône du RÉSULTAT d'une recette (outil = sprite ; matériau = cube texturé).
func _recipe_icon(recipe: Dictionary) -> Texture2D:
	if recipe["type"] == "item":
		var item: Dictionary = GameData.items[recipe["id"]]
		var t: Texture2D = ToolSprite.item_icon(item, {"bois": "chene", "minerai": "fer"}, 40)
		if t != null:
			return t
		return BlockIcon.cube_texture(Color(0.6, 0.6, 0.6), 40)
	var out_mat: String = (GameData.transformations[recipe["id"]]["output"] as Dictionary)["material"]
	var rid: int = GameData.material_runtime_ids.get(out_mat, 0)
	var bt: Texture2D = BlockPreview.icon(rid)
	return bt if bt != null else BlockIcon.cube_texture(Color.html(GameData.materials[out_mat]["color"]), 40)


func _select_recipe(recipe: Dictionary) -> void:
	_selected_recipe = recipe
	_build_craft_detail()


## Exécute une transformation (fonderie) : consomme l'entrée, produit la
## sortie, gagne l'XP de la compétence de station (forge). Vérifie avant.
## Entrées normalisées d'une transformation (liste — `inputs` ou `input` unique).
func _tf_inputs(tdef: Dictionary) -> Array:
	return tdef["inputs"] if tdef.has("inputs") else [tdef.get("input", {})]


## Matériau résolu d'une entrée (choisi si catégorie, fixe si matériau).
func _tf_input_material(tid: String, in_def: Dictionary) -> String:
	if in_def.has("category"):
		return String(_craft_choices.get(tid + ":" + String(in_def["category"]), ""))
	return in_def.get("material", "")


func _do_transform(tid: String) -> void:
	var tdef: Dictionary = GameData.transformations[tid]
	if not _station_available(tdef.get("station", "forge")):
		return
	# Vérifie TOUTES les entrées avant de rien consommer.
	var to_consume := []
	for in_def: Dictionary in _tf_inputs(tdef):
		var mat := _tf_input_material(tid, in_def)
		var amt := int(in_def["amount"])
		if mat == "" or int(_player.inventory.material_stacks.get(mat, 0)) < amt:
			return
		to_consume.append([mat, amt])
	for pair: Array in to_consume:
		_player.inventory.remove_material(pair[0], pair[1])
	var in_amt: int = int((_tf_inputs(tdef)[0] as Dictionary)["amount"])
	var out_mat: String = (tdef["output"] as Dictionary)["material"]
	_player.inventory.add_material(out_mat, int((tdef["output"] as Dictionary)["amount"]))
	var skill: String = tdef.get("skill", "")
	if skill != "":
		_player.skills.gain_xp(skill, in_amt * 10.0)
	EventBus.ui_notification.emit("ui.toast.craft_reussi")
	_refresh_craft()


## Panneau de détail droit de la recette sélectionnée (objet ou transformation).
func _build_craft_detail() -> void:
	if _craft_detail == null:
		return
	for c in _craft_detail.get_children():
		c.queue_free()
	if _selected_recipe.is_empty():
		return
	if _selected_recipe["type"] == "transform":
		_build_transform_detail(_selected_recipe["id"])
	else:
		_build_item_detail(_selected_recipe["id"])


func _detail_header(icon: Texture2D, name_text: String) -> void:
	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 10)
	var ic := TextureRect.new()
	ic.texture = icon
	ic.custom_minimum_size = Vector2(64, 64)
	ic.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	ic.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	head.add_child(ic)
	var title := Label.new()
	title.text = name_text
	title.add_theme_font_size_override("font_size", 22)
	head.add_child(title)
	_craft_detail.add_child(head)


func _station_line(station: String) -> void:
	var avail := _station_available(station)
	var lab := Label.new()
	lab.text = tr("ui.menu.craft_station").format({"station": tr("ui.station." + station),
		"etat": tr("ui.menu.station_dispo") if avail else tr("ui.menu.station_absente")})
	lab.modulate = Color(0.4, 0.9, 0.4) if avail else Color(0.95, 0.4, 0.4)
	_craft_detail.add_child(lab)


func _build_item_detail(item_id: String) -> void:
	var item: Dictionary = GameData.items[item_id]
	var recipe: Dictionary = item["recipe"]
	_detail_header(_recipe_icon({"type": "item", "id": item_id}), tr(item["name_key"]))
	var station: String = recipe.get("station", "aucune")
	_station_line(station)
	var craft_skill: String = recipe.get("craft_skill", "")
	if craft_skill != "":
		var sk := Label.new()
		sk.text = tr("ui.menu.craft_competence").format({
			"competence": tr(GameData.skills.get(craft_skill, {}).get("name_key", craft_skill)),
			"niveau": str(_player.skills.level(craft_skill))})
		_craft_detail.add_child(sk)

	var can_craft := _station_available(station)
	for input: Dictionary in (recipe["inputs"] as Array):
		var category: String = input["category"]
		var amount: int = int(input["amount"])
		var owned := _owned_of_category(category)
		var hb := HBoxContainer.new()
		hb.add_theme_constant_override("separation", 8)
		var lab := Label.new()
		lab.text = "%d× %s" % [amount, tr("category." + category + ".name")]
		lab.custom_minimum_size = Vector2(130, 0)
		hb.add_child(lab)
		var option := OptionButton.new()
		option.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		var key := item_id + ":" + category
		if owned.is_empty():
			option.add_item(tr("ui.menu.craft_manque"))
			option.disabled = true
			can_craft = false
		else:
			for mat_id: String in owned:
				option.add_item("%s (%s)" % [tr(GameData.materials[mat_id]["name_key"]),
					Inventory.format_volume(_player.inventory.total_volume(mat_id))])
			var sel := owned.find(String(_craft_choices.get(key, "")))
			option.selected = sel if sel >= 0 else 0
			_craft_choices[key] = owned[option.selected]
			var owned_ref := owned
			option.item_selected.connect(func(i: int) -> void:
				_craft_choices[key] = owned_ref[i]
				_build_craft_detail())
			if int(_player.inventory.material_stacks.get(owned[option.selected], 0)) < amount:
				can_craft = false
		hb.add_child(option)
		_craft_detail.add_child(hb)

	var btn := Button.new()
	btn.text = tr("ui.menu.fabriquer")
	btn.disabled = not can_craft
	btn.pressed.connect(_do_craft.bind(item_id, recipe, craft_skill))
	_craft_detail.add_child(btn)

	var quality := ItemFactory.craft_quality(_player.skills.level(craft_skill) if craft_skill != "" else 0)
	var res := Label.new()
	res.text = tr("ui.menu.craft_resultat").format({"nom": tr(item["name_key"]),
		"palier": tr(ItemFactory.quality_tier_key(quality))})
	res.modulate = Color(0.75, 0.78, 0.82)
	_craft_detail.add_child(res)
	# Stats de CHAQUE composant choisi (le joueur voit l'effet du matériau).
	for input: Dictionary in (recipe["inputs"] as Array):
		var chosen: String = String(_craft_choices.get(item_id + ":" + String(input["category"]), ""))
		if chosen != "":
			_stats_block(tr("ui.menu.stats_composant"), chosen)


func _build_transform_detail(tid: String) -> void:
	var tdef: Dictionary = GameData.transformations[tid]
	var out_mat: String = (tdef["output"] as Dictionary)["material"]
	var out_amt: int = int((tdef["output"] as Dictionary)["amount"])
	var out_rid: int = GameData.material_runtime_ids.get(out_mat, 0)
	var out_icon: Texture2D = BlockPreview.icon(out_rid)
	if out_icon == null:
		out_icon = BlockIcon.cube_texture(Color.html(GameData.materials[out_mat]["color"]), 64)
	_detail_header(out_icon, "%d× %s" % [out_amt, tr(GameData.materials[out_mat]["name_key"])])
	var station: String = tdef.get("station", "forge")
	_station_line(station)

	var chosen_mats: Array[String] = []
	var can := _station_available(station)
	# Une ligne par ENTRÉE (matériau fixe ou choix par catégorie).
	for in_def: Dictionary in _tf_inputs(tdef):
		var in_amt := int(in_def["amount"])
		var hb := HBoxContainer.new()
		hb.add_theme_constant_override("separation", 8)
		if in_def.has("category"):
			var category: String = in_def["category"]
			var owned := _owned_of_category(category)
			var lab := Label.new()
			lab.text = "%d× %s" % [in_amt, tr("category." + category + ".name")]
			lab.custom_minimum_size = Vector2(130, 0)
			hb.add_child(lab)
			var option := OptionButton.new()
			option.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			var key := tid + ":" + category
			if owned.is_empty():
				option.add_item(tr("ui.menu.craft_manque"))
				option.disabled = true
				can = false
			else:
				for mat_id: String in owned:
					option.add_item("%s (%s)" % [tr(GameData.materials[mat_id]["name_key"]),
						Inventory.format_volume(_player.inventory.total_volume(mat_id))])
				var sel := owned.find(String(_craft_choices.get(key, "")))
				option.selected = sel if sel >= 0 else 0
				_craft_choices[key] = owned[option.selected]
				chosen_mats.append(owned[option.selected])
				var owned_ref := owned
				option.item_selected.connect(func(i: int) -> void:
					_craft_choices[key] = owned_ref[i]
					_build_craft_detail())
				if int(_player.inventory.material_stacks.get(owned[option.selected], 0)) < in_amt:
					can = false
			hb.add_child(option)
		else:
			var mat: String = in_def["material"]
			chosen_mats.append(mat)
			var owned := int(_player.inventory.material_stacks.get(mat, 0))
			var lab := Label.new()
			lab.text = "%d× %s (%d)" % [in_amt, tr(GameData.materials[mat]["name_key"]), owned]
			hb.add_child(lab)
			if owned < in_amt:
				can = false
		_craft_detail.add_child(hb)

	var btn := Button.new()
	btn.text = tr("ui.menu.transformer")
	btn.disabled = not can
	btn.pressed.connect(_do_transform.bind(tid))
	_craft_detail.add_child(btn)

	# STATS de chaque composant choisi + du produit.
	for m: String in chosen_mats:
		_stats_block(tr("ui.menu.stats_composant"), m)
	_stats_block(tr("ui.menu.stats_produit"), out_mat)


## Noms d'affichage des stats de matériau (B.1) — fr par défaut (jeu FR).
const STAT_NAMES := {
	"durete": "Dureté", "densite": "Densité", "valeur_base": "Valeur",
	"conductivite_mana": "Cond. mana", "flammabilite": "Inflammabilité",
	"isolation": "Isolation", "conductivite_electrique": "Cond. élec.",
	"flottabilite": "Flottabilité", "luminosite": "Luminosité",
	"fertilite": "Fertilité", "transparence": "Transparence",
	"elasticite": "Élasticité", "friction": "Friction",
}


## Bloc « toutes les stats » d'un matériau (composant ou produit).
func _stats_block(title: String, material_id: String) -> void:
	var mat: Dictionary = GameData.materials.get(material_id, {})
	if mat.is_empty():
		return
	var head := Label.new()
	head.text = "%s : %s" % [title, tr(mat["name_key"])]
	head.add_theme_font_size_override("font_size", 15)
	_craft_detail.add_child(head)
	var grid := GridContainer.new()
	grid.columns = 3
	var stats: Dictionary = mat["stats"]
	for key: String in STAT_NAMES:
		var l := Label.new()
		l.text = "%s : %s" % [STAT_NAMES[key], str(stats.get(key, 0))]
		l.add_theme_font_size_override("font_size", 12)
		l.modulate = Color(0.7, 0.73, 0.78)
		l.custom_minimum_size = Vector2(120, 0)
		grid.add_child(l)
	_craft_detail.add_child(grid)


## Catégories acceptables pour une entrée de recette : un LINGOT (métal
## raffiné) est utilisable partout où la recette demande du « minerai » — le
## joueur peut donc fondre son minerai en lingot pour un meilleur outil.
const CATEGORY_ALSO_ACCEPTS := {"minerai": ["lingot"]}


## Matériaux possédés de la catégorie donnée (+ catégories équivalentes), triés.
func _owned_of_category(category: String) -> Array[String]:
	var accepted := [category]
	accepted.append_array(CATEGORY_ALSO_ACCEPTS.get(category, []))
	var result: Array[String] = []
	for id: String in _player.inventory.material_stacks:
		var mat: Dictionary = GameData.materials.get(id, {})
		if mat.get("category", "") in accepted:
			result.append(id)
	result.sort()
	return result


## Fabrique l'objet : vérifie/consomme les matériaux, tire la qualité (A.3),
## crée l'instance (ItemFactory/A.4), gagne l'XP d'artisanat, émet item_crafted.
func _do_craft(item_id: String, recipe: Dictionary, craft_skill: String) -> void:
	if not _station_available(recipe.get("station", "aucune")):
		return
	var inputs: Array = recipe["inputs"]
	var choices := {}
	var total_amount := 0
	# Vérifie tout AVANT de consommer (jamais de consommation partielle).
	for input: Dictionary in inputs:
		var category: String = input["category"]
		var amount: int = int(input["amount"])
		var chosen: String = _craft_choices.get(item_id + ":" + category, "")
		if chosen == "" or int(_player.inventory.material_stacks.get(chosen, 0)) < amount:
			return
		choices[category] = chosen
		total_amount += amount
	for input: Dictionary in inputs:
		_player.inventory.remove_material(choices[input["category"]], int(input["amount"]))

	var quality := ItemFactory.craft_quality(_player.skills.level(craft_skill))
	var obj := ItemFactory.craft(item_id, choices, quality)
	if obj.is_empty():
		return
	_player.inventory.add_object(obj)
	if craft_skill != "":
		# XP d'artisanat par l'usage (A.1) — valeur = matériaux consommés × 15
		# (le GDD ne chiffre pas l'XP de craft, interprétation signalée).
		_player.skills.gain_xp(craft_skill, total_amount * 15.0)
	EventBus.item_crafted.emit(item_id, quality, _player)
	EventBus.ui_notification.emit("ui.toast.craft_reussi")
	_refresh_craft()


## Couleur de vignette d'un objet : celle de son matériau principal (première
## entrée de `materials`), gris si indéterminé.
func _object_color(obj: Dictionary) -> Color:
	var materials: Dictionary = obj.get("materials", {})
	for category in materials:
		var mat: Dictionary = GameData.materials.get(materials[category], {})
		if not mat.is_empty():
			return Color.html(mat["color"])
	return Color(0.5, 0.5, 0.5)
