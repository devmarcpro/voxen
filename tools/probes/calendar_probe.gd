extends Probe
## Sonde `--probe-calendrier` (2026-08-04) — calendrier et saisons.
##
## CE QU'ELLE DÉFEND. Le calendrier ne stocke RIEN : année, jour et saison se
## dérivent tous de `TickManager.tick_index`, comme l'heure. C'est ce qui
## garantit qu'aucune sauvegarde ne peut désynchroniser la date de l'heure — et
## c'est exactement le genre de propriété qu'une refonte casse en silence, en
## introduisant un compteur « pour aller plus vite ».
##
## Elle vérifie aussi que les quatre saisons sont ATTEIGNABLES et qu'elles se
## suivent dans l'ordre. Une erreur d'indice donnerait un monde bloqué en
## printemps perpétuel, ce qui ne planterait jamais et ne se verrait qu'au bout
## de vingt heures de jeu.

const TAG := "CALENDRIER"

var _ok := true


func _expect(condition: bool, message: String) -> void:
	print("[%s] %s — %s" % [TAG, "ok" if condition else "ÉCHEC", message])
	if not condition:
		_ok = false


func run() -> void:
	await wait_frame()
	var restore := TickManager.tick_index
	_check_derivation()
	_check_cycle()
	_check_tints()
	TickManager.tick_index = restore
	finish(_ok, TAG)


## TOUT SE DÉRIVE DU TICK. On déplace l'horloge et on vérifie que la date suit,
## dans les deux sens : un calendrier qui n'avancerait que vers le futur
## trahirait un compteur caché.
func _check_derivation() -> void:
	var day := int(DayNightManager.TICKS_PER_DAY)
	TickManager.tick_index = 0
	_expect(CalendarManager.year() == 1 and CalendarManager.day_of_year() == 1,
			"le monde commence à l'an 1, jour 1")

	TickManager.tick_index = day * 45
	_expect(CalendarManager.day_of_year() == 46,
			"45 jours plus tard, on est au jour 46 (%d)" % CalendarManager.day_of_year())

	TickManager.tick_index = day * CalendarManager.DAYS_PER_YEAR
	_expect(CalendarManager.year() == 2 and CalendarManager.day_of_year() == 1,
			"après %d jours, l'an 2 commence" % CalendarManager.DAYS_PER_YEAR)

	# RETOUR EN ARRIÈRE : le menu de triche recule l'horloge, la date doit
	# reculer avec elle.
	TickManager.tick_index = day * 10
	_expect(CalendarManager.year() == 1 and CalendarManager.day_of_year() == 11,
			"reculer l'horloge recule la date (an %d jour %d)" % [
					CalendarManager.year(), CalendarManager.day_of_year()])


## LES QUATRE SAISONS EXISTENT, DANS L'ORDRE, et couvrent l'année entière.
func _check_cycle() -> void:
	var day := int(DayNightManager.TICKS_PER_DAY)
	var seen: Array[String] = []
	for d in CalendarManager.DAYS_PER_YEAR:
		TickManager.tick_index = day * d
		var season := CalendarManager.season()
		if seen.is_empty() or seen[seen.size() - 1] != season:
			seen.append(season)
	print("[%s] sur une année : %s" % [TAG, ", ".join(seen)])
	_expect(seen.size() == 4, "les quatre saisons se succèdent une fois par an")
	_expect(seen == CalendarManager.SEASONS, "elles arrivent dans l'ordre déclaré")


## LA TEINTE SUIT LA SAISON, et l'automne se voit. Une teinte qui resterait
## blanche toute l'année laisserait le système en place sans qu'il fasse rien —
## le défaut le plus probable, et le plus invisible.
func _check_tints() -> void:
	var day := int(DayNightManager.TICKS_PER_DAY)
	var summer := 0
	var autumn := 0
	for d in CalendarManager.DAYS_PER_YEAR:
		TickManager.tick_index = day * d
		if CalendarManager.season() == "ete" and summer == 0:
			summer = d
		elif CalendarManager.season() == "automne" and autumn == 0:
			autumn = d

	# AU COEUR DE CHAQUE SAISON, jamais à son bord. La première version gardait
	# le DERNIER jour d'été — donc en plein fondu vers l'automne : elle
	# affichait « teinte été (1.30, 0.90, 0.50) », soit déjà du roux, et
	# comparait deux nuances d'automne en croyant opposer deux saisons.
	# L'assertion passait quand même, ce qui est pire que si elle avait échoué.
	TickManager.tick_index = day * (summer + CalendarManager.DAYS_PER_SEASON / 2)
	var summer_tint := CalendarManager.foliage_tint()
	# On se place au COEUR de l'automne, pas à son premier jour : le fondu de
	# fin de saison précédente pourrait encore peser sur la teinte.
	TickManager.tick_index = day * (autumn + CalendarManager.DAYS_PER_SEASON / 2)
	var autumn_tint := CalendarManager.foliage_tint()
	print("[%s] teinte été %s → automne %s" % [TAG, summer_tint, autumn_tint])
	_expect(autumn_tint.r > summer_tint.r and autumn_tint.b < summer_tint.b,
			"le feuillage d'automne tire vers le roux (plus de rouge, moins de bleu)")

	# LE FONDU : la teinte ne doit pas basculer d'un bloc à l'autre à minuit.
	var before := 0.0
	var jumps := 0
	var previous := Color.WHITE
	for step in 400:
		TickManager.tick_index = int(float(day * CalendarManager.DAYS_PER_YEAR) * float(step) / 400.0)
		var tint := CalendarManager.foliage_tint()
		if step > 0:
			var delta := absf(tint.r - previous.r) + absf(tint.g - previous.g) \
					+ absf(tint.b - previous.b)
			before = maxf(before, delta)
			if delta > 0.25:
				jumps += 1
		previous = tint
	print("[%s] plus grand saut de teinte sur une année : %.3f (%d brutal(s))" % [
			TAG, before, jumps])
	_expect(jumps == 0, "aucune bascule brutale : les saisons se fondent l'une dans l'autre")
