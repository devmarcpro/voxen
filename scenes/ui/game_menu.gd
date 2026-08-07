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
const TABS: Array = ["personnage", "combat", "inventaire", "craft", "collection", "carte", "royaume", "monde"]

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
## Virtualisation de la liste d'inventaire (2026-08-07).
## `_inv_entries` est la liste TRIÉE complète ; seule une fenêtre en est bâtie.
var _inv_scroll: ScrollContainer
var _inv_entries: Array[Dictionary] = []
var _inv_row_height := 0.0
var _inv_spacer_top: Control
var _inv_spacer_bottom: Control
var _inv_window := Vector2i(-1, -1)
## Lignes construites au-delà de la fenêtre visible, en haut comme en bas :
## sans marge, un défilement à la molette montre du vide le temps d'une frame.
const INV_OVERSCAN := 4
## Hotbar intégrée à l'inventaire (2026-07-27) : bande d'emplacements
## assignables, cible du glisser-déposer depuis la liste.
var _inv_hotbar: HBoxContainer
var _inv_bank := 0
var _inv_bank_label: Label
## Entrée d'inventaire dont le menu contextuel est ouvert.
var _context_entry := {}
## Onglets à contenu simple (labels rafraîchis).
var _perso_label: Label
var _royaume_label: Label
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
	if event.is_action_pressed("inventory"):
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
	_panels["combat"] = _build_combat()
	_panels["inventaire"] = _build_inventaire()
	_panels["craft"] = _build_craft()
	_panels["collection"] = _build_collection()
	_panels["carte"] = _build_carte()
	_panels["royaume"] = _build_royaume()
	_panels["monde"] = _build_monde()
	for tab: String in _panels:
		content.add_child(_panels[tab])


func _select_tab(tab: String) -> void:
	# L'onglet Carte n'a pas de contenu propre : il bascule sur la carte du
	# monde plein écran, qui EST la carte du jeu (touche M).
	if tab == "carte":
		_open_map()
		return
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


## Attributs du personnage, dans l'ordre de la fiche. Constante partagée par la
## construction et le rafraîchissement : deux listes parallèles finiraient par
## diverger et une ligne afficherait la valeur d'une autre.
const STAT_IDS: Array = ["force", "dexterite", "endurance", "volonte", "perception", "charisme"]

## Valeur d'attribut correspondant à une barre pleine. Les attributs n'ont pas de
## maximum dans les règles ; il en faut pourtant un pour dessiner une jauge, et
## le choisir haut évite qu'un personnage avancé sature toutes ses barres et
## qu'elles cessent d'informer.
const STAT_BAR_MAX := 20.0

## Références vivantes de la fiche de personnage. La fiche est CONSTRUITE une
## fois et seulement MISE À JOUR ensuite : elle se rafraîchit trois fois par
## seconde tant que le menu est ouvert, et reconstruire une centaine de nœuds à
## cette cadence pour changer six chiffres est un gaspillage pur.
var _perso_stat_bars := {}
var _perso_vitals := {}
var _perso_equip_rows := {}
var _perso_protection: Label
var _perso_levels: Label
var _perso_gold: Label
var _perso_skills: VBoxContainer


## Fiche de personnage en TROIS COLONNES. Auparavant : un unique Label de
## cinquante lignes empilées, qui obligeait à lire de haut en bas pour trouver
## une information et laissait les trois quarts de l'écran vides. Les trois
## colonnes correspondent à trois questions distinctes — « comment je vais »,
## « ce que je porte », « ce que je sais faire » — et tiennent sans défilement.
func _build_personnage() -> Control:
	var columns := HBoxContainer.new()
	columns.visible = false
	columns.add_theme_constant_override("separation", UITheme.PAD_WIDE)
	columns.alignment = BoxContainer.ALIGNMENT_BEGIN

	columns.add_child(_perso_column_state())
	columns.add_child(_perso_column_equipment())
	columns.add_child(_perso_column_skills())
	return columns


## Colonne 1 — l'état immédiat : jauges vitales puis attributs. Les jauges
## d'abord parce que ce sont les seules valeurs qui changent en combat.
func _perso_column_state() -> Control:
	var box := _perso_section()
	box.add_child(UITheme.heading(tr("ui.menu.section_etat")))
	box.add_child(UITheme.rule())
	for gauge: Array in [["vie", "vie"], ["mana", "mana"], ["faim", "faim"],
			["fatigue", "fatigue"]]:
		var bar := StatBar.new()
		bar.setup(tr("ui.gauge." + String(gauge[0])), String(gauge[1]))
		bar.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		box.add_child(bar)
		_perso_vitals[String(gauge[0])] = bar

	_perso_gold = Label.new()
	_perso_gold.add_theme_font_size_override("font_size", UITheme.FONT_SMALL)
	_perso_gold.add_theme_color_override("font_color", UITheme.TEXT_ACCENT)
	box.add_child(_perso_gold)

	box.add_child(UITheme.heading(tr("ui.menu.section_attributs")))
	box.add_child(UITheme.rule())
	for stat_id: String in STAT_IDS:
		var bar := StatBar.new()
		bar.setup(tr("stat." + stat_id + ".name"), "progression")
		bar.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		box.add_child(bar)
		_perso_stat_bars[stat_id] = bar

	_perso_levels = Label.new()
	_perso_levels.add_theme_font_size_override("font_size", UITheme.FONT_SMALL)
	_perso_levels.add_theme_color_override("font_color", UITheme.TEXT_DIM)
	box.add_child(_perso_levels)
	return box.get_parent()


## Colonne 2 — l'équipement. Les treize emplacements sont TOUJOURS affichés,
## vides compris : la fiche sert autant à savoir ce qu'on porte qu'à voir ce
## qu'on pourrait porter.
func _perso_column_equipment() -> Control:
	var box := _perso_section()
	box.add_child(UITheme.heading(tr("ui.equipement.titre")))
	box.add_child(UITheme.rule())
	for slot: String in Equipment.SLOTS:
		var row := UITheme.field(tr("ui.slot." + slot), "", 110)
		box.add_child(row)
		_perso_equip_rows[slot] = row.get_child(1)
	box.add_child(UITheme.rule())
	_perso_protection = Label.new()
	_perso_protection.add_theme_font_size_override("font_size", UITheme.FONT_SMALL)
	_perso_protection.add_theme_color_override("font_color", UITheme.TEXT_ACCENT)
	box.add_child(_perso_protection)
	return box.get_parent()


## Colonne 3 — les compétences progressées, avec leur barre d'XP. Une compétence
## se lit à sa progression vers le niveau suivant, pas à son total d'XP brut :
## « 340 XP » ne dit rien, une barre aux trois quarts pleine dit tout.
func _perso_column_skills() -> Control:
	var box := _perso_section()
	box.add_child(UITheme.heading(tr("ui.inv.competences")))
	box.add_child(UITheme.rule())
	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_perso_skills = VBoxContainer.new()
	_perso_skills.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(_perso_skills)
	scroll.custom_minimum_size = Vector2(0, 260)
	box.add_child(scroll)
	return box.get_parent()


## Une colonne = un BLOC ENCADRÉ, pas une zone flottante. Le cadre n'est pas
## décoratif : sans lui, la valeur d'une jauge alignée à droite venait toucher
## l'intitulé de la colonne voisine et on lisait « 39/60 Tête ». Le fond et le
## filet disent où une colonne s'arrête.
##
## Retourne le VBox INTÉRIEUR : l'appelant remplit le contenu sans savoir qu'il
## y a un cadre autour, et `_build_personnage` ajoute quand même le bon nœud à
## l'arbre puisque le cadre est un ancêtre.
var _perso_frames: Array[Control] = []


func _perso_section() -> VBoxContainer:
	var frame := PanelContainer.new()
	frame.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	frame.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	var panel := VBoxContainer.new()
	panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	panel.add_theme_constant_override("separation", UITheme.GAP)
	frame.add_child(panel)
	_perso_frames.append(frame)
	return panel


