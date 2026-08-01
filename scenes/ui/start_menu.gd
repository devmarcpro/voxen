class_name StartMenu
extends CanvasLayer

## Langues proposées : (code de locale, libellé natif). Les libellés ne
## sont JAMAIS traduits — une langue se nomme dans sa propre langue.
## Ajouter une entrée ici suffit : le reste (validation, couverture,
## fichiers .translation) est piloté par GameData et project.godot.
const LOCALES: Array = [
	["fr", "Français"],
	["en", "English"],
	["ja", "日本語"],
	["zh_Hans", "简体中文"],
]
## Menu de démarrage (2026-07-21, demande explicite) — construit en code
## comme le reste de l'UI du projet, textes via tr() (10.1, jamais en dur).
## Structure : Solo (Continuer / liste des mondes / Nouvelle partie) ·
## Multijoueur (Héberger / Rejoindre) · Paramètres (langue) · Quitter.
## « Nouvelle partie » : nom du monde + graine + TOUS les paramètres de
## génération (relief quasi plat → montagneux, niveau de la mer, climat,
## densité d'arbres, rivières/cavernes on/off, biome forcé — un monde
## « tout désert » se fait ici). Les paramètres partent dans
## SaveManager.prepare_new_world → world.json → NoiseGenerator.
## Le menu ÉMET `world_ready` quand un monde est choisi ; main.gd démarre
## alors le monde (WorldManager.initialize_world) et le menu se détruit.

signal world_ready

const PANEL_MIN_WIDTH := 460.0

var _bg: ColorRect
var _center: CenterContainer
var _panels := {}              # nom -> VBoxContainer
var _solo_status: Label
var _solo_worlds_box: VBoxContainer
var _name_edit: LineEdit
var _seed_edit: LineEdit
var _relief_slider: HSlider
var _sea_slider: HSlider
var _temp_slider: HSlider
var _hum_slider: HSlider
var _trees_slider: HSlider
var _rivers_check: CheckBox
var _caves_check: CheckBox
var _biome_option: OptionButton
var _biome_ids: Array[String] = []
var _preview_rect: TextureRect
## Résolution de l'aperçu du monde (pixels) — échantillonné sur toute l'étendue.
const PREVIEW_SIZE := 192
## État de l'aperçu courant (pour le nommage + le choix de spawn au clic).
var _preview_gen: NoiseGenerator
var _preview_regions := {}
var _preview_r := 0
var _preview_span := 1.0
var _chosen_spawn: Variant = null   # Vector2i choisi au clic, ou null (auto).
var _preview_names_label: Label
var _ip_edit: LineEdit
## Création de personnage.
const BASE_STAT := 5
const MAX_STAT := 15
const BASE_POINTS := 30
const CHAR_STATS: Array[String] = ["force", "dexterite", "endurance", "volonte", "perception", "charisme"]
var _char_race_option: OptionButton
var _char_class_option: OptionButton
var _race_ids: Array[String] = []
var _class_ids: Array[String] = []
var _stat_alloc := {}          # stat -> points ajoutés au-dessus de BASE_STAT
var _stat_value_labels := {}
var _points_label: Label
var _char_summary: Label


func _ready() -> void:
	layer = 95
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	_build()


func _build() -> void:
	_bg = ColorRect.new()
	_bg.color = Color(0.07, 0.08, 0.1)
	_bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(_bg)
	_center = CenterContainer.new()
	_center.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(_center)
	_panels["main"] = _build_main()
	_panels["solo"] = _build_solo()
	_panels["new"] = _build_new_world()
	_panels["character"] = _build_character()
	_panels["multi"] = _build_multi()
	_panels["settings"] = _build_settings()
	for p: String in _panels:
		_center.add_child(_panels[p])
	_show_panel("main")


func _show_panel(which: String) -> void:
	for p: String in _panels:
		(_panels[p] as Control).visible = p == which
	if which == "solo":
		_refresh_worlds()
	elif which == "character":
		_refresh_character()


# --- Panneaux ---

