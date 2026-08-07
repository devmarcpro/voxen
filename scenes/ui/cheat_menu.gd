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
	forge.name = "Atelier"
	tabs.add_child(forge)
	_weapon_list = VBoxContainer.new()
	_weapon_list.custom_minimum_size = Vector2(1140, 0)
	forge.add_child(_weapon_list)

	# TOUT LE CONTENU DU JEU, UN ONGLET PAR FAMILLE (2026-08-03, demande de
	# l'auteur : « absolument tout dans le jeu doit être accessible dans le menu
	# de triche »).
	#
	# Le menu couvrait le temps, les jauges, la téléportation, les modules et un
	# atelier d'armes. Restaient hors d'atteinte : les 278 matériaux un par un
	# (seul « tous » existait), les armures et consommables, les 4 plats, les 2
	# munitions, les 38 essences d'arbre, les 6 plantes, les 72 transformations,
	# les 14 statuts, les 6 races, les 6 classes, et les 53 compétences prises
	# individuellement — c'est-à-dire l'essentiel du contenu.
	_materials_list = _add_tab(tabs, "Matériaux")
	_objects_list = _add_tab(tabs, "Objets")
	_world_list = _add_tab(tabs, "Monde")
	_character_list = _add_tab(tabs, "Personnage")

	_build_menu()
	_build_weapon_tab()
	_build_materials_tab()
	_build_objects_tab()
	_build_world_tab()
	_build_character_tab()
	visible = false


## Onglet défilable prêt à recevoir des rangées. Toutes les familles de contenu
## passent par ici : c'est ce qui garantit qu'elles se ressemblent.
func _add_tab(tabs: TabContainer, tab_name: String) -> VBoxContainer:
	var scroll := ScrollContainer.new()
	scroll.name = tab_name
	tabs.add_child(scroll)
	var list := VBoxContainer.new()
	list.custom_minimum_size = Vector2(1140, 0)
	scroll.add_child(list)
	return list


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
	_build_module_rows()
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


# --- Modules, livres et assemblages (GDD 5.1) -------------------------------
#
# POURQUOI CETTE SECTION EXISTE. Un module ne s'obtient QUE par la lecture d'un
# livre, et un livre ne se trouve QU'EN DONJON : tester un assemblage demandait
# donc de descendre plusieurs étages, de trouver une cache, de réussir un jet de
# Lecture, et de recommencer pour chaque module manquant. C'est intenable pour
# régler l'équilibrage d'un système dont tout l'intérêt est la combinatoire.

## Difficulté des livres fabriqués ici. Trois crans qui couvrent la plage utile :
## un livre trivial (lisible sans compétence), un livre moyen, et un livre que
## seul un lecteur chevronné ouvre — c'est-à-dire les trois cas que le jet A.7
## doit distinguer.
const CHEAT_BOOK_POWERS := {"facile": 0.0, "moyen": 0.5, "redoutable": 1.0}


