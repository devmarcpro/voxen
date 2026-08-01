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
	title.add_theme_font_size_override("font_size", UITheme.FONT_TITLE)
	title.position = Vector2(24, 16)
	_root.add_child(title)

	_status_label = Label.new()
	_status_label.position = Vector2(24, 56)
	_status_label.add_theme_color_override("font_color", Color(0.6, 1.0, 0.6))
	_root.add_child(_status_label)

	# ONGLETS (2026-07-28) : la liste unique devenait interminable, et l'atelier
	# d'armes n'a rien à faire au milieu des téléportations.
	# Taille ANCRÉE et non figée : à 1180×760 en dur, le menu laissait une bande
	# morte à droite et rognait ses propres colonnes dès qu'un libellé
	# s'allongeait — ce qui est arrivé au premier changement de police.
	var tabs := TabContainer.new()
	tabs.set_anchors_preset(Control.PRESET_FULL_RECT)
	tabs.offset_left = 24
	tabs.offset_top = 84
	tabs.offset_right = -24
	tabs.offset_bottom = -24
	_root.add_child(tabs)

	var general := ScrollContainer.new()
	general.name = "Général"
	tabs.add_child(general)
	_list = VBoxContainer.new()
	_list.custom_minimum_size = Vector2(540, 0)
	general.add_child(_list)

	var forge := ScrollContainer.new()
	forge.name = "Armes"
	tabs.add_child(forge)
	_weapon_list = VBoxContainer.new()
	_weapon_list.custom_minimum_size = Vector2(1140, 0)
	forge.add_child(_weapon_list)

	_build_menu()
	_build_weapon_tab()
	visible = false


## Onglet GÉNÉRAL — panneau de contrôle, refondu le 2026-08-01.
##
## POURQUOI LA REFONTE. C'était une colonne unique de boutons pleine largeur :
## vingt-quatre biomes empilés les uns sous les autres, puis les objets, puis
## les compétences. Il fallait faire défiler pour tout voir, et surtout des pans
## entiers du jeu n'étaient pilotables NULLE PART — à commencer par l'heure, ce
## qui rendait impossible de simplement regarder son propre jeu de nuit.
##
## Deux principes :
##
##   1. TOUT SE PILOTE. Un menu de triche qui ne couvre qu'une partie de l'état
##      oblige à modifier le code pour tester le reste, ce qui est exactement ce
##      qu'il devrait éviter.
##   2. UNE LIGNE PAR SUJET. Les actions d'un même sujet tiennent sur une rangée
##      de petits boutons, pas en pile. La densité n'est pas un caprice : un
##      panneau qu'on embrasse d'un regard se retient, une liste qui défile non.

## Largeur d'un bouton d'action compacte. Assez pour « Crépuscule », pas plus.
const CHEAT_BUTTON_W := 118

## Pas de réglage des jauges et des ressources.
const GOLD_STEP := 500
const XP_STEP := 500.0

var _time_label: Label


func _build_menu() -> void:
	_build_time_row()
	_build_player_rows()
	_build_teleport_rows()
	_build_item_rows()
	_build_creature_rows()
	_build_creative_rows()


# --- Temps ------------------------------------------------------------------

