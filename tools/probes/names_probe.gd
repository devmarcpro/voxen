extends Probe
## Sonde `--probe-noms` — ASSERTIVE, code de sortie 0/1.
##
## Couvre le système de noms culturels (GDD 12.5, algorithme E.31, schéma
## B.11, catalogue C.9), qui n'existait pas avant le 2026-08-02 : le GDD le
## listait explicitement comme « à écrire » (§16).
##
## Ce qu'elle vérifie, et pourquoi chaque point mérite un test :
##
##  1. les 10 cultures de C.9 sont chargées, et chacune couvre les 6
##     gouvernances de B.9 — un titre manquant produit une chaîne vide, donc
##     un roi sans titre, sans la moindre erreur ;
##  2. aucun nom généré n'est vide ni tronqué — le symptôme d'un pool vide ;
##  3. le tirage est DÉTERMINISTE (G.1) : même graine, même nom ;
##  4. il est aussi VARIÉ : un générateur qui rendrait toujours le même nom
##     passerait le test de déterminisme sans rien valoir ;
##  5. `name_order` est respecté (le sino nomme famille avant prénom) ;
##  6. l'héritage du nom de famille (12.2) prime sur le tirage ;
##  7. les cultures dédiées aux races originales leur sont EXCLUSIVES, et
##     l'humain a bien plusieurs cultures possibles — c'est tout le principe
##     « culture ≠ race » de 12.5 ;
##  8. un village hérite de la culture de son royaume, et ses habitants aussi.

const TAG := "NOMS"

## C.9 : dix cultures de lancement.
## Le GDD (C.9) fait foi, et il a été AMENDÉ le 2026-08-09 : trois cultures de
## fantaisie retirées avec les races qu'elles servaient, cinq cultures réelles
## ajoutées. Ce nombre et celui du GDD doivent bouger ENSEMBLE — c'est tout
## l'intérêt de l'asserter plutôt que de compter ce qu'on trouve.
const EXPECTED_CULTURES := 12
## B.9 : six gouvernances, plus l'entrée `guilde_maitre` de 7.3 (indépendante
## du royaume). L'anarchie n'a pas de dirigeant à titrer, elle est donc
## légitimement absente des tables de titres.
const TITLE_KEYS := ["monarchie_hereditaire", "republique_elue", "theocratie",
		"ploutocratie", "dictature_militaire", "guilde_maitre"]
## Races originales (12) : chacune a sa culture, non partagée.
## RACES EXCLUSIVES À UNE CULTURE — plus aucune depuis le 2026-08-09 : la
## fantaisie est retirée et seul l'humain subsiste. La liste reste, VIDE, avec
## le test qui la parcourt : le jour où une seconde race réelle arrive, elle a
## déjà sa vérification. L'effacer aurait fait disparaître la règle avec les
## données qu'elle protégeait.
const EXCLUSIVE_RACES: Array[String] = []

var _ok := true


func _expect(condition: bool, message: String) -> void:
	if condition:
		print("[%s] ok — %s" % [TAG, message])
	else:
		_ok = false
		print("[%s] ÉCHEC : %s" % [TAG, message])


func run() -> void:
	await main.get_tree().process_frame
	_check_catalogue()
	_check_generation()
	_check_determinism_and_variety()
	_check_name_order()
	_check_inheritance()
	_check_race_culture_axes()
	_check_village_inherits_culture()
	finish(_ok, TAG)


## 1. Catalogue complet et titres exhaustifs.
func _check_catalogue() -> void:
	var count: int = GameData.name_cultures.size()
	_expect(count == EXPECTED_CULTURES,
			"%d culture(s) chargée(s) (C.9 en prescrit %d)" % [count, EXPECTED_CULTURES])
	var missing: Array[String] = []
	for cid: String in GameData.name_cultures:
		var titles: Dictionary = (GameData.name_cultures[cid] as Dictionary).get("titres", {})
		for key: String in TITLE_KEYS:
			var entry: Dictionary = titles.get(key, {})
			if String(entry.get("m", "")) == "" or String(entry.get("f", "")) == "":
				missing.append("%s/%s" % [cid, key])
	_expect(missing.is_empty(), "titres complets (m et f) partout%s" % [
			"" if missing.is_empty() else " — manquants : %s" % ", ".join(missing)])


## 2. Aucun nom vide ou tronqué, sur toutes les cultures.
func _check_generation() -> void:
	var broken: Array[String] = []
	var samples: Array[String] = []
	var ids: Array = GameData.name_cultures.keys()
	ids.sort()
	for cid: String in ids:
		for i in 40:
			var given := NameGenerator.given_name(cid, 1000 + i * 37)
			var family := NameGenerator.family_name(cid, 2000 + i * 41)
			var town := NameGenerator.town_name(cid, 3000 + i * 43)
			# Le nom de famille peut légitimement n'avoir qu'une partie
			# (`famille_b: [""]`, convention B.11 du sino) — on n'exige donc
			# qu'il ne soit pas VIDE, pas qu'il soit composé.
			if given.length() < 2 or family.length() < 2 or town.length() < 2:
				broken.append("%s (« %s » / « %s » / « %s »)" % [cid, given, family, town])
				break
		samples.append("%s : %s %s, ville de %s" % [cid,
				NameGenerator.given_name(cid, 4242),
				NameGenerator.family_name(cid, 4242),
				NameGenerator.town_name(cid, 4242)])
	_expect(broken.is_empty(), "aucun nom vide ou tronqué sur %d cultures × 40 tirages%s" % [
			ids.size(), "" if broken.is_empty() else " — " + "; ".join(broken)])
	for line: String in samples:
		print("[%s]   %s" % [TAG, line])