func _build_module_rows() -> void:
	_add_section("Modules — tout apprendre, oublier, monter en niveau")
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", UITheme.GAP)
	row.add_child(_compact("Tout apprendre", func() -> void:
		for module_id: String in GameData.modules:
			if not _player.known_modules.has(module_id):
				_player.known_modules[module_id] = 0
		_set_status("%d module(s) connus." % (_player.known_modules as Dictionary).size())))
	row.add_child(_compact("Tout oublier", func() -> void:
		_player.known_modules.clear()
		# Les assemblages partent avec : garder un slot qui référence un module
		# oublié afficherait un sort que le joueur ne peut plus ni lancer ni
		# reconstituer.
		_player.assemblies.clear()
		_set_status("Modules et assemblages effacés.")))
	row.add_child(_compact("+10 niveaux", func() -> void:
		for module_id: String in (_player.known_modules as Dictionary).keys():
			_player.known_modules[module_id] = int(_player.known_modules[module_id]) + 10
		_set_status("+10 niveaux sur %d module(s)." % (_player.known_modules as Dictionary).size())))
	row.add_child(_compact("Mana infinie", func() -> void:
		_player.mana.current = _player.mana.maximum
		_set_status("Mana au maximum (%d)." % int(_player.mana.maximum))))
	_list.add_child(row)

	# GRILLE COMPLÈTE. Le libellé porte le RÔLE et le coût : c'est ce qui permet
	# de composer un assemblage sans quitter le menu pour aller lire les fiches.
	# Un clic apprend le module, ou le monte d'un niveau s'il est déjà connu.
	var grid := GridContainer.new()
	grid.columns = 4
	var ids: Array = GameData.modules.keys()
	ids.sort()
	for module_id: String in ids:
		var module: Dictionary = GameData.modules[module_id]
		# `: String` explicite : `Dictionary.get` rend un Variant, dont
		# l'inférence est traitée comme une erreur dans ce projet.
		var role: String = {"effet": "E", "modificateur": "M", "declencheur": "D"}.get(
				String(module.get("module_type", "effet")), "?")
		var label := "[%s] %s · %d" % [role, tr(String(module.get("name_key", module_id))),
				int(module.get("mana_cost_base", 0))]
		grid.add_child(_compact(label, _learn_module.bind(module_id)))
	_list.add_child(grid)

	_add_section("Livres — grimoires et manuels de combat")
	var books := HBoxContainer.new()
	books.add_theme_constant_override("separation", UITheme.GAP)
	for kind: String in ["grimoire", "manuel"]:
		for tier: String in ["facile", "moyen", "redoutable"]:
			books.add_child(_compact("%s %s" % [
					"Grimoire" if kind == "grimoire" else "Manuel", tier],
					_give_book.bind(kind, float(CHEAT_BOOK_POWERS[tier]))))
	_list.add_child(books)

	var books2 := HBoxContainer.new()
	books2.add_theme_constant_override("separation", UITheme.GAP)
	books2.add_child(_compact("Lire tout", _read_all_books))
	books2.add_child(_compact("Lecture niv. 50", func() -> void:
		while _player.skills.level("lecture") < 50:
			_player.skills.gain_xp("lecture", 20000.0)
		_set_status("Lecture au niveau %d." % _player.skills.level("lecture"))))
	books2.add_child(_compact("Lecture niv. 0", func() -> void:
		# Remettre la compétence à zéro n'est pas prévu par PlayerSkills (la
		# progression ne redescend jamais) : on réécrit l'entrée directement,
		# ce qui est précisément le privilège d'un menu de triche.
		if (_player.skills.skills as Dictionary).has("lecture"):
			_player.skills.skills["lecture"]["level"] = 0
			_player.skills.skills["lecture"]["xp"] = 0.0
		_set_status("Lecture remise à zéro — les échecs redeviennent probables.")))
	books2.add_child(_compact("Vider les livres", func() -> void:
		var removed := 0
		for obj: Dictionary in (_player.inventory.objects as Array).duplicate():
			if BookFactory.is_book(obj):
				_player.inventory.remove_object_units(obj, int(obj.get("count", 1)))
				removed += 1
		_set_status("%d livre(s) retiré(s)." % removed)))
	_list.add_child(books2)

	_add_section("Assemblages — slots et sorts tout faits")
	var asm := HBoxContainer.new()
	asm.add_theme_constant_override("separation", UITheme.GAP)
	asm.add_child(_compact("Slots max (arme tenue)", func() -> void:
		var skill_id: String = String(_player.weapon_skill_id())
		if skill_id.is_empty():
			_set_status("Aucune arme équipée : les slots dépendent de sa compétence.")
			return
		# 125 = le niveau où les deux formules du GDD 5.1 plafonnent
		# (`2 + N/20` à 6 et `2 + N/25` à 5).
		while _player.skills.level(skill_id) < 125:
			_player.skills.gain_xp(skill_id, 200000.0)
		_set_status("%s niveau %d → %d slots de %d modules." % [
				skill_id, _player.skills.level(skill_id),
				_player.assembly_slot_count(skill_id), _player.assembly_module_count(skill_id)])))
	asm.add_child(_compact("Sorts d'exemple", _fill_example_assemblies))
	asm.add_child(_compact("Vider les assemblages", func() -> void:
		_player.assemblies.clear()
		_set_status("Assemblages effacés.")))
	_list.add_child(asm)


func _learn_module(module_id: String) -> void:
	var known: Dictionary = _player.known_modules
	if known.has(module_id):
		known[module_id] = int(known[module_id]) + 1
		_set_status("%s : niveau %d." % [
				tr(String((GameData.modules[module_id] as Dictionary)["name_key"])),
				int(known[module_id])])
	else:
		known[module_id] = 0
		_set_status("%s appris." % tr(String(
				(GameData.modules[module_id] as Dictionary)["name_key"])))


