extends Control
## Barres de statut + indicateurs (2026-07-26, v2) : PV / mana / faim + horloge
## + température, positionnés en coordonnées ABSOLUES au-dessus de la hotbar
## (un Control sous un CanvasLayer n'a pas de taille → les ancres ne marchent
## pas ; on place tout à la main depuis la taille du viewport).

const BAR_W := 190.0
const BAR_H := 14.0
const GAP := 4.0
const TICKS_PER_DAY := 24000.0
const HOTBAR_MARGIN := 118.0   # hauteur réservée en bas (hotbar + label objet).

var _player: Node
var _camera: Node3D
var _pv_bg: ColorRect
var _mana_bg: ColorRect
var _faim_bg: ColorRect
var _fatigue_bg: ColorRect
var _pv_fill: ColorRect
var _mana_fill: ColorRect
var _faim_fill: ColorRect
var _fatigue_fill: ColorRect
var _temp_label: Label
var _clock: Control


func setup(player: Node, camera: Node3D) -> void:
	_player = player
	_camera = camera


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	position = Vector2.ZERO
	var pv := _make_bar(Color(0.85, 0.2, 0.2)); _pv_bg = pv[0]; _pv_fill = pv[1]
	var mn := _make_bar(Color(0.25, 0.5, 0.95)); _mana_bg = mn[0]; _mana_fill = mn[1]
	var fm := _make_bar(Color(0.9, 0.62, 0.2)); _faim_bg = fm[0]; _faim_fill = fm[1]
	# Fatigue (amendement E.21) — bleu-violet, distincte de la faim.
	var ft := _make_bar(Color(0.55, 0.5, 0.85)); _fatigue_bg = ft[0]; _fatigue_fill = ft[1]
	_clock = Control.new()
	_clock.custom_minimum_size = Vector2(52, 52)
	_clock.size = Vector2(52, 52)
	_clock.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_clock.draw.connect(_draw_clock)
	add_child(_clock)
	_temp_label = Label.new()
	_temp_label.add_theme_font_size_override("font_size", 15)
	add_child(_temp_label)


func _make_bar(color: Color) -> Array:
	var bg := ColorRect.new()
	bg.color = Color(0, 0, 0, 0.55)
	bg.size = Vector2(BAR_W, BAR_H)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var fill := ColorRect.new()
	fill.color = color
	fill.position = Vector2(2, 2)
	fill.size = Vector2(BAR_W - 4, BAR_H - 4)
	fill.mouse_filter = Control.MOUSE_FILTER_IGNORE
	bg.add_child(fill)
	add_child(bg)
	return [bg, fill]


## Maj THROTTLÉE (2026-07-26, fix perf) : ne rien recalculer à 60 fps — le coût
## par frame (positions, température, redraw horloge) faisait chuter le FPS.
## On rafraîchit ~6×/s ; les positions ne bougent qu'au redimensionnement.
var _acc := 0.0
var _last_vp := Vector2.ZERO
func _process(delta: float) -> void:
	if _player == null:
		return
	_acc += delta
	if _acc < 0.16:
		return
	_acc = 0.0
	var vp := get_viewport_rect().size
	if vp != _last_vp:
		_last_vp = vp
		_layout(vp)
	_fill(_pv_fill, _player.health / maxf(_player.health_max, 1.0))
	var m: Object = _player.mana
	_fill(_mana_fill, float(m.current) / maxf(float(m.max_mana()), 1.0))
	_fill(_faim_fill, _player.hunger / maxf(_player.hunger_max, 1.0))
	_fill(_fatigue_fill, _player.fatigue / maxf(_player.fatigue_max, 1.0))
	_clock.queue_redraw()
	if WorldManager.generator != null and _camera != null:
		var pos: Vector3 = _camera.global_position
		var t: float = WorldManager.generator.temperature_at(int(pos.x), int(pos.z))
		var txt := "%d°C" % int(round(-15.0 + t * 55.0))
		if txt != _temp_label.text:
			_temp_label.text = txt
		_temp_label.modulate = Color(0.5, 0.7, 1.0).lerp(Color(1.0, 0.5, 0.3), t)


func _layout(vp: Vector2) -> void:
	var bx := vp.x * 0.5 - BAR_W - 40.0
	# 4 barres depuis l'ajout de la fatigue (PV, mana, faim, fatigue).
	var y0 := vp.y - HOTBAR_MARGIN - 4.0 * (BAR_H + GAP)
	_pv_bg.position = Vector2(bx, y0)
	_mana_bg.position = Vector2(bx, y0 + BAR_H + GAP)
	_faim_bg.position = Vector2(bx, y0 + 2.0 * (BAR_H + GAP))
	_fatigue_bg.position = Vector2(bx, y0 + 3.0 * (BAR_H + GAP))
	_clock.position = Vector2(vp.x * 0.5 + 44.0, y0 - 4.0)
	_temp_label.position = Vector2(vp.x * 0.5 + 104.0, y0 + 14.0)


func _fill(fill: ColorRect, ratio: float) -> void:
	fill.size.x = (BAR_W - 4) * clampf(ratio, 0.0, 1.0)


## Horloge du jour : cadran 24 h, aiguille = heure, fond jour/nuit.
func _draw_clock() -> void:
	var c := _clock.size * 0.5
	var radius: float = minf(c.x, c.y) - 2.0
	var t := fmod(float(TickManager.tick_index), TICKS_PER_DAY) / TICKS_PER_DAY
	var is_day := t > 0.25 and t < 0.75
	_clock.draw_circle(c, radius, Color(0.55, 0.72, 0.95) if is_day else Color(0.12, 0.14, 0.28))
	_clock.draw_arc(c, radius, 0.0, TAU, 32, Color(0, 0, 0, 0.6), 2.0)
	var ang := t * TAU - PI * 0.5
	_clock.draw_line(c, c + Vector2(cos(ang), sin(ang)) * (radius - 4.0), Color(1, 1, 1, 0.9), 2.0)
	for i in 4:
		var a := float(i) * TAU / 4.0 - PI * 0.5
		_clock.draw_line(c + Vector2(cos(a), sin(a)) * (radius - 3.0),
			c + Vector2(cos(a), sin(a)) * radius, Color(1, 1, 1, 0.5), 1.0)