func _build_royaume() -> Control:
	_royaume_label = Label.new()
	return _scroll_with(_royaume_label)


## Onglet Carte — DEUX cartes coexistaient (une miniature embarquée ici, et la
## vraie carte du monde sur M) avec des fonctionnalités divergentes : calques,
## POI, zoom et déplacement n'existaient que sur la seconde. L'onglet ouvre
## désormais CETTE carte (2026-07-27) ; la miniature est retirée.
func _build_carte() -> Control:
	var box := VBoxContainer.new()
	box.visible = false
	box.alignment = BoxContainer.ALIGNMENT_CENTER
	var label := Label.new()
	label.text = tr("ui.menu.carte_aide")
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(label)
	var open_button := Button.new()
	open_button.text = tr("ui.menu.ouvrir_carte")
	open_button.pressed.connect(_open_map)
	box.add_child(open_button)
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
	header.add_theme_font_size_override("font_size", UITheme.FONT_HEADING)
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
	title.add_theme_font_size_override("font_size", UITheme.FONT_BODY)
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


# --- Onglet COMBAT (2026-08-02) ------------------------------------------
#
# L'équipement des mains et le combat vivaient dans deux mondes qui ne se
# parlaient pas : on équipait un bouclier dans un menu contextuel, et on tenait
# une arme par la hotbar. Rien ne disait au joueur ce que ses deux mains
# faisaient ensemble, ni quelle compétence il entraînait.
#
# Cet onglet est cette réponse : les deux mains, la POSTURE qui en découle
# (GDD 6.2 : deux mains / arme + bouclier / deux armes), et les chiffres réels
# de ce qu'on porte. On n'y choisit pas une posture — on la constate, parce
# qu'elle se déduit de l'équipement et jamais d'un bouton.
var _combat_panel: EquipmentPanel
var _combat_stance: Label
var _combat_skill: Label
var _combat_stats: VBoxContainer
var _assembly_box: VBoxContainer


func _build_combat() -> Control:
	var box := VBoxContainer.new()
	box.visible = false
	box.add_theme_constant_override("separation", 10)

	_combat_panel = EquipmentPanel.new()
	_combat_panel.setup(_player, true)
	_combat_panel.changed.connect(_refresh_combat)
	box.add_child(_combat_panel)

	var hint := UITheme.dim(tr("ui.menu.combat_aide"))
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(hint)

	_combat_stance = Label.new()
	_combat_stance.add_theme_font_size_override("font_size", UITheme.FONT_HEADING)
	box.add_child(_combat_stance)
	_combat_skill = Label.new()
	box.add_child(_combat_skill)

	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_combat_stats = VBoxContainer.new()
	_combat_stats.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_combat_stats.add_theme_constant_override("separation", 2)
	scroll.add_child(_combat_stats)
	box.add_child(scroll)

	# --- ASSEMBLAGE DES COMPÉTENCES (GDD 5.1, 2026-08-03) ---
	# C'est ici qu'on fabrique ses sorts et ses attaques spéciales (choix de
	# l'auteur : « on assemble les compétences dans le menu combat »). Placé sous
	# les stats d'arme À DESSEIN : les slots disponibles dérivent du niveau dans
	# la compétence de l'arme équipée, qui se lit juste au-dessus.
	var sep := HSeparator.new()
	box.add_child(sep)
	var title := Label.new()
	title.text = tr("ui.menu.assemblage")
	title.add_theme_font_size_override("font_size", UITheme.FONT_HEADING)
	box.add_child(title)
	var aide := UITheme.dim(tr("ui.menu.assemblage_aide"))
	aide.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(aide)
	var asm_scroll := ScrollContainer.new()
	asm_scroll.custom_minimum_size = Vector2(0, 220)
	asm_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_assembly_box = VBoxContainer.new()
	_assembly_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_assembly_box.add_theme_constant_override("separation", 6)
	asm_scroll.add_child(_assembly_box)
	box.add_child(asm_scroll)
	return box


## Reconstruit l'ÉDITEUR D'ASSEMBLAGE (2026-08-03, réécrit).
##
## DEUX ZONES INDÉPENDANTES, sur demande de l'auteur : techniques d'ARME à
## gauche, SORTS à droite. Chacune a sa réserve de modules et ses propres slots,
## et un module ne peut aller que du bon côté. C'est un écart assumé avec le
## GDD 5.1 (« n'importe quel module dans n'importe quel slot ») ; la règle vit
## dans le modèle (Player.set_assembly), pas ici.
##
## DES CASES ET DU GLISSER-DÉPOSER, et non plus des listes déroulantes. Dans ce
## système l'ORDRE décide de tout : un modificateur avant ou après un effet donne
## deux sorts différents. Une liste déroulante DIT l'ordre mais ne permet pas de
## le CHANGER — il fallait vider et recomposer pour déplacer un module d'un cran.
func _refresh_assembly() -> void:
	if _assembly_box == null:
		return
	for child in _assembly_box.get_children():
		child.queue_free()

	var known: Dictionary = _player.known_modules
	if known.is_empty():
		_assembly_box.add_child(UITheme.dim(tr("ui.menu.assemblage_aucun_module")))
		return

	var columns := HBoxContainer.new()
	columns.add_theme_constant_override("separation", UITheme.GAP_WIDE)
	columns.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_assembly_box.add_child(columns)

	var weapon_family := String(_player.weapon_skill_id())
	columns.add_child(_build_assembly_column(
			weapon_family, tr("ui.menu.assemblage_armes"),
			tr("ui.menu.assemblage_sans_arme")))
	columns.add_child(_build_assembly_column(
			String(_player.SPELL_FAMILY), tr("ui.menu.assemblage_sorts"), ""))


## Une colonne : titre, réserve des modules du bon type, puis les slots.
func _build_assembly_column(family: String, title: String, empty_hint: String) -> Control:
	var column := VBoxContainer.new()
	column.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	column.add_theme_constant_override("separation", UITheme.GAP)

	var header := Label.new()
	header.text = title
	header.add_theme_color_override("font_color", UITheme.TEXT_ACCENT)
	column.add_child(header)

	if family.is_empty():
		# Côté ARMES sans arme équipée : les slots dérivent de la compétence de
		# l'arme, il n'y a donc rien à afficher tant qu'on n'en porte pas.
		column.add_child(UITheme.dim(empty_hint))
		return column

	var wanted := String(_player.family_book_type(family))
	var skill_id := String(_player.family_skill(family))
	column.add_child(UITheme.dim(tr("ui.menu.assemblage_niveau").format({
		"competence": tr("skill.%s.name" % skill_id),
		"niveau": str(_player.skills.level(skill_id))})))

	# --- Réserve : les modules APPRIS du bon type, triés par nom ---
	var pool: Array[String] = []
	for module_id: String in (_player.known_modules as Dictionary):
		var module: Dictionary = GameData.modules.get(module_id, {})
		if module.is_empty() or String(module.get("book_type", "grimoire")) != wanted:
			continue
		pool.append(module_id)
	pool.sort_custom(func(a: String, b: String) -> bool:
		return tr(String((GameData.modules[a] as Dictionary)["name_key"])) \
				< tr(String((GameData.modules[b] as Dictionary)["name_key"])))

	var reserve := GridContainer.new()
	reserve.columns = 2
	reserve.add_theme_constant_override("h_separation", UITheme.GAP)
	reserve.add_theme_constant_override("v_separation", UITheme.GAP)
	if pool.is_empty():
		column.add_child(UITheme.dim(tr("ui.menu.assemblage_reserve_vide")))
	else:
		for module_id in pool:
			var cell := ModuleSlot.new()
			cell.kind = "reserve"
			cell.family = family
			cell.module_id = module_id
			reserve.add_child(cell)
		column.add_child(reserve)

	column.add_child(UITheme.rule())

	# --- Slots d'assemblage ---
	var slot_count: int = _player.assembly_slot_count(family)
	var module_count: int = _player.assembly_module_count(family)
	for slot in slot_count:
		var current: Array = _player.assembly_at(family, slot)
		var line := HBoxContainer.new()
		line.add_theme_constant_override("separation", UITheme.GAP)
		var index_label := Label.new()
		index_label.text = str(slot + 1)
		index_label.custom_minimum_size.x = 16
		line.add_child(index_label)
		for position in module_count:
			var cell := ModuleSlot.new()
			cell.kind = "assemblage"
			cell.family = family
			cell.slot = slot
			cell.position_index = position
			cell.module_id = String(current[position]) if position < current.size() else ""
			cell.dropped.connect(_on_module_dropped)
			cell.cleared.connect(_on_module_cleared)
			line.add_child(cell)
		column.add_child(line)

		var compiled: Dictionary = SpellAssembly.compile(current, _player.known_modules)
		var summary := UITheme.dim("%s   —   %s" % [
				SpellAssembly.describe(compiled),
				tr("ui.menu.assemblage_cout").format({
					"cout": str(int(_player.assembly_cost(family, slot)))})])
		summary.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		column.add_child(summary)
	return column