func _give_book(book_type: String, power: float) -> void:
	var rng := RandomNumberGenerator.new()
	rng.randomize()
	var book: Dictionary = BookFactory.create(book_type, power, rng)
	if book.is_empty():
		_set_status("Aucun module de ce type au catalogue.")
		return
	_player.inventory.add_object(book)
	_set_status("%s (difficulté %d, %d module(s), domaine « %s »)." % [
			tr(String(book["name_key"])), int(book["difficulty"]),
			(book["modules"] as Array).size(), String(book["domain"])])


## Lit TOUS les livres portés, et rapporte le bilan. C'est le seul moyen de
## voir la distribution réussite/échec du jet A.7 sans passer une soirée à
## ouvrir des grimoires un par un.
func _read_all_books() -> void:
	var reussites := 0
	var echecs := 0
	var gagnes := 0
	for obj: Dictionary in (_player.inventory.objects as Array).duplicate():
		if not BookFactory.is_book(obj):
			continue
		var result: Dictionary = _player.read_book(obj)
		if bool(result.get("reussite", false)):
			reussites += 1
			gagnes += (result.get("modules", []) as Array).size()
		else:
			echecs += 1
	if reussites + echecs == 0:
		_set_status("Aucun livre dans l'inventaire.")
		return
	_set_status("%d réussite(s), %d échec(s) — %d module(s) obtenus." % [
			reussites, echecs, gagnes])


## Range trois assemblages qui EXERCENT chacun une mécanique différente : la
## volée, le déclencheur récursif, et la modification d'un effet. Ils servent à
## voir le système marcher sans avoir à le composer soi-même — et à vérifier
## d'un coup d'œil que l'ordre des slots change bien le résultat.
func _fill_example_assemblies() -> void:
	var skill_id: String = String(_player.weapon_skill_id())
	if skill_id.is_empty():
		_set_status("Aucune arme équipée : un assemblage appartient à un type d'arme.")
		return
	var exemples := [
		["triple_lancer", "boule_de_feu", "boule_de_feu", "boule_de_feu"],
		["boule_de_feu", "declencheur_impact", "double_lancer", "eclat_de_glace", "eclat_de_glace"],
		["portee_accrue", "guidage", "arc_electrique"],
		["carapace_de_roche"],
	]
	for liste: Array in exemples:
		for module_id: String in liste:
			if not (_player.known_modules as Dictionary).has(module_id):
				_player.known_modules[module_id] = 0
	var posed := 0
	for index in exemples.size():
		if index >= _player.assembly_slot_count(skill_id):
			break
		if _player.set_assembly(skill_id, index, exemples[index]):
			posed += 1
	_set_status("%d sort(s) rangé(s) sur « %s » (slots de %d modules)." % [
			posed, skill_id, _player.assembly_module_count(skill_id)])


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

	# GROUPÉES PAR CLASSE, et pas en une grille alphabétique de vingt et un
	# boutons où l'épée voisine l'espadon et la faux le gourdin. Le seul
	# regroupement que le jeu possède est le TYPE DE DÉGÂTS — chaque arme ayant
	# sa propre fonctionnalité et sa propre compétence — et il porte même des
	# compétences du même nom. Les groupes sont DÉRIVÉS du catalogue : une arme
	# ajoutée tombe dans le sien sans qu'on touche à ce fichier.
	for group: Array in _weapons_by_class():
		var class_id: String = group[0]
		var ids: Array = group[1]
		_add_forge_section("%s (%d) — clic = forger avec la sélection" % [
				_weapon_class_title(class_id), ids.size()])
		var grid := GridContainer.new()
		grid.columns = 5
		for item_id: String in ids:
			var item: Dictionary = GameData.items[item_id]
			var button := Button.new()
			button.text = tr(item["name_key"])
			button.custom_minimum_size = Vector2(210, UITheme.ROW_H)
			button.tooltip_text = _weapon_tooltip(item_id)
			button.pressed.connect(func() -> void: _forge_weapon(item_id))
			grid.add_child(button)
		_weapon_list.add_child(grid)
	_refresh_forge_label()