func _build_main() -> VBoxContainer:
	var box := _panel_box()
	var title := Label.new()
	title.text = tr("ui.menu.titre")
	title.add_theme_font_size_override("font_size", UITheme.FONT_TITLE)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(title)
	box.add_child(_spacer(24))
	box.add_child(_button("ui.menu.solo", func() -> void: _show_panel("solo")))
	box.add_child(_button("ui.menu.multi", func() -> void: _show_panel("multi")))
	box.add_child(_button("ui.menu.parametres", func() -> void: _show_panel("settings")))
	box.add_child(_spacer(12))
	box.add_child(_button("ui.menu.quitter", func() -> void: get_tree().quit()))
	return box


func _build_solo() -> VBoxContainer:
	var box := _panel_box()
	box.add_child(_title_label("ui.menu.solo"))
	box.add_child(_button("ui.menu.continuer", _on_continue))
	box.add_child(_spacer(8))
	# Liste DÉFILANTE : le nombre de mondes n'est plus plafonné, la hauteur
	# de l'écran ne doit donc plus limiter ce qu'on peut voir et charger.
	var worlds_scroll := ScrollContainer.new()
	worlds_scroll.custom_minimum_size = Vector2(0, 320)
	worlds_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_solo_worlds_box = VBoxContainer.new()
	_solo_worlds_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	worlds_scroll.add_child(_solo_worlds_box)
	box.add_child(worlds_scroll)
	_solo_status = Label.new()
	_solo_status.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(_solo_status)
	box.add_child(_spacer(8))
	box.add_child(_button("ui.menu.nouvelle", func() -> void: _show_panel("new")))
	box.add_child(_button("ui.menu.retour", func() -> void: _show_panel("main")))
	return box


## Liste des mondes existants (reconstruite à chaque ouverture du panneau).
func _refresh_worlds() -> void:
	for child in _solo_worlds_box.get_children():
		child.queue_free()
	var worlds := SaveManager.list_worlds()
	_solo_status.text = tr("ui.menu.aucun_monde") if worlds.is_empty() else \
			tr("ui.menu.nb_mondes").format({"nb": str(worlds.size())})
	# Plus de plafond d'affichage : la liste montrait `slice(0, 8)`, donc les
	# mondes au-delà du 8e devenaient invisibles ET irrécupérables depuis le
	# menu. Elle est désormais complète et défilante.
	for world: Dictionary in worlds:
		var day := int(world["ticks"]) / 24000 + 1
		var row := HBoxContainer.new()
		var b := Button.new()
		b.text = "%s — %s" % [world["name"],
			tr("ui.menu.monde_info").format({"graine": str(world["seed"]), "jour": str(day)})]
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		var dir: String = world["dir"]
		b.pressed.connect(func() -> void: _on_load_world(dir))
		row.add_child(b)
		var del := Button.new()
		del.text = tr("ui.menu.supprimer")
		del.pressed.connect(func() -> void: _confirm_delete(dir, String(world["name"])))
		row.add_child(del)
		_solo_worlds_box.add_child(row)


## Suppression d'un monde : TOUJOURS confirmée. Un clic malheureux effacerait
## des dizaines d'heures de jeu, et rien ne permettrait de revenir en arrière.
func _confirm_delete(dir: String, world_name: String) -> void:
	var dialog := ConfirmationDialog.new()
	dialog.dialog_text = tr("ui.menu.supprimer_confirme").format({"monde": world_name})
	dialog.ok_button_text = tr("ui.menu.supprimer")
	dialog.confirmed.connect(func() -> void:
		SaveManager.delete_world(dir)
		_refresh_worlds())
	dialog.visibility_changed.connect(func() -> void:
		if not dialog.visible:
			dialog.queue_free())
	add_child(dialog)
	dialog.popup_centered()