## L'HEURE, enfin pilotable. `TickManager.tick_index` EST l'horloge du monde :
## la déplacer suffit, tout le reste (soleil, lumière, spawns nocturnes) en
## dérive. On ne touche donc à aucun système d'affichage.
func _build_time_row() -> void:
	_add_section("Temps")
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", UITheme.GAP)
	for entry: Array in [
		["Aube", DayNightManager.HOUR_DAWN],
		["Matin", DayNightManager.HOUR_DAY],
		["Midi", 12.0],
		["Crépuscule", DayNightManager.HOUR_DUSK],
		["Nuit", DayNightManager.HOUR_NIGHT],
		["Minuit", 0.0],
	]:
		row.add_child(_compact(String(entry[0]), func() -> void:
			_set_hour(float(entry[1]))))
	_list.add_child(row)

	var row2 := HBoxContainer.new()
	row2.add_theme_constant_override("separation", UITheme.GAP)
	row2.add_child(_compact("−1 h", func() -> void: _shift_hours(-1.0)))
	row2.add_child(_compact("+1 h", func() -> void: _shift_hours(1.0)))
	row2.add_child(_compact("+1 jour", func() -> void: _shift_hours(24.0)))
	# GEL DU TEMPS : le mode tactique arrête déjà les ticks (E.1). On le
	# réutilise plutôt que d'inventer une seconde pause, qui divergerait.
	row2.add_child(_compact("Geler / reprendre", func() -> void:
		TickManager.tactical_mode = not TickManager.tactical_mode
		_refresh_time_label()))
	row2.add_child(_compact("+100 ticks", func() -> void:
		TickManager.push_ticks(100)
		_refresh_time_label()))
	_list.add_child(row2)

	_time_label = Label.new()
	_time_label.add_theme_font_size_override("font_size", UITheme.FONT_SMALL)
	_time_label.add_theme_color_override("font_color", UITheme.TEXT_DIM)
	_list.add_child(_time_label)
	_refresh_time_label()


func _set_hour(hour: float) -> void:
	var per_day := int(DayNightManager.TICKS_PER_DAY)
	var day := TickManager.tick_index / per_day
	# On avance TOUJOURS dans le futur : reculer l'horloge ferait rejouer des
	# ticks déjà émis et pourrait dérégler ce qui compte en absolu (repos,
	# pousses, contrats). Demander une heure déjà passée avance au lendemain.
	var target := day * per_day + int(hour / DayNightManager.HOURS_PER_DAY * per_day)
	if target <= TickManager.tick_index:
		target += per_day
	TickManager.tick_index = target
	_refresh_time_label()


func _shift_hours(hours: float) -> void:
	var delta := int(hours / DayNightManager.HOURS_PER_DAY * DayNightManager.TICKS_PER_DAY)
	TickManager.tick_index = maxi(0, TickManager.tick_index + delta)
	_refresh_time_label()


func _refresh_time_label() -> void:
	if _time_label == null:
		return
	var per_day := DayNightManager.TICKS_PER_DAY
	var day := int(TickManager.tick_index / int(per_day)) + 1
	var hour := fmod(float(TickManager.tick_index), per_day) / per_day \
		* DayNightManager.HOURS_PER_DAY
	_time_label.text = "Jour %d · %02d:%02d · tick %d%s" % [
		day, int(hour), int(fmod(hour, 1.0) * 60.0), TickManager.tick_index,
		"   [TEMPS GELÉ]" if TickManager.tactical_mode else ""]


# --- Joueur -----------------------------------------------------------------

func _build_player_rows() -> void:
	_add_section("Joueur — jauges")
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", UITheme.GAP)
	row.add_child(_compact("Tout au max", _fill_all_gauges))
	row.add_child(_compact("Vie à 1", func() -> void:
		_player.health = 1.0
		_set_status("Vie ramenée à 1 PV.")))
	row.add_child(_compact("Vider endurance", func() -> void:
		_player.stamina = 0.0
		_set_status("Endurance vidée.")))
	row.add_child(_compact("Affamer", func() -> void:
		_player.hunger = 5.0
		_player.fatigue = 5.0
		_set_status("Faim et fatigue au plancher.")))
	_list.add_child(row)

	_add_section("Joueur — ressources et progression")
	var row2 := HBoxContainer.new()
	row2.add_theme_constant_override("separation", UITheme.GAP)
	row2.add_child(_compact("+%d or" % GOLD_STEP, func() -> void:
		_player.gold += GOLD_STEP
		_set_status("Or : %d." % _player.gold)))
	row2.add_child(_compact("Or à zéro", func() -> void:
		_player.gold = 0
		_set_status("Or remis à zéro.")))
	row2.add_child(_compact("Maximiser compétences", _max_all_skills))
	row2.add_child(_compact("+%d XP partout" % int(XP_STEP), func() -> void:
		for skill_id: String in GameData.skills:
			_player.skills.gain_xp(skill_id, XP_STEP)
		_set_status("+%d XP sur %d compétences." % [int(XP_STEP), GameData.skills.size()])))
	row2.add_child(_compact("Remettre à zéro", func() -> void:
		for skill_id: String in _player.skills.skills:
			var skill: Dictionary = _player.skills.skills[skill_id]
			skill["level"] = 0
			skill["xp"] = 0.0
		_set_status("Toutes les compétences remises à zéro.")))
	_list.add_child(row2)

	_add_section("Joueur — attributs")
	var row3 := HBoxContainer.new()
	row3.add_theme_constant_override("separation", UITheme.GAP)
	for stat_id: String in ["force", "dexterite", "endurance", "volonte",
			"perception", "charisme"]:
		row3.add_child(_compact("%s +5" % tr("stat.%s.name" % stat_id), func() -> void:
			_player.stats[stat_id] = int(_player.stats[stat_id]) + 5
			# La santé et le mana DÉRIVENT des attributs : sans ce recalcul, on
			# gagnait de l'Endurance sans gagner de PV, ce qui donnait l'illusion
			# que la triche ne marchait pas.
			_player.call("_recompute_derived")
			_set_status("%s : %d." % [stat_id, int(_player.stats[stat_id])])))
	_list.add_child(row3)


