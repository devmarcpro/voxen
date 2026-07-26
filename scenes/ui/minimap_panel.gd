extends Control
## Minimap À L'ÉCHELLE DE LA CELLULE (2026-07-26, refonte) : montre la CELLULE
## courante (128 blocs) en entier, FIXE ; seul le marqueur du joueur bouge à
## l'intérieur ; passer dans une autre cellule reconstruit l'image. Rendu de la
## cellule mis en cache (recalculé uniquement au changement de cellule).

const MAP_PX := 132
const RES := 24                  # échantillons par côté (cellule / RES blocs par pixel).
const REFRESH_INTERVAL := 0.25

var _player: Node
var _cell_tex: ImageTexture
var _cell_key := Vector2i(0x7fffffff, 0x7fffffff)
var _cell_size := 128


func _ready() -> void:
	_player = get_node_or_null("../../Player")
	_cell_size = ClaimManager.CELL_SIZE
	custom_minimum_size = Vector2(MAP_PX, MAP_PX)
	var timer := Timer.new()
	timer.wait_time = REFRESH_INTERVAL
	timer.autostart = true
	timer.timeout.connect(queue_redraw)
	add_child(timer)


func _draw() -> void:
	if _player == null or WorldManager.generator == null:
		return
	var pos: Vector3 = _player.get_position_for_ai()
	var cell := Vector2i(floori(pos.x / _cell_size), floori(pos.z / _cell_size))
	if cell != _cell_key:
		_cell_key = cell
		_rebuild_cell(cell)

	draw_rect(Rect2(Vector2.ZERO, Vector2(MAP_PX, MAP_PX)), Color(0, 0, 0, 0.55))
	if _cell_tex != null:
		draw_texture_rect(_cell_tex, Rect2(Vector2.ZERO, Vector2(MAP_PX, MAP_PX)), false)
	draw_rect(Rect2(Vector2.ZERO, Vector2(MAP_PX, MAP_PX)), Color(1, 1, 1, 0.25), false, 1.0)

	# Position FRACTIONNAIRE du joueur dans la cellule (seul le marqueur bouge).
	var lx := (pos.x - float(cell.x * _cell_size)) / float(_cell_size)
	var lz := (pos.z - float(cell.y * _cell_size)) / float(_cell_size)
	var pp := Vector2(lx, lz) * MAP_PX

	# Créatures présentes DANS la cellule courante.
	for creature: Node3D in CreatureManager.creatures:
		if not is_instance_valid(creature):
			continue
		var cpos := creature.position
		if floori(cpos.x / _cell_size) != cell.x or floori(cpos.z / _cell_size) != cell.y:
			continue
		var clp := Vector2((cpos.x - cell.x * _cell_size) / float(_cell_size),
			(cpos.z - cell.y * _cell_size) / float(_cell_size)) * MAP_PX
		draw_circle(clp, 2.5, Color(0.9, 0.15, 0.15))

	# Marqueur joueur (flèche/point) + orientation.
	draw_circle(pp, 3.5, Color.WHITE)
	draw_circle(pp, 3.5, Color.BLACK, false, 1.0)


## (Re)construit l'image de la cellule (échantillonnée via preview_color).
func _rebuild_cell(cell: Vector2i) -> void:
	var g := WorldManager.generator
	var step := _cell_size / RES
	var img := Image.create(RES, RES, false, Image.FORMAT_RGB8)
	for gz in RES:
		for gx in RES:
			var wx := cell.x * _cell_size + gx * step + step / 2
			var wz := cell.y * _cell_size + gz * step + step / 2
			img.set_pixel(gx, gz, g.preview_color(wx, wz))
	_cell_tex = ImageTexture.create_from_image(img)
