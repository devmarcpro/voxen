extends Node
## CALENDRIER ET SAISONS (2026-08-04, demande de l'auteur).
##
## ---------------------------------------------------------------------------
## POURQUOI CE FICHIER, ET POURQUOI IL EST SI PETIT
## ---------------------------------------------------------------------------
## Le monde avait un cycle jour/nuit et rien au-dessus : après le coucher venait
## une aube identique, indéfiniment. Aucun moyen de dire qu'on était en automne,
## donc aucun moyen de faire jaunir un feuillage, mûrir une culture, ou vieillir
## un PNJ — le GDD prévoit pourtant les trois (12.2 : « un âge qui avance avec
## le calendrier »).
##
## Ce gestionnaire ne STOCKE rien. Tout se DÉRIVE de `TickManager.tick_index`,
## exactement comme `DayNightManager` dérive l'heure du même compteur. C'est ce
## qui garantit qu'aucune sauvegarde ne peut désynchroniser la date de l'heure,
## et que reculer l'horloge au menu de triche recule aussi la saison.
##
## ---------------------------------------------------------------------------
## LES VALEURS VIENNENT DU GDD
## ---------------------------------------------------------------------------
## §12.2 pose « 1 an in-game = valeur à calibrer, défaut 120 jours ». On la prend
## telle quelle : 120 jours, quatre saisons de 30 jours. À 24 000 ticks par jour
## (E.1) et 10 ticks par seconde, une saison dure environ **20 heures de jeu
## réel** et une année 80. C'est long, et c'est voulu : une saison qui tourne en
## une soirée serait un gadget météo, pas un cycle qu'on subit.
##
## §16 listait les saisons comme extension différée (« à décider après playtest
## de la boucle agricole »). L'auteur a tranché de les faire maintenant.

## Jours d'une année (GDD 12.2, défaut annoncé).
const DAYS_PER_YEAR := 120
## Quatre saisons de longueur égale.
const SEASONS := ["printemps", "ete", "automne", "hiver"]
const DAYS_PER_SEASON := DAYS_PER_YEAR / 4

## TEINTE DU FEUILLAGE PAR SAISON, multipliée sur la couleur de palette.
##
## On TEINTE, on ne remplace pas : la couleur propre de chaque essence doit
## survivre — les 38 essences ont chacune la leur, et les écraser par un jaune
## d'automne unique effacerait tout ce travail. Un chêne roux et un hêtre cuivré
## restent distincts, ils virent seulement ensemble.
const SEASON_TINTS := {
	"printemps": Color(1.06, 1.10, 0.92),   # Pousses claires, un rien acide.
	"ete": Color(1.0, 1.0, 1.0),            # Référence : la couleur des données.
	"automne": Color(1.35, 0.88, 0.42),     # Roux. C'est la saison qui se voit.
	"hiver": Color(0.72, 0.74, 0.80),       # Terni, légèrement bleuté.
}

## Émis quand on change de saison — pour ce qui doit réagir une fois, et non
## à chaque frame (croissance des cultures, humeur, migrations).
signal season_changed(season: String)

var _last_season := ""


func _process(_delta: float) -> void:
	var now := season()
	if now == _last_season:
		return
	_last_season = now
	season_changed.emit(now)


## Jour absolu depuis le début du monde.
func total_days() -> int:
	# `TICKS_PER_DAY` est un FLOTTANT côté DayNightManager : on le repasse en
	# entier ici, sinon la division rend un flottant et le modulo plus bas ne
	# compile pas.
	return TickManager.tick_index / int(DayNightManager.TICKS_PER_DAY)


## Année en cours, à partir de 1 — personne ne date en « an 0 ».
func year() -> int:
	return total_days() / DAYS_PER_YEAR + 1


## Jour dans l'année, à partir de 1.
func day_of_year() -> int:
	return total_days() % DAYS_PER_YEAR + 1


## Saison en cours.
func season() -> String:
	var index := (day_of_year() - 1) / DAYS_PER_SEASON
	return String(SEASONS[clampi(index, 0, SEASONS.size() - 1)])


## Avancement dans la saison, de 0 à 1. Sert aux transitions continues : une
## saison qui bascule d'un bloc à l'autre se remarque comme un défaut.
func season_progress() -> float:
	var day_in_season := (day_of_year() - 1) % DAYS_PER_SEASON
	var within_day := float(TickManager.tick_index % int(DayNightManager.TICKS_PER_DAY)) \
			/ float(DayNightManager.TICKS_PER_DAY)
	return (float(day_in_season) + within_day) / float(DAYS_PER_SEASON)


## Teinte de feuillage à appliquer MAINTENANT, interpolée avec la saison
## suivante sur le dernier quart de la saison courante.
##
## Sans ce fondu, tout le feuillage du monde changerait de couleur d'un seul
## coup à minuit. La nature ne fait pas ça, et le joueur qui regarde une forêt
## à ce moment-là verrait un défaut d'affichage, pas un changement de saison.
func foliage_tint() -> Color:
	var current: Color = SEASON_TINTS[season()]
	var progress := season_progress()
	if progress < 0.75:
		return current
	var next_index := (SEASONS.find(season()) + 1) % SEASONS.size()
	var next: Color = SEASON_TINTS[SEASONS[next_index]]
	return current.lerp(next, (progress - 0.75) / 0.25)


## Date lisible, pour l'interface et les journaux.
func date_string() -> String:
	return "%s, jour %d de l'an %d" % [
			tr("season.%s.name" % season()), day_of_year(), year()]
