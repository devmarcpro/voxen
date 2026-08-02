extends Control
## Bandeau d'information du jeu : diagnostic, lieu, cible visée, modules, aide.
##
## POURQUOI CE FICHIER A ÉTÉ REFONDU. C'était un unique Label de vingt-cinq
## lignes empilées sans hiérarchie, sur fond de ciel : le FPS, le biome, la
## fertilité du sol, les trois modules de sort et cinq lignes de rappel de
## touches se suivaient dans la même colonne grise. Trouver une valeur
## demandait de relire la liste entière, et le rappel des touches — qui ne
## change jamais — occupait un cinquième de l'écran en permanence.
##
## Trois principes ici :
##
## 1. UN BLOC = UNE QUESTION. « Est-ce que ça rame », « où suis-je », « je vise
##    quoi », « quels sorts ». Chaque bloc est encadré, ce qui rend son étendue
##    visible sans avoir à lire son contenu.
## 2. CE QUI NE CHANGE PAS SE RANGE. L'aide aux commandes passe dans un panneau
##    séparé, en bas, masquable (F3) — utile au premier lancement, encombrant
##    ensuite.
## 3. UN BLOC SANS CONTENU DISPARAÎT. Le bloc « cible » n'existe que quand on
##    vise quelque chose ; le laisser vide reviendrait à réserver de l'espace
##    pour rien.
##
## Les valeurs vitales (PV, mana) ne sont PLUS ici : elles ont des jauges
## dédiées (StatBar), et les afficher deux fois sous deux formes différentes
## était la meilleure façon qu'on ne regarde ni l'une ni l'autre.
##
## Localisation 10.1 : aucune chaîne en dur, tout passe par tr() à placeholders.

const REFRESH_INTERVAL := 0.25
const TOAST_DURATION := 3.0

## Largeur de la colonne d'intitulés. Commune à tous les blocs : c'est elle qui
## fait que les valeurs s'alignent verticalement d'un bloc à l'autre.
const KEY_W := 92

var _player: Node
var _toast_text := ""
var _toast_until := 0.0

var _rows := {}                  # id → Label de valeur
var _blocks := {}                # id → Control encadré (pour le masquage)
var _column: VBoxContainer
var _help: Control
var _toast: Label


func _ready() -> void:
	_player = get_node_or_null("../../Player")
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_build()
	var timer := Timer.new()
	timer.wait_time = REFRESH_INTERVAL
	timer.autostart = true
	timer.timeout.connect(_refresh)
	add_child(timer)
	# Un changement de langue doit reconstruire les INTITULÉS, pas seulement les
	# valeurs : ils sont posés une fois à la construction.
	EventBus.locale_changed.connect(func(_locale: String) -> void: _rebuild_labels())
	EventBus.skill_level_up.connect(_on_skill_level_up)
	EventBus.ui_notification.connect(_on_notification)
	EventBus.creature_killed.connect(_on_creature_killed)
	_refresh()


# --- Construction ------------------------------------------------------------

func _build() -> void:
	_column = VBoxContainer.new()
	_column.add_theme_constant_override("separation", UITheme.GAP)
	_column.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_column)

	_block("systeme", "ui.hud.bloc_systeme", ["fps", "chunks", "meshing"])
	_block("lieu", "ui.hud.bloc_lieu",
		["position", "biome", "royaume", "localite", "lois", "temperature", "fertilite", "cellule", "grille"])
	_block("cible", "ui.hud.bloc_cible", ["materiau", "outil", "creature"])
	_block("modules", "ui.hud.bloc_modules", ["module_j", "module_k", "module_l"])

	_build_help()
	_build_toast()


## Un bloc encadré : titre accentué, filet, puis une ligne par valeur.
func _block(id: String, title_key: String, row_ids: Array) -> void:
	var frame := PanelContainer.new()
	frame.mouse_filter = Control.MOUSE_FILTER_IGNORE
	frame.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", UITheme.GAP_TIGHT)
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	frame.add_child(box)

	var title := Label.new()
	title.text = tr(title_key)
	title.add_theme_font_size_override("font_size", UITheme.FONT_SMALL)
	title.add_theme_color_override("font_color", UITheme.TEXT_ACCENT)
	title.set_meta("title_key", title_key)
	box.add_child(title)

	for row_id: String in row_ids:
		var row := UITheme.field(tr("ui.hud.cle." + row_id), "", KEY_W)
		row.get_child(0).set_meta("key", "ui.hud.cle." + row_id)
		box.add_child(row)
		_rows[row_id] = row.get_child(1)
		# La LIGNE entière est mémorisée, pas seulement son libellé : une valeur
		# absente doit faire disparaître l'intitulé avec elle.
		_rows[row_id + "#row"] = row

	_column.add_child(frame)
	_blocks[id] = frame