## Un module a été déposé. On recompose l'assemblage CIBLE en entier, et on
## retire la source si elle venait d'un autre slot — c'est ce qui fait qu'un
## glissement DÉPLACE au lieu de dupliquer.
func _on_module_dropped(payload: Dictionary, target: ModuleSlot) -> void:
	var module_id := String(payload.get("module", ""))
	if module_id.is_empty():
		return
	var from_slot: bool = String(payload.get("kind", "")) == "assemblage"
	var src_family := String(payload.get("family", ""))
	var src_slot := int(payload.get("slot", -1))
	var src_position := int(payload.get("position", -1))

	# ÉCHANGE plutôt qu'écrasement quand les deux cases sont occupées et de la
	# même famille : c'est le geste attendu quand on réordonne, et il évite de
	# perdre le module qui se trouvait là.
	var displaced := target.module_id
	var cible: Array = (_player.assembly_at(target.family, target.slot) as Array).duplicate()
	while cible.size() <= target.position_index:
		cible.append("")
	cible[target.position_index] = module_id

	if from_slot and src_family == target.family and src_slot == target.slot:
		# Même slot : simple permutation interne.
		while cible.size() <= src_position:
			cible.append("")
		cible[src_position] = displaced
		_player.set_assembly(target.family, target.slot, _compact_ids(cible))
	else:
		_player.set_assembly(target.family, target.slot, _compact_ids(cible))
		if from_slot:
			# Venu d'un AUTRE slot : on l'en retire, sinon le module existerait
			# à deux endroits pour un seul glissement.
			var source: Array = (_player.assembly_at(src_family, src_slot) as Array).duplicate()
			if src_position >= 0 and src_position < source.size():
				source[src_position] = displaced
			_player.set_assembly(src_family, src_slot, _compact_ids(source))
	_refresh_assembly()


func _on_module_cleared(target: ModuleSlot) -> void:
	var current: Array = (_player.assembly_at(target.family, target.slot) as Array).duplicate()
	if target.position_index >= 0 and target.position_index < current.size():
		current.remove_at(target.position_index)
	_player.set_assembly(target.family, target.slot, _compact_ids(current))
	_refresh_assembly()


## Retire les trous. Un assemblage est une SUITE, pas une grille à cases vides :
## laisser un trou au milieu ferait croire à un emplacement réservé alors que
## l'interpréteur ne lit que la suite.
func _compact_ids(ids: Array) -> Array:
	var out: Array[String] = []
	for id: Variant in ids:
		if String(id) != "":
			out.append(String(id))
	return out


func _refresh_combat() -> void:
	if _combat_panel == null:
		return
	_combat_panel.refresh()
	var stance := String(_player.combat_stance())
	_combat_stance.text = tr("ui.posture." + stance)
	# La table vit sur le JOUEUR : `player.gd` n'a pas de `class_name`, on lit
	# donc la constante sur l'instance et non sur un type qui n'existe pas.
	var skill := String((_player.STANCE_SKILL as Dictionary).get(stance, ""))
	_combat_skill.text = "" if skill == "" else tr("ui.menu.posture_competence").format({
		"competence": tr("skill.%s.name" % skill)})
	_combat_skill.visible = skill != ""

	for child in _combat_stats.get_children():
		child.queue_free()
	_combat_line(tr("ui.slot.arme_1"), _player.call("_current_weapon_stats"))
	var offhand: Dictionary = _player.offhand_stats()
	if not offhand.is_empty():
		_combat_line(tr("ui.slot.arme_2"), offhand)
	var shield: Dictionary = _player.shield_profile()
	if bool(shield.get("present", false)):
		_combat_stats.add_child(UITheme.dim(tr("ui.combat.bouclier_ligne").format({
			"couverture": int(shield["couverture"]),
			"absorption": int(round(float(shield["absorption"]) * 100.0))})))
	_refresh_assembly()


## Une ligne de chiffres pour une main. Ce sont les valeurs RÉELLEMENT utilisées
## par le combat (WeaponStats), pas une copie : un écran qui recalculerait ses
## propres nombres finirait par mentir.
func _combat_line(title: String, stats: Dictionary) -> void:
	if stats.is_empty():
		return
	var header := Label.new()
	header.text = title
	header.add_theme_color_override("font_color", Color(0.6, 0.85, 1.0))
	_combat_stats.add_child(header)
	# RÉPERTOIRE : ce que l'arme sait faire. Sans cet affichage, le joueur
	# découvrirait par accident que sa masse ne pique pas — il croirait à un
	# bug de visée plutôt qu'à une propriété de l'arme.
	var names: Array[String] = []
	for direction: int in (stats.get("directions", []) as Array):
		names.append(tr("ui.direction." + MeleeAttack.direction_name(direction)))
	if not names.is_empty():
		_combat_stats.add_child(UITheme.dim(tr("ui.combat.attaques").format({
			"directions": ", ".join(names)})))
	_combat_stats.add_child(UITheme.dim(tr("ui.combat.fiche").format({
		"allonge": "%.2f" % float(stats.get("reach", 0.0)),
		"des": String(stats.get("dice", "")),
		"vitesse": "%.1f" % float(stats.get("speed", 0.0)),
		"parade": int(round(float(stats.get("parry_window_ms", 0.0)))),
		"endurance": "%.1f" % float(stats.get("stamina_cost", 0.0)),
		"mains": int(stats.get("hands", 1)),
	})))


var _inv_equipment: EquipmentPanel


func _build_inventaire() -> Control:
	# DEUX COLONNES (2026-08-02, demande de l'auteur) : le personnage et son
	# équipement à gauche, la liste à droite. On glisse donc un objet de la
	# liste DIRECTEMENT sur la silhouette pour l'équiper, au lieu de passer par
	# un menu contextuel qui n'affichait jamais ce qu'on portait déjà.
	var split := HBoxContainer.new()
	split.visible = false
	split.add_theme_constant_override("separation", 16)
	_inv_equipment = EquipmentPanel.new()
	_inv_equipment.setup(_player, false)
	_inv_equipment.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	# Le panneau d'équipement et la liste partagent le MÊME joueur : équiper
	# depuis la silhouette doit retirer l'objet de la liste dans la foulée.
	_inv_equipment.changed.connect(_refresh_inventory)
	split.add_child(_inv_equipment)

	var box := VBoxContainer.new()
	box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	box.add_theme_constant_override("separation", 8)
	split.add_child(box)

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
	_inv_scroll = scroll
	# LISTE VIRTUALISÉE : seules les lignes VISIBLES sont construites, et elles
	# se reconstruisent au défilement. Un inventaire complet fait des centaines
	# de lignes ; à ~1 ms la ligne, tout bâtir gèle l'ouverture, et le gel
	# grandit avec la partie. C'est le seul des trois correctifs qui tienne
	# encore à deux mille objets.
	scroll.get_v_scroll_bar().value_changed.connect(func(_v: float) -> void: _refresh_visible_rows())
	scroll.resized.connect(_refresh_visible_rows)

	# Bande de hotbar : cible du glisser-déposer, et rappel permanent de ce
	# qui est réellement accessible en jeu.
	var hotbar_header := HBoxContainer.new()
	var hotbar_title := Label.new()
	hotbar_title.text = tr("ui.menu.hotbar")
	hotbar_header.add_child(hotbar_title)
	var prev := Button.new()
	prev.text = "<"
	prev.pressed.connect(func() -> void: _change_bank(-1))
	hotbar_header.add_child(prev)
	_inv_bank_label = Label.new()
	hotbar_header.add_child(_inv_bank_label)
	var next := Button.new()
	next.text = ">"
	next.pressed.connect(func() -> void: _change_bank(1))
	hotbar_header.add_child(next)
	# Petite taille : c'est une aide, pas une donnée. En taille courante, cette
	# phrase à elle seule dépassait la largeur du panneau et se faisait rogner.
	var hint := UITheme.dim(tr("ui.menu.hotbar_aide"))
	hint.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	hotbar_header.add_child(hint)
	box.add_child(hotbar_header)

	_inv_hotbar = HBoxContainer.new()
	_inv_hotbar.add_theme_constant_override("separation", 6)
	for slot in _player.HOTBAR_SLOTS:
		_inv_hotbar.add_child(_hotbar_slot(slot))
	box.add_child(_inv_hotbar)
	return split


