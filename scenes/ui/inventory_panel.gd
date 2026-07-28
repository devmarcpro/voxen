extends PanelContainer
## Panneau d'inventaire (Tab) — étape D.3.3 : piles, outils, poids/capacité
## (A.4.2), compétences avec niveau/XP/potentiel (A.1/A.1.1).
## Localisation 10.1 : tout passe par des clés tr() avec placeholders.

const REFRESH_INTERVAL := 0.25

var _player: Node
var _label: Label


func _ready() -> void:
	_player = get_node_or_null("../../Player")
	visible = false
	var margin := MarginContainer.new()
	for side in ["margin_left", "margin_top", "margin_right", "margin_bottom"]:
		margin.add_theme_constant_override(side, 14)
	_label = Label.new()
	margin.add_child(_label)
	add_child(margin)
	var timer := Timer.new()
	timer.wait_time = REFRESH_INTERVAL
	timer.autostart = true
	timer.timeout.connect(_refresh)
	add_child(timer)


## Neutralisé le 2026-07-21 : Tab ouvre désormais le menu à onglets unifié
## (scenes/ui/game_menu.gd), dont l'onglet Inventaire remplace ce panneau.
## Nœud conservé (référencé par main.tscn) mais inerte — jamais affiché.
func _unhandled_key_input(_event: InputEvent) -> void:
	pass


func _refresh() -> void:
	if not visible or _player == null:
		return
	var inventory: Inventory = _player.inventory
	# A.4.2 : la charge compte l'inventaire ET l'équipement porté (6.2).
	var capacity: float = _player.carry_capacity()
	var weight: float = _player.carried_weight()
	var lines: Array[String] = [
		tr("ui.inv.titre"),
		"",
		tr("ui.inv.poids").format({"poids": "%.1f" % weight, "capacite": "%.0f" % capacity}),
	]
	if weight > capacity:
		lines.append(tr("ui.inv.surcharge"))
	lines.append("")
	# Outils / objets.
	for obj in inventory.objects:
		lines.append(tr("ui.inv.outil_ligne").format({
			"nom": tr(obj["name_key"]),
			"qualite": "%.2f" % float(obj["quality"]),
			"durete": "%.1f" % float(obj["base_hardness"]),
		}))
	# Piles de matériaux.
	var ids: Array = inventory.material_stacks.keys()
	ids.sort()
	for id: String in ids:
		lines.append("%s × %d" % [tr(String(GameData.stackable(id).get("name_key", ""))), inventory.material_stacks[id]])
	if inventory.objects.is_empty() and ids.is_empty():
		lines.append(tr("ui.inv.vide"))
	# Compétences (A.1) — niveau, XP vers le prochain niveau, potentiel.
	lines.append("")
	lines.append(tr("ui.inv.competences"))
	var skills: PlayerSkills = _player.skills
	var skill_ids: Array = skills.skills.keys()
	skill_ids.sort()
	for id: String in skill_ids:
		var s: Dictionary = skills.skills[id]
		lines.append(tr("ui.inv.competence_ligne").format({
			"nom": tr(GameData.skills[id]["name_key"]),
			"niveau": str(s["level"]),
			"xp": "%.0f" % float(s["xp"]),
			"xp_max": "%.0f" % PlayerSkills.xp_next(int(s["level"])),
			"potentiel": "%.0f" % float(s["potential"]),
		}))
	_label.text = "\n".join(lines)