## Armes et outils groupés par classe : [[classe, [ids triés]], …].
##
## Les trois classes de dégâts d'abord, dans l'ordre du plus courant au plus
## rare ; les outils ensuite, qui n'en ont pas. L'ordre est FIXE et non
## alphabétique : on cherche une masse dans « contondant », pas à la lettre C.
func _weapons_by_class() -> Array:
	var by_class := {}
	for item_id: String in _weapon_ids():
		var key := String((GameData.items[item_id] as Dictionary).get("weapon_class", ""))
		if not by_class.has(key):
			by_class[key] = [] as Array
		(by_class[key] as Array).append(item_id)
	var out: Array = []
	for key: String in WEAPON_CLASS_ORDER:
		if by_class.has(key):
			(by_class[key] as Array).sort()
			out.append([key, by_class[key]])
			by_class.erase(key)
	# Une classe INCONNUE de cette liste n'est pas perdue : elle passe en queue.
	# Sans ça, ajouter un type de dégâts ferait disparaître ses armes du menu
	# sans le moindre signe — la panne silencieuse habituelle.
	var rest := by_class.keys()
	rest.sort()
	for key: String in rest:
		(by_class[key] as Array).sort()
		out.append([key, by_class[key]])
	return out


const WEAPON_CLASS_ORDER: Array[String] = ["tranchant", "percant", "contondant", ""]


func _weapon_class_title(class_id: String) -> String:
	if class_id == "":
		return "Outils"
	return "Armes %ses" % tr("skill.%s.name" % class_id).to_lower()


func _add_forge_section(title_text: String) -> void:
	var label := Label.new()
	label.text = title_text
	label.add_theme_font_size_override("font_size", UITheme.FONT_BODY)
	label.add_theme_color_override("font_color", Color(1.0, 0.85, 0.4))
	_weapon_list.add_child(label)


