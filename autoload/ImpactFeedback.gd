extends Node
## Retour d'impact du combat — le POIDS des coups (2026-08-02).
##
## POURQUOI CE FICHIER EXISTE. Le combat directionnel était mécaniquement
## complet — sweet spot, bonus de vitesse, parade directionnelle, chambering —
## et pourtant « les coups n'ont pas de poids » (retour de l'auteur). C'était
## exact, et ce n'était pas un problème de mécanique : à l'instant du contact,
## RIEN ne se passait à l'écran. La lame traversait la cible à vitesse
## constante, la caméra ne bronchait pas, et un chiffre montait quelque part.
##
## Le contact est pourtant le seul instant où le joueur apprend quoi que ce
## soit : c'est là qu'il découvre s'il a touché avec le fer ou avec le manche,
## s'il avançait ou reculait, si la garde adverse a tenu. Sans réaction
## perceptible, toute la finesse du modèle de dégâts reste invisible.
##
## DEUX EFFETS, ET DÉLIBÉRÉMENT PAS TROIS.
##
##   1. LE HIT-STOP. La progression du geste se fige quelques dizaines de
##      millisecondes au contact. C'est ce qui donne à la lame l'impression de
##      MORDRE au lieu de traverser. C'est le plus gros contributeur au poids
##      ressenti, et de loin le moins cher.
##   2. LA SECOUSSE DE CAMÉRA. Une impulsion brève, d'amplitude proportionnelle
##      à la violence du contact, qui retombe toute seule.
##
## Le troisième — le SON — n'est pas ici : le projet n'a aucun système audio, et
## en improviser un dans le fichier du retour d'impact produirait un bus audio
## sans réglage de volume ni sourdine. Il viendra comme système à part entière.
##
## POURQUOI PAS `Engine.time_scale`. C'est la façon habituelle de faire un
## hit-stop, et elle est INTERDITE ici. TickManager convertit `delta` en ticks
## de jeu (`_process`, accumulateur) : ralentir l'horloge du moteur ralentirait
## l'horloge du MONDE — fluides, croissance, IA, calendrier — et, en réseau,
## ferait diverger ce client de tous les autres. Le hit-stop de ce fichier est
## donc LOCAL : il ne fige que l'avancement du geste de son porteur, et le
## temps de jeu continue, inchangé, à 10 Hz.
##
## Ce fichier ne décide de RIEN dans le combat. Il ne connaît ni dégâts, ni
## endurance, ni créature : il reçoit un événement de contact déjà résolu et en
## produit une conséquence purement perceptive. On peut le débrancher en entier
## sans changer l'issue d'un seul échange.

## Nature du contact. Chacune a un poids distinct parce que chacune apprend
## quelque chose de différent au joueur — les confondre reviendrait à ne rien
## lui dire.
const IMPACT_CHAIR := "chair"          # le fer entre : le coup a porté
const IMPACT_ARMURE := "armure"        # métal contre métal : ça a porté, mais ça a résisté
const IMPACT_GLISSANT := "glissant"    # frappé au manche : erreur de distance
const IMPACT_PARE := "pare"            # la garde adverse a tenu
const IMPACT_ECRASE := "ecrase"        # crushthrough : la garde a cédé
const IMPACT_CHAMBRE := "chambre"      # les deux lames s'entrechoquent

## Poids de chaque contact : durée du hit-stop (s) et secousse de base (0..1).
##
## L'ORDRE N'EST PAS L'ORDRE DES DÉGÂTS, et c'est voulu. Un chambering
## n'inflige rien et secoue le plus ; un coup glissant n'inflige rien non plus
## et secoue le moins. Ce qu'on met en scène, ce n'est pas le nombre de points
## de vie perdus — c'est l'ÉVÉNEMENT, sa rareté et sa violence mécanique. Un
## duel se lit à ses instants remarquables, pas à son arithmétique.
const WEIGHT := {
	IMPACT_CHAIR:    {"stop": 0.055, "shake": 0.30},
	IMPACT_ARMURE:   {"stop": 0.075, "shake": 0.44},
	IMPACT_GLISSANT: {"stop": 0.025, "shake": 0.12},
	IMPACT_PARE:     {"stop": 0.090, "shake": 0.50},
	IMPACT_ECRASE:   {"stop": 0.100, "shake": 0.66},
	IMPACT_CHAMBRE:  {"stop": 0.110, "shake": 0.60},
}