func _build_new_world() -> VBoxContainer:
	var box := _panel_box()
	box.add_child(_title_label("ui.menu.nouvelle"))

	var name_row := HBoxContainer.new()
	name_row.add_child(_row_label("ui.menu.nom_monde"))
	_name_edit = LineEdit.new()
	_name_edit.text = tr("ui.menu.nom_defaut")
	_name_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name_row.add_child(_name_edit)
	box.add_child(name_row)

	var seed_row := HBoxContainer.new()
	seed_row.add_child(_row_label("ui.menu.graine"))
	_seed_edit = LineEdit.new()
	_seed_edit.text = str(randi() % 1000000)
	_seed_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	seed_row.add_child(_seed_edit)
	var reroll := Button.new()
	reroll.text = "🎲"
	reroll.pressed.connect(func() -> void: _seed_edit.text = str(randi() % 1000000))
	seed_row.add_child(reroll)
	box.add_child(seed_row)

	box.add_child(_spacer(8))
	# Paramètres de génération (NoiseGenerator) : relief 0 = plat, 1 = normal.
	_relief_slider = _slider_row(box, "ui.menu.relief", 0.0, 2.0, 0.05, 1.0)
	_sea_slider = _slider_row(box, "ui.menu.niveau_mer", -8.0, 8.0, 1.0, 0.0)
	_temp_slider = _slider_row(box, "ui.menu.temperature", -0.5, 0.5, 0.05, 0.0)
	_hum_slider = _slider_row(box, "ui.menu.humidite", -0.5, 0.5, 0.05, 0.0)
	_trees_slider = _slider_row(box, "ui.menu.arbres", 0.0, 3.0, 0.1, 1.0)

	var checks := HBoxContainer.new()
	_rivers_check = CheckBox.new()
	_rivers_check.text = tr("ui.menu.rivieres")
	_rivers_check.button_pressed = true
	checks.add_child(_rivers_check)
	_caves_check = CheckBox.new()
	_caves_check.text = tr("ui.menu.cavernes")
	_caves_check.button_pressed = true
	checks.add_child(_caves_check)
	box.add_child(checks)

	var biome_row := HBoxContainer.new()
	biome_row.add_child(_row_label("ui.menu.biome_force"))
	_biome_option = OptionButton.new()
	_biome_option.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_biome_option.add_item(tr("ui.menu.biome_aucun"))
	_biome_ids = ["" ]
	var biome_ids: Array = GameData.biomes.keys()
	biome_ids.sort()
	for id: String in biome_ids:
		_biome_option.add_item(tr(GameData.biomes[id]["name_key"]))
		_biome_ids.append(id)
	biome_row.add_child(_biome_option)
	box.add_child(biome_row)

	box.add_child(_spacer(8))
	# Aperçu du monde (possible car monde fini + déterministe, 2026-07-26).
	box.add_child(_button("ui.menu.apercu", _render_world_preview))
	var hint := Label.new()
	hint.text = tr("ui.menu.spawn_hint")
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(hint)
	_preview_rect = TextureRect.new()
	_preview_rect.custom_minimum_size = Vector2(PREVIEW_SIZE, PREVIEW_SIZE)
	_preview_rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_preview_rect.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	_preview_rect.mouse_filter = Control.MOUSE_FILTER_STOP
	_preview_rect.gui_input.connect(_on_preview_clicked)
	var preview_center := HBoxContainer.new()
	preview_center.alignment = BoxContainer.ALIGNMENT_CENTER
	preview_center.add_child(_preview_rect)
	box.add_child(preview_center)
	_preview_names_label = Label.new()
	_preview_names_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_preview_names_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_preview_names_label.custom_minimum_size = Vector2(PREVIEW_SIZE + 40, 0)
	box.add_child(_preview_names_label)

	box.add_child(_spacer(12))
	box.add_child(_button("ui.menu.creer", _on_create))
	box.add_child(_button("ui.menu.retour", func() -> void: _show_panel("solo")))
	return box


