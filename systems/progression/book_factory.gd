class_name BookFactory
extends RefCounted
## Grimoires et manuels de combat (GDD 5.1 / A.7) — 2026-08-02.
##
## LES MODULES NE SE CRAFTENT PAS. Ils s'obtiennent en LISANT des livres,
## trouvés en donjon ou achetés. Un livre est GÉNÉRÉ ALÉATOIREMENT : il tire un
## domaine, une difficulté et la liste des modules qu'il contient. Plus il est
## puissant, plus il est difficile à lire — et une lecture peut ÉCHOUER.
##
## DEUX TYPES, et la distinction vient des données et non d'ici : chaque module
## déclare son `book_type` (« grimoire » pour les sorts, « manuel » pour les
## armes) et ses `grimoire_domains`. Le schéma des modules les portait déjà bien
## avant que les livres n'existent ; ce fichier ne fait que s'en servir.
##
## Un livre est à USAGE UNIQUE : consommé à la lecture, réussite ou échec.

## Difficulté d'un livre, bornée. Elle pilote à la fois le DD du jet (A.7) et la
## richesse du contenu — un livre facile donne peu, un livre redoutable donne
## beaucoup mais se refuse longtemps au joueur.
const MIN_DIFFICULTY := 4
const MAX_DIFFICULTY := 40
## Modules contenus, selon la difficulté.
const MIN_MODULES := 1
const MAX_MODULES := 5


## Tous les modules d'un type de livre (« grimoire » ou « manuel »), triés.
## Le tri est nécessaire au déterminisme : l'ordre d'itération d'un Dictionary
## Godot suit l'insertion, donc l'ordre de lecture des fichiers.
static func modules_of_type(book_type: String) -> Array[String]:
	var out: Array[String] = []
	for id: String in GameData.modules:
		var module: Dictionary = GameData.modules[id]
		if String(module.get("book_type", "grimoire")) != book_type:
			continue
		# UN DOMAINE EST OBLIGATOIRE pour être enseigné (C.6 : « chaque livre
		# tire son domaine, qui filtre les modules qu'il contient »). Sans ce
		# garde, `morsure_simple` — l'attaque des créatures, sans domaine, à 0
		# mana et 0 puissance — se retrouvait distribuée par les manuels de
		# combat comme récompense de donjon.
		if (module.get("grimoire_domains", []) as Array).is_empty():
			continue
		out.append(id)
	out.sort()
	return out


## Domaines disponibles pour un type de livre, tirés des modules eux-mêmes.
static func domains_of_type(book_type: String) -> Array[String]:
	var seen := {}
	for id: String in modules_of_type(book_type):
		for domain: String in ((GameData.modules[id] as Dictionary).get("grimoire_domains", []) as Array):
			seen[domain] = true
	var out: Array[String] = []
	for domain: String in seen:
		out.append(domain)
	out.sort()
	return out


