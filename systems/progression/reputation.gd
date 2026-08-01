class_name Reputation
extends RefCounted
## Réputation et relations (GDD 7.2), sur l'échelle −100..+100.
##
## QUATRE NIVEAUX EN PARALLÈLE, comme le GDD les pose :
##   - RELATION INDIVIDUELLE avec un PNJ donné ;
##   - réputation par RACE ;
##   - réputation par ROYAUME (14.4/E.27) — le niveau que le GDD nomme
##     explicitement, désormais réel ;
##   - réputation par VILLAGE, plus fine que le royaume et conservée : une
##     bourgade se souvient de ce que la cour ignore, et c'est elle qu'on croise
##     en jeu. Un village en terre sauvage n'a d'ailleurs pas de royaume du tout ;
##   - réputation GLOBALE, toutes factions confondues.
##
## Ce qui compte pour une décision donnée n'est jamais un seul de ces quatre :
## `standing_with()` les combine. Un inconnu n'est pas neutre — il vous juge sur
## votre réputation.
##
## LA PERSISTANCE PAR ÉCART, et pourquoi. Les habitants d'un village ne sont pas
## sauvegardés : leur composition est dérivée de (cellule, graine), ce qui
## permet d'entrer et sortir cent fois sans rien écrire. Une relation
## individuelle ne peut donc pas vivre sur l'instance de créature — elle
## disparaîtrait au premier éloignement. Elle est stockée ici, sous une CLÉ
## STABLE dérivée du village et du rang dans le roster, et seuls les écarts au
## défaut (zéro) occupent de la place. Un monde où le joueur n'a parlé à
## personne ne coûte rien du tout.

## Bornes de l'échelle (7.2).
const MIN := -100.0
const MAX := 100.0

## Seuils de palier, copiés du GDD :
##   ≤ −50            hostile à vue (gardes et civils fuient ou attaquent)
##   −49 .. −20       prix +25 %, quêtes refusées
##   −19 .. +19       neutre
##   +20 .. +49       prix −10 %
##   ≥ +50            quêtes spéciales, rumeurs, recrutement facilité
const HOSTILE := -50.0
const MEFIANT := -20.0
const AMICAL := 20.0
const DEVOUE := 50.0

## Part de la réputation collective qui pèse sur un individu qu'on n'a jamais
## croisé. Volontairement forte pour la race et le village — c'est ce qui donne
## sa portée à une mauvaise action : massacrer un village doit se savoir.
const WEIGHT_INDIVIDUAL := 1.0
const WEIGHT_VILLAGE := 0.5
const WEIGHT_KINGDOM := 0.4
const WEIGHT_RACE := 0.35
const WEIGHT_GLOBAL := 0.25

## Report d'un gain individuel sur les échelons collectifs. Une bonne action
## envers UN villageois rejaillit un peu sur son village et sa race, sinon la
## réputation collective ne bougerait jamais que par des événements scriptés.
const SPILL_VILLAGE := 0.35
const SPILL_KINGDOM := 0.25
const SPILL_RACE := 0.15
const SPILL_GLOBAL := 0.10

## −25 % du gain appliqué aux rivaux déclarés (7.2 : « pas de cascade au-delà
## d'un degré »). `rivals` vit dans data/races/ (B.9) ; aucune race n'en déclare
## encore, le mécanisme attend donc ses données sans rien coûter.
const RIVAL_BACKLASH := -0.25

var individuals := {}   # clé stable → float
var villages := {}      # "x:z" → float
var kingdoms := {}      # id de royaume → float
var races := {}         # id de race → float
var global := 0.0


## Clé stable d'un habitant : village + rang dans le roster. Le roster étant
## déterministe, ce couple désigne toujours la même personne — c'est ce qui
## permet de retrouver une relation après avoir quitté la région.
static func resident_key(cell: Vector2i, roster_index: int) -> String:
	return "%d:%d#%d" % [cell.x, cell.y, roster_index]


static func village_key(cell: Vector2i) -> String:
	return "%d:%d" % [cell.x, cell.y]