## Création de personnage (6.1/C.1-C.3) : race, classe, 30 points à répartir
## (base 5, max 15) + les points bonus de la classe (Vagabond). L'apparence
## (parties de corps, section 12) est différée (bibliothèque .vox inexistante).
func _build_character() -> VBoxContainer:
	var box := _panel_box()
	box.add_child(_title_label("ui.menu.creation_perso"))

	# Race + classe (OptionButton). Leur bonus s'affiche dans le résumé.
	var race_ids: Array = GameData.races.keys()
	race_ids.sort()
	var race_row := HBoxContainer.new()
	race_row.add_child(_row_label("ui.menu.race"))
	_char_race_option = OptionButton.new()
	_char_race_option.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	for id: String in race_ids:
		_char_race_option.add_item(tr(GameData.races[id]["name_key"]))
		_race_ids.append(id)
	_char_race_option.item_selected.connect(func(_i: int) -> void: _refresh_character())
	race_row.add_child(_char_race_option)
	box.add_child(race_row)

	var class_ids: Array = GameData.classes.keys()
	class_ids.sort()
	var class_row := HBoxContainer.new()
	class_row.add_child(_row_label("ui.menu.classe"))
	_char_class_option = OptionButton.new()
	_char_class_option.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	for id: String in class_ids:
		_char_class_option.add_item(tr(GameData.classes[id]["name_key"]))
		_class_ids.append(id)
	_char_class_option.item_selected.connect(func(_i: int) -> void: _refresh_character())
	class_row.add_child(_char_class_option)
	box.add_child(class_row)

	box.add_child(_spacer(6))
	_points_label = Label.new()
	_points_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(_points_label)

	# Une ligne par stat : libellé, − / valeur / +.
	for stat_id: String in CHAR_STATS:
		_stat_alloc[stat_id] = 0
		var srow := HBoxContainer.new()
		srow.add_child(_row_label("stat." + stat_id + ".name"))
		var minus := Button.new()
		minus.text = "−"
		minus.pressed.connect(_adjust_stat.bind(stat_id, -1))
		srow.add_child(minus)
		var value := Label.new()
		value.custom_minimum_size.x = 40.0
		value.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		_stat_value_labels[stat_id] = value
		srow.add_child(value)
		var plus := Button.new()
		plus.text = "+"
		plus.pressed.connect(_adjust_stat.bind(stat_id, 1))
		srow.add_child(plus)
		box.add_child(srow)

	box.add_child(_spacer(6))
	_char_summary = Label.new()
	_char_summary.autowrap_mode = TextServer.AUTOWRAP_WORD
	_char_summary.custom_minimum_size.x = PANEL_MIN_WIDTH
	box.add_child(_char_summary)

	box.add_child(_spacer(8))
	box.add_child(_button("ui.menu.commencer", _on_start_character))
	box.add_child(_button("ui.menu.retour", func() -> void: _show_panel("new")))
	return box


## Points de création disponibles = base + bonus de classe (Vagabond +15).
func _total_points() -> int:
	var cls: Dictionary = GameData.classes.get(_class_ids[_char_class_option.selected], {})
	return BASE_POINTS + int(cls.get("extra_points", 0))


func _points_spent() -> int:
	var spent := 0
	for stat_id in _stat_alloc:
		spent += int(_stat_alloc[stat_id])
	return spent


func _adjust_stat(stat_id: String, delta: int) -> void:
	var new_val := int(_stat_alloc[stat_id]) + delta
	if new_val < 0 or BASE_STAT + new_val > MAX_STAT:
		return
	if delta > 0 and _points_spent() >= _total_points():
		return  # Plus de points disponibles.
	_stat_alloc[stat_id] = new_val
	_refresh_character()


