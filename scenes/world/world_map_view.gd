extends CanvasLayer
## Carte du monde — VUE 2D (2026-07-20, remplace la version 3D précédente
## suite retour explicite : « remplace la world map par du 2D »). Chaque
## CELLULE NORMALE (128×128 blocs, 3.2/3.3) est dessinée comme une mini-image
## de 16×16 PIXELS (échantillonnage interne tous les 8 blocs) — « comme ça on
## peut voir la composition des cellules » (demande explicite). Le zoom ne
## change QUE _radius (combien de cellules sont affichées), jamais la
## résolution interne d'une cellule. Touche L : calques (biome/relief,
## danger, revendications, exploration). La carte reste un RÉSUMÉ, jamais
## une source de vérité (E.2). Plus de caméra 3D dédiée : le joueur n'est
## jamais réellement déplacé, seul l'affichage change — évite toute la
## complexité (décalage de coordonnées, ombres, etc.) de la version 3D.

const CELL_PIXELS := 16                 # Résolution interne fixe par cellule (composition visible).
const MIN_RADIUS := 4
const MAX_RADIUS := 60                  # Grille max ~121×121 cellules — garde-fou perf (construction de la mosaïque), pas une limite de gameplay.
const RADIUS_STEP := 3
const BASE_RADIUS := 18
## Déplacement CASE PAR CASE sur la carte (2026-07-27). ZQSD/WASD ne fait
## plus défiler la vue : il fait MARCHER le joueur d'une cellule (128 blocs).
## Le temps s'écoule réellement pendant le trajet — E.1 : « le saut n'est
## jamais gratuit ». Coût doublé par rapport à la marche au sol (3 ticks/bloc,
## E.1) : traverser la carte est pratique, jamais gratuit.
const MAP_TICKS_PER_BLOCK := 6
## Anti-répétition : une pression = une case, sinon un appui maintenu
## traverserait le monde et affamerait le joueur en une seconde.
const STEP_COOLDOWN := 0.18
const SIDEBAR_WIDTH := 320.0            # Réserve la largeur du panneau de stats (WorldMapPanel).

const LAYERS := ["biome", "danger", "revendications", "exploration"]

var _player: Node
var _stats_panel: Control
var _hidden_hud_nodes: Array[CanvasItem] = []
var _root: Control
var _bg: ColorRect
var _texture_rect: TextureRect
var _poi_layer: Control
var _selection: ColorRect
var _player_marker_outer: ColorRect
var _player_marker_inner: ColorRect
var _info_label: Label
var _loading_label: Label

var is_open := false
var _radius := BASE_RADIUS
## Centre de la vue, en unités de CELLULE (128 blocs, toujours).
var _center_tile := Vector2i.ZERO
var _layer_index := 0
var _pan_accum := Vector2.ZERO
var _step_cooldown := 0.0
## Barres d'état + horloge affichées SUR la carte : voyager consomme faim et
## fatigue, le joueur doit pouvoir décider de s'arrêter.
var _clock_label: Label
var _bars: Control
var _avatar: TextureRect
var _hover_tile := Vector2i(1 << 30, 0)
var _side := 0                          # Cellules par côté (2*_radius+1) de la dernière mosaïque construite.
var _display_scale := 1.0
var _origin := Vector2.ZERO             # Coin haut-gauche de la mosaïque à l'écran.

## Cache par cellule (2026-07-21, demande explicite : la carte se
## régénérait ENTIÈREMENT à chaque ouverture/zoom/pan, alors que le monde
## sous-jacent est déterministe — une cellule déjà peinte une fois ne
## change plus jamais sur les calques "biome"/"danger" (purement procéduraux,
## fonctions pures du seed). Clé = "cx_cz_layer", valeur = petite Image
## CELL_PIXELS×CELL_PIXELS déjà calculée, réutilisée par blit_rect (aucun
## nouvel échantillonnage de bruit). Les calques "revendications"/
## "exploration" changent en cours de partie (claims/brouillard) et restent
## TOUJOURS recalculés — ils sont de toute façon bon marché (pas de bruit).
var _cell_cache: Dictionary = {}
var _cell_cache_generator: NoiseGenerator = null