func _build_help() -> void:
	_help = PanelContainer.new()
	_help.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_help.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	_help.position = Vector2(0, -110)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", UITheme.GAP_TIGHT)
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_help.add_child(box)
	for index in HELP_LINES.size():
		var line := UITheme.dim(_help_line(index))
		line.set_meta("help_line", index)
		box.add_child(line)
	var hint := UITheme.dim(_toggle_hint())
	hint.add_theme_color_override("font_color", UITheme.TEXT_ACCENT)
	hint.set_meta("help_hint", true)
	box.add_child(hint)
	add_child(_help)
	# Une remappe doit se voir immédiatement : sans ceci, l'aide continuerait
	# d'annoncer l'ancienne touche jusqu'au prochain changement de langue.
	InputManager.bindings_changed.connect(_rebuild_help)


## Aide contextuelle : chaque ligne est une liste de GROUPES, et chaque groupe
## est soit une liste d'actions (leurs touches accolées : « ZQSD »), soit une
## clé de localisation seule pour ce que l'InputMap ne couvre pas (la souris).
##
## Les touches ne sont plus ÉCRITES dans les fichiers de langue. Elles
## l'étaient — « ZQSD : marcher · Espace : sauter · F : vol/marche » en dur
## dans fr.csv, en.csv, ja.csv et zh_Hans.csv — donc toute réaffectation
## rendait l'aide fausse dans quatre langues à la fois, silencieusement.
const HELP_LINES: Array = [
	[["move_forward", "move_left", "move_back", "move_right"], ["jump"], ["toggle_fly"], ["sprint"], ["sneak"]],
	["ui.hud.souris"],
	["ui.hud.hotbar", ["cycle_grid"]],
	[["module_1", "module_2", "module_3"], ["toggle_claim"], ["cycle_claim_role"], ["world_map"], ["inventory"]],
	[["eat"], ["equip"], ["pickup"], ["sleep"], ["talk"]],
	[["stall_stock"], ["stall_collect"], ["save_game"], ["reload_data"], ["cheat_menu"]],
]


## Une ligne d'aide : « ZQSD : marcher · Espace : sauter · … ».
func _help_line(index: int) -> String:
	var parts: Array[String] = []
	for group: Variant in HELP_LINES[index]:
		if group is String:
			parts.append(tr(group))  # Bloc figé (souris, hotbar 1-9).
			continue
		var actions := group as Array
		# Le libellé est celui de la PREMIÈRE action du groupe : « avancer »
		# nomme l'ensemble ZQSD, « module_1 » l'ensemble J/K/L.
		parts.append("%s : %s" % [
				InputManager.keys_label(actions),
				tr(InputManager.label_key(String(actions[0])))])
	return " · ".join(parts)


func _toggle_hint() -> String:
	return tr("ui.hud.aide_bascule").format({"touche": InputManager.key_label("debug_hud")})


## Repose les textes de l'aide (remappe ou changement de langue).
func _rebuild_help() -> void:
	if _help == null:
		return
	for child in (_help.get_child(0) as Node).get_children():
		var label := child as Label
		if label.has_meta("help_line"):
			label.text = _help_line(int(label.get_meta("help_line")))
		elif label.has_meta("help_hint"):
			label.text = _toggle_hint()


## Le toast (montée de niveau, créature tuée) est CENTRÉ et séparé du reste :
## noyé au milieu d'une liste de diagnostic, il passait inaperçu — or c'est le
## seul élément du HUD qui annonce un événement plutôt qu'un état.
func _build_toast() -> void:
	_toast = Label.new()
	_toast.set_anchors_preset(Control.PRESET_CENTER_TOP)
	_toast.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_toast.add_theme_color_override("font_color", UITheme.TEXT_ACCENT)
	_toast.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_toast.visible = false
	add_child(_toast)