func _refresh_character() -> void:
	if _points_label == null:
		return
	var race: Dictionary = GameData.races.get(_race_ids[_char_race_option.selected], {})
	var cls: Dictionary = GameData.classes.get(_class_ids[_char_class_option.selected], {})
	# Changer de classe peut réduire le budget (Vagabond +15 → autre) : si
	# l'allocation courante dépasse, on la remet à zéro (jamais de dépassement).
	if _points_spent() > _total_points():
		for stat_id in _stat_alloc:
			_stat_alloc[stat_id] = 0
	_points_label.text = tr("ui.menu.points_restants").format({
		"restants": str(_total_points() - _points_spent()), "total": str(_total_points())})
	# Valeur affichée = base + réparti + bonus race + bonus classe.
	for stat_id: String in CHAR_STATS:
		var value := BASE_STAT + int(_stat_alloc[stat_id])
		value += int((race.get("stat_bonuses", {}) as Dictionary).get(stat_id, 0))
		value += int((cls.get("stat_bonuses", {}) as Dictionary).get(stat_id, 0))
		_stat_value_labels[stat_id].text = str(value)
	# Résumé de classe : compétences de départ + or (les traits de race, tags
	# internes non localisés, sont omis de l'affichage — à localiser plus tard).
	var skills_txt: Array = []
	for s in (cls.get("starting_skills", {}) as Dictionary):
		skills_txt.append("%s %d" % [tr(GameData.skills.get(s, {}).get("name_key", s)), int(cls["starting_skills"][s])])
	var gold: int = int(cls.get("gold", 0))
	var lines: Array[String] = []
	if not skills_txt.is_empty():
		lines.append(tr("ui.menu.perso_competences").format({"competences": ", ".join(skills_txt)}))
	if gold > 0:
		lines.append(tr("ui.menu.perso_or").format({"or": str(gold)}))
	_char_summary.text = "\n".join(lines) if not lines.is_empty() else ""


func _on_start_character() -> void:
	var stats := {}
	for stat_id: String in CHAR_STATS:
		stats[stat_id] = BASE_STAT + int(_stat_alloc[stat_id])
	SaveManager.pending_character = {
		"race": _race_ids[_char_race_option.selected],
		"class": _class_ids[_char_class_option.selected],
		"stats": stats,
	}
	_finish()


func _build_multi() -> VBoxContainer:
	var box := _panel_box()
	box.add_child(_title_label("ui.menu.multi"))
	box.add_child(_button("ui.menu.host", _on_host))
	var ip_row := HBoxContainer.new()
	ip_row.add_child(_row_label("ui.menu.ip"))
	_ip_edit = LineEdit.new()
	_ip_edit.text = "127.0.0.1"
	_ip_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	ip_row.add_child(_ip_edit)
	box.add_child(ip_row)
	box.add_child(_button("ui.menu.rejoindre", _on_join))
	box.add_child(_spacer(8))
	box.add_child(_button("ui.menu.retour", func() -> void: _show_panel("main")))
	return box


func _build_settings() -> VBoxContainer:
	var box := _panel_box()
	box.add_child(_title_label("ui.menu.parametres"))
	var lang_row := HBoxContainer.new()
	lang_row.add_child(_row_label("ui.menu.langue"))
	var lang := OptionButton.new()
	# Table unique langue -> libellé (2026-07-27) : ajouter une langue est
	# désormais une ligne de données. Le sélecteur était câblé en dur sur
	# deux entrées (« 0 si fr sinon en »), donc toute 3e langue était
	# invisible dans l'interface même une fois traduite.
	var current := TranslationServer.get_locale()
	var selected_index := 0
	for i in LOCALES.size():
		var entry: Array = LOCALES[i]
		lang.add_item(String(entry[1]))  # Noms de langues : invariants, jamais traduits.
		if current.begins_with(String(entry[0])):
			selected_index = i
	lang.selected = selected_index
	lang.item_selected.connect(_on_language_selected)
	lang.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	lang_row.add_child(lang)
	box.add_child(lang_row)

	# Distance d'affichage (rayon de chunks) — de 4 (rapide) à 48 (très loin,
	# lourd sur iGPU : beaucoup plus de chunks + overdraw).
	var dist_row := HBoxContainer.new()
	dist_row.add_child(_row_label("ui.menu.distance_affichage"))
	var dist := HSlider.new()
	dist.min_value = 4
	dist.max_value = 48
	dist.step = 2
	dist.value = WorldManager.render_radius
	dist.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	dist.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	var dist_val := Label.new()
	dist_val.custom_minimum_size.x = 40.0
	dist_val.text = str(WorldManager.render_radius)
	dist.value_changed.connect(func(v: float) -> void:
		dist_val.text = str(int(v))
		WorldManager.set_render_distance(int(v)))
	dist_row.add_child(dist)
	dist_row.add_child(dist_val)
	box.add_child(dist_row)

	box.add_child(_spacer(8))
	box.add_child(_button("ui.menu.retour", func() -> void: _show_panel("main")))
	return box