func _fill_all_gauges() -> void:
	_player.health = _player.health_max
	_player.mana.current = _player.mana.max_mana()
	_player.stamina = _player.stamina_max
	_player.hunger = _player.hunger_max
	_player.fatigue = _player.fatigue_max
	_set_status("Toutes les jauges au maximum.")


# --- Téléportation ----------------------------------------------------------

func _build_teleport_rows() -> void:
	_add_section("Téléportation — point d'intérêt")
	var poi := HBoxContainer.new()
	poi.add_theme_constant_override("separation", UITheme.GAP)
	# Deux types seulement depuis le 2026-08-01 : les autres POI n'avaient aucun
	# contenu et téléportaient le joueur sur du vide.
	for entry: Array in [["Village", "village"], ["Donjon", "donjon"]]:
		poi.add_child(_compact(String(entry[0]), _teleport_to_poi.bind(String(entry[1]))))
	_list.add_child(poi)

	# Les biomes en GRILLE : vingt-quatre boutons empilés en colonne
	# occupaient tout l'onglet et repoussaient le reste hors de l'écran.
	_add_section("Téléportation — biome (%d)" % GameData.biomes.size())
	var grid := GridContainer.new()
	grid.columns = 6
	var biome_ids := GameData.biomes.keys()
	biome_ids.sort()
	for biome_id: String in biome_ids:
		var biome: Dictionary = GameData.biomes[biome_id]
		grid.add_child(_compact(tr(biome.get("name_key", biome_id)),
			_teleport_to_biome.bind(biome_id)))
	_list.add_child(grid)


# --- Objets et collection ---------------------------------------------------

func _build_item_rows() -> void:
	_add_section("Objets et collection")
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", UITheme.GAP)
	row.add_child(_compact("Tous les matériaux", _give_all_materials))
	row.add_child(_compact("Tous les objets", _give_all_items))
	row.add_child(_compact("Vider l'inventaire", func() -> void:
		_player.inventory.objects.clear()
		_player.inventory.material_stacks.clear()
		_player.inventory.material_fractions.clear()
		_set_status("Inventaire vidé.")))
	# Compléter la collection d'un clic : sans ça, tester l'écran de collection
	# rempli demanderait de forger et d'offrir cent six objets à la main.
	row.add_child(_compact("Compléter la collection", func() -> void:
		for key: String in Collection.catalogue():
			_player.collection.entries[key] = {
				"quality": 1.0, "materials": {}, "tick": TickManager.tick_index}
		_set_status("Collection complétée (%d pièces)." % Collection.catalogue().size())))
	row.add_child(_compact("Vider la collection", func() -> void:
		_player.collection.entries.clear()
		_set_status("Collection vidée.")))
	_list.add_child(row)


# --- Créatures --------------------------------------------------------------