## Repose tous les textes FIXES après un changement de langue.
func _rebuild_labels() -> void:
	for id: String in _blocks:
		var box: Node = (_blocks[id] as Control).get_child(0)
		for child in box.get_children():
			if child.has_meta("title_key"):
				(child as Label).text = tr(String(child.get_meta("title_key")))
			elif child is HBoxContainer and child.get_child(0).has_meta("key"):
				var key_label: Label = child.get_child(0)
				key_label.text = tr(String(key_label.get_meta("key")))
	_rebuild_help()
	_refresh()


func _unhandled_key_input(event: InputEvent) -> void:
	var key := event as InputEventKey
	if key == null or not key.pressed or key.echo:
		return
	if event.is_action_pressed("debug_hud"):
		_help.visible = not _help.visible
		_blocks["systeme"].visible = _help.visible
		get_viewport().set_input_as_handled()


# --- Événements --------------------------------------------------------------

func _on_creature_killed(killer, victim) -> void:
	if killer == _player and victim != null:
		_show_toast(tr("ui.toast.creature_tuee").format({"creature": tr(victim.display_name_key)}))


func _on_skill_level_up(skill_id: String, new_level: int, _entity) -> void:
	var skill: Dictionary = GameData.skills.get(skill_id, {})
	_show_toast(tr("ui.toast.niveau").format({
		"competence": tr(skill.get("name_key", skill_id)),
		"niveau": str(new_level),
	}))


func _on_notification(message_key: String) -> void:
	_show_toast(tr(message_key))


func _show_toast(text_value: String) -> void:
	_toast_text = text_value
	_toast_until = Time.get_ticks_msec() / 1000.0 + TOAST_DURATION
	_toast.text = text_value
	_toast.visible = true


# --- Rafraîchissement --------------------------------------------------------

## Nom `_put` et non `_set` : `Object._set` est un point d entree du moteur,
## le redefinir avec une autre signature casse le chargement du script.
func _put(row_id: String, value: String) -> void:
	var label: Label = _rows.get(row_id)
	if label == null:
		return
	if label.text != value:
		label.text = value
	(_rows[row_id + "#row"] as Control).visible = value != ""


func _refresh() -> void:
	var s := WorldManager.stats()
	var camera := get_viewport().get_camera_3d()
	var pos := camera.global_position if camera != null else Vector3.ZERO

	_put("fps", str(int(Performance.get_monitor(Performance.TIME_FPS))))
	_put("chunks", tr("ui.hud.chunks_valeur").format({
		"meshes": str(s["meshes"]), "cache": str(s["cache"]), "file": str(s["queue"])}))
	_put("meshing", tr("ui.hud.meshing_valeur").format({
		"moyen": "%.2f" % s["meshing_avg_ms"], "max": "%.2f" % s["meshing_max_ms"]}))
	_put("position", "%d, %d, %d" % [int(pos.x), int(pos.y), int(pos.z)])

	if WorldManager.generator != null:
		var biome: Dictionary = WorldManager.generator.biome_at(int(pos.x), int(pos.z))
		_put("biome", tr(biome["name_key"]) if not biome.is_empty() else "")
		var temp_n := WorldManager.generator.temperature_at(int(pos.x), int(pos.z))
		_put("temperature", "%d°C" % int(round(-15.0 + temp_n * 55.0)))
		_put("fertilite", "%d%%" % int(round(
			WorldManager.generator.fertility_at(int(pos.x), int(pos.z)) * 100.0)))

	if _player != null:
		_put("grille", tr("ui.hud.grille_valeur").format({"res": str(_player.active_res)}))
		# SOUS QUELLE AUTORITÉ ? Lois, taxes et gardes en dépendent (14.4), et
		# « hors royaume = aucune loi » est une information, pas une absence :
		# on l'affiche explicitement plutôt que de laisser la ligne vide.
		# Le générateur est ABSENT au menu de démarrage : le HUD s'y rafraîchit
		# quand même, et l'interroger sans garde y plantait une fois par tick.
		var kingdom := {}
		if WorldManager.generator != null:
			kingdom = WorldManager.generator.kingdom_at_cell(_player.current_cell())
		if kingdom.is_empty():
			_put("royaume", tr("ui.hud.terres_sauvages"))
			_put("lois", "")
		else:
			_put("royaume", "%s · %s" % [String(kingdom["name"]),
				tr("gouvernance." + String(kingdom["government_type"]))])
			_put("lois", _laws_summary(kingdom))
		# NOM DE LA LOCALITÉ (12.5/E.31, 2026-08-02). Les villages n'avaient
		# aucun nom : on ne pouvait désigner un lieu que par ses coordonnées.
		# La ligne DISPARAÎT hors d'un village (`_put` masque une valeur vide),
		# elle n'occupe donc pas le HUD en pleine nature.
		var here: Vector2i = _player.current_cell()
		var has_village := WorldManager.generator != null 				and not (WorldManager.generator.city_at_cell(here) as Dictionary).is_empty()
		_put("localite", VillageManager.name_of(here) if has_village else "")
		var cell: Vector2i = _player.current_cell()
		var status := tr("ui.hud.cellule_libre")
		if ClaimManager.is_claimed(cell):
			status = tr("ui.role_name." + ClaimManager.role_of(cell))
		_put("cellule", "(%d, %d) %s" % [cell.x, cell.y, status])
		_refresh_target()
		_refresh_modules()

	if _toast.visible and Time.get_ticks_msec() / 1000.0 >= _toast_until:
		_toast.visible = false


