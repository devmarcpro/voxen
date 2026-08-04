extends CanvasLayer
## Panneau de COFFRE (GDD F.6) — 2026-08-03.
##
## POURQUOI IL EXISTE. Le coffre a été posé sans interface : la touche
## d'interaction prenait TOUT d'un coup. C'était juste assez pour vider le
## coffre du boss, et inutilisable pour ce à quoi un coffre sert vraiment —
## ranger. On ne peut pas déposer, on ne peut pas voir avant de prendre, on ne
## peut pas laisser la moitié.
##
## DEUX COLONNES, un sens de lecture : l'INVENTAIRE à gauche, le COFFRE à
## droite, et un clic déplace une ligne d'un côté à l'autre. Pas de
## glisser-déposer ici, contrairement au menu combat : là-bas l'ORDRE porte du
## sens et il faut pouvoir le manipuler ; dans un coffre l'ordre ne veut rien
## dire, et un clic est plus rapide qu'un glissement.
##
## OBJETS ET MATÉRIAUX sont deux stocks distincts dans ce projet (instances vs
## piles) : le panneau les affiche ensemble mais les transfère par les chemins
## respectifs de l'inventaire — les mélanger produirait des piles d'épées.

const PANEL_W := 760
const COLUMN_W := 340

var is_open := false

var _player: Node
var _pos := Vector3i.ZERO
var _root: Control
var _title: Label
var _inv_list: VBoxContainer
var _chest_list: VBoxContainer
var _footer: Label


func _ready() -> void:
	layer = 60
	visible = false
	_player = get_tree().current_scene.get_node_or_null("Player")
	_build()


func _build() -> void:
	var shade := ColorRect.new()
	shade.color = Color(0, 0, 0, 0.55)
	shade.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(shade)

	var centre := CenterContainer.new()
	centre.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(centre)

	_root = PanelContainer.new()
	_root.custom_minimum_size = Vector2(PANEL_W, 460)
	centre.add_child(_root)

	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", UITheme.GAP_WIDE)
	_root.add_child(box)

	_title = Label.new()
	_title.add_theme_font_size_override("font_size", UITheme.FONT_HEADING)
	box.add_child(_title)
	box.add_child(UITheme.rule())

	var columns := HBoxContainer.new()
	columns.add_theme_constant_override("separation", UITheme.GAP_WIDE)
	box.add_child(columns)
	_inv_list = _build_column(columns, tr("ui.coffre.inventaire"))
	_chest_list = _build_column(columns, tr("ui.coffre.contenu"))

	box.add_child(UITheme.rule())
	var actions := HBoxContainer.new()
	actions.add_theme_constant_override("separation", UITheme.GAP)
	actions.add_child(_button("ui.coffre.tout_deposer", _deposit_all))
	actions.add_child(_button("ui.coffre.tout_prendre", _take_all))
	actions.add_child(_button("ui.coffre.fermer", _close))
	box.add_child(actions)
	_footer = UITheme.dim("")
	box.add_child(_footer)


func _build_column(parent: Control, title: String) -> VBoxContainer:
	var column := VBoxContainer.new()
	column.custom_minimum_size = Vector2(COLUMN_W, 0)
	var header := Label.new()
	header.text = title
	header.add_theme_color_override("font_color", UITheme.TEXT_ACCENT)
	column.add_child(header)
	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(COLUMN_W, 320)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	var list := VBoxContainer.new()
	list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(list)
	column.add_child(scroll)
	parent.add_child(column)
	return list


func _button(key: String, callback: Callable) -> Button:
	var b := Button.new()
	b.text = tr(key)
	b.pressed.connect(callback)
	return b


## Ouvre le panneau sur le coffre en `pos`. Retourne false si ce n'en est pas un
## — l'appelant retombe alors sur ses autres interactions.
func open_at(pos: Vector3i) -> bool:
	if _player == null or not ContainerManager.is_chest(pos):
		return false
	_pos = pos
	is_open = true
	visible = true
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	_player.input_locked = true
	var fly := get_tree().current_scene.get_node_or_null("FlyCamera")
	if fly != null:
		fly.input_locked = true
	_refresh()
	return true


func _close() -> void:
	is_open = false
	visible = false
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	if _player != null:
		_player.input_locked = false
	var fly := get_tree().current_scene.get_node_or_null("FlyCamera")
	if fly != null:
		fly.input_locked = false


func _unhandled_key_input(event: InputEvent) -> void:
	if not is_open:
		return
	var key := event as InputEventKey
	if key != null and key.pressed and not key.echo \
			and (key.physical_keycode == KEY_ESCAPE or event.is_action_pressed("interact")):
		_close()
		get_viewport().set_input_as_handled()