func _build_creature_rows() -> void:
	# Le pool de spawn NATUREL filtre par biome et exclut les civils : impossible
	# d'y faire apparaître un forgeron ou un ours polaire en plein désert pour
	# les tester. Ici on passe outre, c'est le propre d'un menu de triche.
	_add_section("Créatures — clic = faire apparaître devant soi")
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", UITheme.GAP)
	row.add_child(_compact("Retirer toutes", _despawn_all_creatures))
	row.add_child(_compact("Tuer les hostiles", func() -> void:
		var killed := 0
		for creature in CreatureManager.creatures:
			if creature != null and is_instance_valid(creature) and not creature.is_dead():
				creature.health = 0.0
				killed += 1
		_set_status("%d créature(s) tuée(s)." % killed)))
	_list.add_child(row)

	var creature_grid := GridContainer.new()
	creature_grid.columns = 6
	var creature_ids := GameData.creatures.keys()
	creature_ids.sort()
	for creature_id: String in creature_ids:
		var creature: Dictionary = GameData.creatures[creature_id]
		creature_grid.add_child(_compact(tr(creature.get("name_key", creature_id)),
			_spawn_creature.bind(creature_id)))
	_list.add_child(creature_grid)


## Bouton d'action compact. Toutes les actions du menu passent par ici : c'est
## ce qui garantit qu'aucune rangée ne se met à respirer différemment des autres.
func _compact(text_value: String, callback: Callable) -> Button:
	var button := Button.new()
	button.text = text_value
	button.custom_minimum_size = Vector2(CHEAT_BUTTON_W, UITheme.ROW_H)
	button.add_theme_font_size_override("font_size", UITheme.FONT_SMALL)
	button.pressed.connect(callback)
	return button

# --- Atelier d'ARMES (onglet dédié) -----------------------------------------
#
# 21 armes × 41 bois × 21 minerais × 11 gemmes : afficher toutes les combinaisons
# en boutons est hors de question — ce sont des dizaines de milliers de nœuds à
# construire au démarrage, pour une grille que personne ne peut parcourir.
#
# L'onglet est donc un ATELIER : on choisit un bois, un minerai, une gemme, une
# qualité, puis on clique l'arme. Toutes les combinaisons restent atteignables,
# en quelques clics, et le menu ne coûte qu'une centaine de boutons.

var _weapon_list: VBoxContainer
var _forge_wood := "chene"
var _forge_ore := "fer"
var _forge_quality := 1.0
## "" = aucune. Le sertissage est facultatif ici comme au craft normal : sinon
## la moitié des combinaisons testables serait inatteignable depuis le menu.
var _forge_gem := ""
var _forge_label: Label

## Paliers de qualité (A.3) : couvrent l'échelle « misérable » → « mythique »
## sans imposer un curseur au pixel près.
const FORGE_QUALITIES := [0.3, 0.7, 1.0, 1.4, 2.0, 3.0, 5.0]


func _build_weapon_tab() -> void:
	_forge_label = Label.new()
	_forge_label.add_theme_font_size_override("font_size", UITheme.FONT_BODY)
	_forge_label.add_theme_color_override("font_color", Color(0.6, 1.0, 0.6))
	_weapon_list.add_child(_forge_label)

	_add_forge_section("Qualité")
	var quality_row := HBoxContainer.new()
	for quality: float in FORGE_QUALITIES:
		var button := Button.new()
		button.text = "%.1f — %s" % [quality, tr(ItemFactory.quality_tier_key(quality))]
		button.pressed.connect(func() -> void:
			_forge_quality = quality
			_refresh_forge_label())
		quality_row.add_child(button)
	_weapon_list.add_child(quality_row)

	_add_forge_section("Manche — bois (%d)" % _materials_of("bois").size())
	_weapon_list.add_child(_material_picker("bois", func(id: String) -> void:
		_forge_wood = id
		_refresh_forge_label()))

	_add_forge_section("Tête — minerai (%d)" % _materials_of("minerai").size())
	_weapon_list.add_child(_material_picker("minerai", func(id: String) -> void:
		_forge_ore = id
		_refresh_forge_label()))

	_add_forge_section("Gemme — cristal (%d, facultative)" % _materials_of("cristal").size())
	var gem_row := HBoxContainer.new()
	var none_button := Button.new()
	none_button.text = "aucune"
	none_button.pressed.connect(func() -> void:
		_forge_gem = ""
		_refresh_forge_label())
	gem_row.add_child(none_button)
	gem_row.add_child(_material_picker("cristal", func(id: String) -> void:
		_forge_gem = id
		_refresh_forge_label()))
	_weapon_list.add_child(gem_row)

	var weapons := _weapon_ids()
	_add_forge_section("Armes (%d) — clic = forger avec la sélection" % weapons.size())
	var grid := GridContainer.new()
	grid.columns = 5
	for item_id: String in weapons:
		var item: Dictionary = GameData.items[item_id]
		var button := Button.new()
		button.text = tr(item["name_key"])
		button.custom_minimum_size = Vector2(210, UITheme.ROW_H)
		button.tooltip_text = _weapon_tooltip(item_id)
		button.pressed.connect(func() -> void: _forge_weapon(item_id))
		grid.add_child(button)
	_weapon_list.add_child(grid)
	_refresh_forge_label()


