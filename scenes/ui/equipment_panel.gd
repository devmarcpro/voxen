class_name EquipmentPanel
extends VBoxContainer
## Silhouette du personnage et ses emplacements d'équipement (2026-08-02).
##
## POURQUOI CE FICHIER EXISTE. L'équipement n'avait aucune représentation : on
## équipait par un menu contextuel, à l'aveugle, sans jamais VOIR ce qu'on
## portait. Deux écrans en ont besoin — l'inventaire, pour glisser un objet sur
## le personnage, et l'onglet Combat, pour les deux mains — et les dupliquer
## aurait garanti qu'ils divergent au premier ajustement.
##
## Le panneau ne connaît ni le menu ni la liste d'inventaire : il reçoit le
## joueur, affiche ses emplacements, et prévient par un signal quand quelque
## chose a changé. C'est l'appelant qui décide de ce qu'il rafraîchit.

## Émis après un équipement ou un retrait — l'appelant rafraîchit sa liste.
signal changed

## Disposition en TROIS COLONNES autour de la silhouette : ce qui se porte à
## gauche, le corps au centre, ce qui se porte à droite. La colonne du milieu
## suit l'axe du corps, de la tête aux pieds, pour qu'on trouve un emplacement
## sans le lire.
const LAYOUT := {
	"gauche": ["tete", "torse", "jambes", "pieds"],
	"droite": ["mains", "dos", "amulette", "anneau_1", "anneau_2"],
	"mains": ["arme_1", "arme_2"],
}
const SLOT_SIZE := 52


var _player: Node
var _slots := {}          # nom d'emplacement -> PanelContainer
## Emplacements affichés en grand (les deux mains) : ils portent la posture de
## combat, c'est ce qu'on regarde en premier.
var _hands_only := false


## `hands_only` : ne montrer que les deux mains (onglet Combat). L'inventaire,
## lui, montre les treize emplacements.
func setup(player: Node, hands_only: bool = false) -> void:
	_player = player
	_hands_only = hands_only
	add_theme_constant_override("separation", 6)
	if hands_only:
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 10)
		row.alignment = BoxContainer.ALIGNMENT_CENTER
		for slot: String in LAYOUT["mains"]:
			row.add_child(_slot_widget(slot, true))
		add_child(row)
	else:
		var grid := HBoxContainer.new()
		grid.add_theme_constant_override("separation", 8)
		grid.alignment = BoxContainer.ALIGNMENT_CENTER
		grid.add_child(_column(LAYOUT["gauche"]))
		grid.add_child(_silhouette())
		grid.add_child(_column(LAYOUT["droite"]))
		add_child(grid)
		var hands := HBoxContainer.new()
		hands.add_theme_constant_override("separation", 10)
		hands.alignment = BoxContainer.ALIGNMENT_CENTER
		for slot: String in LAYOUT["mains"]:
			hands.add_child(_slot_widget(slot, true))
		add_child(hands)
	refresh()


func _column(slots: Array) -> Control:
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 6)
	for slot: String in slots:
		column.add_child(_slot_widget(slot, false))
	return column


## Silhouette : un simple gabarit de proportions, pas un portrait. Elle sert de
## repère spatial — sans elle, deux colonnes d'icônes ne se lisent pas comme un
## personnage et l'on ne sait plus quel emplacement est où.
func _silhouette() -> Control:
	var box := VBoxContainer.new()
	box.custom_minimum_size = Vector2(96, 0)
	box.alignment = BoxContainer.ALIGNMENT_CENTER
	box.add_theme_constant_override("separation", 2)
	for shape: Array in [[26, 26], [46, 54], [40, 44], [34, 16]]:
		var piece := ColorRect.new()
		piece.custom_minimum_size = Vector2(shape[0], shape[1])
		piece.color = Color(0.30, 0.33, 0.38)
		piece.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
		box.add_child(piece)
	return box


func _slot_widget(slot: String, large: bool) -> Control:
	var panel := PanelContainer.new()
	var side := SLOT_SIZE + (14 if large else 0)
	panel.custom_minimum_size = Vector2(side, side)
	panel.set_meta("slot", slot)
	var icon := TextureRect.new()
	icon.name = "Icon"
	icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	icon.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel.add_child(icon)
	var tag := Label.new()
	tag.name = "Tag"
	tag.text = tr("ui.slot." + slot)
	tag.add_theme_font_size_override("font_size", UITheme.FONT_SMALL)
	tag.modulate = Color(1, 1, 1, 0.5)
	tag.mouse_filter = Control.MOUSE_FILTER_IGNORE
	tag.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	tag.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	panel.add_child(tag)
	# Les trois rappels du glisser-déposer de Godot vivent sur la CIBLE.
	panel.set_drag_forwarding(Callable(), _can_drop.bind(panel), _drop.bind(panel))
	panel.gui_input.connect(_on_slot_input.bind(slot))
	_slots[slot] = panel
	return panel


## N'accepte que ce qui va RÉELLEMENT dans cet emplacement. Refuser au survol
## plutôt qu'au dépôt évite au joueur de découvrir l'échec après coup — et lui
## apprend la règle (un bouclier ne va qu'en main gauche) sans un mot d'aide.
func _can_drop(_pos: Vector2, data: Variant, panel: Control) -> bool:
	if not (data is Dictionary) or not (data as Dictionary).has("entry"):
		return false
	var entry: Dictionary = (data as Dictionary)["entry"]
	if entry.get("kind", "") != "object":
		return false
	var item: Dictionary = GameData.items.get(
		(entry["object"] as Dictionary).get("item_id", ""), {})
	var wanted := String(item.get("equip_slot", ""))
	if wanted == "":
		return false
	var slot := String(panel.get_meta("slot", ""))
	if wanted == slot:
		return true
	var group: Array = Equipment.SLOT_GROUPS.get(wanted, [])
	return slot in group


func _drop(_pos: Vector2, data: Variant, panel: Control) -> void:
	var entry: Dictionary = (data as Dictionary)["entry"]
	_player.equip_instance_in_slot(entry["object"], String(panel.get_meta("slot", "")))
	refresh()
	changed.emit()


## Clic DROIT : retirer la pièce. Même geste que pour libérer un emplacement de
## hotbar, pour que les deux se manipulent pareil.
func _on_slot_input(event: InputEvent, slot: String) -> void:
	var button := event as InputEventMouseButton
	if button == null or not button.pressed or button.button_index != MOUSE_BUTTON_RIGHT:
		return
	_player.unequip_slot(slot)
	refresh()
	changed.emit()


func refresh() -> void:
	if _player == null:
		return
	for slot: String in _slots:
		var panel: PanelContainer = _slots[slot]
		var icon := panel.get_node("Icon") as TextureRect
		var tag := panel.get_node("Tag") as Label
		var piece: Dictionary = _player.equipment.equipped(slot)
		if piece.is_empty():
			icon.texture = null
			tag.text = tr("ui.slot." + slot)
			tag.modulate = Color(1, 1, 1, 0.45)
			panel.tooltip_text = tr("ui.equipement.vide")
			continue
		var item: Dictionary = GameData.items.get(piece.get("item_id", ""), {})
		icon.texture = WeaponPreview.item_icon(item, piece.get("materials", {}), SLOT_SIZE)
		tag.text = ""
		panel.tooltip_text = tr(String(piece.get("name_key", "")))
