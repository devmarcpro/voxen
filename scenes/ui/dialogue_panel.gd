extends CanvasLayer
## Menu contextuel de dialogue PNJ (GDD E.23).
##
## STRUCTURE IMPOSÉE PAR LE GDD, et c'est une bonne contrainte : « interagir
## avec un PNJ ouvre un MENU CONTEXTUEL, pas un arbre ». La réplique d'ambiance
## en haut, les options en dessous, affichées SELON LE CONTEXTE.
##
## LES OPTIONS INDISPONIBLES RESTENT VISIBLES, grisées, avec leur raison. C'est
## délibéré et contraire au réflexe habituel de masquer : un joueur qui ne voit
## jamais « Recruter » ne saura pas que recruter existe. Voir l'option barrée
## d'un « Ne vous suivra pas » enseigne la mécanique et désigne l'objectif, ce
## qu'un menu propre et vide ne fera jamais.

const RELATION_TALK := 1.0
## Une seule micro-relation par jour et par PNJ (E.23). Sans cette borne, on
## monterait n'importe quelle relation au maximum en martelant une touche, et
## tout le système de réputation deviendrait décoratif.
const TALK_COOLDOWN_TICKS := int(DayNightManager.TICKS_PER_DAY)

## Rendement d'un cadeau : relation gagnée par point de valeur de l'objet.
## Volontairement faible — offrir doit être un geste répété, pas un achat.
const GIFT_RELATION_PER_VALUE := 0.35
const GIFT_RELATION_MAX := 25.0

var is_open := false

var _player: Node
var _creature: Node
var _root: Control
var _line_label: Label
var _options: VBoxContainer
## Dernier tick où l'on a parlé à ce PNJ : clé sociale → tick.
var _last_talk := {}


func _ready() -> void:
	layer = 12
	_player = get_node_or_null("../Player")
	_build()
	visible = false


## MISE EN PAGE REFAITE LE 2026-08-09 (demande de l'auteur : « la fenêtre de
## dialogue doit faire quasiment tout l'écran mais un peu plus petit qu'on voie
## un peu derrière sur les côtés, portrait du PNJ plutôt grand — placé à GAUCHE
## à sa demande du 2026-08-09 — les infos à côté et en dessous toutes les options.
##
## POURQUOI CE FORMAT ET PAS L'ANCIEN. La fenêtre faisait 560 px de large au
## centre de l'écran : la conversation était une petite boîte posée sur le jeu,
## et les options — six aujourd'hui, une douzaine prévues par E.23 — s'y
## entassaient. Parler à quelqu'un est un MOMENT, pas une notification ; la
## fenêtre prend donc l'écran, tout en laissant voir la scène sur les bords
## pour qu'on n'oublie pas OÙ l'on est.
func _build() -> void:
	_root = Control.new()
	_root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(_root)

	var shade := ColorRect.new()
	shade.color = Color(0.0, 0.0, 0.0, 0.45)
	shade.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	shade.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(shade)

	# LA MARGE EST LE SUJET. Ancrée au plein écran puis rentrée de MARGIN de
	# chaque côté : la fenêtre s'adapte à toutes les résolutions et laisse
	# toujours voir la même bande de jeu — une taille fixe aurait rempli un
	# écran de portable et flotté sur un grand moniteur.
	var frame := PanelContainer.new()
	frame.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	frame.offset_left = MARGIN_H
	frame.offset_right = -MARGIN_H
	frame.offset_top = MARGIN_V
	frame.offset_bottom = -MARGIN_V
	_root.add_child(frame)

	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", UITheme.GAP)
	frame.add_child(box)

	# --- Haut : PORTRAIT À GAUCHE, identité à sa droite ---
	# L'ordre d'ajout EST la mise en page dans une HBox : le portrait entre en
	# premier, donc il occupe le bord gauche et le texte coule à sa droite.
	var header := HBoxContainer.new()
	header.add_theme_constant_override("separation", UITheme.GAP)
	box.add_child(header)

	# PORTRAIT. `PanelContainer` autour du `TextureRect` : sans cadre, une
	# silhouette de repli flotterait sans qu'on comprenne que c'est un portrait.
	var portrait_frame := PanelContainer.new()
	portrait_frame.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	header.add_child(portrait_frame)
	_portrait = TextureRect.new()
	_portrait.custom_minimum_size = Vector2(PORTRAIT_SIZE, PORTRAIT_SIZE)
	_portrait.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_portrait.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_portrait.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	portrait_frame.add_child(_portrait)

	var who := VBoxContainer.new()
	who.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	who.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	header.add_child(who)
	_title = UITheme.heading("")
	who.add_child(_title)
	_subtitle = UITheme.dim("")
	who.add_child(_subtitle)
	# La réplique vit sous l'identité, dans la colonne de gauche : c'est ce
	# qu'on lit, et la mettre sous le portrait l'aurait reléguée au second rang.
	_line_label = Label.new()
	_line_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_line_label.custom_minimum_size = Vector2(0, 72)
	_line_label.add_theme_font_size_override("font_size", UITheme.FONT_HEADING)
	_line_label.add_theme_color_override("font_color", UITheme.TEXT_ACCENT)
	who.add_child(_line_label)

	box.add_child(UITheme.rule())

	# --- Bas : toutes les options, dans la place qui reste ---
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	box.add_child(scroll)
	_options = VBoxContainer.new()
	_options.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_options.add_theme_constant_override("separation", UITheme.GAP_TIGHT)
	scroll.add_child(_options)