func _add_forge_section(title_text: String) -> void:
	var label := Label.new()
	label.text = title_text
	label.add_theme_font_size_override("font_size", UITheme.FONT_BODY)
	label.add_theme_color_override("font_color", Color(1.0, 0.85, 0.4))
	_weapon_list.add_child(label)


func _weapon_ids() -> Array:
	var ids: Array = []
	for item_id: String in GameData.items:
		if String((GameData.items[item_id] as Dictionary).get("type", "")) == "arme":
			ids.append(item_id)
	ids.sort()
	return ids


func _materials_of(category: String) -> Array:
	var ids: Array = []
	for mat_id: String in GameData.materials:
		if String((GameData.materials[mat_id] as Dictionary).get("category", "")) == category:
			ids.append(mat_id)
	ids.sort()
	return ids


## Grille de pastilles colorées d'une catégorie. Le `callback` reçoit l'id.
func _material_picker(category: String, callback: Callable) -> GridContainer:
	var grid := GridContainer.new()
	grid.columns = 14
	for mat_id: String in _materials_of(category):
		var mat: Dictionary = GameData.materials[mat_id]
		var button := Button.new()
		button.custom_minimum_size = Vector2(34, 34)
		# La DURETÉ et la DENSITÉ sont ce qui change réellement l'arme (dégâts
		# et vitesse) : les afficher évite de forger à l'aveugle.
		button.tooltip_text = "%s — dureté %.0f · densité %.0f" % [
			tr(mat["name_key"]), float(mat["stats"]["durete"]), float(mat["stats"]["densite"])]
		button.icon = BlockIcon.cube_texture(Color.html(mat["color"]), 28)
		button.expand_icon = true
		button.pressed.connect(func() -> void: callback.call(mat_id))
		grid.add_child(button)
	return grid


## Aperçu des stats DÉRIVÉES avec la sélection courante — c'est là tout
## l'intérêt de pouvoir tout combiner : voir ce que les matériaux changent.
func _weapon_tooltip(item_id: String) -> String:
	var item: Dictionary = GameData.items[item_id]
	var functionality: Dictionary = GameData.functionalities.get(item.get("functionality", ""), {})
	if functionality.is_empty():
		return item_id
	return "%s · %s · %d main(s)" % [
		item_id, String(functionality.get("type_degats", "?")),
		int(functionality.get("hands", 1))]


func _refresh_forge_label() -> void:
	if _forge_label == null:
		return
	var wood: Dictionary = GameData.materials.get(_forge_wood, {})
	var ore: Dictionary = GameData.materials.get(_forge_ore, {})
	# +1 pour « aucune gemme » : ne pas sertir est une combinaison à part entière.
	var total := _weapon_ids().size() * _materials_of("bois").size() 		* _materials_of("minerai").size() * (_materials_of("cristal").size() + 1)
	var gem_text := "aucune" if _forge_gem == "" 		else tr(GameData.materials.get(_forge_gem, {}).get("name_key", _forge_gem))
	_forge_label.text = "Sélection : manche %s · tête %s · gemme %s · qualité %.1f (%s)   —   %d combinaisons possibles" % [
		tr(wood.get("name_key", _forge_wood)), tr(ore.get("name_key", _forge_ore)), gem_text,
		_forge_quality, tr(ItemFactory.quality_tier_key(_forge_quality)), total]


