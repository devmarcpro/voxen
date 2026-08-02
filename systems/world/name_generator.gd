class_name NameGenerator
extends RefCounted
## Noms culturels de PNJ, de villes et titres (GDD 12.5, algorithme E.31,
## schéma B.11, catalogue C.9) — classe statique pure et DÉTERMINISTE : mêmes
## graine et mêmes entrées → mêmes noms, à chaque appel (G.1).
##
## CE QUE CE FICHIER N'EST PAS. Il ne remplace pas `WorldNamer`, qui nomme le
## MONDE, les continents et les océans par assemblage de syllabes génériques.
## Ces noms-là n'appartiennent à personne : il n'existe pas de culture avant
## qu'un royaume existe. Ici, tout part au contraire d'une CULTURE (B.11), et
## c'est elle qui donne leur cohérence sonore à un royaume, à ses villes et à
## ses habitants.
##
## PRINCIPE (12.5) : aucun nom n'est écrit à la main. Chacun est une partie A
## concaténée à une partie B, tirées dans les pools de la culture. Douze
## préfixes et neuf suffixes suffisent à plus de cent prénoms, tous cohérents
## entre eux — c'est ce qui permet de tenir dix cultures sans écrire dix listes
## de mille noms.
##
## CONCATÉNATION DIRECTE, sans règle de jonction : E.31 l'impose explicitement,
## et c'est aux DONNÉES de s'enchaîner proprement. Une culture dont un préfixe
## finit comme un suffixe commence produira des syllabes doublées — c'est un
## défaut de pool, à corriger dans le JSON, jamais par une règle ici.

## Sels de hachage : deux tirages du même PNJ (prénom, nom) ne doivent jamais
## être corrélés, sinon un « Marcus Marcius » sortirait bien plus souvent que
## le hasard ne le voudrait.
const SALT_GIVEN_A := 1301
const SALT_GIVEN_B := 1303
const SALT_FAMILY_A := 1307
const SALT_FAMILY_B := 1309
const SALT_TOWN_A := 1319
const SALT_TOWN_B := 1321
const SALT_CULTURE := 1327
const SALT_RETRY := 7919

## Culture de repli si les données manquent ou si aucune n'accepte la race.
## Jamais un plantage : un PNJ sans nom est un bug visible, un PNJ au nom
## d'une autre culture est une imperfection.
const FALLBACK_CULTURE := "culture_latine"


static func _pick(pool: Array, seed_value: int, salt: int) -> String:
	if pool.is_empty():
		return ""
	return String(pool[NoiseGenerator.pcg_hash(seed_value, salt, 0) % pool.size()])


static func _culture(culture_id: String) -> Dictionary:
	var c: Dictionary = GameData.name_cultures.get(culture_id, {})
	if c.is_empty():
		c = GameData.name_cultures.get(FALLBACK_CULTURE, {})
	if c.is_empty() and not GameData.name_cultures.is_empty():
		c = GameData.name_cultures.values()[0]
	return c


# --- Choix de la culture ---

## Culture d'un royaume, tirée parmi celles qui acceptent sa race dominante,
## pondérée par `race_affinity` (B.11).
##
## C'est ici que se joue « culture ≠ race » (12.5) : un royaume humain peut
## être latin, sino, slave ou nordique, et deux royaumes humains voisins
## sonneront différemment. Les races originales (Sylvide, Cendreux,
## Échomorphe) n'ont qu'une culture chacune, donc le tirage est forcé — c'est
## voulu, leur identité sonore leur est propre.
static func culture_for_race(race: String, seed_value: int) -> String:
	var eligible: Array[String] = []
	var weights: Array[float] = []
	var total := 0.0
	# Ordre de clés STABLE (trié) : `GameData.name_cultures` est un Dictionary,
	# dont l'ordre d'insertion suit l'ordre de lecture du disque. S'y fier
	# rendrait le tirage dépendant du système de fichiers — donc non
	# reproductible d'une machine à l'autre, ce qui casserait G.1.
	var ids: Array = GameData.name_cultures.keys()
	ids.sort()
	for cid: String in ids:
		var affinity: Dictionary = (GameData.name_cultures[cid] as Dictionary).get("race_affinity", {})
		var w := float(affinity.get(race, 0.0))
		if w > 0.0:
			eligible.append(cid)
			weights.append(w)
			total += w
	if eligible.is_empty():
		return FALLBACK_CULTURE
	# Tirage pondéré sur un entier, pas sur un flottant : le hachage rend un
	# entier, et repasser par un randf() introduirait une dépendance à l'état
	# global du générateur aléatoire.
	var roll := float(NoiseGenerator.pcg_hash(seed_value, SALT_CULTURE, 0) % 100000) / 100000.0 * total
	var acc := 0.0
	for i in eligible.size():
		acc += weights[i]
		if roll < acc:
			return eligible[i]
	return eligible[eligible.size() - 1]


