extends Node
## Décimation et repeuplement des villages (GDD 3.4 / E.25).
##
## POURQUOI CE FICHIER EXISTE. La population d'un village est DÉRIVÉE de
## (cellule, graine) : c'est ce qui permet d'entrer et sortir cent fois sans
## rien écrire sur disque, et c'est un bon choix. Mais un choix qui, tel quel,
## rend le meurtre gratuit — un habitant tué réapparaissait à la visite
## suivante, intact, et le joueur pouvait vider un village sans conséquence
## puis le retrouver plein.
##
## LA SOLUTION EST DE PERSISTER LES ABSENCES, PAS LES PRÉSENCES. On n'écrit que
## ce qui dévie de la dérivation : les rangs de roster dont l'occupant est mort.
## Le cas courant — un village intact — ne coûte rien du tout, et un monde entier
## où le joueur n'a tué personne tient dans un dictionnaire vide. C'est la même
## logique que la réputation, qui ne stocke que les relations non nulles.
##
## CE QUE ÇA DÉBLOQUE, au-delà du poids donné aux méfaits : la décimation totale
## du GDD (« un village peut être entièrement vidé », 3.4), le POI abandonné qui
## en résulte, et le repeuplement lent d'une zone pacifiée (E.25).

## Un passage hebdomadaire, comme le prescrit E.25 : 7 jours de jeu.
const WEEK_TICKS := int(DayNightManager.TICKS_PER_DAY) * 7
## `chance_repop = 0.15 * (1 - population/capacite) * (1 - corruption/100)`.
const REPOP_BASE := 0.15

## village → tableau des rangs de roster dont l'occupant est mort.
var casualties := {}

var _next_repop_tick := WEEK_TICKS


func _ready() -> void:
	TickManager.tick_world.connect(_on_tick)


func _key(cell: Vector2i) -> String:
	return "%d:%d" % [cell.x, cell.y]


## Cet habitant est-il mort ? Interrogé au peuplement : un rang mort ne fait
## apparaître personne.
func is_dead(cell: Vector2i, roster_index: int) -> bool:
	return roster_index in (casualties.get(_key(cell), []) as Array)


## Enregistre la mort d'un habitant. Idempotent : une créature peut être
## signalée morte par plusieurs chemins (coup fatal, nettoyage de tick) sans
## que le village perde deux habitants pour une seule mort.
func record_death(cell: Vector2i, roster_index: int) -> void:
	if roster_index < 0:
		return
	var key := _key(cell)
	var list: Array = casualties.get(key, [])
	if roster_index in list:
		return
	list.append(roster_index)
	casualties[key] = list
	EventBus.ui_notification.emit("ui.toast.villageois_tue")


## Nombre d'habitants encore en vie, et capacité du village.
func census(cell: Vector2i, roster_size: int) -> Dictionary:
	var lost: int = (casualties.get(_key(cell), []) as Array).size()
	return {"vivants": maxi(0, roster_size - lost), "capacite": roster_size,
		"perdus": lost}


## Un village vidé de ses habitants devient un POI ABANDONNÉ (3.4) : les
## bâtiments restent debout et persistants, mais plus personne n'y vit. On ne
## détruit donc rien — c'est justement ce qui permettra au joueur de le
## réoccuper avec ses propres recrues.
func is_abandoned(cell: Vector2i, roster_size: int) -> bool:
	return roster_size > 0 and int(census(cell, roster_size)["vivants"]) == 0


# --- Repeuplement (E.25) -----------------------------------------------------

func _on_tick(tick_index: int) -> void:
	if tick_index < _next_repop_tick:
		return
	_next_repop_tick = tick_index + WEEK_TICKS
	_repopulate_pass()


## Passage hebdomadaire sur les villages ENDEUILLÉS. On n'itère que sur eux :
## la liste est vide dans une partie normale, et parcourir le monde entier pour
## constater que tout va bien serait absurde.
##
## La formule vient d'E.25 : `0.15 × (1 − population/capacité) × pacification`.
## Un village presque plein repeuple lentement, un village vidé repeuple vite —
## et la corruption locale freine le tout, ce qui lie la démographie à la
## pression civilisatrice comme le veut le GDD.
func _repopulate_pass() -> void:
	for key: String in casualties.keys():
		var list: Array = casualties[key]
		if list.is_empty():
			casualties.erase(key)
			continue
		var capacity := _capacity_of(key)
		if capacity <= 0:
			continue
		var alive := capacity - list.size()
		var under := 1.0 - float(alive) / float(capacity)
		var chance := REPOP_BASE * under * _pacification(key)
		if randf() < chance:
			# On rend un rang au hasard : le village se repeuple, mais ce n'est
			# pas la même personne qui revient. La relation nouée avec le mort
			# reste perdue, et c'est voulu — tuer quelqu'un ne s'annule pas.
			list.remove_at(randi_range(0, list.size() - 1))
			casualties[key] = list


## Capacité (taille du roster) du village désigné par sa clé. Recalculée depuis
## la génération plutôt que stockée : deux sources pour la même valeur
## finiraient par diverger au premier ajustement du plan de village.
func _capacity_of(key: String) -> int:
	var parts := key.split(":")
	if parts.size() != 2:
		return 0
	var cell := Vector2i(int(parts[0]), int(parts[1]))
	var generator := WorldManager.generator
	if generator == null:
		return 0
	var plan: Dictionary = generator.city_at_cell(cell)
	if plan.is_empty():
		return 0
	return VillagePopulation.roster(cell, generator.world_seed, plan).size()


## Nom d'un village (12.5/E.31), dérivé de sa cellule et de la culture du
## royaume qui la tient — donc stable, jamais stocké, et cohérent avec les
## autres localités du même royaume.
##
## Les villages n'avaient AUCUN nom : la carte n'affichait qu'une pastille, et
## le journal parlait de « la cellule (-40, -30) ». Un lieu sans nom ne se
## raconte pas, et E.31 prévoyait déjà tout ce qu'il fallait.
func name_of(cell: Vector2i) -> String:
	var generator := WorldManager.generator
	if generator == null:
		return ""
	var kingdom: Dictionary = generator.kingdom_at_cell(cell)
	var culture := String(kingdom.get("culture", ""))
	if culture == "":
		# Terres sauvages : pas de royaume, donc pas de culture imposée. On
		# retombe sur la même règle que la population du village, pour que le
		# nom du lieu et celui de ses habitants sonnent pareil.
		culture = NameGenerator.culture_for_race("humain",
				NoiseGenerator.pcg_hash(cell.x, cell.y,
						generator.world_seed + VillagePopulation.SEED_POPULATION))
	return NameGenerator.town_name(culture,
			NoiseGenerator.pcg_hash(cell.x, cell.y, generator.world_seed + 5507))


## Facteur de pacification (E.20). La corruption locale n'étant pas encore
## calculée, on retourne 1.0 : un village repeuple donc à sa vitesse nominale.
## Le point d'accroche existe pour que le jour où la corruption arrivera, il n'y
## ait qu'une fonction à remplir.
func _pacification(_key: String) -> float:
	return 1.0


func save_state() -> Dictionary:
	return {"casualties": casualties.duplicate(true),
		"next_repop_tick": _next_repop_tick}


func restore_state(data: Dictionary) -> void:
	casualties = (data.get("casualties", {}) as Dictionary).duplicate(true)
	_next_repop_tick = int(data.get("next_repop_tick", WEEK_TICKS))