## Bande de jeu laissée visible autour de la fenêtre. Assez pour qu'on voie où
## l'on est, assez peu pour que la conversation reste le sujet.
const MARGIN_H := 90.0
const MARGIN_V := 60.0
## Portrait « plutôt grand » : il occupe le quart droit de l'en-tête.
const PORTRAIT_SIZE := 260.0

var _portrait: TextureRect

var _title: Label
var _subtitle: Label


## Ouvre le menu sur `creature`. Refuse une créature qui n'a rien à dire : une
## bête n'a pas de conversation, et lui en ouvrir une serait promettre une
## mécanique qui n'existe pas.
func open_with(creature: Node) -> bool:
	if creature == null or not is_instance_valid(creature):
		return false
	if String(creature.ai_profile) not in ["civil", "garde"]:
		return false
	_creature = creature
	is_open = true
	visible = true
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	_player.input_locked = true
	var fly := get_node_or_null("../FlyCamera")
	if fly != null:
		fly.input_locked = true
	_refresh(true)
	return true


func close() -> void:
	is_open = false
	visible = false
	_creature = null
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	_player.input_locked = false
	var fly := get_node_or_null("../FlyCamera")
	if fly != null:
		fly.input_locked = false


func _unhandled_key_input(event: InputEvent) -> void:
	var key := event as InputEventKey
	if key == null or not key.pressed or key.echo:
		return
	if key.physical_keycode == KEY_ESCAPE and is_open:
		close()
		get_viewport().set_input_as_handled()


## `new_line` : faut-il tirer une nouvelle réplique ? On ne le fait qu'à
## l'ouverture et sur « Parler ». Rafraîchir la liste des options après un
## cadeau ne doit pas faire changer la phrase — le PNJ n'a pas repris la parole.
func _refresh(new_line: bool) -> void:
	if _creature == null or not is_instance_valid(_creature):
		close()
		return
	# LE NOM DE LA PERSONNE, PAS CELUI DE SON ESPÈCE (2026-08-09). On lisait
	# `display_name_key`, donc « Villageois » pour tout le monde : le village
	# avait des noms, des âges et des origines, et le dialogue affichait une
	# étiquette d'espèce. `display_name()` retombe sur l'espèce pour une bête,
	# qui n'a effectivement pas de nom.
	_title.text = String(_creature.call("display_name"))
	_refresh_portrait()
	var tier: String = _creature.call("relation_tier")
	# ÂGE, RÔLE ET ORIGINE sous le nom : c'est ce qui distingue deux villageois
	# l'un de l'autre, et ce qui donne prise à une conversation.
	var line := String(_creature.call("identity_line"))
	var job := String(_creature.job)
	if line == "":
		line = "" if job == "" else tr("job." + job)
	_subtitle.text = "%s%s" % [
		"" if line == "" else line + " · ",
		tr("ui.dialogue.relation").format({"palier": tr("relation." + tier)})]

	if new_line:
		var context := DialoguePool.context_for(_creature, _player.reputation)
		var text_key := DialoguePool.pick(context)
		_line_label.text = tr(text_key) if text_key != "" else ""

	for child in _options.get_children():
		child.queue_free()
	_add_option(tr("ui.dialogue.parler"), _can_talk(), _reason_talk(), _on_talk)
	_add_option(tr("ui.dialogue.offrir"), _best_gift() != {},
		tr("ui.dialogue.rien_a_offrir"), _on_gift)
	# Options prévues par E.23 dont le système n'existe pas encore. Elles sont
	# affichées désactivées PLUTÔT QUE MASQUÉES : c'est ce qui apprend au joueur
	# ce qu'un PNJ pourra offrir, et ce qui rend visible ce qui manque au jeu.
	_add_option(tr("ui.dialogue.commercer"), false, tr("ui.dialogue.pas_marchand"), Callable())
	_add_option(tr("ui.dialogue.quetes"), false, tr("ui.dialogue.pas_de_quetes"), Callable())
	_add_option(tr("ui.dialogue.recruter"), false, tr("ui.dialogue.pas_recrutable"), Callable())
	_add_option(tr("ui.dialogue.fermer"), true, "", close)


