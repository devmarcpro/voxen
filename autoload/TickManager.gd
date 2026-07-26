extends Node
## TickManager — seule source d'avancement du temps de jeu (5.0, D.2, E.1).
## 10 ticks/s en temps réel ; en mode tactique, les ticks ne sont émis que
## lorsqu'une action de joueur consomme du temps (implémenté à l'étape combat).
## Aucun système de gameplay n'utilise _process(delta) : tous s'abonnent au
## signal `tick` — delta reste réservé au purement visuel.

## Émis à chaque tick de simulation.
signal tick(tick_index: int)

const TICKS_PER_SECOND := 10
const TICK_DT := 0.1
## Garde-fou : nombre max de ticks rattrapés sur une même frame (évite la
## spirale de rattrapage après un gel de la fenêtre).
const MAX_CATCHUP := 10

## Compteur global de ticks — sert aussi d'horloge calendaire (E.1 :
## 1 jour in-game = 24 000 ticks, 1 semaine = 7 jours).
var tick_index: int = 0
## Mode tactique (5.0) : true = les ticks n'avancent plus avec l'horloge.
var tactical_mode := false

var _accumulator := 0.0


func _process(delta: float) -> void:
	# NOTE : ceci est le SEUL usage légitime de _process pour du temps de jeu —
	# il ne fait que convertir l'horloge réelle en ticks (E.1).
	if tactical_mode:
		return
	_accumulator += delta
	var caught_up := 0
	while _accumulator >= TICK_DT and caught_up < MAX_CATCHUP:
		_accumulator -= TICK_DT
		caught_up += 1
		_run_tick()
	if caught_up >= MAX_CATCHUP:
		_accumulator = 0.0


## Pousse N ticks immédiatement (mode tactique : coût d'une action, E.1).
func push_ticks(count: int) -> void:
	for i in count:
		_run_tick()


func _run_tick() -> void:
	tick_index += 1
	# Ordre d'un tick (E.1) : 1. entités → 2. systèmes du monde →
	# 3. dispatch EventBus → 4. réseau. Les phases se rempliront au fil
	# des étapes de D.3 ; pour l'instant un seul signal suffit.
	tick.emit(tick_index)