func _forge_weapon(item_id: String) -> void:
	var choices := {"bois": _forge_wood, "minerai": _forge_ore}
	if _forge_gem != "" and ItemFactory.accepts_gem(item_id):
		choices[ItemFactory.GEM_CATEGORY] = _forge_gem
	var instance := ItemFactory.craft(item_id, choices, _forge_quality)
	if instance.is_empty():
		_set_status("Forge impossible : « %s »." % item_id)
		return
	_player.inventory.add_object(instance)
	# Les stats DÉRIVÉES sont ce qui distingue deux exemplaires de la même arme :
	# les afficher rend la combinatoire lisible au lieu d'être un tas d'objets.
	var functionality: Dictionary = GameData.functionalities.get(instance["functionality"], {})
	var derived := WeaponStats.derive(functionality, instance)
	_set_status("%s (%s/%s%s, q%.1f) — poids %.0f · allonge %.2f · wind-up %.0f ms · parade %.0f ms" % [
		tr(GameData.items[item_id]["name_key"]), _forge_wood, _forge_ore,
		"" if not instance.has("gem") else "/" + String(instance["gem"]), _forge_quality,
		float(instance["weight"]), float(derived["reach"]),
		float(derived["windup_ms"]), float(derived["parry_window_ms"])])


# --- Spawn de créatures (triche) -----------------------------------------

## Distance devant le joueur où la créature apparaît. Assez près pour la voir
## immédiatement, assez loin pour ne pas naître dans le corps du joueur.
const SPAWN_AHEAD := 4.0

## Couleur d'étiquette par profil d'IA (F.3) — lecture immédiate de ce qu'on
## s'apprête à lâcher devant soi.
func _profile_color(profile: String) -> Color:
	match profile:
		"hostile": return Color(1.0, 0.45, 0.4)
		"bete_sauvage": return Color(1.0, 0.8, 0.45)
		"fuit": return Color(0.6, 0.9, 1.0)
	return Color(0.8, 0.85, 0.8)


func _spawn_creature(creature_id: String) -> void:
	var fly_camera := get_node_or_null("../FlyCamera") as Node3D
	if fly_camera == null:
		return
	# DEVANT le joueur, à plat : le tangage de la caméra ne doit pas envoyer la
	# créature dans le ciel ou sous terre quand on regarde en l'air.
	var forward := -fly_camera.global_basis.z
	forward.y = 0.0
	if forward.length_squared() < 0.001:
		forward = Vector3.FORWARD
	var spot := fly_camera.global_position + forward.normalized() * SPAWN_AHEAD
	# Posée sur le SOL RÉEL (blocs), pas sur la hauteur procédurale : en
	# grotte, en donjon ou sur du terrain modifié, les deux diffèrent.
	var ground := _ground_under(spot)
	if not is_nan(ground):
		spot.y = ground
	var creature := CreatureManager.spawn(creature_id, spot)
	if creature == null:
		_set_status("Spawn refusé : budget de %d créatures atteint." % CreatureManager.MAX_ACTIVE)
		return
	var data: Dictionary = GameData.creatures[creature_id]
	_set_status("%s apparu(e) à %.0f m (%s)" % [
		tr(data["name_key"]), SPAWN_AHEAD, String(data.get("ai_profile", "?"))])


## Hauteur du premier bloc plein sous `position`, ou NAN si rien trouvé.
func _ground_under(position: Vector3) -> float:
	var bx := floori(position.x)
	var bz := floori(position.z)
	var start := floori(position.y) + 2
	for wy in range(start, start - 40, -1):
		if WorldManager.block_at_world(Vector3i(bx, wy, bz)) != 0:
			# Convention des créatures : indice du bloc + 0,5 (voir
			# Creature._ground_height) — s'en écarter les ferait flotter.
			return float(wy) + 0.5
	return NAN


func _despawn_all_creatures() -> void:
	var count := CreatureManager.creatures.size()
	for creature in CreatureManager.creatures.duplicate():
		CreatureManager.despawn(creature)
	_set_status("%d créature(s) retirée(s)." % count)