func _ready() -> void:
	layer = 10  # Au-dessus du HUD (CanvasLayer par défaut, layer=0).
	_player = get_node_or_null("../Player")
	_stats_panel = get_node_or_null("../HUD/WorldMapPanel")
	# Panneau purement informatif : ne doit jamais intercepter un clic destiné
	# à la carte (bug constaté avec la version 3D — même précaution ici).
	if _stats_panel != null:
		_stats_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	for path in ["../HUD/Hotbar", "../HUD/Crosshair", "../HUD/HarvestBar", "../HUD/HeldItemLabel", "../HUD/InfoLabel", "../HUD/Minimap"]:
		var n := get_node_or_null(path)
		if n != null:
			_hidden_hud_nodes.append(n)

	_root = Control.new()
	_root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_STOP
	_root.gui_input.connect(_on_gui_input)
	add_child(_root)

	# Ne couvre QUE la zone de la mosaïque (pas tout l'écran) : la sidebar de
	# stats vit dans le CanvasLayer HUD, un calque EN DESSOUS du nôtre — un
	# fond plein écran ici la cacherait entièrement (bug constaté). Position
	# et taille exactes recalculées à chaque _build_mosaic().
	_bg = ColorRect.new()
	_bg.color = Color(0.05, 0.05, 0.06)
	_bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(_bg)

	_texture_rect = TextureRect.new()
	_texture_rect.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST  # Mosaïque nette (pixels = échantillons de blocs, pas de flou).
	_texture_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(_texture_rect)

	# Icônes de POI (E.2) : nœuds séparés au-dessus de la mosaïque, reconstruits
	# à chaque _build_mosaic() — jamais mélangés aux pixels de l'Image (résolution
	# fixe indépendante du zoom, contrairement à la mosaïque).
	_poi_layer = Control.new()
	_poi_layer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(_poi_layer)

	_selection = ColorRect.new()
	_selection.color = Color(1.0, 1.0, 1.0, 0.35)
	_selection.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_selection.visible = false
	_root.add_child(_selection)

	# Marqueur de position du joueur : contour noir + centre blanc, TOUJOURS
	# au-dessus des icônes de POI (ajouté après elles) — position figée tant
	# que la carte est ouverte (le joueur est verrouillé, _open()), redessiné
	# uniquement à chaque _build_mosaic() (pan/zoom), comme les icônes de POI.
	_player_marker_outer = ColorRect.new()
	_player_marker_outer.color = Color.BLACK
	_player_marker_outer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_player_marker_outer.visible = false
	_root.add_child(_player_marker_outer)
	_player_marker_inner = ColorRect.new()
	_player_marker_inner.color = Color(1.0, 1.0, 1.0)
	_player_marker_inner.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_player_marker_inner.visible = false
	_root.add_child(_player_marker_inner)

	# Marqueur AVATAR (2026-07-27) : l'icône du joueur sur la carte est le
	# rendu de son propre modèle, pas un point blanc anonyme.
	_avatar = TextureRect.new()
	_avatar.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_avatar.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	_avatar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_avatar.visible = false
	_root.add_child(_avatar)

	# Horloge + barres d'état : voyager sur la carte consomme du temps, donc
	# de la faim et de la fatigue. Sans ces indicateurs le joueur ne verrait
	# pas qu'il s'épuise en traversant le monde.
	_clock_label = Label.new()
	_clock_label.position = Vector2(12.0, 34.0)
	_clock_label.add_theme_font_size_override("font_size", UITheme.FONT_BODY)
	_clock_label.add_theme_constant_override("outline_size", 4)
	_clock_label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.7))
	_root.add_child(_clock_label)

	_bars = Control.new()
	_bars.position = Vector2(12.0, 60.0)
	_bars.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_bars.draw.connect(_draw_bars)
	_root.add_child(_bars)

	_info_label = Label.new()
	_info_label.position = Vector2(12.0, 8.0)
	_info_label.add_theme_constant_override("outline_size", 4)
	_info_label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.6))
	_root.add_child(_info_label)

	# Écran de chargement (2026-07-21, demande explicite) : la toute première
	# construction de la mosaïque (cache froid, block_at par pixel + scan de
	# rivières par cellule) peut prendre un temps perceptible — sans retour
	# visuel, la carte semblait figée le temps du calcul synchrone.
	_loading_label = Label.new()
	_loading_label.text = "Chargement..."
	_loading_label.add_theme_font_size_override("font_size", UITheme.FONT_TITLE)
	_loading_label.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	_loading_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_loading_label.visible = false
	_root.add_child(_loading_label)

	visible = false


func _unhandled_key_input(event: InputEvent) -> void:
	var key := event as InputEventKey
	if key == null or not key.pressed or key.echo:
		return
	if event.is_action_pressed("world_map") and not is_open:
		_open()
	elif key.physical_keycode == KEY_ESCAPE and is_open:
		_close()
	elif event.is_action_pressed("map_legend") and is_open:
		_layer_index = (_layer_index + 1) % LAYERS.size()
		_build_mosaic()


func _on_gui_input(event: InputEvent) -> void:
	if not is_open:
		return
	var button := event as InputEventMouseButton
	if button != null and button.pressed:
		if button.button_index == MOUSE_BUTTON_LEFT:
			_try_select(button.position)
		elif button.button_index == MOUSE_BUTTON_WHEEL_UP:
			_set_zoom(_radius - RADIUS_STEP)
		elif button.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			_set_zoom(_radius + RADIUS_STEP)
	var motion := event as InputEventMouseMotion
	if motion != null:
		_update_hover(motion.position)


func _process(delta: float) -> void:
	if not is_open:
		return
	_refresh_status()
	# Mêmes actions que la marche au sol : le déplacement case par case sur la
	# carte doit suivre la remappe du joueur, sinon il se retrouve avec deux
	# jeux de touches de déplacement différents selon l'écran ouvert.
	_step_cooldown = maxf(0.0, _step_cooldown - delta)
	if _step_cooldown > 0.0:
		return
	var step := Vector2i.ZERO
	if Input.is_action_pressed("move_forward"):
		step.y -= 1
	elif Input.is_action_pressed("move_back"):
		step.y += 1
	elif Input.is_action_pressed("move_left"):
		step.x -= 1
	elif Input.is_action_pressed("move_right"):
		step.x += 1
	if step == Vector2i.ZERO:
		return
	_step_cooldown = STEP_COOLDOWN
	_walk_one_cell(step)