func _change_bank(delta: int) -> void:
	_inv_bank = wrapi(_inv_bank + delta, 0, _player.hotbar_bank_count())
	_refresh_inventory()


## Un emplacement de hotbar : accepte le dépôt d'une entrée d'inventaire,
## clic droit pour le vider.
func _hotbar_slot(slot: int) -> Control:
	var panel := PanelContainer.new()
	panel.custom_minimum_size = Vector2(SWATCH_SIZE + 12, SWATCH_SIZE + 12)
	panel.set_meta("slot", slot)
	var icon := TextureRect.new()
	icon.name = "Icon"
	icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	icon.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	panel.add_child(icon)
	# Numéro de la touche (1-9) : la bande de l'inventaire doit se lire comme
	# la hotbar en jeu, sinon on assigne à l'aveugle.
	var key_label := Label.new()
	key_label.text = str(slot + 1)
	key_label.add_theme_font_size_override("font_size", UITheme.FONT_SMALL)
	key_label.modulate = Color(1, 1, 1, 0.55)
	key_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	key_label.set_anchors_preset(Control.PRESET_TOP_LEFT)
	key_label.offset_left = 4
	key_label.offset_top = 1
	panel.add_child(key_label)
	# Le glisser-déposer de Godot passe par ces trois rappels sur la CIBLE.
	panel.set_drag_forwarding(Callable(), _can_drop_on_slot.bind(panel), _drop_on_slot.bind(panel))
	panel.gui_input.connect(_on_slot_input.bind(slot))
	return panel


func _can_drop_on_slot(_pos: Vector2, data: Variant, _panel: Control) -> bool:
	return data is Dictionary and (data as Dictionary).has("entry")


func _drop_on_slot(_pos: Vector2, data: Variant, panel: Control) -> void:
	var slot := int(panel.get_meta("slot", 0))
	_player.bind_hotbar(_inv_bank * _player.HOTBAR_SLOTS + slot, (data as Dictionary)["entry"])
	_refresh_inventory()


## Clic DROIT sur un emplacement : le libérer (l'objet reste en inventaire).
func _on_slot_input(event: InputEvent, slot: int) -> void:
	var button := event as InputEventMouseButton
	if button != null and button.pressed and button.button_index == MOUSE_BUTTON_RIGHT:
		_player.unbind_hotbar(_inv_bank * _player.HOTBAR_SLOTS + slot)
		_refresh_inventory()


## Rafraîchit la bande de hotbar depuis les liaisons du joueur.
func _refresh_hotbar_strip() -> void:
	if _inv_hotbar == null:
		return
	_inv_bank = mini(_inv_bank, _player.hotbar_bank_count() - 1)
	_inv_bank_label.text = "%d / %d" % [_inv_bank + 1, _player.hotbar_bank_count()]
	var entries: Array[Dictionary] = _player.hotbar_entries(_inv_bank)
	for slot in _inv_hotbar.get_child_count():
		var panel := _inv_hotbar.get_child(slot) as PanelContainer
		var icon := panel.get_node("Icon") as TextureRect
		var entry: Dictionary = entries[slot] if slot < entries.size() else {}
		if entry.is_empty():
			icon.texture = null
			panel.tooltip_text = tr("ui.menu.hotbar_vide")
			continue
		icon.texture = _entry_icon(entry, int(SWATCH_SIZE))
		panel.tooltip_text = _entry_name(entry)


# --- Rafraîchissement ---

func _refresh() -> void:
	if not is_open or _player == null:
		return
	match _current_tab:
		"personnage": _refresh_personnage()
		"combat": _refresh_combat()
		"inventaire": _refresh_inventory()
		"craft": _refresh_craft()
		"collection": _refresh_collection()
		"royaume": _refresh_royaume()


## Met à jour les VALEURS de la fiche, sans jamais toucher à sa structure.
func _refresh_personnage() -> void:
	if _perso_gold == null:
		return
	_perso_vitals["vie"].set_values(_player.health, _player.health_max)
	_perso_vitals["mana"].set_values(float(_player.mana.current), float(_player.mana.max_mana()))
	_perso_vitals["faim"].set_values(_player.hunger, _player.hunger_max)
	_perso_vitals["fatigue"].set_values(_player.fatigue, _player.fatigue_max)
	_perso_gold.text = tr("ui.hud.or").format({"or": str(_player.gold)})

	for stat_id: String in STAT_IDS:
		var value := float(_player.stats[stat_id])
		var bar: StatBar = _perso_stat_bars[stat_id]
		bar.set_values(value, STAT_BAR_MAX)

	_perso_levels.text = "%s   %s" % [
		tr("ui.menu.niveau_combat").format({"niveau": str(_derived_level("combat"))}),
		tr("ui.menu.niveau_general").format({"niveau": str(_derived_level("general"))})]

	# Équipement (6.2) : les 13 emplacements, dés de réduction compris (A.4.2).
	var equipment: Equipment = _player.equipment
	for slot: String in Equipment.SLOTS:
		var piece: Dictionary = equipment.equipped(slot)
		var cell: Label = _perso_equip_rows[slot]
		if piece.is_empty():
			cell.text = tr("ui.equipement.vide")
			cell.add_theme_color_override("font_color", UITheme.TEXT_DIM)
			continue
		var text := "%s (%s)" % [tr(String(piece.get("name_key", ""))),
			tr(ItemFactory.quality_tier_key(float(piece.get("quality", 1.0))))]
		var dice := Equipment.piece_dice(piece, slot)
		if dice != "":
			text += " %s" % dice
		cell.text = text
		cell.add_theme_color_override("font_color", UITheme.TEXT)
	var total_dice: String = equipment.total_armor_dice()
	_perso_protection.text = tr("ui.equipement.protection").format({
		"des": total_dice if total_dice != "" else "—"})

	_refresh_skill_list()


## Liste des compétences progressées. Reconstruite seulement quand sa COMPOSITION
## change : gagner de l'XP met à jour des barres existantes, débloquer une
## nouvelle compétence est le seul événement qui justifie de recréer des nœuds.
var _skill_bars := {}