func _add_section(title_text: String) -> void:
	var label := Label.new()
	label.text = title_text
	label.add_theme_font_size_override("font_size", UITheme.FONT_BODY)
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
	if event.is_action_pressed("cheat_menu"):
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
	# L'heure avance pendant qu'on ne regarde pas : la relire à l'ouverture, et
	# la tenir à jour tant que le menu est visible. Un cadran figé sur l'heure
	# de la dernière ouverture est pire que pas de cadran du tout.
	_refresh_time_label()
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
		if poi_type not in POIGenerator.pois_at_cell(cell, WorldManager.world_seed, biome):
			return false
		# Un village TIRÉ n'est pas un village CONSTRUIT : les contraintes de
		# site en écartent quatre sur cinq. Se téléporter sur un marqueur vide
		# est exactement ce qui a fait croire que la génération était cassée.
		if poi_type == "village":
			return not g.city_at_cell(cell).is_empty()
		return true

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


# --- Créatif : donner n'importe quel bloc ou objet ---------------------------

## Côté d'une vignette créative. Petite volontairement : 249 matériaux en
## vignettes de 34 px tiennent en quelques rangées, la même grille en boutons
## texte occuperait plusieurs écrans.
const CREATIVE_CELL := 34


func _build_creative_rows() -> void:
	_add_section("Créatif — matériaux (%d) — clic = dans la barre" % GameData.materials.size())
	var mat_grid := GridContainer.new()
	mat_grid.columns = 24
	var material_ids := GameData.materials.keys()
	material_ids.sort()
	for mat_id: String in material_ids:
		var material: Dictionary = GameData.materials[mat_id]
		var rid: int = GameData.material_runtime_ids.get(mat_id, -1)
		mat_grid.add_child(_creative_cell(rid, Color.html(material["color"]),
			tr(material["name_key"]),
			func() -> void:
				_player.inventory.add_material(mat_id, MATERIAL_GIVE_AMOUNT)
				_set_status("+%d %s" % [MATERIAL_GIVE_AMOUNT, tr(material["name_key"])])))
	_list.add_child(mat_grid)

	_add_section("Créatif — objets (%d)" % GameData.items.size())
	var item_grid := GridContainer.new()
	item_grid.columns = 24
	var item_ids := GameData.items.keys()
	item_ids.sort()
	for item_id: String in item_ids:
		var item: Dictionary = GameData.items[item_id]
		var cell := _creative_cell(-1, _item_color(item), tr(item["name_key"]),
			func() -> void:
				_give_item(item_id)
				_set_status("+ %s" % tr(item["name_key"])))
		# Apparence d'OUTIL (sprite teinté) plutôt qu'un cube couleur.
		var tool_tex: Texture2D = ToolSprite.item_icon(item,
			{"bois": "chene", "minerai": "fer"}, CREATIVE_CELL - 6)
		if tool_tex != null:
			cell.icon = tool_tex
		item_grid.add_child(cell)
	_list.add_child(item_grid)


## Cellule créative : bouton avec icône de bloc TEXTURÉE (rendu voxel) si prête,
## sinon cube couleur ; infobulle nom. `rid` = id matériau (-1 = objet, pas de
## rendu voxel).
func _creative_cell(rid: int, color: Color, name_text: String, callback: Callable) -> Button:
	var b := Button.new()
	b.custom_minimum_size = Vector2(CREATIVE_CELL, CREATIVE_CELL)
	b.tooltip_text = name_text
	b.icon = BlockIcon.cube_texture(color, CREATIVE_CELL - 6)
	b.expand_icon = true
	b.pressed.connect(callback)
	if rid >= 0:
		_creative_cells.append({"button": b, "rid": rid})
	return b


## Remplace les vignettes couleur par les icônes texturées prêtes.
## Tenue à jour du panneau tant qu'il est ouvert : les icônes voxel arrivent en
## différé (rendu asynchrone) et l'horloge, elle, avance toute seule.
func _process(_delta: float) -> void:
	if not is_open:
		return
	_refresh_creative_icons()
	_refresh_time_label()


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