# --- Noms ---

## Prénom (E.31). `taken` : prénoms déjà portés dans le même royaume — un
## doublon direct est re-tiré UNE FOIS, puis accepté. E.31 le dit : l'unicité
## n'est pas garantie (deux « Li Wei » peuvent coexister), on évite seulement
## le doublon immédiat qui se remarquerait dans un même village.
static func given_name(culture_id: String, seed_value: int, taken: Dictionary = {}) -> String:
	var c := _culture(culture_id)
	if c.is_empty():
		return ""
	var name := _pick(c.get("prenom_a", []), seed_value, SALT_GIVEN_A) \
			+ _pick(c.get("prenom_b", []), seed_value, SALT_GIVEN_B)
	if taken.has(name):
		var retry := seed_value ^ SALT_RETRY
		name = _pick(c.get("prenom_a", []), retry, SALT_GIVEN_A) \
				+ _pick(c.get("prenom_b", []), retry, SALT_GIVEN_B)
	return name


## Nom de famille d'un FONDATEUR (PNJ sans parent connu). Pour un enfant, ne
## pas appeler cette fonction : E.31 impose l'HÉRITAGE — voir `inherited_family_name`.
static func family_name(culture_id: String, seed_value: int) -> String:
	var c := _culture(culture_id)
	if c.is_empty():
		return ""
	return _pick(c.get("famille_a", []), seed_value, SALT_FAMILY_A) \
			+ _pick(c.get("famille_b", []), seed_value, SALT_FAMILY_B)


## Nom de famille d'un PNJ, héritage compris (E.31). `parent_family` vide =
## fondateur. La règle tient en une ligne, mais elle est le seul endroit du
## système où la démographie (12.2) touche les noms : la centraliser ici évite
## que chaque appelant réinvente « et si le PNJ a un parent ? ».
static func inherited_family_name(culture_id: String, seed_value: int,
		parent_family: String = "") -> String:
	return parent_family if parent_family != "" else family_name(culture_id, seed_value)


## Titre d'un PNJ à `leadership_role` (E.31). `government` vient du royaume
## (B.9), ou "guilde_maitre" pour un maître de guilde, qui ne dépend d'aucun
## royaume (7.3). `gender` : "m" ou "f". Rend "" si le rôle n'a pas de titre
## dans cette culture — une anarchie, par exemple, n'a personne à titrer.
static func title(culture_id: String, government: String, gender: String) -> String:
	var titles: Dictionary = _culture(culture_id).get("titres", {})
	var entry: Dictionary = titles.get(government, {})
	return String(entry.get(gender, entry.get("m", "")))


## Nom d'une ville ou d'un village (E.31). Toutes les localités d'un royaume
## partagent sa culture, donc sa sonorité.
static func town_name(culture_id: String, seed_value: int) -> String:
	var c := _culture(culture_id)
	if c.is_empty():
		return ""
	return _pick(c.get("ville_a", []), seed_value, SALT_TOWN_A) \
			+ _pick(c.get("ville_b", []), seed_value, SALT_TOWN_B)


# --- Affichage ---

## Nom complet affichable, dans l'ordre de la culture (E.31 : « résolu en une
## fonction d'affichage unique réutilisée partout »). Fiches PNJ, dialogue
## (E.23), journaux de raid (E.6) et quêtes (B.7) doivent tous passer par ici,
## sinon `name_order` finira par n'être respecté qu'à moitié.
static func display_name(culture_id: String, given: String, family: String,
		npc_title: String = "") -> String:
	var order := String(_culture(culture_id).get("name_order", "prenom_nom"))
	var parts: Array[String] = []
	if npc_title != "":
		parts.append(npc_title)
	if order == "nom_prenom":
		if family != "":
			parts.append(family)
		if given != "":
			parts.append(given)
	else:
		if given != "":
			parts.append(given)
		if family != "":
			parts.append(family)
	return " ".join(parts)


## Identité complète d'un PNJ, en une fois : { "culture", "prenom",
## "nom_famille", "titre", "affichage" }. C'est la porte d'entrée normale —
## les fonctions unitaires au-dessus servent aux cas particuliers.
static func identity(culture_id: String, seed_value: int, gender: String = "m",
		government: String = "", parent_family: String = "",
		taken: Dictionary = {}) -> Dictionary:
	var given := given_name(culture_id, seed_value, taken)
	var family := inherited_family_name(culture_id, seed_value, parent_family)
	var npc_title := title(culture_id, government, gender) if government != "" else ""
	return {
		"culture": culture_id,
		"prenom": given,
		"nom_famille": family,
		"titre": npc_title,
		"affichage": display_name(culture_id, given, family, npc_title),
	}