## Génère une instance de livre.
##
## `power` (0..1) module la difficulté : c'est par lui que la profondeur d'un
## donjon se traduit en qualité de butin (E.29 : « le loot croît avec la
## profondeur »). L'appelant décide, la fabrique ne connaît pas les donjons.
static func create(book_type: String, power: float, rng: RandomNumberGenerator) -> Dictionary:
	var pool := modules_of_type(book_type)
	if pool.is_empty():
		return {}
	var item_id := "grimoire" if book_type == "grimoire" else "manuel_de_combat"
	var difficulty := int(round(lerpf(float(MIN_DIFFICULTY), float(MAX_DIFFICULTY), clampf(power, 0.0, 1.0))))

	# Domaine : il FILTRE les modules du livre (GDD C.6/B.4). Un livre qui
	# piocherait au hasard dans tout le catalogue n'aurait aucune identité, et
	# la notion de domaine ne servirait à rien.
	var domains := domains_of_type(book_type)
	var domain := "" if domains.is_empty() else domains[rng.randi() % domains.size()]
	var candidates: Array[String] = []
	for id in pool:
		var doms: Array = (GameData.modules[id] as Dictionary).get("grimoire_domains", [])
		if domain == "" or domain in doms:
			candidates.append(id)
	if candidates.is_empty():
		candidates = pool

	# Contenu : un livre difficile contient davantage de modules.
	var count := clampi(int(round(lerpf(float(MIN_MODULES), float(MAX_MODULES), clampf(power, 0.0, 1.0)))),
			MIN_MODULES, MAX_MODULES)
	var modules: Array[String] = []
	for i in count:
		var pick: String = candidates[rng.randi() % candidates.size()]
		# Un même module PEUT figurer deux fois : le lire à nouveau le fait
		# monter en niveau (5.1 : « les modules montent de niveau à l'usage »),
		# ce n'est donc pas un doublon inutile.
		modules.append(pick)

	return {
		"uid": ItemFactory.next_uid(),
		"item_id": item_id,
		"name_key": "item.%s.name" % item_id,
		"book_type": book_type,
		"domain": domain,
		"difficulty": difficulty,
		"modules": modules,
		"count": 1,
		"weight": 1.0,
		"value": float(difficulty) * 3.0,
		"tags": ["livre", book_type],
	}


## Un objet d'inventaire est-il un livre ?
static func is_book(obj: Dictionary) -> bool:
	return obj.has("modules") and obj.has("difficulty")


## Résout la LECTURE (GDD A.7, formule reprise telle quelle) :
##   jet = 1d20 + N_lecture/2 + Perception/4   contre   DD = 10 + difficulte/2
##   réussite        → modules = max(1, floor(nb * min(1, N_lecture / difficulte)))
##   réussite de 10+ → tous les modules du livre, plus un bonus d'XP
##
## Retourne { "reussite": bool, "marge": int, "modules": Array[String],
##            "echec": Dictionary }. Ne modifie RIEN : l'appelant applique.
## Séparer le jet de son application permet de le tester sans joueur, et évite
## qu'une règle de progression se retrouve enfouie dans le code d'inventaire.
static func resolve_reading(book: Dictionary, reading_level: int, perception: int,
		rng: RandomNumberGenerator) -> Dictionary:
	var difficulty := maxi(int(book.get("difficulty", 1)), 1)
	var roll := rng.randi_range(1, 20) + reading_level / 2 + perception / 4
	var dd := 10 + difficulty / 2
	var margin := roll - dd
	var contents: Array = book.get("modules", [])
	if margin < 0:
		return {"reussite": false, "marge": margin, "modules": [] as Array[String],
			"echec": _failure_for(-margin)}
	var gained: Array[String] = []
	if margin >= 10:
		for id: String in contents:
			gained.append(String(id))
	else:
		var ratio := minf(1.0, float(reading_level) / float(difficulty))
		var count := maxi(1, int(floor(float(contents.size()) * ratio)))
		for i in mini(count, contents.size()):
			gained.append(String(contents[i]))
	return {"reussite": true, "marge": margin, "modules": gained, "echec": {}}


## Effet d'échec correspondant à l'ampleur du ratage (`shortfall` = de combien
## le jet est passé sous le DD). Table en DONNÉES (data/reading_failures.json,
## GDD A.7 : « extensible ») : ajouter un effet ne touche pas ce fichier.
static func _failure_for(shortfall: int) -> Dictionary:
	var table: Dictionary = GameData.reading_failures
	# Du plus grave au plus bénin : on veut le pire effet dont le seuil est
	# atteint, pas le premier trouvé.
	var best := {}
	var best_seuil := -1
	for severity: String in table:
		for entry: Dictionary in (table[severity] as Array):
			var seuil := int(entry.get("seuil", 0))
			if shortfall >= seuil and seuil > best_seuil:
				best = entry
				best_seuil = seuil
	return best