## Amplitude maximale de la secousse, en radians (~2,6°). Volontairement
## MODESTE : la caméra est aussi le réticule. Une secousse qui déplace la visée
## ferait rater le coup suivant, et punirait donc le joueur d'avoir réussi le
## précédent.
const MAX_SHAKE_ANGLE := 0.046
## Retour au calme, par seconde. La secousse doit être finie avant que le geste
## suivant soit armable, sinon elle se cumule d'un coup à l'autre.
const TRAUMA_DECAY := 3.4
## Fréquences des trois axes de secousse, en Hz. Premières différentes et non
## harmoniques : le mouvement ne se répète pas et ne dégénère pas en oscillation
## régulière, qui se lirait comme une panne d'affichage plutôt qu'un choc.
const SHAKE_FREQ := Vector3(29.0, 23.0, 17.0)

## Plafond du multiplicateur de force. Un coup parfait (sweet spot au fer, en
## pleine charge, à la tête) ne doit pas quintupler la secousse : au-delà, on ne
## lit plus rien et le joueur perd sa cible.
const MAX_FORCE := 2.0

## Secousse courante, 0..1. L'amplitude suit son CARRÉ (modèle de Eiserloh) :
## les petits chocs restent discrets, les gros dominent nettement.
var trauma := 0.0
## Temps de hit-stop restant, exprimé dans le `delta` du geste qui le subit.
var _stop_left := 0.0
## Un geste a-t-il prélevé du figement depuis la dernière frame ? Sert à jeter
## les figements que personne ne consomme (voir _process).
var _consumed_last_frame := false
var _time := 0.0
## Réglage joueur, 0 = aucune secousse (confort visuel / mal des transports).
## Relu à chaque impact plutôt que mis en cache : le menu doit pouvoir le
## changer en plein combat et que ça s'entende immédiatement.
var _shake_scale := 1.0


func _ready() -> void:
	EventBus.combat_impact.connect(_on_impact)
	SettingsManager.setting_changed.connect(_on_setting_changed)
	_reload_settings()


func _on_setting_changed(section: String, key: String, _value: Variant) -> void:
	if section == "combat" and key == "secousse_camera":
		_reload_settings()


func _reload_settings() -> void:
	_shake_scale = clampf(float(SettingsManager.get_value(
		"combat", "secousse_camera", 1.0)), 0.0, 1.0)


## Un contact vient d'être résolu. `force` est le produit des multiplicateurs
## offensifs (zone × sweet spot × vitesse) : 1 = coup nominal.
func _on_impact(kind: String, _world_position: Vector3, force: float) -> void:
	var weight: Dictionary = WEIGHT.get(kind, WEIGHT[IMPACT_CHAIR])
	var scaled := clampf(force, 0.25, MAX_FORCE)
	# Le hit-stop suit la force en RACINE, pas linéairement : un coup deux fois
	# plus fort ne doit pas figer le jeu deux fois plus longtemps — au-delà
	# d'une centaine de millisecondes, le figement cesse d'être un impact et
	# devient une saccade.
	_stop_left = maxf(_stop_left, float(weight["stop"]) * sqrt(scaled))
	trauma = clampf(trauma + float(weight["shake"]) * scaled * _shake_scale, 0.0, 1.0)