func individual(key: String) -> float:
	return float(individuals.get(key, 0.0))


func village(cell: Vector2i) -> float:
	return float(villages.get(village_key(cell), 0.0))


func race(race_id: String) -> float:
	return float(races.get(race_id, 0.0))


func kingdom(kingdom_id: String) -> float:
	return float(kingdoms.get(kingdom_id, 0.0))


## Ce qu'une créature donnée pense du joueur, tous niveaux confondus.
##
## Une créature sans clé individuelle (une bête, un civil hors village) est
## jugée sur les seuls échelons collectifs : c'est exactement ce qu'on veut,
## un inconnu n'a pas d'avis personnel mais il a entendu parler de vous.
func standing_with(key: String, cell: Vector2i, race_id: String,
		kingdom_id: String = "") -> float:
	var total := individual(key) * WEIGHT_INDIVIDUAL \
		+ village(cell) * WEIGHT_VILLAGE \
		+ kingdom(kingdom_id) * WEIGHT_KINGDOM \
		+ race(race_id) * WEIGHT_RACE \
		+ global * WEIGHT_GLOBAL
	return clampf(total, MIN, MAX)


## Palier lisible d'une valeur : "hostile", "mefiant", "neutre", "amical",
## "devoue". Un seul endroit décide des seuils — les comparer à la main ailleurs
## ferait diverger l'UI et les règles au premier ajustement.
static func tier(value: float) -> String:
	if value <= HOSTILE:
		return "hostile"
	if value < MEFIANT:
		return "mefiant"
	if value < AMICAL:
		return "neutre"
	if value < DEVOUE:
		return "amical"
	return "devoue"


## Multiplicateur de PRIX appliqué à ce qu'on achète (7.2). Un marchand méfiant
## majore, un marchand acquis consent une remise.
static func price_factor(value: float) -> float:
	match tier(value):
		"hostile", "mefiant":
			return 1.25
		"amical", "devoue":
			return 0.90
	return 1.0


## Enregistre une action envers un habitant : la relation individuelle bouge de
## `amount`, et une fraction rejaillit sur son village, sa race et la réputation
## globale. Retourne la nouvelle relation individuelle.
func record(key: String, cell: Vector2i, race_id: String, amount: float,
		kingdom_id: String = "") -> float:
	if amount == 0.0:
		return individual(key)
	if key != "":
		individuals[key] = clampf(individual(key) + amount, MIN, MAX)
	_add_village(cell, amount * SPILL_VILLAGE)
	if kingdom_id != "":
		kingdoms[kingdom_id] = clampf(kingdom(kingdom_id) + amount * SPILL_KINGDOM,
			MIN, MAX)
	_add_race(race_id, amount * SPILL_RACE)
	global = clampf(global + amount * SPILL_GLOBAL, MIN, MAX)
	# Contrecoup chez les rivaux déclarés de la race concernée.
	var data: Dictionary = GameData.races.get(race_id, {})
	for rival: Variant in (data.get("rivals", []) as Array):
		_add_race(String(rival), amount * SPILL_RACE * RIVAL_BACKLASH)
	return individual(key)


func _add_village(cell: Vector2i, amount: float) -> void:
	var key := village_key(cell)
	villages[key] = clampf(float(villages.get(key, 0.0)) + amount, MIN, MAX)


func _add_race(race_id: String, amount: float) -> void:
	if race_id == "":
		return
	races[race_id] = clampf(float(races.get(race_id, 0.0)) + amount, MIN, MAX)


func save_state() -> Dictionary:
	return {"individuals": individuals.duplicate(), "villages": villages.duplicate(),
		"kingdoms": kingdoms.duplicate(), "races": races.duplicate(), "global": global}


func restore_state(data: Dictionary) -> void:
	individuals = (data.get("individuals", {}) as Dictionary).duplicate()
	villages = (data.get("villages", {}) as Dictionary).duplicate()
	kingdoms = (data.get("kingdoms", {}) as Dictionary).duplicate()
	races = (data.get("races", {}) as Dictionary).duplicate()
	global = float(data.get("global", 0.0))