func _refresh_skill_list() -> void:
	var skills: PlayerSkills = _player.skills
	var active: Array[String] = []
	for id: String in skills.skills:
		if int((skills.skills[id] as Dictionary)["level"]) > 0:
			active.append(id)
	active.sort()

	if active.hash() != _skill_bars.keys().hash():
		for child in _perso_skills.get_children():
			child.queue_free()
		_skill_bars.clear()
		if active.is_empty():
			_perso_skills.add_child(UITheme.dim(tr("ui.menu.aucune_competence")))
		for id: String in active:
			var bar := StatBar.new()
			bar.setup(tr(GameData.skills[id]["name_key"]), "xp")
			bar.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			_perso_skills.add_child(bar)
			_skill_bars[id] = bar

	for id: String in _skill_bars:
		var skill: Dictionary = skills.skills[id]
		var level := int(skill["level"])
		var bar: StatBar = _skill_bars[id]
		# Le CHIFFRE affiché est le niveau, la BARRE est la progression vers le
		# suivant : c'est la seule combinaison qui répond d'un coup d'œil aux
		# deux questions qu'on se pose (« j'en suis où » et « c'est loin »).
		bar.set_values(float(skill["xp"]), PlayerSkills.xp_next(level))
		bar.set_label("%s %d" % [tr(GameData.skills[id]["name_key"]), level])


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
	_refresh_hotbar_strip()
	if _inv_equipment != null:
		_inv_equipment.refresh()
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
		_inv_entries = []
		var empty := Label.new()
		empty.text = tr("ui.inv.vide")
		_inv_list.add_child(empty)
		return
	_inv_entries = entries
	# HAUTEUR DE LIGNE MESURÉE SUR UNE VRAIE LIGNE, pas devinée : elle dépend de
	# la police et des surcharges de thème, et une estimation fausse décale la
	# fenêtre visible d'autant plus qu'on descend.
	if _inv_row_height <= 0.0:
		var probe := _inventory_row(entries[0])
		_inv_list.add_child(probe)
		_inv_row_height = probe.custom_minimum_size.y + 2.0
		probe.queue_free()
		_inv_list.remove_child(probe)
	# Deux cales portent la hauteur des lignes NON construites : la barre de
	# défilement doit annoncer la taille de la liste ENTIÈRE, sinon on ne peut
	# atteindre que ce qui est déjà bâti.
	_inv_spacer_top = Control.new()
	_inv_spacer_bottom = Control.new()
	_inv_list.add_child(_inv_spacer_top)
	_inv_list.add_child(_inv_spacer_bottom)
	_inv_window = Vector2i(-1, -1)
	_refresh_visible_rows()


## (Re)construit la fenêtre de lignes visibles. Ne fait RIEN si la fenêtre n'a
## pas bougé — le signal de défilement se déclenche à chaque pixel, et
## reconstruire à chaque pixel serait pire que ne pas virtualiser du tout.
func _refresh_visible_rows() -> void:
	if _inv_list == null or _inv_scroll == null or _inv_entries.is_empty() or _inv_row_height <= 0.0:
		return
	var top := _inv_scroll.scroll_vertical
	var height := maxf(_inv_scroll.size.y, 1.0)
	var first := maxi(0, int(floorf(float(top) / _inv_row_height)) - INV_OVERSCAN)
	var last := mini(_inv_entries.size() - 1,
			int(ceilf((float(top) + height) / _inv_row_height)) + INV_OVERSCAN)
	if Vector2i(first, last) == _inv_window:
		return
	_inv_window = Vector2i(first, last)
	for child in _inv_list.get_children():
		if child != _inv_spacer_top and child != _inv_spacer_bottom:
			_inv_list.remove_child(child)
			child.queue_free()
	_inv_spacer_top.custom_minimum_size = Vector2(0, float(first) * _inv_row_height)
	_inv_spacer_bottom.custom_minimum_size = Vector2(0,
			float(_inv_entries.size() - 1 - last) * _inv_row_height)
	var index := 1  # Juste après la cale du haut.
	for i in range(first, last + 1):
		var row := _inventory_row(_inv_entries[i])
		_inv_list.add_child(row)
		_inv_list.move_child(row, index)
		index += 1


## Ligne d'inventaire : icône de bloc en CUBE (texturée si prête, sinon couleur)
## à gauche + nom/infos à droite (2026-07-26).
func _inventory_row(entry: Dictionary) -> Control:
	# Bouton plutôt que conteneur nu : la ligne est cliquable (menu d'actions)
	# ET source de glisser-déposer vers la hotbar.
	var button := Button.new()
	button.flat = true
	# Hauteur = vignette OU les deux lignes de texte, selon ce qui est le plus
	# haut. Avec la police pixel, un nom en taille courante plus un détail en
	# petite taille dépassent la vignette : à hauteur figée sur la seule
	# vignette, chaque ligne mordait sur la suivante.
	button.custom_minimum_size = Vector2(0,
		maxf(SWATCH_SIZE, UITheme.FONT_BODY + UITheme.FONT_SMALL + UITheme.GAP * 3) + UITheme.GAP)
	button.pressed.connect(_open_entry_menu.bind(entry, button))
	button.set_drag_forwarding(_drag_entry.bind(entry, button), Callable(), Callable())
	var row := HBoxContainer.new()
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.set_anchors_preset(Control.PRESET_FULL_RECT)
	row.add_theme_constant_override("separation", 10)
	button.add_child(row)
	var swatch := TextureRect.new()
	var rid: int = entry.get("rid", -1)
	var tex: Texture2D = null
	if rid >= 0:
		tex = BlockPreview.icon(rid)                     # bloc : cube texturé
	elif entry.has("obj"):
		var obj: Dictionary = entry["obj"]                # outil : sprite teinté
		var item: Dictionary = GameData.items.get(obj.get("item_id", ""), {})
		tex = WeaponPreview.item_icon(item, obj.get("materials", {}), SWATCH_SIZE)
	# MASQUE + TEINTE quand il n'y a pas encore d'icône rendue. Dessiner un cube
	# coloré par ligne coûtait 8 ms — 1735 ms pour 210 lignes, les trois quarts
	# du gel à l'ouverture de l'inventaire. La forme ne dépend pas de la couleur :
	# on partage une seule texture par taille et le GPU fait la multiplication.
	if tex != null:
		swatch.texture = tex
	else:
		swatch.texture = BlockIcon.cube_mask(SWATCH_SIZE)
		BlockIcon.tint_texture_rect(swatch, entry["swatch"])
	swatch.custom_minimum_size = Vector2(SWATCH_SIZE, SWATCH_SIZE)
	swatch.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	swatch.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	swatch.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	swatch.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(swatch)
	var texts := VBoxContainer.new()
	texts.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	texts.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	texts.add_theme_constant_override("separation", UITheme.GAP_TIGHT)
	var name_label := Label.new()
	name_label.text = entry["name"]
	name_label.add_theme_font_size_override("font_size", UITheme.FONT_BODY)
	texts.add_child(name_label)
	var info_label := Label.new()
	info_label.text = entry["info"]
	info_label.add_theme_font_size_override("font_size", UITheme.FONT_SMALL)
	info_label.add_theme_color_override("font_color", UITheme.TEXT_DIM)
	texts.add_child(info_label)
	row.add_child(texts)
	# Emplacement de hotbar occupé : le rappeler sur la ligne, sinon rien
	# n'indique qu'un objet est déjà accessible en jeu.
	var bound: int = _player.hotbar_index_of(_entry_to_player(entry))
	if bound >= 0:
		var badge := Label.new()
		badge.text = tr("ui.menu.hotbar_badge").format({
			"banque": str(bound / _player.HOTBAR_SLOTS + 1),
			"slot": str(bound % _player.HOTBAR_SLOTS + 1)})
		badge.add_theme_font_size_override("font_size", UITheme.FONT_SMALL)
		badge.add_theme_color_override("font_color", Color(0.6, 0.85, 1.0))
		badge.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		badge.custom_minimum_size = Vector2(70, 0)
		badge.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		row.add_child(badge)
	return button


## Convertit une entrée d'AFFICHAGE (liste triable) en entrée telle que le
## joueur la manipule (all_entries) — les deux structures diffèrent, et les
## liaisons de hotbar raisonnent sur la seconde.
func _entry_to_player(entry: Dictionary) -> Dictionary:
	if entry.get("kind", "") == "object":
		return {"kind": "object", "object": entry.get("obj", {})}
	return {"kind": "material", "id": String(entry.get("id", ""))}