func _refresh() -> void:
	var chest := ContainerManager.contents(_pos)
	if chest.is_empty():
		_close()
		return
	var use := ContainerManager.usage(_pos)
	_title.text = tr("ui.coffre.titre").format({
		"coffre": tr(String((GameData.materials.get(String(chest.get("material", "coffre")), {})
				as Dictionary).get("name_key", "material.coffre.name"))),
		"utilise": str(use.x), "capacite": str(use.y)})

	for child in _inv_list.get_children():
		child.queue_free()
	for child in _chest_list.get_children():
		child.queue_free()

	# --- Inventaire du joueur : cliquer DÉPOSE ---
	for obj: Dictionary in (_player.inventory.objects as Array):
		_inv_list.add_child(_row(_object_label(obj), _deposit_object.bind(obj)))
	for material_id: String in _player.inventory.material_ids():
		var count := int(_player.inventory.material_stacks.get(material_id, 0))
		if count <= 0:
			continue
		_inv_list.add_child(_row("%s ×%d" % [
				tr(String((GameData.stackable(material_id) as Dictionary).get("name_key", material_id))), count],
				_deposit_material.bind(material_id, count)))

	# --- Contenu du coffre : cliquer PREND ---
	for obj: Dictionary in (chest["objects"] as Array):
		_chest_list.add_child(_row(_object_label(obj), _take_object.bind(obj)))
	for material_id: String in (chest["materials"] as Dictionary):
		var stored := int(chest["materials"][material_id])
		_chest_list.add_child(_row("%s ×%d" % [
				tr(String((GameData.stackable(material_id) as Dictionary).get("name_key", material_id))), stored],
				_take_material.bind(material_id)))

	var gold := int(chest["gold"])
	if gold > 0:
		_chest_list.add_child(_row(tr("ui.coffre.or").format({"or_": str(gold)}), _take_gold))
	if (chest["objects"] as Array).is_empty() and (chest["materials"] as Dictionary).is_empty() and gold <= 0:
		_chest_list.add_child(UITheme.dim(tr("ui.coffre.vide")))
	_footer.text = tr("ui.coffre.aide")


func _row(text_value: String, callback: Callable) -> Button:
	var b := Button.new()
	b.text = text_value
	b.alignment = HORIZONTAL_ALIGNMENT_LEFT
	b.add_theme_font_size_override("font_size", UITheme.FONT_SMALL)
	b.pressed.connect(callback)
	return b


func _object_label(obj: Dictionary) -> String:
	var name := tr(String(obj.get("name_key", obj.get("item_id", "?"))))
	var count := int(obj.get("count", 1))
	return name if count <= 1 else "%s ×%d" % [name, count]


# --- Transferts ---
#
# CHAQUE SENS PASSE PAR L'API DE SON STOCK. Un objet est une instance, un
# matériau une pile : les confondre produirait des piles d'épées.

func _deposit_object(obj: Dictionary) -> void:
	if not ContainerManager.store_object(_pos, obj):
		EventBus.ui_notification.emit("ui.toast.coffre_plein")
		return
	_player.inventory.remove_object_units(obj, int(obj.get("count", 1)))
	_refresh()


func _deposit_material(material_id: String, count: int) -> void:
	if not ContainerManager.store_material(_pos, material_id, count):
		EventBus.ui_notification.emit("ui.toast.coffre_plein")
		return
	_player.inventory.remove_material(material_id, count)
	_refresh()


func _take_object(obj: Dictionary) -> void:
	var chest := ContainerManager.contents(_pos)
	if chest.is_empty():
		return
	(chest["objects"] as Array).erase(obj)
	_player.inventory.add_object(obj)
	_refresh()


func _take_material(material_id: String) -> void:
	var chest := ContainerManager.contents(_pos)
	if chest.is_empty():
		return
	var materials: Dictionary = chest["materials"]
	var count := int(materials.get(material_id, 0))
	if count <= 0:
		return
	materials.erase(material_id)
	_player.inventory.add_material(material_id, count)
	_refresh()


func _take_gold() -> void:
	var chest := ContainerManager.contents(_pos)
	if chest.is_empty():
		return
	_player.gold += int(chest["gold"])
	chest["gold"] = 0
	_refresh()


func _take_all() -> void:
	_player.gold += ContainerManager.take_all(_pos, _player.inventory)
	_refresh()


## Dépose tout ce qui tient. S'ARRÊTE au premier refus plutôt que de continuer :
## un coffre qui se remplit à moitié en silence laisse le joueur croire que tout
## est rangé, et c'est ainsi qu'on perd des objets qu'on croyait à l'abri.
func _deposit_all() -> void:
	for obj: Dictionary in (_player.inventory.objects as Array).duplicate():
		if not ContainerManager.store_object(_pos, obj):
			EventBus.ui_notification.emit("ui.toast.coffre_plein")
			break
		_player.inventory.remove_object_units(obj, int(obj.get("count", 1)))
	for material_id: String in _player.inventory.material_ids().duplicate():
		var count := int(_player.inventory.material_stacks.get(material_id, 0))
		if count <= 0:
			continue
		if not ContainerManager.store_material(_pos, material_id, count):
			EventBus.ui_notification.emit("ui.toast.coffre_plein")
			break
		_player.inventory.remove_material(material_id, count)
	_refresh()
