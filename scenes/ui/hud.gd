extends Label
## HUD de debug — FPS, chunks, position, biome, cible de récolte, toasts de
## niveau. Localisation 10.1 : AUCUNE string en dur — tout passe par des
## clés tr() avec placeholders (jamais de concaténation de phrases).

const REFRESH_INTERVAL := 0.25
const TOAST_DURATION := 3.0

var _player: Node
var _toast_text := ""
var _toast_until := 0.0


func _ready() -> void:
	_player = get_node_or_null("../../Player")
	var timer := Timer.new()
	timer.wait_time = REFRESH_INTERVAL
	timer.autostart = true
	timer.timeout.connect(_refresh)
	add_child(timer)
	EventBus.locale_changed.connect(func(_locale: String) -> void: _refresh())
	EventBus.skill_level_up.connect(_on_skill_level_up)
	EventBus.ui_notification.connect(_on_notification)
	EventBus.creature_killed.connect(_on_creature_killed)
	_refresh()


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
	_refresh()


func _refresh() -> void:
	var s := WorldManager.stats()
	var camera := get_viewport().get_camera_3d()
	var pos := camera.global_position if camera != null else Vector3.ZERO
	var lines: Array[String] = [
		tr("ui.hud.fps").format({"fps": str(int(Performance.get_monitor(Performance.TIME_FPS)))}),
		tr("ui.hud.chunks").format({
			"meshes": str(s["meshes"]),
			"cache": str(s["cache"]),
			"file": str(s["queue"]),
		}),
		tr("ui.hud.meshing").format({
			"moyen": "%.2f" % s["meshing_avg_ms"],
			"max": "%.2f" % s["meshing_max_ms"],
		}),
		tr("ui.hud.pos").format({"x": str(int(pos.x)), "y": str(int(pos.y)), "z": str(int(pos.z))}),
	]
	# Santé/mana du joueur (A.5).
	if _player != null:
		lines.append(tr("ui.hud.sante").format({"pv": str(int(_player.health)), "pv_max": str(int(_player.health_max))}))
		lines.append(tr("ui.hud.mana").format({"mana": str(int(_player.mana.current)), "mana_max": str(int(_player.mana.max_mana()))}))
		lines.append(tr("ui.hud.or").format({"or": str(_player.gold)}))
	# Biome courant (résolution B.6 au point de la caméra).
	if WorldManager.generator != null:
		var biome: Dictionary = WorldManager.generator.biome_at(int(pos.x), int(pos.z))
		if not biome.is_empty():
			lines.append(tr("ui.hud.biome").format({"biome": tr(biome["name_key"])}))
		# Température (°C flavor, -15..40) + fertilité locale (prospection
		# agricole, 2026-07-26) : le joueur choisit où cultiver.
		var temp_n := WorldManager.generator.temperature_at(int(pos.x), int(pos.z))
		lines.append(tr("ui.hud.temperature").format({"deg": str(int(round(-15.0 + temp_n * 55.0)))}))
		var fert := WorldManager.generator.fertility_at(int(pos.x), int(pos.z))
		lines.append(tr("ui.hud.fertilite").format({"pct": str(int(round(fert * 100.0)))}))
	# Grille de construction active (4.1 : 32/16/8/4 px).
	if _player != null:
		lines.append(tr("ui.hud.grille").format({"res": str(_player.active_res)}))
	# Cible de récolte (A.2 — feedback « l'outil rebondit »).
	if _player != null:
		var info: Dictionary = _player.target_info()
		if not info.is_empty():
			if info["bouncing"]:
				lines.append(tr("ui.hud.cible_rebond").format({"materiau": tr(info["name_key"])}))
			else:
				lines.append(tr("ui.hud.cible").format({
					"materiau": tr(info["name_key"]),
					"progres": str(info["progress_pct"]),
				}))
			var tool_key: String = info["tool_name_key"]
			lines.append(tr("ui.hud.outil").format({
				"outil": tr(tool_key) if tool_key != "" else tr("ui.outil.mains_nues"),
			}))
	# Modules assemblés (E.3/A.6 — touches J/K/L).
	if _player != null:
		for i in _player.MODULE_LOADOUT.size():
			var module: Dictionary = GameData.modules[_player.MODULE_LOADOUT[i]]
			lines.append(tr("ui.hud.module").format({
				"slot": ["J", "K", "L"][i],
				"nom": tr(module["name_key"]),
				"cout": str(int(module["mana_cost_base"])),
			}))
	# Cellule courante et statut de claim (3.3).
	if _player != null:
		var cell: Vector2i = _player.current_cell()
		var status: String
		if ClaimManager.is_claimed(cell):
			status = tr("ui.hud.cellule_revendiquee").format({"role": tr("ui.role_name." + ClaimManager.role_of(cell))})
		else:
			status = tr("ui.hud.cellule_libre")
		lines.append(tr("ui.hud.cellule").format({"x": str(cell.x), "z": str(cell.y), "statut": status}))
	# Créature visée (E.3).
	if _player != null:
		var creature_info: Dictionary = _player.creature_target_info()
		if not creature_info.is_empty():
			lines.append("%s — %d/%d PV" % [tr(creature_info["name_key"]), creature_info["health"], creature_info["health_max"]])
	# Toast de passage de niveau (A.1).
	if Time.get_ticks_msec() / 1000.0 < _toast_until:
		lines.append(_toast_text)
	lines.append(tr("ui.hud.controles1"))
	lines.append(tr("ui.hud.controles2"))
	lines.append(tr("ui.hud.controles3"))
	lines.append(tr("ui.hud.controles4"))
	lines.append(tr("ui.hud.controles5"))
	text = "\n".join(lines)