func _process(delta: float) -> void:
	# Le temps et la secousse sont PUREMENT VISUELS : ils suivent l'horloge des
	# frames. Le hit-stop, lui, n'est PAS décompté ici — voir `consume_freeze`.
	_time += delta
	if trauma > 0.0:
		trauma = maxf(0.0, trauma - TRAUMA_DECAY * delta)
	# FIGEMENT PÉRIMÉ. Un figement n'a de sens que pour un geste EN COURS. Or on
	# encaisse aussi des coups sans être en train d'attaquer : sans cette purge,
	# ce figement-là resterait en réserve et viendrait geler le DÉBUT de la
	# prochaine attaque — le joueur paierait au hasard, plusieurs secondes plus
	# tard, un coup qu'il a subi et déjà oublié.
	#
	# On laisse une frame entière pour le consommer (le porteur du geste avance
	# dans son propre `_process`, dont l'ordre vis-à-vis de celui-ci n'est pas
	# garanti), puis on jette.
	if _stop_left > 0.0:
		if not _consumed_last_frame:
			_stop_left = 0.0
		_consumed_last_frame = false


## Absorbe le hit-stop sur le delta d'un geste et retourne CE QU'IL EN RESTE.
##
## POURQUOI CETTE FORME, ET PAS UN SIMPLE `is_frozen()`. La première version
## décomptait le figement dans `_process` et exposait un booléen ; le porteur du
## geste s'arrêtait tant qu'il était vrai. Deux horloges différentes décidaient
## donc du même instant — celle des frames du moteur et celle du `delta` passé
## à la machine à états. Elles ne coïncident pas dès qu'on ne les fait pas
## avancer ensemble : la sonde de combat, qui pompe des deltas simulés sans
## laisser passer de vraies frames, restait figée POUR TOUJOURS. Onze
## vérifications sont tombées d'un coup, et à juste titre : le geste n'avançait
## plus du tout. En jeu, le même défaut se serait manifesté plus discrètement,
## à chaque écart entre le framerate réel et le temps simulé.
##
## Ici il n'y a plus qu'UNE horloge : celle du geste lui-même. Le figement est
## exprimé dans la monnaie de celui qui le subit, et il se draine exactement au
## rythme où ce geste aurait avancé. Un figement de 55 ms coûte 55 ms de geste,
## que le jeu tourne à 30 ou à 240 images par seconde.
##
## Le joueur continue par ailleurs de tourner la tête et de se déplacer pendant
## le figement : seul l'avancement de l'attaque est suspendu. Figer le joueur
## entier lui arracherait le contrôle en récompense d'avoir touché.
func consume_freeze(delta: float) -> float:
	if _stop_left <= 0.0:
		return delta
	_consumed_last_frame = true
	var used := minf(_stop_left, delta)
	_stop_left -= used
	return delta - used


## Décalage angulaire à ajouter à l'orientation de la caméra, en radians
## (tangage, lacet, roulis). Purement additif : la caméra ne doit JAMAIS
## réinjecter ce décalage dans son propre lacet/tangage, sinon la secousse
## déplacerait durablement la visée au lieu de revenir à zéro.
func camera_shake() -> Vector3:
	if trauma <= 0.0:
		return Vector3.ZERO
	var amount := MAX_SHAKE_ANGLE * trauma * trauma
	return Vector3(
		amount * _wobble(SHAKE_FREQ.x, 0.0),
		amount * _wobble(SHAKE_FREQ.y, 1.7),
		amount * _wobble(SHAKE_FREQ.z, 3.1) * 1.4)


## Oscillation pseudo-aléatoire bornée à [-1, 1]. Deux sinus de fréquences
## incommensurables suffisent : c'est indiscernable d'un bruit sur les ~300 ms
## que dure une secousse, et cela ne coûte ni ressource `Noise`, ni tirage.
func _wobble(frequency: float, phase: float) -> float:
	return sin(_time * frequency + phase) * 0.75 \
		+ sin(_time * frequency * 0.37 + phase * 2.3) * 0.25
