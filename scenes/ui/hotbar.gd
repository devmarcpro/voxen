extends HBoxContainer
## Hotbar (9 emplacements × 9 banques) — OUTILS puis piles de matériaux
## (étape D.3.3). Sélection d'emplacement par les touches 1-9 ou la molette ;
## banque active par Ctrl+1-9 ou Ctrl+molette, affichée à droite.
## Un outil s'affiche en bicolore (tête = couleur du minerai, manche =
## couleur du bois — les vrais modèles .vox arrivent à l'étape 5) ; un
## matériau en aplat + quantité.

const SLOT_COUNT := 9
const SLOT_SIZE := 44
const REFRESH_INTERVAL := 0.2

var _player: Node
var _held_label: Label
var _bank_label: Label
var _slots: Array[Panel] = []
var _heads: Array[ColorRect] = []    # Partie haute (matériau/tête d'outil).
var _handles: Array[ColorRect] = []  # Partie basse (manche d'outil).
var _icons: Array[TextureRect] = []  # Icône cube 3 faces (blocs matériaux).
var _counts: Array[Label] = []
## Numéro de touche (1-9) affiché en haut à gauche de chaque emplacement.
var _keys: Array[Label] = []


func _ready() -> void:
	_player = get_node_or_null("../../Player")
	_held_label = get_node_or_null("../HeldItemLabel")
	for i in SLOT_COUNT:
		var slot := Panel.new()
		slot.custom_minimum_size = Vector2(SLOT_SIZE, SLOT_SIZE)
		var head := ColorRect.new()
		head.set_anchors_preset(Control.PRESET_FULL_RECT)
		head.offset_left = 5
		head.offset_top = 5
		head.offset_right = -5
		head.offset_bottom = -5
		head.color = Color.TRANSPARENT
		head.mouse_filter = Control.MOUSE_FILTER_IGNORE
		slot.add_child(head)
		var handle := ColorRect.new()
		handle.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
		handle.offset_left = 5
		handle.offset_top = -21
		handle.offset_right = -5
		handle.offset_bottom = -5
		handle.color = Color.TRANSPARENT
		handle.visible = false
		handle.mouse_filter = Control.MOUSE_FILTER_IGNORE
		slot.add_child(handle)
		var icon := TextureRect.new()
		icon.set_anchors_preset(Control.PRESET_FULL_RECT)
		icon.offset_left = 4
		icon.offset_top = 4
		icon.offset_right = -4
		icon.offset_bottom = -4
		icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE  # ne force PAS la case à la taille de la texture
		icon.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
		icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
		slot.add_child(icon)
		_icons.append(icon)
		var count := Label.new()
		count.set_anchors_preset(Control.PRESET_BOTTOM_RIGHT)
		count.offset_left = -SLOT_SIZE + 4
		count.offset_top = -22
		count.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		count.mouse_filter = Control.MOUSE_FILTER_IGNORE
		slot.add_child(count)
		var key_label := Label.new()
		key_label.text = str(i + 1)
		key_label.set_anchors_preset(Control.PRESET_TOP_LEFT)
		key_label.offset_left = 4
		key_label.offset_top = 1
		key_label.add_theme_font_size_override("font_size", UITheme.FONT_SMALL)
		# Coin OPPOSÉ à la quantité (bas-droite) : les deux ne se recouvrent
		# jamais, quel que soit le nombre de chiffres.
		key_label.modulate = Color(1, 1, 1, 0.55)
		key_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
		slot.add_child(key_label)
		_keys.append(key_label)
		add_child(slot)
		_slots.append(slot)
		_heads.append(head)
		_handles.append(handle)
		_counts.append(count)
	_bank_label = Label.new()
	_bank_label.custom_minimum_size = Vector2(28, SLOT_SIZE)
	_bank_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_bank_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	add_child(_bank_label)
	var timer := Timer.new()
	timer.wait_time = REFRESH_INTERVAL
	timer.autostart = true
	timer.timeout.connect(_refresh)
	add_child(timer)
	_refresh()