## Ce que la forge du menu de triche sait produire.
##
## LES OUTILS AUSSI, pas seulement les armes (2026-08-03). Le filtre ne gardait
## que `type == "arme"` : les foreuses, qui sont des outils, restaient
## introuvables autrement qu'en les craftant pour de vrai, ce qui est justement
## ce qu'un menu de triche existe pour éviter.
func _weapon_ids() -> Array:
	var ids: Array = []
	for item_id: String in GameData.items:
		if String((GameData.items[item_id] as Dictionary).get("type", "")) in ["arme", "outil"]:
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
		button.icon = BlockIcon.cube_mask(28)
		BlockIcon.tint_button(button, Color.html(mat["color"]))
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
		var tool_tex: Texture2D = WeaponPreview.item_icon(item,
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
	# La grille créative aligne les 507 matériaux : c'est la seconde liste longue
	# du jeu, et elle paierait le même prix que l'inventaire sans le masque.
	b.icon = BlockIcon.cube_mask(CREATIVE_CELL - 6)
	BlockIcon.tint_button(b, color)
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

# ============================================================================
# TOUT LE CONTENU — un onglet par famille (2026-08-03)
# ============================================================================
#
# RÈGLE DE CONSTRUCTION : jamais une liste écrite à la main. Chaque grille est
# bâtie en parcourant le registre de GameData correspondant, donc ajouter un
# matériau, une essence ou un statut au jeu le rend triche-able sans toucher à
# ce fichier. Une liste recopiée aurait divergé dès le contenu suivant.

var _materials_list: VBoxContainer
var _objects_list: VBoxContainer
var _world_list: VBoxContainer
var _character_list: VBoxContainer

## Colonnes des grilles de contenu : six tiennent dans la largeur de l'onglet
## au format de bouton compact utilisé partout ailleurs.
const CONTENT_COLUMNS := 6

## Durée d'un statut posé depuis le menu : assez long pour l'observer, assez
## court pour ne pas rester collé au personnage toute la partie.
const CHEAT_STATUS_TICKS := 600

## Quantité créditée par un clic sur une ressource (plat, munition, viande).
const RESOURCE_GIVE_AMOUNT := 10


## Titre de section dans un onglet donné — `_add_section` n'écrit que dans
## l'onglet Général.
func _section_in(list: VBoxContainer, title_text: String) -> void:
	var label := Label.new()
	label.text = title_text
	label.add_theme_font_size_override("font_size", UITheme.FONT_BODY)
	label.add_theme_color_override("font_color", Color(1.0, 0.85, 0.4))
	list.add_child(label)


## Grille de boutons : un par id, libellé traduit, action liée à l'id.
func _content_grid(list: VBoxContainer, ids: Array, label_of: Callable, action: Callable) -> void:
	var grid := GridContainer.new()
	grid.columns = CONTENT_COLUMNS
	for id: String in ids:
		grid.add_child(_compact(String(label_of.call(id)), action.bind(id)))
	list.add_child(grid)


## Ids d'un registre, TRIÉS. L'ordre d'un Dictionary est celui de l'insertion,
## donc celui du système de fichiers : impraticable pour chercher une entrée
## parmi deux cent soixante-dix-huit.
func _sorted_ids(registry: Dictionary) -> Array:
	var ids: Array = registry.keys()
	ids.sort()
	return ids


## Libellé traduit d'une entrée de registre, avec repli sur son id — une entrée
## sans clé de locale doit rester cliquable, pas disparaître.
func _label_of(registry: Dictionary, id: String) -> String:
	var entry: Dictionary = registry.get(id, {})
	return tr(String(entry.get("name_key", id)))


# --- Onglet MATÉRIAUX -------------------------------------------------------

## Les 278 matériaux, RANGÉS PAR CATÉGORIE. En une seule grille alphabétique,
## trouver « granit » parmi 278 boutons demanderait de tout lire ; par
## catégorie, on sait déjà dans quelle section chercher.
func _build_materials_tab() -> void:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", UITheme.GAP)
	row.add_child(_compact("Tout donner", _give_all_materials))
	row.add_child(_compact("Vider matériaux", func() -> void:
		_player.inventory.material_stacks.clear()
		_player.inventory.material_fractions.clear()
		_set_status("Matériaux retirés de l'inventaire.")))
	_materials_list.add_child(row)

	var by_category := {}
	for material_id: String in GameData.materials:
		var category := String((GameData.materials[material_id] as Dictionary).get("category", "?"))
		if not by_category.has(category):
			by_category[category] = []
		(by_category[category] as Array).append(material_id)

	var categories: Array = by_category.keys()
	categories.sort()
	for category: String in categories:
		var ids: Array = by_category[category]
		ids.sort()
		_section_in(_materials_list, "%s (%d) — clic = +%d" % [
				category.capitalize(), ids.size(), MATERIAL_GIVE_AMOUNT])
		_content_grid(_materials_list, ids,
			func(id: String) -> String: return _label_of(GameData.materials, id),
			_give_material)


func _give_material(material_id: String) -> void:
	_player.inventory.add_material(material_id, MATERIAL_GIVE_AMOUNT)
	_set_status("+%d %s." % [MATERIAL_GIVE_AMOUNT, _label_of(GameData.materials, material_id)])


# --- Onglet OBJETS ----------------------------------------------------------

## Tout ce qui s'obtient en inventaire : objets fabriqués (TOUTES catégories,
## pas seulement les armes), plats, munitions et autres ressources.
##
## Les objets sont forgés avec les réglages de l'onglet ATELIER (bois, minerai,
## gemme, qualité) : dupliquer ici des sélecteurs de matériaux aurait fait deux
## états à tenir synchronisés pour le même geste.
func _build_objects_tab() -> void:
	var by_type := {}
	for item_id: String in GameData.items:
		var item_type := String((GameData.items[item_id] as Dictionary).get("type", "?"))
		if not by_type.has(item_type):
			by_type[item_type] = []
		(by_type[item_type] as Array).append(item_id)

	var types: Array = by_type.keys()
	types.sort()
	for item_type: String in types:
		var ids: Array = by_type[item_type]
		ids.sort()
		_section_in(_objects_list, "%s (%d) — forgé aux réglages de l'Atelier" % [
				item_type.capitalize(), ids.size()])
		_content_grid(_objects_list, ids,
			func(id: String) -> String: return _label_of(GameData.items, id),
			_forge_any_item)

	# PLATS, MUNITIONS ET RESSOURCES. Ils ne se forgent pas : ce sont des
	# instances de ressource empilables, sans choix de matériaux.
	var resource_ids := _sorted_ids(GameData.resources)
	_section_in(_objects_list, "Ressources, plats et munitions (%d) — clic = +%d" % [
			resource_ids.size(), RESOURCE_GIVE_AMOUNT])
	_content_grid(_objects_list, resource_ids,
		func(id: String) -> String: return _label_of(GameData.resources, id),
		_give_resource)


func _give_resource(resource_id: String) -> void:
	var instance := ItemFactory.resource_instance(resource_id, RESOURCE_GIVE_AMOUNT)
	if instance.is_empty():
		return
	_player.inventory.add_object(instance)
	_set_status("+%d %s." % [RESOURCE_GIVE_AMOUNT, _label_of(GameData.resources, resource_id)])


## Forge un objet quelconque aux réglages courants de l'atelier.
func _forge_any_item(item_id: String) -> void:
	var item: Dictionary = GameData.items.get(item_id, {})
	if item.is_empty():
		return
	# Chaque catégorie de la recette reçoit le choix courant de l'atelier ; une
	# catégorie qu'il ne propose pas (cuir, tissu…) prend le premier matériau
	# venu, sans quoi une cuirasse serait infabricable depuis ce menu.
	var choices := {}
	for input: Dictionary in (item.get("recipe", {}) as Dictionary).get("inputs", []):
		var category := String(input["category"])
		if category == "bois":
			choices[category] = _forge_wood
		elif category == "minerai":
			choices[category] = _forge_ore
		else:
			var pool := _materials_of(category)
			if not pool.is_empty():
				choices[category] = String(pool[0])
	if _forge_gem != "":
		choices["cristal"] = _forge_gem
	var instance := ItemFactory.craft(item_id, choices, _forge_quality)
	if instance.is_empty():
		_set_status("« %s » : aucun matériau disponible pour sa recette." % item_id)
		return
	_player.inventory.add_object(instance)
	_set_status("%s forgé (qualité %.1f)." % [_label_of(GameData.items, item_id), _forge_quality])


# --- Onglet MONDE -----------------------------------------------------------

## Ce qui se pose ou se déclenche dans le monde : essences d'arbre, plantes,
## transformations d'atelier, navigation de dimension.
func _build_world_tab() -> void:
	_section_in(_world_list, "Arbres (%d) — clic = planter devant soi" % GameData.trees.size())
	_content_grid(_world_list, _sorted_ids(GameData.trees),
		func(id: String) -> String: return _label_of(GameData.trees, id),
		_plant_tree)

	_section_in(_world_list, "Plantes (%d) — clic = planter devant soi" % GameData.plants.size())
	_content_grid(_world_list, _sorted_ids(GameData.plants),
		func(id: String) -> String: return _label_of(GameData.plants, id),
		_plant_plant)

	# TRANSFORMATIONS : elles ne se déclenchent qu'à la bonne station, avec les
	# bons intrants et la bonne compétence. Ici on saute tout ça et on crédite la
	# sortie — c'est la seule façon d'obtenir de l'acier ou du verre sans monter
	# la chaîne de production complète, et c'est le propre d'un menu de triche.
	_section_in(_world_list, "Transformations (%d) — clic = crédite la sortie" % GameData.transformations.size())
	_content_grid(_world_list, _sorted_ids(GameData.transformations),
		func(id: String) -> String: return _label_of(GameData.transformations, id),
		_apply_transformation)

	# DIMENSIONS : la grille est bâtie depuis le REGISTRE, comme tout le reste.
	# Une dimension ajoutée en données devient accessible ici sans une ligne de
	# code — c'était tout l'objet de la généralisation.
	_section_in(_world_list, "Dimensions (%d) — clic = y entrer" % GameData.dimensions.size())
	_content_grid(_world_list, _sorted_ids(GameData.dimensions),
		func(id: String) -> String: return _label_of(GameData.dimensions, id),
		_enter_dimension)

	_section_in(_world_list, "Donjon — navigation d'étage")
	var dims := HBoxContainer.new()
	dims.add_theme_constant_override("separation", UITheme.GAP)
	dims.add_child(_compact("Entrer en donjon", _enter_nearest_dungeon))
	dims.add_child(_compact("Sortir", func() -> void:
		# `DimensionManager.leave` couvre TOUTES les dimensions ; celle du
		# donjon passe par son backend, qui a son propre chemin de sortie.
		if DimensionManager.active == &"donjon":
			DungeonManager.leave()
		else:
			DimensionManager.leave()
		_set_status("Retour à l'overworld.")))
	dims.add_child(_compact("Descendre", func() -> void:
		DungeonManager.descend()
		_set_status("Étage inférieur.")))
	dims.add_child(_compact("Monter", func() -> void:
		DungeonManager.ascend()
		_set_status("Étage supérieur.")))
	_world_list.add_child(dims)


## Entre dans une dimension quelconque. Le donjon garde sa porte dédiée juste
## en dessous : il lui faut une CELLULE, alors que les dimensions génériques se
## construisent d'elles-mêmes.
func _enter_dimension(dimension_id: String) -> void:
	if dimension_id == "donjon":
		_enter_nearest_dungeon()
		return
	var here: Vector3 = _player.get_position_for_ai()
	if DimensionManager.enter(StringName(dimension_id), here, Vector3.ZERO):
		_set_status("Entré dans « %s »." % _label_of(GameData.dimensions, dimension_id))
	else:
		_set_status("Impossible d'entrer dans « %s »." % dimension_id)


func _apply_transformation(transformation_id: String) -> void:
	var recipe: Dictionary = GameData.transformations.get(transformation_id, {})
	var output: Dictionary = recipe.get("output", {})
	var material_id := String(output.get("material", ""))
	if material_id == "" or not GameData.materials.has(material_id):
		_set_status("« %s » : matériau de sortie inconnu." % transformation_id)
		return
	var amount := int(output.get("amount", 1)) * 10
	_player.inventory.add_material(material_id, amount)
	_set_status("+%d %s." % [amount, _label_of(GameData.materials, material_id)])


func _enter_nearest_dungeon() -> void:
	var here: Vector3 = _player.get_position_for_ai()
	var cell := ClaimManager.cell_of_block(int(here.x), int(here.z))
	# Même recherche en anneaux que la téléportation de POI : on ne veut pas d'un
	# second parcours qui divergerait du premier.
	for radius in range(0, MAX_RING):
		for dz in range(-radius, radius + 1):
			for dx in range(-radius, radius + 1):
				if maxi(absi(dx), absi(dz)) != radius:
					continue
				var candidate := cell + Vector2i(dx, dz)
				if DungeonManager.is_dungeon_cell(candidate):
					DungeonManager.enter_from_map(candidate)
					_set_status("Entrée dans le donjon de la cellule %s." % str(candidate))
					return
	_set_status("Aucun donjon trouvé alentour.")


## Plante une essence devant le joueur, blocs ET sous-grilles de détail — comme
## le générateur de monde la planterait.
func _plant_tree(species_id: String) -> void:
	var species: Dictionary = GameData.trees.get(species_id, {})
	if species.is_empty():
		return
	var spot := _spot_ahead()
	var tree := TreeGenerator.generate(spot, WorldManager.world_seed + TickManager.tick_index, species)
	var blocks: Dictionary = tree["blocks"]
	for pos: Vector3i in blocks:
		WorldManager.set_block(pos, blocks[pos])
	var subdivs: Dictionary = tree["trunk_subdivs"]
	for pos: Vector3i in subdivs:
		WorldManager.set_subdiv_grid(pos, subdivs[pos], blocks[pos])
	_set_status("%s planté (%d blocs)." % [_label_of(GameData.trees, species_id), blocks.size()])


## Plante une culture devant le joueur. Une plante tient dans UN bloc (c'est ce
## qui rend son indivisibilité gratuite) : sa sous-grille est le végétal, et sa
## grille de racines occupe le bloc du dessous quand l'espèce en a.
func _plant_plant(plant_id: String) -> void:
	var species: Dictionary = GameData.plants.get(plant_id, {})
	if species.is_empty():
		return
	var spot := _spot_ahead()
	var plant := PlantGenerator.generate(spot, WorldManager.world_seed + TickManager.tick_index,
			species, PLANT_MATURE_STAGE)
	var grid: PackedInt32Array = plant.get("grid", PackedInt32Array())
	if grid.is_empty():
		_set_status("« %s » n'a rien produit." % plant_id)
		return
	WorldManager.set_subdiv_grid(spot, grid, SubdivGrid.dominant_id(grid))
	var roots: PackedInt32Array = plant.get("root_grid", PackedInt32Array())
	if not roots.is_empty():
		WorldManager.set_subdiv_grid(spot + Vector3i(0, -1, 0), roots,
				SubdivGrid.dominant_id(roots))
	_set_status("%s planté." % _label_of(GameData.plants, plant_id))


## Stade de croissance des plantes posées ici : la plante est toujours donnée
## MATURE, c'est celle qu'on veut voir et récolter en test.
const PLANT_MATURE_STAGE := 3


## Case de sol libre devant le joueur — le sol RÉEL (blocs), pas la hauteur
## procédurale : en grotte, en donjon ou sur du terrain modifié, les deux
## diffèrent, et la même règle vaut déjà pour le spawn de créature.
func _spot_ahead() -> Vector3i:
	var fly_camera := get_node_or_null("../FlyCamera") as Node3D
	if fly_camera == null:
		return Vector3i.ZERO
	var forward := -fly_camera.global_basis.z
	forward.y = 0.0
	if forward.length_squared() < 0.001:
		forward = Vector3.FORWARD
	var spot := fly_camera.global_position + forward.normalized() * SPAWN_AHEAD
	var x := int(floor(spot.x))
	var z := int(floor(spot.z))
	var y := int(floor(fly_camera.global_position.y))
	for i in 64:
		if WorldManager.block_at_world(Vector3i(x, y - 1, z)) != 0:
			break
		y -= 1
	return Vector3i(x, y, z)


# --- Onglet PERSONNAGE ------------------------------------------------------

## Ce qui définit le personnage : race, classe, compétences une par une,
## statuts. Le menu ne savait que « tout maximiser » ou « tout remettre à
## zéro » sur les compétences, ce qui ne permet de tester aucun palier précis.
func _build_character_tab() -> void:
	_section_in(_character_list, "Races (%d) — clic = recrée le personnage" % GameData.races.size())
	_content_grid(_character_list, _sorted_ids(GameData.races),
		func(id: String) -> String: return _label_of(GameData.races, id),
		func(id: String) -> void: _recreate_character(id, String(_player.class_id)))

	_section_in(_character_list, "Classes (%d) — clic = recrée le personnage" % GameData.classes.size())
	_content_grid(_character_list, _sorted_ids(GameData.classes),
		func(id: String) -> String: return _label_of(GameData.classes, id),
		func(id: String) -> void: _recreate_character(String(_player.race_id), id))

	_section_in(_character_list, "Statuts (%d) — clic = appliquer, re-clic = retirer" % GameData.status_effects.size())
	_content_grid(_character_list, _sorted_ids(GameData.status_effects),
		func(id: String) -> String: return _label_of(GameData.status_effects, id),
		_toggle_status)

	_section_in(_character_list, "Compétences (%d) — clic = +5 niveaux" % GameData.skills.size())
	_content_grid(_character_list, _sorted_ids(GameData.skills),
		func(id: String) -> String: return _label_of(GameData.skills, id),
		_bump_skill)


func _toggle_status(status_id: String) -> void:
	if _player.statuses.has(status_id):
		_player.statuses.remove(status_id)
		_set_status("Statut « %s » retiré." % _label_of(GameData.status_effects, status_id))
		return
	_player.statuses.apply(status_id, CHEAT_STATUS_TICKS, 1.0)
	_set_status("%s appliqué (%d ticks)." % [
			_label_of(GameData.status_effects, status_id), CHEAT_STATUS_TICKS])


func _bump_skill(skill_id: String) -> void:
	var skill: Dictionary = _player.skills.skills.get(skill_id, {})
	if skill.is_empty():
		return
	skill["level"] = int(skill["level"]) + 5
	_set_status("%s : niveau %d." % [_label_of(GameData.skills, skill_id), int(skill["level"])])


## Recrée le personnage avec une race et une classe données.
##
## `apply_character` est LE chemin officiel — bonus de race, bonus de classe,
## compétences de départ, potentiels planchers. Écrire `race_id` à la main
## donnerait une race sans aucun de ses effets, c'est-à-dire une étiquette.
func _recreate_character(race_id: String, class_id: String) -> void:
	var allocated := {}
	for stat_id: String in _player.stats:
		allocated[stat_id] = int(_player.stats[stat_id])
	_player.apply_character({"race": race_id, "class": class_id, "stats": allocated})
	_set_status("Personnage recréé : %s / %s." % [
			_label_of(GameData.races, race_id), _label_of(GameData.classes, class_id)])
