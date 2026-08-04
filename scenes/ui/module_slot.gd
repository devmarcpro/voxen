class_name ModuleSlot
extends PanelContainer
## Une CASE de module (menu combat, GDD 5.1) — 2026-08-03.
##
## Deux rôles, un seul type de nœud :
##   - case de RÉSERVE : porte un module appris, source de glissement, jamais
##     vidée (on ne « consomme » pas un module en l'assemblant, on l'y range) ;
##   - case d'ASSEMBLAGE : une position d'un slot de compétence, qui accepte un
##     dépôt et peut elle-même être glissée ailleurs.
##
## POURQUOI LE GLISSER-DÉPOSER, ET PAS UNE LISTE DÉROULANTE. Dans ce système
## l'ORDRE décide de tout : un modificateur placé avant ou après un effet donne
## deux sorts différents. Une liste déroulante par position dit l'ordre mais ne
## permet pas de le CHANGER — il fallait vider et recomposer pour déplacer un
## module d'un cran, c'est-à-dire précisément l'activité principale de cet écran.
##
## Le glissement natif de Godot (`_get_drag_data` / `_can_drop_data` /
## `_drop_data`) est utilisé tel quel : il gère l'aperçu et le survol, et
## réécrire ça à la main n'apporterait rien.

## Émis quand un dépôt a eu lieu. `payload` décrit CE QUI a été glissé, `self`
## dit OÙ — c'est le panneau qui recompose l'assemblage, la case ne connaît pas
## le modèle.
signal dropped(payload: Dictionary, target: ModuleSlot)
## Émis au clic droit : retirer le module de cette case.
signal cleared(target: ModuleSlot)

## Largeur calée sur le PLUS LONG nom du catalogue (« Déclencheur à l'impact »).
## À 112 px les noms de déclencheurs étaient tronqués en plein milieu, ce qui
## rendait la case illisible alors que c'est tout ce qu'elle a à dire.
const SIZE := Vector2(148, 32)

## Teintes par rôle de module. Elles portent l'information la plus utile de tout
## l'écran : un assemblage se lit à ses couleurs avant de se lire à ses noms.
const ROLE_COLORS := {
	"effet": Color(0.32, 0.44, 0.62),
	"modificateur": Color(0.46, 0.38, 0.22),
	"declencheur": Color(0.44, 0.26, 0.44),
}

## Identité de la case dans le modèle. "reserve" ou "assemblage" ; pour un
## assemblage : la famille, le slot et la position.
var kind := "reserve"
var family := ""
var slot := -1
var position_index := -1
var module_id := ""

var _label: Label


func _ready() -> void:
	custom_minimum_size = SIZE
	mouse_filter = Control.MOUSE_FILTER_STOP
	_label = Label.new()
	_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_label.autowrap_mode = TextServer.AUTOWRAP_OFF
	_label.clip_text = true
	_label.add_theme_font_size_override("font_size", UITheme.FONT_SMALL)
	_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	add_child(_label)
	refresh()


## (Re)pose le contenu de la case. `id` vide = case libre.
func set_module(id: String) -> void:
	module_id = id
	if is_inside_tree():
		refresh()


func refresh() -> void:
	if _label == null:
		return
	var style := StyleBoxFlat.new()
	style.set_corner_radius_all(3)
	style.set_border_width_all(1)
	if module_id.is_empty():
		_label.text = "—"
		_label.add_theme_color_override("font_color", UITheme.TEXT_DIM)
		style.bg_color = UITheme.BG_SLOT
		style.border_color = UITheme.LINE
		tooltip_text = ""
	else:
		var module: Dictionary = GameData.modules.get(module_id, {})
		_label.text = tr(String(module.get("name_key", module_id)))
		_label.add_theme_color_override("font_color", UITheme.TEXT)
		var role := String(module.get("module_type", "effet"))
		style.bg_color = ROLE_COLORS.get(role, UITheme.BG_SLOT)
		style.border_color = UITheme.LINE_STRONG
		# L'infobulle porte ce qui ne tient pas dans la case : le rôle, le coût,
		# et surtout CE QUE FAIT le module dans l'ordre — sans quoi la couleur
		# reste un code qu'il faut apprendre ailleurs.
		tooltip_text = "%s · %s · %d mana" % [
			tr("ui.module.role." + role),
			tr(String(module.get("name_key", module_id))),
			int(module.get("mana_cost_base", 0))]
	add_theme_stylebox_override("panel", style)


# --- Glisser-déposer natif ---

func _get_drag_data(_at: Vector2) -> Variant:
	if module_id.is_empty():
		return null
	var payload := {
		"module": module_id, "kind": kind,
		"family": family, "slot": slot, "position": position_index,
	}
	# Aperçu : une COPIE de la case, pas le nœud lui-même. Déplacer l'original
	# le retirerait de l'arbre pendant le glissement, et un dépôt annulé le
	# laisserait nulle part.
	var preview := ModuleSlot.new()
	preview.kind = "apercu"
	preview.module_id = module_id
	preview.modulate.a = 0.85
	set_drag_preview(preview)
	return payload


func _can_drop_data(_at: Vector2, data: Variant) -> bool:
	# La RÉSERVE n'accepte rien : elle contient déjà tout ce qu'on connaît, et y
	# déposer n'aurait aucun sens. Retirer un module d'un assemblage se fait au
	# clic droit, pas en le rejetant dans le tas.
	return kind == "assemblage" and data is Dictionary and (data as Dictionary).has("module")


func _drop_data(_at: Vector2, data: Variant) -> void:
	dropped.emit(data as Dictionary, self)


func _gui_input(event: InputEvent) -> void:
	var button := event as InputEventMouseButton
	if button != null and button.pressed and button.button_index == MOUSE_BUTTON_RIGHT:
		if kind == "assemblage" and not module_id.is_empty():
			cleared.emit(self)
			accept_event()