## 3 et 4. Déterminisme ET variété — les deux ensemble, jamais l'un sans
## l'autre : une fonction constante satisfait le premier et ruine le jeu.
func _check_determinism_and_variety() -> void:
	var cid := "culture_latine"
	var first := NameGenerator.given_name(cid, 777)
	var again := NameGenerator.given_name(cid, 777)
	_expect(first == again, "déterminisme : deux appels sur la graine 777 rendent « %s »" % first)

	var seen := {}
	for i in 300:
		seen[NameGenerator.given_name(cid, i * 31 + 5)] = true
	_expect(seen.size() >= 40,
			"variété : %d prénoms distincts sur 300 tirages" % seen.size())


## 5. Ordre d'affichage propre à la culture.
func _check_name_order() -> void:
	var latin := NameGenerator.display_name("culture_latine", "Marcus", "Cornelius")
	var sino := NameGenerator.display_name("culture_sino", "Wei", "Li")
	_expect(latin == "Marcus Cornelius", "ordre latin : « %s »" % latin)
	_expect(sino == "Li Wei", "ordre sino (nom avant prénom) : « %s »" % sino)
	var titled := NameGenerator.display_name("culture_latine", "Marcus", "Cornelius", "Roi")
	_expect(titled.begins_with("Roi "), "le titre précède le nom : « %s »" % titled)


## 6. Héritage du nom de famille (E.31 : l'enfant porte celui du parent).
func _check_inheritance() -> void:
	var founder := NameGenerator.family_name("culture_nordique", 5150)
	var child := NameGenerator.inherited_family_name("culture_nordique", 9999, founder)
	var orphan := NameGenerator.inherited_family_name("culture_nordique", 9999, "")
	_expect(child == founder, "un enfant hérite : « %s » = « %s »" % [child, founder])
	_expect(orphan != "" and orphan != founder,
			"un fondateur tire le sien : « %s »" % orphan)


## 7. « Culture ≠ race » (12.5) : l'humain a le choix, les races originales non.
func _check_race_culture_axes() -> void:
	for race: String in EXCLUSIVE_RACES:
		var picked := {}
		for i in 60:
			picked[NameGenerator.culture_for_race(race, i * 97 + 3)] = true
		var holders: Array[String] = []
		for cid: String in GameData.name_cultures:
			var affinity: Dictionary = (GameData.name_cultures[cid] as Dictionary).get("race_affinity", {})
			if float(affinity.get(race, 0.0)) > 0.0:
				holders.append(cid)
		_expect(picked.size() == 1 and holders.size() == 1,
				"« %s » : une seule culture possible (%s)" % [race, holders])

	var human := {}
	for i in 200:
		human[NameGenerator.culture_for_race("humain", i * 61 + 7)] = true
	_expect(human.size() >= 4,
			"« humain » : %d cultures différentes tirées — la culture ne découle pas de la race" % human.size())


## 8. Un village porte la culture de son royaume, et ses habitants avec lui.
func _check_village_inherits_culture() -> void:
	var generator := WorldManager.generator
	if generator == null:
		_expect(false, "aucun monde actif — vérification du village impossible.")
		return
	# On cherche une cellule qui soit À LA FOIS sous autorité et bâtie : hors
	# royaume il n'y a pas de culture à hériter, et sans village il n'y a
	# personne à nommer. Chercher seulement l'un des deux laissait le test se
	# déclarer « non vérifié » et ne rien prouver (constaté au premier essai).
	var found := Vector2i(1 << 30, 0)
	var kingdom := {}
	for radius in range(0, 60):
		if found.x != 1 << 30:
			break
		for dz in range(-radius, radius + 1):
			for dx in range(-radius, radius + 1):
				if maxi(absi(dx), absi(dz)) != radius:
					continue
				var c := Vector2i(dx, dz)
				var k: Dictionary = generator.kingdom_at_cell(c)
				if k.is_empty() or String(k.get("culture", "")) == "":
					continue
				if (generator.city_at_cell(c) as Dictionary).is_empty():
					continue
				found = c
				kingdom = k
				break
			if found.x != 1 << 30:
				break
	if found.x == 1 << 30:
		_expect(false, "aucune cellule à la fois sous autorité et bâtie — vérification impossible.")
		return
	var culture := String(kingdom["culture"])
	print("[%s] royaume « %s » (%s, %s) culture=%s" % [TAG, kingdom.get("name", "?"),
			kingdom.get("race", "?"), kingdom.get("government_type", "?"), culture])
	var affinity: Dictionary = (GameData.name_cultures[culture] as Dictionary).get("race_affinity", {})
	_expect(float(affinity.get(String(kingdom.get("race", "")), 0.0)) > 0.0,
			"la culture du royaume accepte bien sa race dominante")

	var plan: Dictionary = generator.city_at_cell(found)
	var roster := VillagePopulation.roster(found, generator.world_seed, plan, culture)
	var wrong := 0
	for entry: Dictionary in roster:
		if String(entry.get("culture", "")) != culture or String(entry.get("prenom", "")) == "":
			wrong += 1
	_expect(wrong == 0, "%d habitant(s), tous nommés dans la culture du royaume" % roster.size())
	for i in mini(3, roster.size()):
		var e: Dictionary = roster[i]
		print("[%s]   %s (%s)" % [TAG,
				NameGenerator.display_name(culture, String(e["prenom"]), String(e["nom_famille"])),
				e.get("job", "-")])