## Fait marcher le joueur d'UNE cellule dans la direction donnée, en faisant
## réellement s'écouler le temps du trajet (faim, fatigue, régénération, IA).
## Le joueur peut donc s'affaiblir — voire mourir — en traversant la carte
## sans surveiller ses jauges : c'est voulu.
func _walk_one_cell(step: Vector2i) -> void:
	if _player == null:
		return
	var cs := ClaimManager.CELL_SIZE
	var pos: Vector3 = _player.get_position_for_ai()
	var target_cell := Vector2i(floori(pos.x / cs) + step.x, floori(pos.z / cs) + step.y)
	# Une cellule de donjon ne se traverse pas : on y ENTRE (3.5).
	if DungeonManager.is_dungeon_cell(target_cell):
		_close()
		DungeonManager.enter_from_map(target_cell)
		return
	var wx := target_cell.x * cs + cs / 2
	var wz := target_cell.y * cs + cs / 2
	var travelled := Vector2(float(wx) - pos.x, float(wz) - pos.z).length()
	var ticks := int(round(travelled * float(MAP_TICKS_PER_BLOCK)))

	_player.teleport_to_surface(wx, wz)
	# Le temps du trajet, poussé par paquets : les systèmes à ticks (faim,
	# fatigue, régén, créatures) le consomment vraiment.
	var pushed := 0
	while pushed < ticks:
		var batch := mini(500, ticks - pushed)
		TickManager.push_ticks(batch)
		pushed += batch
	_center_tile = target_cell
	_build_mosaic()
	_update_player_marker()
	_refresh_status()
	# Mort en chemin : la carte se ferme, le joueur réapparaît à son ancre.
	if float(_player.health) <= 0.0:
		_close()


## Horloge et jauges, rafraîchies à chaque frame pendant que la carte est
## ouverte (le temps peut avancer très vite en marchant de case en case).
func _refresh_status() -> void:
	if _player == null or _clock_label == null:
		return
	var h := DayNightManager.hour()
	_clock_label.text = tr("ui.carte.heure").format({
		"heure": "%02d:%02d" % [int(h), int(fmod(h, 1.0) * 60.0)],
		"phase": tr("ui.phase." + DayNightManager.phase())})
	_bars.queue_redraw()


const BAR_W := 190.0
const BAR_H := 12.0
const BAR_GAP := 4.0


func _draw_bars() -> void:
	if _player == null:
		return
	var jauges := [
		[float(_player.health) / maxf(float(_player.health_max), 1.0), Color(0.85, 0.25, 0.25)],
		[float(_player.mana.current) / maxf(float(_player.mana.max_mana()), 1.0), Color(0.3, 0.5, 0.9)],
		[float(_player.hunger) / maxf(float(_player.hunger_max), 1.0), Color(0.9, 0.62, 0.2)],
		[float(_player.fatigue) / maxf(float(_player.fatigue_max), 1.0), Color(0.55, 0.5, 0.85)],
	]
	for i in jauges.size():
		var y := float(i) * (BAR_H + BAR_GAP)
		_bars.draw_rect(Rect2(0.0, y, BAR_W, BAR_H), Color(0, 0, 0, 0.55))
		var ratio: float = clampf(jauges[i][0], 0.0, 1.0)
		_bars.draw_rect(Rect2(2.0, y + 2.0, (BAR_W - 4.0) * ratio, BAR_H - 4.0), jauges[i][1])


func _set_zoom(radius: int) -> void:
	var new_radius := clampi(radius, MIN_RADIUS, MAX_RADIUS)
	if new_radius == _radius:
		return
	_radius = new_radius
	_build_mosaic()


## Ouverture publique (appelée par l'onglet Carte du menu de jeu, game_menu.gd).
func open() -> void:
	if not is_open:
		_open()


func _open() -> void:
	if WorldManager.generator == null or _player == null:
		return
	is_open = true
	visible = true
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	_player.input_locked = true
	var fly_camera := get_node_or_null("../FlyCamera")
	if fly_camera != null:
		fly_camera.input_locked = true
	for n in _hidden_hud_nodes:
		n.visible = false
	if _stats_panel != null:
		_stats_panel.visible = true
	_radius = BASE_RADIUS
	var player_pos: Vector3 = _player.get_position_for_ai()
	_center_tile = Vector2i(floori(player_pos.x / ClaimManager.CELL_SIZE), floori(player_pos.z / ClaimManager.CELL_SIZE))
	_pan_accum = Vector2.ZERO
	# Écran de chargement : affiché AVANT la construction de la mosaïque
	# (maintenant asynchrone par budget de temps, voir BUILD_BUDGET_MS — plus
	# jamais un seul blocage long, mais la toute première construction sur
	# cache froid peut quand même prendre plusieurs frames visibles). BUG
	# RÉEL corrigé le 2026-07-21 : `_bg` n'était dimensionné qu'à LA FIN de
	# _build_mosaic() — pendant tout le chargement (potentiellement plusieurs
	# secondes la toute première fois), il restait à sa taille par défaut
	# (quasi nulle), laissant voir le monde 3D par-dessous dans un coin de
	# l'écran. Couvre tout de suite le viewport, avant même le label.
	var avail := get_viewport().get_visible_rect().size
	_bg.position = Vector2.ZERO
	_bg.size = avail
	_texture_rect.visible = false
	_poi_layer.visible = false
	_loading_label.visible = true
	await get_tree().process_frame
	await get_tree().process_frame
	await _build_mosaic()
	_loading_label.visible = false
	_texture_rect.visible = true
	_poi_layer.visible = true