func _refresh() -> void:
	if _player == null:
		return
	# Nom de l'objet/du bloc en main, au-dessus de la hotbar.
	if _held_label != null:
		var name_key: String = _player.held_name_key()
		_held_label.text = tr(name_key) if name_key != "" else ""
	_bank_label.text = "%d/9" % (_player.active_hotbar + 1)
	var entries: Array[Dictionary] = _player.hotbar_entries()
	for i in SLOT_COUNT:
		var selected: bool = i == _player.selected_slot
		_slots[i].modulate = Color(1, 1, 1, 1.0) if selected else Color(0.75, 0.75, 0.75, 0.75)
		_keys[i].modulate = Color(1, 0.92, 0.6, 1.0) if selected else Color(1, 1, 1, 0.55)
		# Emplacement VIDE : depuis que la hotbar est assignable (2026-07-27),
		# un slot non lié rend un dictionnaire vide au lieu d'être absent.
		# TEINTE REMISE À BLANC EN TÊTE DE BOUCLE. Les vignettes partagent
		# désormais un masque coloré par `modulate` : sans cette remise à zéro,
		# une teinte survivrait au changement d'objet et la nouvelle icône —
		# qui, elle, est déjà colorée — sortirait multipliée par l'ancienne.
		_icons[i].modulate = Color.WHITE
		if i >= entries.size() or entries[i].is_empty():
			_heads[i].color = Color(0, 0, 0, 0.25)
			_handles[i].visible = false
			_icons[i].texture = null
			_counts[i].text = ""
			_slots[i].tooltip_text = ""
			continue
		var entry: Dictionary = entries[i]
		# COMBAT (2026-08-07) : l'entrée porte l'arme ÉQUIPÉE, ou rien — et
		# « rien » veut dire les poings, pas une case vide. La branche générique
		# plus bas lisait `entry["id"]` et plantait sur tout genre inconnu ; elle
		# aurait planté pareil sur un assemblage. Une barre qui crashe parce
		# qu'on y met ce que le jeu propose n'est pas une barre.
		if String(entry.get("kind", "")) == "combat":
			var armed: Dictionary = entry.get("object", {})
			_heads[i].color = Color.TRANSPARENT
			_handles[i].visible = false
			_counts[i].text = ""
			if armed.is_empty():
				_icons[i].texture = BlockIcon.item_mask(SLOT_SIZE - 12)
				_icons[i].modulate = Color(0.92, 0.78, 0.62)  # Un poing : teinte de peau.
				_slots[i].tooltip_text = tr("ui.hotbar.mains_nues")
			else:
				var item: Dictionary = GameData.items.get(armed.get("item_id", ""), {})
				# TEINTE REMISE À BLANC : la branche « mains nues » ci-dessus
				# pose une teinte de peau, et une case réutilisée la gardait —
				# l'arme s'affichait alors couleur chair.
				_icons[i].modulate = Color.WHITE
				_icons[i].texture = WeaponPreview.item_icon(item, armed.get("materials", {}), SLOT_SIZE)
				_slots[i].tooltip_text = tr(String(armed.get("name_key", "")))
			continue
		if String(entry.get("kind", "")) == "assemblage":
			_heads[i].color = Color.TRANSPARENT
			_handles[i].visible = false
			_counts[i].text = ""
			_icons[i].texture = BlockIcon.item_mask(SLOT_SIZE - 12)
			_icons[i].modulate = Color(0.55, 0.75, 1.0)  # Bleu de mana.
			_slots[i].tooltip_text = tr("ui.hotbar.assemblage")
			continue
		if String(entry.get("kind", "")) == "object":
			var obj: Dictionary = entry["object"]
			var mats: Dictionary = obj.get("materials", {})
			# Apparence d'OUTIL (sprite manche+tête teintés) si dispo, sinon
			# repli bicolore tête/manche (2026-07-26).
			var item: Dictionary = GameData.items.get(obj.get("item_id", ""), {})
			var tool_tex: Texture2D = WeaponPreview.item_icon(item, mats, SLOT_SIZE)
			# Ressource (viande, peau) : pastille colorée d'objet — pas de
			# sprite dédié, et surtout pas l'apparence d'un bloc.
			if tool_tex == null and obj.has("color"):
				tool_tex = BlockIcon.item_mask(SLOT_SIZE - 12)
				_icons[i].modulate = Color.html(String(obj["color"]))
			if tool_tex != null:
				_icons[i].texture = tool_tex
				_heads[i].color = Color.TRANSPARENT
				_handles[i].visible = false
			else:
				_icons[i].texture = null
				_heads[i].color = _material_color(mats.get("minerai", ""))
				_handles[i].color = _material_color(mats.get("bois", ""))
				_handles[i].visible = true
			var units := int(obj.get("count", 1))
			_counts[i].text = str(units) if units > 1 else ""
			_slots[i].tooltip_text = tr(obj["name_key"])
		else:
			var mat: Dictionary = GameData.stackable(entry["id"])
			# Bloc = icône TEXTURÉE (rendu voxel) si prête, sinon cube couleur.
			_heads[i].color = Color.TRANSPARENT
			_handles[i].visible = false
			var rid: int = GameData.material_runtime_ids.get(entry["id"], 0)
			var tex: Texture2D = BlockPreview.icon(rid)
			# Masque partagé + teinte, comme les lignes d'inventaire : la hotbar
			# se reconstruit à chaque changement de sélection, et redessiner
			# neuf cubes colorés à chaque coup de molette n'a aucun sens.
			if tex != null:
				_icons[i].texture = tex
			else:
				_icons[i].texture = BlockIcon.cube_mask(SLOT_SIZE - 12)
				BlockIcon.tint_texture_rect(_icons[i], Color.html(mat["color"]))
			_counts[i].text = Inventory.format_volume(float(entry.get("volume", entry.get("count", 0))))
			_slots[i].tooltip_text = tr(mat["name_key"])


func _material_color(material_id: String) -> Color:
	var mat: Variant = GameData.stackable(material_id)
	return Color.html(mat["color"]) if mat != null else Color(0.5, 0.5, 0.5)