## Données emportées par le glisser-déposer d'une ligne d'inventaire.
func _drag_entry(_pos: Vector2, entry: Dictionary, source: Control) -> Variant:
	var preview := TextureRect.new()
	preview.texture = _entry_icon(_entry_to_player(entry), int(SWATCH_SIZE))
	preview.custom_minimum_size = Vector2(SWATCH_SIZE, SWATCH_SIZE)
	# set_drag_preview appartient à Control : le menu est un CanvasLayer, c'est
	# le bouton SOURCE du glisser qui doit porter l'aperçu.
	source.set_drag_preview(preview)
	return {"entry": _entry_to_player(entry)}


## Icône d'une entrée (bloc texturé, outil teinté, ou pastille de ressource).
func _entry_icon(entry: Dictionary, size: int) -> Texture2D:
	if entry.get("kind", "") == "object":
		var obj: Dictionary = entry.get("object", {})
		var item: Dictionary = GameData.items.get(obj.get("item_id", ""), {})
		var tex := WeaponPreview.item_icon(item, obj.get("materials", {}), size)
		if tex != null:
			return tex
		return BlockIcon.item_texture(_object_color(obj), size)
	var id := String(entry.get("id", ""))
	var rid: int = GameData.material_runtime_ids.get(id, -1)
	if rid >= 0:
		var block_tex := BlockPreview.icon(rid)
		if block_tex != null:
			return block_tex
	var mat: Dictionary = GameData.stackable(id)
	return BlockIcon.cube_texture(Color.html(String(mat.get("color", "#888888"))), size)


func _entry_name(entry: Dictionary) -> String:
	if entry.get("kind", "") == "object":
		return tr(String((entry.get("object", {}) as Dictionary).get("name_key", "?")))
	return tr(String(GameData.stackable(String(entry.get("id", ""))).get("name_key", "?")))


## Menu d'ACTIONS d'une entrée (demande explicite 2026-07-27) : déposer,
## équiper, assigner à un emplacement de hotbar, détails. Les entrées non
## applicables sont désactivées plutôt que masquées — on voit ce qui existe.
func _open_entry_menu(entry: Dictionary, anchor: Control) -> void:
	_context_entry = entry
	var player_entry := _entry_to_player(entry)
	var menu := PopupMenu.new()
	add_child(menu)

	menu.add_item(tr("ui.menu.action.infos"), 0)

	var obj: Dictionary = entry.get("obj", {})
	var item: Dictionary = GameData.items.get(obj.get("item_id", ""), {})
	var equipable: bool = not obj.is_empty() and String(item.get("equip_slot", "")) != ""
	menu.add_item(tr("ui.menu.action.equiper"), 1)
	menu.set_item_disabled(menu.get_item_index(1), not equipable)

	# Sous-menu hotbar : banque -> emplacement.
	var hotbar_menu := PopupMenu.new()
	hotbar_menu.name = "HotbarMenu"
	for bank in _player.hotbar_bank_count():
		var bank_menu := PopupMenu.new()
		bank_menu.name = "Bank%d" % bank
		for slot in _player.HOTBAR_SLOTS:
			bank_menu.add_item(tr("ui.menu.action.slot").format({"slot": str(slot + 1)}),
					bank * _player.HOTBAR_SLOTS + slot)
		bank_menu.id_pressed.connect(func(index: int) -> void:
			_player.bind_hotbar(index, player_entry)
			menu.hide()
			_refresh_inventory())
		hotbar_menu.add_child(bank_menu)
		hotbar_menu.add_submenu_item(tr("ui.menu.action.banque").format({"banque": str(bank + 1)}), bank_menu.name)
	menu.add_child(hotbar_menu)
	menu.add_submenu_item(tr("ui.menu.action.hotbar"), hotbar_menu.name)

	var bound: int = _player.hotbar_index_of(player_entry)
	menu.add_item(tr("ui.menu.action.retirer_hotbar"), 2)
	menu.set_item_disabled(menu.get_item_index(2), bound < 0)

	menu.add_separator()
	menu.add_item(tr("ui.menu.action.deposer"), 3)

	menu.id_pressed.connect(func(id: int) -> void:
		match id:
			0: _show_entry_details(entry)
			1: _equip_entry(player_entry)
			2: _player.unbind_hotbar(bound)
			3: _drop_entry(player_entry)
		_refresh_inventory())
	menu.popup_hide.connect(menu.queue_free)
	menu.position = Vector2i(anchor.get_screen_position()) + Vector2i(int(SWATCH_SIZE), int(anchor.size.y))
	menu.popup()


func _equip_entry(player_entry: Dictionary) -> void:
	if player_entry.get("kind", "") != "object":
		return
	_player.equip_instance(player_entry.get("object", {}))


## Dépose au sol (A.10 : même mécanisme que les caches de mort).
func _drop_entry(player_entry: Dictionary) -> void:
	_player.drop_entry(player_entry)


func _show_entry_details(entry: Dictionary) -> void:
	var dialog := AcceptDialog.new()
	dialog.title = String(entry.get("name", "?"))
	dialog.dialog_text = "%s\n%s" % [entry.get("info", ""), _entry_detail_text(entry)]
	add_child(dialog)
	dialog.confirmed.connect(dialog.queue_free)
	dialog.canceled.connect(dialog.queue_free)
	dialog.popup_centered()


## Détail long : nutrition, bonus de potentiel, emplacement d'équipement.
func _entry_detail_text(entry: Dictionary) -> String:
	var lines: Array[String] = []
	var obj: Dictionary = entry.get("obj", {})
	var source: Dictionary = obj if not obj.is_empty() else GameData.stackable(String(entry.get("id", "")))
	var nutrition: Dictionary = source.get("nutrition", {})
	if nutrition.has("faim"):
		lines.append(tr("ui.menu.detail.nutrition").format({
			"faim": str(int(nutrition["faim"])),
			"cru": str(int(float(nutrition["faim"]) * 0.5))}))
	var potentiel: Dictionary = source.get("potentiel", {})
	for stat_id: String in potentiel:
		lines.append(tr("ui.menu.detail.potentiel").format({
			"stat": tr("stat." + stat_id + ".name"), "valeur": str(potentiel[stat_id])}))
	var item: Dictionary = GameData.items.get(obj.get("item_id", ""), {})
	if String(item.get("equip_slot", "")) != "":
		lines.append(tr("ui.menu.detail.emplacement").format({
			"slot": tr("ui.slot." + String(item["equip_slot"]))}))
	return "\n".join(lines)


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
				"quantite": int(obj.get("count", 1)),
				"durete": float(obj.get("base_hardness", 0.0)),
				"densite": 0.0,
				"valeur": 0.0,
				"poids": float(obj.get("weight", 0.0)),
			},
		})

	for id: String in inv.material_ids():
		# stackable() et non materials : sans ça les RESSOURCES (viandes,
		# peaux) disparaissaient purement et simplement de l'écran
		# d'inventaire — détenues, mais invisibles.
		var mat: Dictionary = GameData.stackable(id)
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
			# `id` INDISPENSABLE : sans lui, _entry_to_player() renvoyait
			# {"kind":"material","id":""} pour TOUTES les lignes, donc la même
			# liaison — d'où le badge de hotbar affiché sur chaque matériau
			# (bug visuel signalé le 2026-07-27).
			"id": id,
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
		header.add_theme_font_size_override("font_size", UITheme.FONT_BODY)
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
			mark.add_theme_font_size_override("font_size", UITheme.FONT_SMALL)
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
		var t: Texture2D = WeaponPreview.item_icon(item, {"bois": "chene", "minerai": "fer"}, 40)
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
	title.add_theme_font_size_override("font_size", UITheme.FONT_HEADING)
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

	_gem_selector(item_id)

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
	head.add_theme_font_size_override("font_size", UITheme.FONT_SMALL)
	_craft_detail.add_child(head)
	var grid := GridContainer.new()
	grid.columns = 3
	var stats: Dictionary = mat["stats"]
	for key: String in STAT_NAMES:
		var l := Label.new()
		l.text = "%s : %s" % [STAT_NAMES[key], str(stats.get(key, 0))]
		l.add_theme_font_size_override("font_size", UITheme.FONT_SMALL)
		l.modulate = Color(0.7, 0.73, 0.78)
		l.custom_minimum_size = Vector2(120, 0)
		grid.add_child(l)
	_craft_detail.add_child(grid)


