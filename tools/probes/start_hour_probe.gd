extends Probe
## Sonde `--probe-heure` (2026-07-28) : une PARTIE NEUVE doit démarrer à 8 h du
## matin (DayNightManager.START_HOUR), pas à minuit.
##
## Deux chemins de création existent et doivent concorder :
##  - `SaveManager.prepare_new_world()` — menu de démarrage (vraie nouvelle partie) ;
##  - `SaveManager.prepare_default_if_needed()` — mode direct (benchs, captures).
## Le second avait été oublié dans un premier correctif : il posait `active_config`
## sans toucher à l'horloge, et repartait donc de 0 h.

func run() -> void:
	await wait_seconds(0.3)
	var target: float = DayNightManager.START_HOUR
	var expected_tick: int = DayNightManager.start_tick()

	# Chemin 1 — mode direct (celui emprunté par cette sonde au démarrage).
	# ATTENTION : ce chemin CHARGE le monde par défaut s'il existe déjà sur
	# disque, et restaure alors son heure sauvegardée — ce qui est le
	# comportement voulu. L'heure de départ ne s'applique qu'à un monde NEUF, on
	# ne juge donc ce chemin que dans ce cas (piège d'assertion rencontré en
	# écrivant cette sonde : un monde par défaut laissé par un bench précédent
	# faisait échouer le test alors que le code était correct).
	var h_direct: float = DayNightManager.hour()
	var phase_direct: String = DayNightManager.phase()
	var direct_was_loaded: bool = SaveManager.world_loaded
	print("[HEURE] direct : tick=%d heure=%.2f phase=%s (monde chargé=%s)" % [
		TickManager.tick_index, h_direct, phase_direct, direct_was_loaded])

	# Chemin 2 — création explicite par le menu. Sans danger pour les sauvegardes
	# du joueur : `--probe-heure` figure dans SaveManager.DISABLED_ARGS, donc
	# aucune écriture disque n'a lieu (voir le commentaire là-bas — l'oubli de
	# cette entrée avait créé de vrais mondes bidons et détourné `dernier.json`).
	SaveManager.prepare_new_world("sonde_heure", 1337, {})
	var h_menu: float = DayNightManager.hour()
	var phase_menu: String = DayNightManager.phase()
	print("[HEURE] menu   : tick=%d heure=%.2f phase=%s" % [
		TickManager.tick_index, h_menu, phase_menu])

	print("[HEURE] attendu : tick=%d heure=%.2f (phase « jour » = %.0f h-%.0f h)" % [
		expected_tick, target, DayNightManager.HOUR_DAY, DayNightManager.HOUR_DUSK])

	# Tolérance : quelques ticks peuvent s'être écoulés depuis le démarrage.
	var ok := absf(h_menu - target) < 0.1 and phase_menu == "jour"
	if not direct_was_loaded:
		# Monde par défaut NEUF : il doit lui aussi démarrer en pleine journée.
		ok = ok and phase_direct == "jour"
	else:
		print("[HEURE] chemin direct non jugé : monde existant chargé, son heure sauvegardée prime.")
	finish(ok, "HEURE")