func _close() -> void:
	is_open = false
	visible = false
	var fly_camera := get_node_or_null("../FlyCamera")
	if fly_camera != null:
		fly_camera.input_locked = false
	_player.input_locked = false
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	for n in _hidden_hud_nodes:
		n.visible = true
	if _stats_panel != null:
		_stats_panel.visible = false


func _update_info_label() -> void:
	var layer_key := "ui.map.layer." + String(LAYERS[_layer_index])
	_info_label.text = tr("ui.map.zoom_info").format({"grille": "%dx%d" % [_side, _side], "calque": tr(layer_key)})


## Couleur d'un point monde selon le calque actif (biome/relief par défaut,
## danger, revendications, exploration — sélection au clavier via L).
## `h`/`surf_id` viennent d'un SEUL appel `g.sample_surface(wx,wz)` fait par
## l'appelant (voir _render_cell — jamais un second échantillonnage complet
## du terrain ici, bug de perf réel corrigé le 2026-07-21 : `height_at()` +
## `block_at()` séparés recalculaient le terrain DEUX FOIS par pixel,
## bloquant le thread principal >20 s sur une grande carte). `rivers`
## (segments proches, calculés UNE FOIS par cellule — voir _build_mosaic)
## permet d'afficher les rivières (creusées localement, jamais reflétées par
## la hauteur seule). Océans/lacs : PAR PIXEL (résolution fine, évite
## l'écueil de l'ancienne tentative à 1 point/cellule qui exagérait chaque
## mare en un aplat bleu géant, voir mémoire projet).
func _sample_color(wx: int, wz: int, g: NoiseGenerator, h: int, surf_id: int, rivers: Array[Dictionary]) -> Color:
	match LAYERS[_layer_index]:
		"danger":
			const DANGER_COLOR := [Color(0.25, 0.7, 0.25), Color(0.85, 0.55, 0.1), Color(0.75, 0.1, 0.1)]
			return DANGER_COLOR[g.danger_level(wx, wz)]
		"revendications":
			var cell := ClaimManager.cell_of_block(wx, wz)
			if not ClaimManager.is_claimed(cell):
				return Color(0.25, 0.25, 0.25)
			match ClaimManager.role_of(cell):
				"habitation": return Color(0.9, 0.75, 0.2)
				"champs": return Color(0.55, 0.8, 0.2)
				"ressources_naturelles": return Color(0.2, 0.6, 0.5)
				_: return Color(0.8, 0.8, 0.8)
		"exploration":
			# Vue de DESSUS : une case est révélée si elle a été parcourue à
			# n'importe quelle hauteur. L'ancien test forçait chunk_y = 0 —
			# explorer en altitude ou sous terre ne révélait donc rien
			# (corrigé le 2026-07-27 avec le stockage par colonne).
			var explored := ExplorationManager.is_column_explored(wx >> 4, wz >> 4)
			return Color(0.7, 0.7, 0.75) if explored else Color(0.08, 0.08, 0.1)
		_:
			if h <= g.water_level:
				# Océan/lac : plus profond = plus sombre (lisible sans être
				# une source de vérité — juste un dégradé de profondeur).
				# `water_level` par-monde (paramètre « niveau de la mer »).
				var depth := clampf(float(g.water_level - h) / 12.0, 0.0, 1.0)
				return Color(0.22, 0.45, 0.7).lerp(Color(0.04, 0.12, 0.35), depth)
			if g.river_carve_at(float(wx), float(wz), rivers) > 0:
				return Color(0.3, 0.6, 0.8)
			# Matériau RÉEL de surface (2026-07-21, demande explicite : la carte
			# doit être "plus représentative du terrain réel") — PAS la couleur
			# générique du biome : capture nativement les variantes déjà
			# générées (littoraux sable/galets/falaise selon la pente, etc. —
			# E.2.2) sans dupliquer cette logique ici.
			if surf_id > 0 and surf_id < GameData.material_by_runtime.size():
				var mat_name: String = GameData.material_by_runtime[surf_id]
				var mat: Dictionary = GameData.materials.get(mat_name, {})
				if mat.has("color"):
					return Color.html(mat["color"])
			return Color(0.3, 0.3, 0.3)