func _add_option(label: String, enabled: bool, reason: String, callback: Callable) -> void:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", UITheme.GAP_WIDE)
	var button := Button.new()
	button.text = label
	button.custom_minimum_size = Vector2(220, UITheme.ROW_H)
	button.disabled = not enabled or callback.is_null()
	if not button.disabled:
		button.pressed.connect(callback)
	row.add_child(button)
	if button.disabled and reason != "":
		var note := UITheme.dim(reason)
		note.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		row.add_child(note)
	_options.add_child(row)


# --- Parler ------------------------------------------------------------------

func _can_talk() -> bool:
	var key := String(_creature.social_key)
	if key == "":
		return true
	return TickManager.tick_index - int(_last_talk.get(key, -TALK_COOLDOWN_TICKS)) \
		>= TALK_COOLDOWN_TICKS


func _reason_talk() -> String:
	return tr("ui.dialogue.deja_parle")


## Parler rapporte peu, et une fois par jour. Le jet de Charisme (E.3, jet de
## compétence universel) module le gain : un personnage charismatique noue des
## liens plus vite, sans que cela devienne un raccourci.
func _on_talk() -> void:
	var key := String(_creature.social_key)
	_last_talk[key] = TickManager.tick_index
	var charisma := float(_player.stats.get("charisme", 5))
	var gain := RELATION_TALK * (1.0 + charisma / 20.0)
	_player.reputation.record(key, _creature.village_cell,
		String(_creature.race_id), gain, String(_creature.kingdom_id))
	_refresh(true)


# --- Offrir ------------------------------------------------------------------

## Meilleur cadeau disponible : l'objet de plus grande valeur de l'inventaire.
##
## On propose le PLUS PRÉCIEUX et non le premier venu : offrir doit être un
## sacrifice ressenti, et laisser le jeu choisir un caillou viderait le geste
## de son sens. Le joueur reste libre de ne pas cliquer.
func _best_gift() -> Dictionary:
	var best := {}
	for instance: Dictionary in _player.inventory.objects:
		var value := _gift_value(instance)
		if value <= 0.0:
			continue
		if best.is_empty() or value > _gift_value(best):
			best = instance
	return best


func _gift_value(instance: Dictionary) -> float:
	if instance.is_empty():
		return 0.0
	# La qualité pèse : offrir un chef-d'œuvre n'est pas offrir un rebut.
	return float(instance.get("weight", 0.0)) * 0.1 \
		+ float(instance.get("base_hardness", 0.0)) * float(instance.get("quality", 1.0)) * 0.5


func _on_gift() -> void:
	var gift := _best_gift()
	if gift.is_empty():
		return
	var gain: float = minf(_gift_value(gift) * GIFT_RELATION_PER_VALUE, GIFT_RELATION_MAX)
	_player.reputation.record(String(_creature.social_key), _creature.village_cell,
		String(_creature.race_id), gain, String(_creature.kingdom_id))
	# L'objet est DONNÉ : il quitte l'inventaire. Un cadeau qu'on garde n'est
	# pas un cadeau, et la relation s'achèterait alors gratuitement.
	_player.inventory.remove_object_units(gift, 1)
	EventBus.ui_notification.emit("ui.dialogue.cadeau_accepte")
	_refresh(false)


## Remplit le portrait et le TEINTE de la couleur du personnage.
##
## Le rendu est GÉNÉRIQUE — tous les habitants partagent le modèle humanoïde —
## et c'est la teinte qui distingue les gens, exactement comme dans le monde :
## la couleur d'un PNJ y est déjà déterministe par son espèce. Rendre un
## portrait par habitant produirait des centaines de fois la même image.
func _refresh_portrait() -> void:
	if _portrait == null or _creature == null:
		return
	var tex: Texture2D = PortraitPreview.portrait()
	if tex != null:
		_portrait.texture = tex
		_portrait.modulate = _creature_tint()
		return
	# REPLI : une silhouette pleine, teintée pareil. Le rendu 3D échoue en
	# headless et peut échouer si le modèle manque ; un cadre vide laisserait
	# croire à un bug d'affichage plutôt qu'à une absence de portrait.
	_portrait.texture = BlockIcon.item_mask(int(PORTRAIT_SIZE))
	_portrait.modulate = _creature_tint()


## Teinte d'un personnage : la même que celle de son corps dans le monde, donc
## dérivée de son identité. Deux villageois différents ne doivent pas avoir le
## même portrait, et celui qu'on voit dans la fenêtre doit être celui qu'on
## vient de regarder.
func _creature_tint() -> Color:
	var key := String((_creature.identity as Dictionary).get("affichage", ""))
	if key == "":
		key = String(_creature.creature_id)
	# TEINTE DISCRÈTE. À 0,35 de saturation elle REPEIGNAIT le portrait en rose :
	# on ne voyait plus ni la peau, ni les vêtements, seulement une couleur. Elle
	# doit distinguer deux personnes, pas les redessiner — le modèle porte déjà
	# ses propres couleurs, et c'est lui qu'on veut voir.
	return Color.from_hsv(float(absi(key.hash()) % 360) / 360.0, 0.10, 1.0)