## Le bloc « cible » ne s'affiche QUE si l'on vise quelque chose. Un bloc vide en
## permanence apprendrait au joueur à ne plus regarder cet endroit de l'écran,
## et il ne le regarderait pas non plus le jour où il s'y passe quelque chose.
func _refresh_target() -> void:
	var info: Dictionary = _player.target_info()
	var creature_info: Dictionary = _player.creature_target_info()
	_blocks["cible"].visible = not (info.is_empty() and creature_info.is_empty())
	if not _blocks["cible"].visible:
		return

	if info.is_empty():
		_put("materiau", "")
		_put("outil", "")
	elif info["bouncing"]:
		# « L'outil rebondit » (A.2) : l'outil est trop tendre pour ce bloc. En
		# rouge, parce que c'est un échec et non une progression lente.
		_put("materiau", tr("ui.hud.cible_rebond_valeur").format({
			"materiau": tr(info["name_key"])}))
		_rows["materiau"].add_theme_color_override("font_color", UITheme.TEXT_WARN)
		_put("outil", tr(String(info["tool_name_key"])) if String(info["tool_name_key"]) != ""
			else tr("ui.outil.mains_nues"))
	else:
		_put("materiau", "%s — %d%%" % [tr(info["name_key"]), int(info["progress_pct"])])
		_rows["materiau"].add_theme_color_override("font_color", UITheme.TEXT)
		_put("outil", tr(String(info["tool_name_key"])) if String(info["tool_name_key"]) != ""
			else tr("ui.outil.mains_nues"))

	if creature_info.is_empty():
		_put("creature", "")
	else:
		# La touche d'interaction s'affiche SUR la ligne de la créature visée :
		# c'est le seul endroit où le joueur regarde déjà au moment où elle
		# devient utile.
		var hint := ""
		if _player.can_talk_to_target():
			hint = "   [" + tr("ui.dialogue.interagir") + "]"
		_put("creature", "%s %d/%d%s" % [tr(creature_info["name_key"]),
			int(creature_info["health"]), int(creature_info["health_max"]), hint])


func _refresh_modules() -> void:
	for index in _player.MODULE_LOADOUT.size():
		var module: Dictionary = GameData.modules[_player.MODULE_LOADOUT[index]]
		_put(["module_j", "module_k", "module_l"][index],
			tr("ui.hud.module_valeur").format({
				"nom": tr(module["name_key"]),
				"cout": str(int(module["mana_cost_base"]))}))


## Résumé des lois locales. UNE LOI QU'ON DÉCOUVRE PAR LA SANCTION N'EST PAS UNE
## RÈGLE, c'est un piège : le joueur doit pouvoir lire ce qui est interdit ici
## avant de l'enfreindre. C'est particulièrement vrai des interdictions
## arbitraires — se faire confisquer une lance sans savoir qu'elle est prohibée
## se lit comme un vol, pas comme une loi.
func _laws_summary(kingdom: Dictionary) -> String:
	var laws := KingdomLaws.laws_of(kingdom)
	if laws.is_empty():
		return tr("ui.loi.aucune")
	var parts: Array[String] = []
	for law: Dictionary in laws:
		if String(law.get("type", "comportement")) == "objet":
			var item: Dictionary = GameData.items.get(String(law["target"]), {})
			parts.append(tr("ui.loi.interdit").format({
				"objet": tr(String(item.get("name_key", law["target"])))}))
		else:
			parts.append(tr("loi." + String(law["target"])))
	return " · ".join(parts)