## Numéro de génération de la mosaïque EN COURS de construction — permet à
## une construction devenue obsolète (zoom/pan pendant qu'une construction
## précédente tournait encore) de s'arrêter proprement au lieu de continuer
## à travailler pour rien ou d'écraser un résultat plus récent.
var _mosaic_generation := 0
## Budget de temps PAR FRAME pour construire la mosaïque (2026-07-21, bug
## réel corrigé : un point-requête RÉEL par pixel — `block_at`, plus lourd
## que l'ancien `biome_at` — sur ~350 000 pixels d'un coup bloquait le thread
## principal plusieurs secondes, perçu comme un plantage/gel par
## l'utilisateur). Construite CELLULE PAR CELLULE avec un `await` dès que ce
## budget est dépassé — jamais plus d'~1 frame de travail sans rendre la
## main, quelle que soit la taille de la grille affichée.
## Temps de calcul accordé par frame pendant la construction.
##
## 8 ms était le réglage d'un travail de FOND, à faire pendant que le joueur
## joue. Mais la carte est MODALE : elle occupe tout l'écran, affiche
## « Chargement… », et rien d'autre n'a besoin de la frame. Se brider à 8 ms
## revenait à ne travailler qu'un huitième du temps — mesuré le 2026-08-01,
## 22,5 s de temps réel pour 10,6 s de calcul, soit près de 12 s passées à
## attendre la frame suivante pour rien.
##
## 30 ms laisse encore tourner l'affichage à ~30 images/s, largement assez pour
## un écran de chargement, et rend au calcul les trois quarts du temps perdu.
const BUILD_BUDGET_MS := 30.0

## Construit la mosaïque 2D (survol simplifié, jamais la source de vérité —
## E.2) : chaque cellule normale (128 blocs) devient un carré de CELL_PIXELS
## (16) pixels, échantillonné tous les 8 blocs (128/16) pour montrer la
## composition interne de la cellule. Nuance de luminosité approximative en
## guise de relief (pas de vrai terrain en 2D). ASYNCHRONE (voir
## BUILD_BUDGET_MS) : ne bloque jamais le thread principal longtemps d'un
## coup, quitte à afficher la mosaïque en plusieurs passes visibles.
func _build_mosaic() -> void:
	var g := WorldManager.generator
	if g == null:
		return
	# Le monde change de générateur au hot-reload (F5, seed/matériaux/biomes
	# potentiellement modifiés) — le cache d'une génération précédente ne
	# serait plus valide, on le vide.
	if g != _cell_cache_generator:
		_cell_cache.clear()
		_cell_cache_generator = g
	_mosaic_generation += 1
	var my_gen := _mosaic_generation
	_side = _radius * 2 + 1
	var img_size := _side * CELL_PIXELS
	var img := Image.create(img_size, img_size, false, Image.FORMAT_RGB8)
	var cs := ClaimManager.CELL_SIZE
	var layer_key: String = LAYERS[_layer_index]
	var cacheable: bool = layer_key == "biome" or layer_key == "danger"

	var budget_start := Time.get_ticks_msec()
	for cz in _side:
		for cx in _side:
			var tile := _center_tile + Vector2i(cx - _radius, cz - _radius)
			var cache_id := "%d_%d_%s" % [tile.x, tile.y, layer_key]
			var cell_img: Image = _cell_cache.get(cache_id) if cacheable else null
			if cell_img == null:
				cell_img = _render_cell(tile, g, cs)
				if cacheable:
					_cell_cache[cache_id] = cell_img
			img.blit_rect(cell_img, Rect2i(0, 0, CELL_PIXELS, CELL_PIXELS), Vector2i(cx * CELL_PIXELS, cz * CELL_PIXELS))
			if Time.get_ticks_msec() - budget_start >= BUILD_BUDGET_MS:
				await get_tree().process_frame
				if my_gen != _mosaic_generation:
					return  # Une construction plus récente a pris le relais.
				budget_start = Time.get_ticks_msec()
	if my_gen != _mosaic_generation:
		return
	_texture_rect.texture = ImageTexture.create_from_image(img)

	# Ajuste l'affichage pour occuper la zone dispo (hors sidebar de stats),
	# toujours carré → carré, jamais déformé.
	var avail := get_viewport().get_visible_rect().size
	var side_px := minf(avail.x - SIDEBAR_WIDTH, avail.y - 40.0)
	_display_scale = side_px / float(img_size)
	_texture_rect.size = Vector2(img_size, img_size) * _display_scale
	_origin = Vector2(avail.x - side_px - 12.0, (avail.y - side_px) * 0.5)
	_texture_rect.position = _origin
	_bg.position = Vector2(_origin.x - 12.0, 0.0)
	_bg.size = Vector2(avail.x - _bg.position.x, avail.y)
	_update_info_label()
	_update_poi_markers()
	_update_player_marker()
	_hover_tile = Vector2i(1 << 30, 0)
	_selection.visible = false


## Résolution d'ÉCHANTILLONNAGE réelle par cellule (bruit/terrain), distincte
## de CELL_PIXELS (résolution d'AFFICHAGE) : SAMPLE_DIV×SAMPLE_DIV points de
## terrain réels par cellule, chacun rempli sur un bloc CELL_PIXELS/SAMPLE_DIV
## de pixels affichés (agrandissement au plus proche voisin). BUG DE PERF
## RÉEL trouvé et corrigé le 2026-07-21 : échantillonner CELL_PIXELS² (256)
## points de terrain PAR CELLULE, avec une grille de ~1400 cellules visibles,
## c'est ~350 000 requêtes de terrain — mesuré à >20 s, perçu comme un
## plantage/gel par l'utilisateur. SAMPLE_DIV=4 (16 points/cellule) réduit
## ça d'un facteur 16 (~22 000 requêtes), tout en restant BEAUCOUP plus
## détaillé que l'ancienne tentative à 1 SEUL point/cellule (celle qui avait
## exagéré chaque mare en un aplat bleu géant, voir mémoire projet).
const SAMPLE_DIV := 4