## Catégories acceptables pour une entrée de recette : un LINGOT (métal
## raffiné) est utilisable partout où la recette demande du « minerai » — le
## joueur peut donc fondre son minerai en lingot pour un meilleur outil.
const CATEGORY_ALSO_ACCEPTS := {"minerai": ["lingot"]}


## Matériaux possédés de la catégorie donnée (+ catégories équivalentes), triés.
## Clé de choix du LOGEMENT DE GEMME. Distincte de la clé de catégorie
## `item_id + ":cristal"` : la gemme n'est pas une entrée de recette, et les
## confondre ferait consommer la pierre comme un composant obligatoire.
func _gem_choice_key(item_id: String) -> String:
	return item_id + ":gemme"


func _gem_choice(item_id: String) -> String:
	return String(_craft_choices.get(_gem_choice_key(item_id), ""))


## Logement de gemme FACULTATIF, affiché seulement sur les armes assemblées.
## Première entrée = « aucune », et c'est le défaut : sertir doit être un choix
## délibéré, pas quelque chose qu'on subit parce qu'on avait un quartz.
func _gem_selector(item_id: String) -> void:
	if not ItemFactory.accepts_gem(item_id):
		return
	var owned: Array[String] = []
	for mat_id: String in ItemFactory.gem_materials():
		if int(_player.inventory.material_stacks.get(mat_id, 0)) >= 1:
			owned.append(mat_id)

	var hb := HBoxContainer.new()
	hb.add_theme_constant_override("separation", 8)
	var lab := Label.new()
	lab.text = tr("ui.menu.craft_gemme")
	lab.custom_minimum_size = Vector2(130, 0)
	hb.add_child(lab)

	var option := OptionButton.new()
	option.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	option.add_item(tr("ui.menu.gemme_aucune"))
	for mat_id: String in owned:
		option.add_item("%s (%s)" % [tr(GameData.materials[mat_id]["name_key"]),
			Inventory.format_volume(_player.inventory.total_volume(mat_id))])
	var key := _gem_choice_key(item_id)
	var chosen := _gem_choice(item_id)
	var index := owned.find(chosen)
	# Une gemme dépensée entre deux ouvertures du menu ne doit pas laisser un
	# choix fantôme : on retombe sur « aucune ».
	if index < 0:
		_craft_choices[key] = ""
	option.selected = index + 1 if index >= 0 else 0
	var owned_ref := owned
	option.item_selected.connect(func(i: int) -> void:
		_craft_choices[key] = "" if i == 0 else owned_ref[i - 1]
		_build_craft_detail())
	hb.add_child(option)
	_craft_detail.add_child(hb)

	# Ce que la pierre apporte VRAIMENT, écrit noir sur blanc : elle ne change
	# ni les dégâts ni la dureté, elle ouvre l'enchantement et alourdit un peu.
	var note := Label.new()
	var current := _gem_choice(item_id)
	if current == "":
		note.text = tr("ui.menu.gemme_sans")
	else:
		var stats: Dictionary = (GameData.materials[current] as Dictionary)["stats"]
		note.text = tr("ui.menu.gemme_effet").format({
			"mana": str(int(stats.get("conductivite_mana", 0))),
			"poids": "%.2f" % (float(stats.get("densite", 0.0)) * ItemFactory.GEM_WEIGHT_SHARE)})
	note.modulate = Color(0.70, 0.74, 0.80)
	_craft_detail.add_child(note)


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
	# GEMME facultative : vérifiée dans le même temps que le reste, pour ne
	# jamais consommer les composants d'une arme dont la pierre a disparu entre
	# l'affichage et le clic.
	var gem := _gem_choice(item_id)
	if gem != "" and ItemFactory.accepts_gem(item_id):
		if int(_player.inventory.material_stacks.get(gem, 0)) < 1:
			return
		choices[ItemFactory.GEM_CATEGORY] = gem
	else:
		gem = ""

	for input: Dictionary in inputs:
		_player.inventory.remove_material(choices[input["category"]], int(input["amount"]))
	if gem != "":
		_player.inventory.remove_material(gem, 1)

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
	# Ressource (viande, peau) : couleur portée par l'instance elle-même,
	# dérivée de l'espèce source — elle n'a pas de matériaux de craft.
	if obj.has("color"):
		return Color.html(String(obj["color"]))
	var materials: Dictionary = obj.get("materials", {})
	for category in materials:
		var mat: Dictionary = GameData.materials.get(materials[category], {})
		if not mat.is_empty():
			return Color.html(mat["color"])
	return Color(0.5, 0.5, 0.5)


# --- Collection (2026-08-01) -------------------------------------------------
#
# « Un des objectifs du joueur est de collectionner tous les items du jeu. »
# Cet onglet est donc une VITRINE, pas une liste : on doit voir d'un coup d'œil
# ce qui manque, et le manque doit se lire comme un trou dans une étagère.
#
# PAGINATION plutôt que défilement. Le catalogue est un objet qu'on parcourt,
# pas un flux : la page 3 reste la page 3 et le joueur s'en souvient. Un long
# défilement effacerait ce repère, et une grille de plusieurs centaines de
# vignettes n'a de toute façon pas de forme lisible.

## Vignettes par page. 8 colonnes × 5 rangées : la grille reste carrée à l'œil
## et une page entière tient sans défilement à la définition de référence.
const COLLECTION_COLUMNS := 8
const COLLECTION_ROWS := 5
const COLLECTION_PER_PAGE := COLLECTION_COLUMNS * COLLECTION_ROWS

## Critères de tri : (clé de langue, identifiant interne).
const COLLECTION_SORTS: Array = [
	["ui.collection.tri_etat", "etat"],
	["ui.collection.tri_nom", "nom"],
	["ui.collection.tri_type", "type"],
	["ui.collection.tri_qualite", "qualite"],
]

var _collection_grid: GridContainer
var _collection_progress: StatBar
var _collection_page_label: Label
var _collection_detail: VBoxContainer
var _collection_page := 0
var _collection_sort := 0
var _collection_selected := ""


func _build_collection() -> Control:
	var root := HBoxContainer.new()
	root.visible = false
	root.add_theme_constant_override("separation", UITheme.PAD_WIDE)

	# --- Colonne gauche : la vitrine ---
	var left := PanelContainer.new()
	left.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", UITheme.GAP)
	left.add_child(box)

	_collection_progress = StatBar.new()
	_collection_progress.setup(tr("ui.menu.onglet.collection"), "xp")
	_collection_progress.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	box.add_child(_collection_progress)
	box.add_child(UITheme.rule())

	var controls := HBoxContainer.new()
	controls.add_theme_constant_override("separation", UITheme.GAP_WIDE)
	controls.add_child(UITheme.dim(tr("ui.collection.tri")))
	var sort_option := OptionButton.new()
	for entry: Array in COLLECTION_SORTS:
		sort_option.add_item(tr(String(entry[0])))
	sort_option.selected = _collection_sort
	sort_option.item_selected.connect(func(index: int) -> void:
		_collection_sort = index
		# Retour à la première page : après un tri, la page 3 ne contient plus
		# ce qu'elle contenait, et y rester désoriente.
		_collection_page = 0
		_refresh_collection())
	controls.add_child(sort_option)

	var previous := Button.new()
	previous.text = "<"
	previous.pressed.connect(func() -> void: _turn_collection_page(-1))
	controls.add_child(previous)
	_collection_page_label = Label.new()
	_collection_page_label.add_theme_font_size_override("font_size", UITheme.FONT_SMALL)
	_collection_page_label.custom_minimum_size = Vector2(130, 0)
	_collection_page_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_collection_page_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	controls.add_child(_collection_page_label)
	var next := Button.new()
	next.text = ">"
	next.pressed.connect(func() -> void: _turn_collection_page(1))
	controls.add_child(next)
	box.add_child(controls)

	_collection_grid = GridContainer.new()
	_collection_grid.columns = COLLECTION_COLUMNS
	box.add_child(_collection_grid)
	root.add_child(left)

	# --- Colonne droite : la pièce sélectionnée ---
	var right := PanelContainer.new()
	right.custom_minimum_size = Vector2(360, 0)
	right.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	_collection_detail = VBoxContainer.new()
	_collection_detail.add_theme_constant_override("separation", UITheme.GAP)
	right.add_child(_collection_detail)
	root.add_child(right)
	return root


