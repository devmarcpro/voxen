extends Control
## Barres de statut + indicateurs (2026-07-26, v2) : PV / mana / faim + horloge
## + température, positionnés en coordonnées ABSOLUES au-dessus de la hotbar
## (un Control sous un CanvasLayer n'a pas de taille → les ancres ne marchent
## pas ; on place tout à la main depuis la taille du viewport).

## Les jauges sont désormais des StatBar : intitulé + barre + chiffre. Avant,
## c'étaient quatre rectangles colorés anonymes — il fallait connaître l'ordre
## par cœur pour savoir lequel était la faim, et aucun ne donnait de valeur. Une
## barre à moitié pleine ne dit pas s'il reste 30 PV ou 3.
const BAR_W := 300.0
const BAR_H := 14.0
const GAP := 2.0
const TICKS_PER_DAY := 24000.0
const HOTBAR_MARGIN := 118.0   # hauteur réservée en bas (hotbar + label objet).

var _player: Node
var _camera: Node3D
var _bars := {}
var _frame: PanelContainer
var _stack: VBoxContainer
var _temp_label: Label
var _clock: Control


func setup(player: Node, camera: Node3D) -> void:
	_player = player
	_camera = camera


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	position = Vector2.ZERO
	# Un CADRE autour des jauges : posées à nu sur le monde, elles flottaient et
	# leur zone n'était pas lisible. Le cadre les désigne comme un ensemble.
	_frame = PanelContainer.new()
	_frame.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_stack = VBoxContainer.new()
	_stack.add_theme_constant_override("separation", GAP)
	_stack.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_frame.add_child(_stack)
	add_child(_frame)
	# Fatigue (amendement E.21) — bleu-violet, distincte de la faim.
	for gauge: String in ["vie", "mana", "faim", "fatigue"]:
		var bar := StatBar.new()
		bar.setup(tr("ui.gauge." + gauge), gauge)
		bar.custom_minimum_size = Vector2(BAR_W, StatBar.LINE_H)
		_stack.add_child(bar)
		_bars[gauge] = bar
	_clock = Control.new()
	_clock.custom_minimum_size = Vector2(52, 52)
	_clock.size = Vector2(52, 52)
	_clock.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_clock.draw.connect(_draw_clock)
	add_child(_clock)
	_temp_label = Label.new()
	_temp_label.add_theme_font_size_override("font_size", UITheme.FONT_SMALL)
	add_child(_temp_label)


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
	_bars["vie"].set_values(_player.health, _player.health_max)
	var m: Object = _player.mana
	_bars["mana"].set_values(float(m.current), float(m.max_mana()))
	_bars["faim"].set_values(_player.hunger, _player.hunger_max)
	_bars["fatigue"].set_values(_player.fatigue, _player.fatigue_max)
	_clock.queue_redraw()
	if WorldManager.generator != null and _camera != null:
		var pos: Vector3 = _camera.global_position
		var t: float = WorldManager.generator.temperature_at(int(pos.x), int(pos.z))
		var txt := "%d°C" % int(round(-15.0 + t * 55.0))
		if txt != _temp_label.text:
			_temp_label.text = txt
		_temp_label.modulate = Color(0.5, 0.7, 1.0).lerp(Color(1.0, 0.5, 0.3), t)


func _layout(vp: Vector2) -> void:
	var bx := vp.x * 0.5 - BAR_W - 56.0
	# 4 jauges depuis l'ajout de la fatigue (PV, mana, faim, fatigue).
	var height := 4.0 * (StatBar.LINE_H + GAP) + UITheme.PAD * 2.0
	var y0 := vp.y - HOTBAR_MARGIN - height
	_frame.position = Vector2(bx, y0)
	_frame.size = Vector2(BAR_W + UITheme.PAD * 2.0, height)
	_clock.position = Vector2(vp.x * 0.5 + 44.0, y0)
	_temp_label.position = Vector2(vp.x * 0.5 + 104.0, y0 + 18.0)


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
