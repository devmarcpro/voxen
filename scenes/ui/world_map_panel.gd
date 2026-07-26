extends PanelContainer
## Panneau de stats affiché PENDANT que la carte du monde 3D est ouverte
## (scenes/world/world_map_view.gd gère l'écran lui-même, l'ouverture/
## fermeture et le voyage rapide). « Le joueur peut accéder à toutes ses
## stats » : stats C.1, santé/mana, compétences — plus les infos de la
## cellule survolée par la souris sur le relief.

var _player: Node
var _label: Label
var _hover_cell := Vector2i(1 << 30, 0)

const STAT_IDS: Array[String] = ["force", "dexterite", "endurance", "volonte", "perception", "charisme"]


func _ready() -> void:
	_player = get_node_or_null("../../Player")
	visible = false
	var margin := MarginContainer.new()
	for side in ["margin_left", "margin_top", "margin_right", "margin_bottom"]:
		margin.add_theme_constant_override(side, 14)
	_label = Label.new()
	# Sans wrap, une ligne longue (ex. info de cellule survolée) forçait la
	# taille minimale du Label au-delà de l'ancrage défini, et le panneau
	# s'étalait jusqu'à couvrir le centre de l'écran — bloquant les clics de
	# voyage rapide sur la carte (bug constaté au test).
	_label.autowrap_mode = TextServer.AUTOWRAP_WORD
	custom_minimum_size = Vector2(288.0, 0.0)
	clip_contents = true
	margin.add_child(_label)
	add_child(margin)
	var timer := Timer.new()
	timer.wait_time = 0.25
	timer.autostart = true
	timer.timeout.connect(_refresh)
	add_child(timer)


## Appelé par WorldMapView à chaque changement de cellule survolée.
func show_hovered_cell(cell: Vector2i) -> void:
	_hover_cell = cell
	_refresh()


func _refresh() -> void:
	if not visible or _player == null:
		return
	var lines: Array[String] = [tr("ui.map.titre"), ""]

	# Stats C.1.
	for stat_id in STAT_IDS:
		lines.append("%s : %d" % [tr("stat." + stat_id + ".name"), int(_player.stats[stat_id])])
	lines.append("")
	lines.append(tr("ui.hud.sante").format({"pv": str(int(_player.health)), "pv_max": str(int(_player.health_max))}))
	lines.append(tr("ui.hud.mana").format({"mana": str(int(_player.mana.current)), "mana_max": str(int(_player.mana.max_mana()))}))

	# Compétences (A.1).
	lines.append("")
	lines.append(tr("ui.inv.competences"))
	var skills: PlayerSkills = _player.skills
	var skill_ids: Array = skills.skills.keys()
	skill_ids.sort()
	for id: String in skill_ids:
		var s: Dictionary = skills.skills[id]
		if int(s["level"]) <= 0:
			continue  # N'encombre pas l'écran des compétences jamais utilisées.
		lines.append(tr("ui.inv.competence_ligne").format({
			"nom": tr(GameData.skills[id]["name_key"]),
			"niveau": str(s["level"]),
			"xp": "%.0f" % float(s["xp"]),
			"xp_max": "%.0f" % PlayerSkills.xp_next(int(s["level"])),
			"potentiel": "%.0f" % float(s["potential"]),
		}))

	# Cellule survolée sur le relief.
	if _hover_cell.x != (1 << 30) and WorldManager.generator != null:
		lines.append("")
		var g := WorldManager.generator
		var wx := _hover_cell.x * ClaimManager.CELL_SIZE + ClaimManager.CELL_SIZE / 2
		var wz := _hover_cell.y * ClaimManager.CELL_SIZE + ClaimManager.CELL_SIZE / 2
		var biome: Dictionary = g.biome_at(wx, wz)
		var danger := g.danger_level(wx, wz)
		var status: String
		if ClaimManager.is_claimed(_hover_cell):
			status = tr("ui.hud.cellule_revendiquee").format({"role": tr("ui.role_name." + ClaimManager.role_of(_hover_cell))})
		else:
			status = tr("ui.hud.cellule_libre")
		lines.append(tr("ui.hud.cellule").format({"x": str(_hover_cell.x), "z": str(_hover_cell.y), "statut": status}))
		if not biome.is_empty():
			lines.append("%s — %s" % [tr(biome["name_key"]), tr("ui.map.danger.%d" % danger)])

	lines.append("")
	lines.append(tr("ui.map.aide"))
	_label.text = "\n".join(lines)