func _turn_collection_page(delta: int) -> void:
	var pages := _collection_pages()
	_collection_page = wrapi(_collection_page + delta, 0, pages)
	_refresh_collection()


func _collection_pages() -> int:
	return maxi(1, ceili(float(Collection.catalogue().size()) / float(COLLECTION_PER_PAGE)))


## Catalogue trié selon le critère courant.
func _collection_sorted() -> Array[String]:
	var collection: Collection = _player.collection
	var keys := Collection.catalogue()
	var mode := String(COLLECTION_SORTS[_collection_sort][1])
	match mode:
		"nom":
			keys.sort_custom(func(a: String, b: String) -> bool:
				return tr(Collection.name_key_of(a)) < tr(Collection.name_key_of(b)))
		"type":
			keys.sort_custom(func(a: String, b: String) -> bool:
				var ka := Collection.kind_of(a)
				var kb := Collection.kind_of(b)
				if ka == kb:
					return tr(Collection.name_key_of(a)) < tr(Collection.name_key_of(b))
				return ka < kb)
		"etat":
			# MANQUANTS D'ABORD : c'est le tri d'un collectionneur, celui qui
			# répond à « qu'est-ce qu'il me reste à trouver ».
			keys.sort_custom(func(a: String, b: String) -> bool:
				var ha := collection.has(a)
				var hb := collection.has(b)
				if ha == hb:
					return tr(Collection.name_key_of(a)) < tr(Collection.name_key_of(b))
				return not ha)
		"qualite":
			keys.sort_custom(func(a: String, b: String) -> bool:
				var qa := collection.quality_of(a)
				var qb := collection.quality_of(b)
				if is_equal_approx(qa, qb):
					return tr(Collection.name_key_of(a)) < tr(Collection.name_key_of(b))
				return qa > qb)
	return keys


func _refresh_collection() -> void:
	if _collection_grid == null:
		return
	var collection: Collection = _player.collection
	var progress := collection.progress()
	_collection_progress.set_values(float(progress["offerts"]), float(progress["total"]))

	var pages := _collection_pages()
	_collection_page = clampi(_collection_page, 0, pages - 1)
	_collection_page_label.text = tr("ui.collection.page").format({
		"page": str(_collection_page + 1), "pages": str(pages)})

	for child in _collection_grid.get_children():
		child.queue_free()
	var keys := _collection_sorted()
	var start := _collection_page * COLLECTION_PER_PAGE
	for offset in COLLECTION_PER_PAGE:
		var index := start + offset
		if index >= keys.size():
			break
		_collection_grid.add_child(_collection_slot(keys[index]))
	_build_collection_detail()


## Une vignette. Une pièce OFFERTE s'affiche en couleur ; une pièce manquante
## reste une silhouette éteinte — c'est ce contraste, et lui seul, qui fait
## qu'une étagère incomplète se voit sans être lue.
func _collection_slot(key: String) -> Control:
	var collection: Collection = _player.collection
	var owned := collection.has(key)
	var button := Button.new()
	button.custom_minimum_size = Vector2(UITheme.SLOT + 12, UITheme.SLOT + 12)
	button.tooltip_text = tr(Collection.name_key_of(key))
	button.pressed.connect(func() -> void:
		_collection_selected = key
		_build_collection_detail())
	var icon := TextureRect.new()
	icon.set_anchors_preset(Control.PRESET_FULL_RECT)
	icon.texture = _collection_icon(key)
	icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	icon.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	# Silhouette : la même icône, presque noire. Pas d'icône « point
	# d'interrogation » — la forme de ce qui manque est déjà une information,
	# et c'est ce qui donne envie d'aller le chercher.
	icon.modulate = Color.WHITE if owned else Color(0.16, 0.17, 0.21, 0.85)
	button.add_child(icon)
	if key == _collection_selected:
		button.add_theme_stylebox_override("normal", button.get_theme_stylebox("pressed"))
	return button


func _collection_icon(key: String) -> Texture2D:
	var item: Dictionary = GameData.items.get(key, {})
	if not item.is_empty():
		var tex: Texture2D = WeaponPreview.item_icon(item,
			{"bois": "chene", "minerai": "fer", "textile": "lin"}, int(SWATCH_SIZE))
		if tex != null:
			return tex
	var resource: Dictionary = GameData.resources.get(key, {})
	var color := Color.html(String(resource.get("color", "#8A8A8A")))
	return BlockIcon.cube_texture(color, int(SWATCH_SIZE))


## Panneau de droite : ce qu'on sait de la pièce, et le bouton qui la sacrifie.
func _build_collection_detail() -> void:
	if _collection_detail == null:
		return
	for child in _collection_detail.get_children():
		child.queue_free()
	if _collection_selected == "":
		_collection_detail.add_child(UITheme.dim(tr("ui.collection.manquant"), false))
		return

	var key := _collection_selected
	var collection: Collection = _player.collection
	_collection_detail.add_child(UITheme.heading(tr(Collection.name_key_of(key))))
	_collection_detail.add_child(UITheme.rule())
	_collection_detail.add_child(UITheme.field(
		tr("ui.collection.tri_type"), Collection.kind_of(key), 110))

	if collection.has(key):
		var entry: Dictionary = collection.entries[key]
		var owned_quality := float(entry.get("quality", 1.0))
		_collection_detail.add_child(UITheme.field(tr("ui.collection.tri_qualite"),
			"%.2f — %s" % [owned_quality, tr(ItemFactory.quality_tier_key(owned_quality))], 110))
	else:
		_collection_detail.add_child(UITheme.dim(tr("ui.collection.manquant")))

	# Le MEILLEUR exemplaire en inventaire : c'est celui qu'on proposera, parce
	# qu'offrir le pire alors qu'on a mieux ne sert à rien et qu'obliger le
	# joueur à trier lui-même serait une corvée.
	var best := _best_owned_for(key)
	if best.is_empty():
		_collection_detail.add_child(UITheme.dim(tr("ui.collection.rien_a_offrir")))
		return
	if not collection.would_improve(best):
		_collection_detail.add_child(UITheme.dim(tr("ui.collection.deja_mieux")))
		return

	var quality := float(best.get("quality", 1.0))
	_collection_detail.add_child(UITheme.dim(tr("ui.collection.qualite").format({
		"palier": tr(ItemFactory.quality_tier_key(quality))})))
	var donate := Button.new()
	donate.text = tr("ui.collection.offrir")
	donate.add_theme_color_override("font_color", UITheme.TEXT_WARN)
	var uid := int(best["uid"])
	donate.pressed.connect(func() -> void:
		_player.donate_to_collection(uid)
		_refresh_collection())
	_collection_detail.add_child(donate)


## Meilleur exemplaire possédé de ce type, ou {}.
func _best_owned_for(key: String) -> Dictionary:
	var best := {}
	for instance: Dictionary in _player.inventory.objects:
		if Collection.key_of(instance) != key:
			continue
		if best.is_empty() or float(instance.get("quality", 1.0)) > float(best.get("quality", 1.0)):
			best = instance
	return best