## Peint UNE cellule (CELL_PIXELS×CELL_PIXELS à l'affichage, SAMPLE_DIV² points
## de terrain réels — voir SAMPLE_DIV) — extrait de _build_mosaic (2026-07-21)
## pour être mis en cache par cellule (voir _cell_cache) : sans ce cache, la
## carte rééchantillonnait TOUT le bruit/terrain à chaque ouverture/zoom/pan,
## alors que le monde sous-jacent est déterministe et ne change jamais sur
## les calques procéduraux.
func _render_cell(tile: Vector2i, g: NoiseGenerator, cs: int) -> Image:
	var cell_img := Image.create(CELL_PIXELS, CELL_PIXELS, false, Image.FORMAT_RGB8)
	var base_wx := tile.x * cs
	var base_wz := tile.y * cs
	# Rivières : UN SEUL scan régional par cellule (pas par point d'échantillon
	# — la recherche de sources sur toute une fenêtre de RIVER_SEARCH_RADIUS
	# serait bien trop coûteuse répétée à chaque point ; les tracés eux-mêmes
	# sont déjà mis en cache par NoiseGenerator, voir rivers_near/
	# river_carve_at, 2026-07-21 — affichage de l'eau).
	var rivers := g.rivers_near(base_wx, base_wx + cs, base_wz, base_wz + cs)
	# Le village de la cellule, résolu UNE fois : les seize échantillons qui
	# suivent tombent tous dans la même cellule de village, donc dans le même
	# layout. Le résoudre par échantillon prenait un mutex seize fois pour rien
	# — 2,5 s sur une construction complète de carte (mesuré le 2026-08-01).
	var city := g.city_at_cell(tile)
	var block := CELL_PIXELS / SAMPLE_DIV
	var sample_span := cs / SAMPLE_DIV
	for sy in SAMPLE_DIV:
		for sx in SAMPLE_DIV:
			var wx := base_wx + sx * sample_span + sample_span / 2
			var wz := base_wz + sy * sample_span + sample_span / 2
			# UN SEUL échantillonnage du terrain par point (hauteur ET matériau
			# de surface réel ensemble) — jamais `height_at()`+`block_at()`
			# séparés (double calcul redondant, bug de perf réel corrigé le
			# 2026-07-21).
			var sample := g.sample_surface(wx, wz, city)
			var h: int = sample["h"]
			var surf_id: int = sample["surf"]
			# Ombrage approximatif (relief lisible, jamais un vrai terrain) :
			# plage fixe plutôt qu'une normalisation min/max sur toute la
			# mosaïque — évite un second passage d'échantillonnage complet.
			var shade := clampf((float(h) + 20.0) / 320.0, 0.0, 1.0)
			var color := _sample_color(wx, wz, g, h, surf_id, rivers) * (0.55 + shade * 0.45)
			color.a = 1.0
			for py in range(sy * block, (sy + 1) * block):
				for px in range(sx * block, (sx + 1) * block):
					cell_img.set_pixel(px, py, color)
	return cell_img


## Position du joueur sur la mosaïque, en coordonnées FRACTIONNAIRES de
## cellule (précision sous-cellule, pas juste "dans quelle case"). Caché si
## le joueur est actuellement hors de la zone affichée (pan/zoom).
func _update_player_marker() -> void:
	if _player == null:
		_player_marker_outer.visible = false
		_player_marker_inner.visible = false
		return
	var pos: Vector3 = _player.get_position_for_ai()
	var cs := ClaimManager.CELL_SIZE
	var frac := Vector2(pos.x / float(cs), pos.z / float(cs)) - Vector2(_center_tile - Vector2i(_radius, _radius))
	var cell_px := CELL_PIXELS * _display_scale
	var screen_pos := _origin + frac * cell_px
	var span := float(_side) * cell_px
	if screen_pos.x < _origin.x or screen_pos.y < _origin.y or screen_pos.x > _origin.x + span or screen_pos.y > _origin.y + span:
		_player_marker_outer.visible = false
		_player_marker_inner.visible = false
		if _avatar != null:
			_avatar.visible = false
		return
	var outer_size := cell_px * 0.4
	# Avatar du joueur si son icône est disponible ; sinon le repère
	# noir/blanc historique, qui reste un repli sûr.
	var avatar_tex: Texture2D = BlockPreview.avatar_icon()
	if avatar_tex != null:
		var avatar_size := maxf(cell_px * 0.9, 18.0)
		_avatar.texture = avatar_tex
		_avatar.size = Vector2.ONE * avatar_size
		_avatar.position = screen_pos - Vector2.ONE * avatar_size * 0.5
		_avatar.visible = true
		_player_marker_outer.visible = false
		_player_marker_inner.visible = false
		return
	_avatar.visible = false
	var inner_size := outer_size * 0.5
	_player_marker_outer.size = Vector2.ONE * outer_size
	_player_marker_outer.position = screen_pos - Vector2.ONE * outer_size * 0.5
	_player_marker_outer.visible = true
	_player_marker_inner.size = Vector2.ONE * inner_size
	_player_marker_inner.position = screen_pos - Vector2.ONE * inner_size * 0.5
	_player_marker_inner.visible = true


