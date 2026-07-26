extends Control
## Carte du monde EMBARQUÉE dans l'onglet Carte du menu (2026-07-26). Le joueur
## reste TOUJOURS AU CENTRE ; la carte défile sous lui. Marqueur = modèle 3D du
## joueur (icône rendue). Clic = voyage PROGRESSIF (le joueur y marche, 2× plus
## lent qu'à pied) puis ferme le menu. Image de fond mise en cache (reconstruite
## quand le joueur a bougé).

const MAP_PX := 420
const RES := 84                 # échantillons/côté
const SPAN_BLOCKS := 672.0      # étendue visible (~5 cellules)

signal travel_requested(wx: int, wz: int)

var _player: Node
var _bg_tex: ImageTexture
var _bg_center := Vector2(1e12, 1e12)


func setup(player: Node) -> void:
	_player = player


func _ready() -> void:
	custom_minimum_size = Vector2(MAP_PX, MAP_PX)
	mouse_filter = Control.MOUSE_FILTER_STOP
	gui_input.connect(_on_click)
	var timer := Timer.new()
	timer.wait_time = 0.3
	timer.autostart = true
	timer.timeout.connect(queue_redraw)
	add_child(timer)


func _center() -> Vector2:
	var p: Vector3 = _player.get_position_for_ai()
	return Vector2(p.x, p.z)


func _draw() -> void:
	if _player == null or WorldManager.generator == null:
		return
	var c := _center()
	# Reconstruit le fond si le joueur a bougé d'au moins ~un échantillon.
	if _bg_tex == null or _bg_center.distance_to(c) > SPAN_BLOCKS / RES:
		_rebuild_bg(c)
		_bg_center = c
	draw_rect(Rect2(Vector2.ZERO, Vector2(MAP_PX, MAP_PX)), Color(0, 0, 0, 0.6))
	if _bg_tex != null:
		# Décale le fond selon le déplacement depuis sa construction → défilement fluide.
		var off := (_bg_center - c) / SPAN_BLOCKS * MAP_PX
		draw_texture_rect(_bg_tex, Rect2(off, Vector2(MAP_PX, MAP_PX)), false)
	draw_rect(Rect2(Vector2.ZERO, Vector2(MAP_PX, MAP_PX)), Color(1, 1, 1, 0.25), false, 1.0)
	# Marqueur central = modèle 3D du joueur (icône), sinon point blanc.
	var avatar: Texture2D = BlockPreview.avatar_icon()
	var mid := Vector2(MAP_PX, MAP_PX) * 0.5
	if avatar != null:
		var s := Vector2(48, 48)
		draw_texture_rect(avatar, Rect2(mid - s * 0.5, s), false)
	else:
		draw_circle(mid, 5.0, Color.WHITE)


func _rebuild_bg(c: Vector2) -> void:
	var g := WorldManager.generator
	var step := SPAN_BLOCKS / RES
	var ox := c.x - SPAN_BLOCKS * 0.5
	var oz := c.y - SPAN_BLOCKS * 0.5
	var img := Image.create(RES, RES, false, Image.FORMAT_RGB8)
	for gz in RES:
		for gx in RES:
			img.set_pixel(gx, gz, g.preview_color(int(ox + gx * step), int(oz + gz * step)))
	_bg_tex = ImageTexture.create_from_image(img)


func _on_click(event: InputEvent) -> void:
	var mb := event as InputEventMouseButton
	if mb == null or not mb.pressed or mb.button_index != MOUSE_BUTTON_LEFT:
		return
	var c := _center()
	var wx := int(c.x - SPAN_BLOCKS * 0.5 + mb.position.x / MAP_PX * SPAN_BLOCKS)
	var wz := int(c.y - SPAN_BLOCKS * 0.5 + mb.position.y / MAP_PX * SPAN_BLOCKS)
	travel_requested.emit(wx, wz)