# --- Actions ---

func _on_continue() -> void:
	if SaveManager.continue_last():
		_finish()
	else:
		_solo_status.text = tr("ui.menu.aucun_monde")


func _on_load_world(dir: String) -> void:
	if SaveManager.load_world_at(dir):
		_finish()


## « Créer et jouer » : prépare le monde PUIS passe à la création de
## personnage (6.3 : monde → personnage → jeu).
func _on_create() -> void:
	var world_name := _name_edit.text.strip_edges()
	if world_name == "":
		world_name = tr("ui.menu.nom_defaut")
	SaveManager.prepare_new_world(world_name, _parse_seed(_seed_edit.text), _current_params())
	_show_panel("character")


## Paramètres de génération courants (sliders/cases) — partagés par la création
## et l'aperçu du monde.
func _current_params() -> Dictionary:
	var p := {
		"relief": _relief_slider.value,
		"niveau_mer": int(_sea_slider.value),
		"temperature": _temp_slider.value,
		"humidite": _hum_slider.value,
		"arbres": _trees_slider.value,
		"rivieres": _rivers_check.button_pressed,
		"cavernes": _caves_check.button_pressed,
		"biome_force": _biome_ids[_biome_option.selected],
	}
	# Point de spawn choisi au clic sur l'aperçu (sinon spawn auto sur terre).
	if _chosen_spawn != null:
		p["spawn"] = [(_chosen_spawn as Vector2i).x, (_chosen_spawn as Vector2i).y]
	return p


## Rend un APERÇU du monde complet (2026-07-26) pour la graine/params courants.
## Possible car le monde est désormais FINI et déterministe : on échantillonne
## `preview_color` sur toute l'étendue en une image PREVIEW_SIZE². Le point de
## spawn (terre ferme) est marqué d'une croix.
func _render_world_preview() -> void:
	if _preview_rect == null:
		return
	var g := NoiseGenerator.new(_parse_seed(_seed_edit.text), _current_params())
	_preview_gen = g
	_chosen_spawn = null  # Nouveau monde → spawn auto tant qu'on ne clique pas.
	var n := PREVIEW_SIZE
	var r := g.world_radius
	var span := 2.0 * float(r) / float(n)
	_preview_r = r
	_preview_span = span
	# Nom du monde généré → prérempli dans le champ (l'utilisateur peut changer).
	_name_edit.text = g.world_name()
	_preview_regions = g.detect_regions(96)
	_redraw_preview()
	# Noms des continents / océans sous l'aperçu.
	var conts: Array = _preview_regions["continents"]
	var ocs: Array = _preview_regions["oceans"]
	var cont_names := ", ".join(conts.map(func(c): return String(c["name"])))
	var oc_names := ", ".join(ocs.map(func(o): return String(o["name"])))
	_preview_names_label.text = tr("ui.menu.regions").format({
		"continents": cont_names if cont_names != "" else "—",
		"oceans": oc_names if oc_names != "" else "—"})


## (Re)dessine l'image de l'aperçu + marqueur de spawn (choisi ou auto).
func _redraw_preview() -> void:
	var g := _preview_gen
	var n := PREVIEW_SIZE
	var r := _preview_r
	var span := _preview_span
	var img := Image.create(n, n, false, Image.FORMAT_RGB8)
	for py in n:
		for px in n:
			img.set_pixelv(Vector2i(px, py), g.preview_color(int(-r + px * span), int(-r + py * span)))
	# Marqueur de spawn : choisi (vert) ou automatique (blanc).
	var spawn: Vector2i = _chosen_spawn if _chosen_spawn != null else g.find_land_spawn(0, 0)
	var col := Color.LIME_GREEN if _chosen_spawn != null else Color.WHITE
	var sx := int((float(spawn.x) + r) / span)
	var sy := int((float(spawn.y) + r) / span)
	for d in range(-3, 4):
		if sx + d >= 0 and sx + d < n:
			img.set_pixelv(Vector2i(sx + d, sy), col)
		if sy + d >= 0 and sy + d < n:
			img.set_pixelv(Vector2i(sx, sy + d), col)
	_preview_rect.texture = ImageTexture.create_from_image(img)


