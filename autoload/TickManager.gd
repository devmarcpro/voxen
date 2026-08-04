extends Node
## TickManager — seule source d'avancement du temps de jeu (5.0, D.2, E.1).
## 10 ticks/s en temps réel ; en mode tactique, les ticks ne sont émis que
## lorsqu'une action de joueur consomme du temps.
## Aucun système de gameplay n'utilise _process(delta) : tous s'abonnent aux
## signaux de phase — delta reste réservé au purement visuel.
##
## PHASES (2026-07-27) : l'ordre du tick était documenté (« entités → monde →
## dispatch → réseau ») mais rien ne l'appliquait — l'ordre réel était celui de
## connexion des signaux, donc l'ordre de déclaration des autoloads. Avec les
## fluides, la fertilité et l'intégrité structurelle à venir, un ordre implicite
## produit des bugs d'un seul tick impossibles à reproduire (une créature qui
## agit sur un bloc que le monde n'a pas encore mis à jour, ou l'inverse).

## Phase 1 — entités : joueur, créatures, PNJ, projectiles. Elles LISENT le
## monde et déposent leurs intentions.
@warning_ignore("unused_signal")
signal tick_entities(tick_index: int)
## Phase 2 — monde : fluides, intégrité structurelle, croissance/fertilité,
## boutiques, donjons. Elles ÉCRIVENT le monde, via
## WorldManager.set_block_batched() — jamais set_block().
@warning_ignore("unused_signal")
signal tick_world(tick_index: int)
## Phase 3 — après flush : exploration, autosave, réseau, UI. Le monde est
## stable et remaillé, tout est cohérent pour la lecture.
@warning_ignore("unused_signal")
signal tick_post(tick_index: int)

## LEGACY (à migrer) : ancien signal unique, émis en tête de phase 1 pour ne rien
## casser pendant la transition. Chaque abonné doit basculer vers la phase qui le
## concerne, après quoi ce signal disparaîtra.
@warning_ignore("unused_signal")
signal tick(tick_index: int)

const TICKS_PER_SECOND := 10
const TICK_DT := 0.1
## Garde-fou : nombre max de ticks rattrapés sur une même frame (évite la
## spirale de rattrapage après un gel de la fenêtre).
const MAX_CATCHUP := 10

## Budget d'un tick complet (G.8 : aucune frame > 16 ms). Un tick qui le dépasse
## fait forcément rater sa frame, puisqu'il s'exécute DANS une frame.
const TICK_BUDGET_US := 16000
## Anti-spam : une alerte au plus toutes les N secondes réelles. Un tick lourd
## l'est généralement plusieurs ticks d'affilée — dix lignes par seconde noient
## la console sans rien apprendre de plus.
const WARN_COOLDOWN_SEC := 2.0

## Compteur global de ticks — sert aussi d'horloge calendaire (E.1 :
## 1 jour in-game = 24 000 ticks, 1 semaine = 7 jours).
var tick_index: int = 0
## Mode tactique (5.0) : true = les ticks n'avancent plus avec l'horloge.
var tactical_mode := false
## Instrumentation : quatre Time.get_ticks_usec() par tick, à 10 Hz, sont
## gratuits — la couper coûterait plus cher en branches qu'elle ne rapporte.
var profiling := true

var _accumulator := 0.0
## Coût du DERNIER tick par phase, en µs (lu par le HUD et les benchs).
var phase_us := {"entities": 0, "world": 0, "flush": 0, "post": 0}
var _last_total_us := 0
var _max_total_us := 0
var _last_warn_msec := 0


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


## Signal émis quand du temps de jeu passe SANS être simulé (voyage rapide).
## Les systèmes dont l'état évolue linéairement avec le temps — faim, fatigue,
## régénération de mana — doivent rattraper en forme close ; les autres n'ont
## rien à faire.
signal ticks_skipped(count: int)


## AVANCE L'HORLOGE SANS SIMULER (2026-08-03, voyage rapide instantané).
##
## `push_ticks` simule chaque tick, ce qui est juste pour le coût d'une action
## en mode tactique — quelques ticks. Le voyage rapide, lui, coûte 6 ticks par
## bloc : traverser 500 blocs, c'est 3 000 ticks. Les simuler, c'était :
##   - faire tourner l'IA de toutes les créatures 3 000 fois pour rien ;
##   - peupler puis relâcher CHAQUE village survolé, d'où les pics de tick
##     à 62 ms et les erreurs en cascade relevés en jeu ;
##   - et geler la partie plusieurs secondes.
##
## L'heure du jour se recalcule depuis `tick_index` (DayNightManager), donc
## l'avancer suffit pour elle. Le reste est prévenu par `ticks_skipped`.
func skip_ticks(count: int) -> void:
	if count <= 0:
		return
	tick_index += count
	ticks_skipped.emit(count)


func _run_tick() -> void:
	tick_index += 1
	var t0 := Time.get_ticks_usec()

	# --- Phase 1 : entités (lecture du monde) ---
	tick.emit(tick_index)            # LEGACY, à retirer une fois les abonnés migrés
	tick_entities.emit(tick_index)
	var t1 := Time.get_ticks_usec()

	# --- Phase 2 : systèmes du monde (écriture BATCHÉE du monde) ---
	tick_world.emit(tick_index)
	var t2 := Time.get_ticks_usec()

	# --- Flush : UN remesh par chunk touché, quel que soit le nombre de blocs
	# écrits pendant la phase monde. C'est ce qui rend les fluides et l'intégrité
	# structurelle tenables (voir WorldManager.set_block_batched).
	if WorldManager.has_batched_edits():
		WorldManager.flush_batched_edits()
	var t3 := Time.get_ticks_usec()

	# --- Phase 3 : après-coup (monde stable et remaillé) ---
	tick_post.emit(tick_index)
	var t4 := Time.get_ticks_usec()

	if not profiling:
		return
	phase_us["entities"] = t1 - t0
	phase_us["world"] = t2 - t1
	phase_us["flush"] = t3 - t2
	phase_us["post"] = t4 - t3
	_last_total_us = t4 - t0
	_max_total_us = maxi(_max_total_us, _last_total_us)
	if _last_total_us > TICK_BUDGET_US:
		var now := Time.get_ticks_msec()
		if now - _last_warn_msec >= int(WARN_COOLDOWN_SEC * 1000.0):
			_last_warn_msec = now
			# Le détail par phase est tout l'intérêt de l'alerte : « le tick dure
			# 30 ms » n'apprend rien, « le flush dure 27 ms » désigne le coupable.
			push_warning("[TICK %d] %.1f ms > budget %.0f ms — entités %.1f | monde %.1f | flush %.1f | post %.1f" % [
				tick_index, _last_total_us / 1000.0, TICK_BUDGET_US / 1000.0,
				phase_us["entities"] / 1000.0, phase_us["world"] / 1000.0,
				phase_us["flush"] / 1000.0, phase_us["post"] / 1000.0])


## Statistiques pour le HUD et les benchs (même forme que WorldManager.stats()).
func stats() -> Dictionary:
	return {
		"tick": tick_index,
		"last_ms": _last_total_us / 1000.0,
		"max_ms": _max_total_us / 1000.0,
		"entities_ms": phase_us["entities"] / 1000.0,
		"world_ms": phase_us["world"] / 1000.0,
		"flush_ms": phase_us["flush"] / 1000.0,
		"post_ms": phase_us["post"] / 1000.0,
	}


## Remise à zéro du pic (début de mesure d'un bench).
func reset_profile() -> void:
	_max_total_us = 0