## Icônes de POI (E.2) par cellule visible — placement uniquement, aucune
## structure en jeu pour l'instant (voir POIGenerator). Jusqu'à 2 icônes
## côte à côte par cellule (plafond du placement lui-même).
func _update_poi_markers() -> void:
	for child in _poi_layer.get_children():
		child.queue_free()
	var g := WorldManager.generator
	if g == null:
		return
	var cell_px := CELL_PIXELS * _display_scale
	_draw_kingdom_territories(g, cell_px)
	for cz in _side:
		for cx in _side:
			var tile := _center_tile + Vector2i(cx - _radius, cz - _radius)
			var center_w := POIGenerator.cell_center_world(tile)
			var biome: Dictionary = g.biome_at(center_w.x, center_w.y)
			if biome.is_empty():
				continue
			# Emprise (2026-07-21) : une cellule engloutie par le footprint
			# d'une grande ville voisine n'affiche RIEN en propre — l'ancre
			# dessine un marqueur qui couvre visuellement tout le footprint.
			var owner := POIGenerator.village_owner_of(tile, WorldManager.world_seed, Callable(self, "_cell_biome"))
			if owner != tile:
				continue
			var pois := POIGenerator.pois_at_cell(tile, WorldManager.world_seed, biome)
			if pois.is_empty():
				continue
			# LE MARQUEUR DOIT CORRESPONDRE À UN VILLAGE QUI EXISTE.
			#
			# Bug signalé par l'auteur (« je crois que les villages ne se
			# génèrent pas ») et mesuré par --probe-villages : sur 59 cellules
			# désignées « village » par le tirage de POI, 12 seulement passent
			# les contraintes de site (au sec, assez plat). La carte dessinait
			# pourtant les 59. Le joueur marchait vers un marqueur, ne trouvait
			# rien, et en concluait que la génération était cassée — alors que
			# c'est la CARTE qui mentait.
			#
			# On interroge donc le vrai calcul. Il est coûteux, mais uniquement
			# pour les 2,5 % de cellules déjà désignées, et il est mis en cache
			# par le générateur : on reste très loin du piège de perf documenté
			# plus haut (350 000 requêtes de terrain).
			if "village" in pois and g.city_at_cell(tile).is_empty():
				pois = pois.duplicate()
				pois.erase("village")
				if pois.is_empty():
					continue
			var base_pos := _origin + Vector2(cx, cz) * cell_px
			var mark_size := cell_px * 0.28
			var next_slot := 0
			for poi_type in pois:
				if poi_type == "village" and POIGenerator.village_size_at(tile, WorldManager.world_seed) == "grande_ville":
					# Grande ville : un marqueur qui couvre visuellement tout
					# le footprint (GRANDE_VILLE_FOOTPRINT cellules), pas une
					# simple pastille — distinct au premier coup d'œil.
					var span := POIGenerator.GRANDE_VILLE_FOOTPRINT * cell_px
					var mark := ColorRect.new()
					mark.color = Color(1.0, 0.9, 0.35, 0.85)
					mark.mouse_filter = Control.MOUSE_FILTER_IGNORE
					mark.size = Vector2.ONE * (span * 0.5)
					mark.position = base_pos + Vector2(span, span) * 0.25
					_poi_layer.add_child(mark)
					continue
				var mark := ColorRect.new()
				mark.color = _poi_color(poi_type)
				mark.mouse_filter = Control.MOUSE_FILTER_IGNORE
				mark.size = Vector2.ONE * mark_size
				mark.position = base_pos + Vector2(cell_px * 0.08 + next_slot * (mark_size + cell_px * 0.06), cell_px * 0.08)
				_poi_layer.add_child(mark)
				next_slot += 1


## Callable liée pour POIGenerator.village_owner_of (biome au centre d'une
## cellule candidate — signature attendue : Vector2i -> Dictionary).
func _cell_biome(cell: Vector2i) -> Dictionary:
	var g := WorldManager.generator
	if g == null:
		return {}
	var center := POIGenerator.cell_center_world(cell)
	return g.biome_at(center.x, center.y)


func _poi_color(poi_type: String) -> Color:
	match poi_type:
		"village": return Color(0.95, 0.85, 0.3)
		"donjon": return Color(0.75, 0.1, 0.1)
		_: return Color.WHITE


## Convertit une position écran en cellule (ou le sentinel (1<<30, 0) si hors
## de la mosaïque).
func _pixel_to_tile(mouse_pos: Vector2) -> Vector2i:
	var local := (mouse_pos - _origin) / _display_scale
	var span := float(_side * CELL_PIXELS)
	if local.x < 0.0 or local.y < 0.0 or local.x >= span or local.y >= span:
		return Vector2i(1 << 30, 0)
	var cx := int(local.x) / CELL_PIXELS
	var cz := int(local.y) / CELL_PIXELS
	return _center_tile + Vector2i(cx - _radius, cz - _radius)