## Clic sur l'aperçu = choix du point de spawn (uniquement sur la terre ferme).
func _on_preview_clicked(event: InputEvent) -> void:
	if _preview_gen == null:
		return
	var mb := event as InputEventMouseButton
	if mb == null or not mb.pressed or mb.button_index != MOUSE_BUTTON_LEFT:
		return
	var local := mb.position  # coordonnées locales au TextureRect (taille = PREVIEW_SIZE).
	var px := int(local.x)
	var py := int(local.y)
	if px < 0 or py < 0 or px >= PREVIEW_SIZE or py >= PREVIEW_SIZE:
		return
	var wx := int(-_preview_r + px * _preview_span)
	var wz := int(-_preview_r + py * _preview_span)
	if _preview_gen.height_at(wx, wz) < _preview_gen.water_level:
		return  # Clic en mer ignoré : pas de spawn sous l'eau.
	_chosen_spawn = Vector2i(wx, wz)
	_redraw_preview()


## Héberge le monde PAR DÉFAUT (graine 1337) : le handshake de graine
## n'existe pas encore (E.11 différé), les invités supposent 1337 — héberger
## un autre monde les désynchroniserait.
func _on_host() -> void:
	SaveManager.prepare_default_if_needed()
	NetworkManager.host()
	_finish()


func _on_join() -> void:
	# E.10 : les invités ne possèdent pas la sauvegarde du monde.
	SaveManager.enabled = false
	SaveManager.prepare_default_if_needed()
	NetworkManager.join(_ip_edit.text.strip_edges())
	_finish()


func _on_language_selected(index: int) -> void:
	var locale := String((LOCALES[index] as Array)[0]) if index < LOCALES.size() else "en"
	TranslationServer.set_locale(locale)
	EventBus.locale_changed.emit(locale)
	# Les textes du menu sont posés à la construction : reconstruire.
	_bg.queue_free()
	_center.queue_free()
	_panels.clear()
	_build.call_deferred()


func _finish() -> void:
	world_ready.emit()
	queue_free()


# --- Aides de construction ---

func _panel_box() -> VBoxContainer:
	var box := VBoxContainer.new()
	box.custom_minimum_size.x = PANEL_MIN_WIDTH
	box.add_theme_constant_override("separation", 8)
	box.visible = false
	return box


func _title_label(key: String) -> Label:
	var label := Label.new()
	label.text = tr(key)
	label.add_theme_font_size_override("font_size", UITheme.FONT_HEADING)
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	return label


func _row_label(key: String) -> Label:
	var label := Label.new()
	label.text = tr(key)
	label.custom_minimum_size.x = 160.0
	return label


func _button(key: String, callback: Callable) -> Button:
	var b := Button.new()
	b.text = tr(key)
	b.pressed.connect(callback)
	return b


func _spacer(height: float) -> Control:
	var c := Control.new()
	c.custom_minimum_size.y = height
	return c


## Ligne « libellé + slider + valeur » ; retourne le slider.
func _slider_row(parent: VBoxContainer, key: String, minv: float, maxv: float, step: float, default: float) -> HSlider:
	var row := HBoxContainer.new()
	row.add_child(_row_label(key))
	var slider := HSlider.new()
	slider.min_value = minv
	slider.max_value = maxv
	slider.step = step
	slider.value = default
	slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	slider.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(slider)
	var value_label := Label.new()
	value_label.text = String.num(default, 2)
	value_label.custom_minimum_size.x = 48.0
	slider.value_changed.connect(func(v: float) -> void: value_label.text = String.num(v, 2))
	row.add_child(value_label)
	parent.add_child(row)
	return slider


## Graine : entier direct, vide = aléatoire, sinon hachage du texte (une
## graine « mot de passe » à la Minecraft).
func _parse_seed(text: String) -> int:
	var stripped := text.strip_edges()
	if stripped == "":
		return randi() % 1000000
	if stripped.is_valid_int():
		return stripped.to_int()
	return hash(stripped) & 0x7FFFFFFF