func _update_hover(mouse_pos: Vector2) -> void:
	var tile := _pixel_to_tile(mouse_pos)
	if tile == _hover_tile:
		return
	_hover_tile = tile
	if tile.x == (1 << 30):
		_selection.visible = false
		return
	var offset := tile - _center_tile + Vector2i(_radius, _radius)
	var cell_px := CELL_PIXELS * _display_scale
	_selection.position = _origin + Vector2(offset.x, offset.y) * cell_px
	_selection.size = Vector2.ONE * cell_px
	_selection.visible = true
	if _stats_panel != null and _stats_panel.has_method("show_hovered_cell"):
		_stats_panel.show_hovered_cell(tile)


func _try_select(mouse_pos: Vector2) -> void:
	var tile := _pixel_to_tile(mouse_pos)
	if tile.x == (1 << 30):
		return
	# Passe par fast_travel_to_cell (et non _to_world) : une cellule DONJON
	# fait entrer DIRECTEMENT dans le donjon (3.5, 2026-07-21) — le voyage
	# rapide ne peut cibler que l'entrée, jamais un point arbitraire.
	_player.fast_travel_to_cell(tile)
	_close()


## Teinte de TERRITOIRE : chaque royaume colore ses cellules (14.4/E.27).
##
## Un voile translucide plutôt qu'un aplat : la carte doit rester lisible EN
## DESSOUS. Le joueur a besoin de voir simultanément le relief et l'autorité —
## c'est précisément la superposition des deux qui lui apprend qu'un royaume
## s'arrête devant une montagne, et qui rend la frontière signifiante plutôt
## qu'arbitraire.
##
## Les royaumes lointains s'affichent AVANT toute visite : c'est la propriété
## qu'E.27 achète en interdisant tout calcul dépendant du terrain généré, et
## c'est ce qui donne au joueur une raison d'aller quelque part.
const KINGDOM_TINT_ALPHA := 0.30
const KINGDOM_BORDER_ALPHA := 0.85


func _draw_kingdom_territories(g: NoiseGenerator, cell_px: float) -> void:
	# UNE requête par cellule visible, pas cinq. La première version interrogeait
	# aussi les quatre voisines pour tracer les frontières : sur une grille de
	# 37×37, cela faisait près de 7 000 requêtes là où 1 369 suffisent. On relève
	# d'abord la carte politique dans un dictionnaire local, puis on en DÉDUIT
	# les frontières — un voisin hors champ n'a pas besoin d'être calculé, il
	# suffit de le traiter comme « pas le même royaume ».
	var owners := {}
	for cz in _side:
		for cx in _side:
			var tile := _center_tile + Vector2i(cx - _radius, cz - _radius)
			var kingdom := g.kingdom_at_cell(tile)
			if not kingdom.is_empty():
				owners[Vector2i(cx, cz)] = kingdom

	for grid_pos: Vector2i in owners:
		var kingdom: Dictionary = owners[grid_pos]
		var base_pos := _origin + Vector2(grid_pos) * cell_px
		var tint := ColorRect.new()
		tint.color = Color(kingdom["color"], KINGDOM_TINT_ALPHA)
		tint.mouse_filter = Control.MOUSE_FILTER_IGNORE
		tint.size = Vector2.ONE * cell_px
		tint.position = base_pos
		_poi_layer.add_child(tint)

		# FRONTIÈRE : un liseré sur les côtés qui donnent sur autre chose. Sans
		# lui, deux royaumes voisins de teintes proches se lisent comme un seul
		# bloc, et l'information politique la plus utile — où s'arrête
		# l'autorité — disparaît.
		for offset: Vector2i in [Vector2i(1, 0), Vector2i(-1, 0),
				Vector2i(0, 1), Vector2i(0, -1)]:
			var neighbour: Dictionary = owners.get(grid_pos + offset, {})
			if String(neighbour.get("id", "")) == String(kingdom["id"]):
				continue
			var edge := ColorRect.new()
			edge.color = Color(kingdom["color"], KINGDOM_BORDER_ALPHA)
			edge.mouse_filter = Control.MOUSE_FILTER_IGNORE
			var thickness: float = maxf(1.0, cell_px * 0.08)
			if offset.x != 0:
				edge.size = Vector2(thickness, cell_px)
				edge.position = base_pos + Vector2(
					cell_px - thickness if offset.x > 0 else 0.0, 0.0)
			else:
				edge.size = Vector2(cell_px, thickness)
				edge.position = base_pos + Vector2(0.0,
					cell_px - thickness if offset.y > 0 else 0.0)
			_poi_layer.add_child(edge)


## Nom du royaume d'une cellule, pour l'infobulle de la carte. Vide en terre
## sauvage — et c'est une information : « hors royaume = aucune loi » (14.4).
func kingdom_label_at(tile: Vector2i) -> String:
	var g := WorldManager.generator
	if g == null:
		return ""
	var kingdom := g.kingdom_at_cell(tile)
	if kingdom.is_empty():
		return ""
	return "%s (%s)" % [String(kingdom["name"]),
		tr("gouvernance." + String(kingdom["government_type"]))]
