extends Probe
## Sonde `--probe-pnj` — habitants de village.
##
## CE QU'ELLE DÉFEND EN PREMIER : qu'il n'existe pas de classe « PNJ ».
##
## Le GDD (12.1) pose que villageois, marchands et monstres sont construits de
## la même façon, et l'auteur l'a rappelé mot pour mot — « un sanglier et un
## marchand sont faits de la même façon ». La tentation, dès qu'on ajoute un
## métier et un domicile, est de créer une sous-classe pour les ranger. Ce
## serait rouvrir la séparation que le GDD ferme, et il faudrait ensuite
## dupliquer le combat, le loot, l'inventaire et l'IA des deux côtés.
##
## Le premier test compare donc le SCRIPT d'un sanglier et celui d'un marchand.
## S'ils divergent un jour, il aura fallu le décider explicitement.

const TAG := "PNJ"

var _ok := true


func _check(label: String, condition: bool, detail: String = "") -> void:
	if not condition:
		_ok = false
	print("[%s] %s%s : %s" % [TAG, label, "" if detail == "" else " (" + detail + ")",
		"OK" if condition else "ÉCHEC"])


func run() -> void:
	await main.get_tree().process_frame
	_check_unified_structure()
	_check_jobs_have_candidates()
	await _check_village_is_populated()
	_check_reputation()
	_check_dialogue()
	_check_decimation()
	_check_decimation_is_wired()
	_check_identity()
	_check_collision()
	await _check_bodies_separate()
	finish(_ok, TAG)


## Peuple un village ET VIDE LA FILE DE SPAWN.
##
## Depuis le 2026-08-03, `_populate_village` MET EN FILE ses habitants au lieu
## de les instancier d'un bloc — vingt corps riggés dans le même tick faisaient
## des pics à 62 ms en jeu. La sonde doit donc laisser la file se vider, sinon
## elle constate zéro habitant et accuse à tort le peuplement.
func _populate_and_drain(cell: Vector2i, plan: Dictionary) -> void:
	CreatureManager.call("_populate_village", cell, plan)
	# Borne de sûreté : une file qui ne se vide pas est un bug en soi, on ne
	# veut pas qu'il se transforme en sonde qui tourne sans fin.
	for i in 200:
		if (CreatureManager._spawn_queue as Array).is_empty():
			return
		CreatureManager.call("_drain_spawn_queue")


## LE VERROU. Un sanglier et un marchand doivent être la même classe.
func _check_unified_structure() -> void:
	var boar := CreatureManager.spawn("bandit", Vector3(0, 200, 0))
	var merchant := CreatureManager.spawn("marchand_ambulant", Vector3(0, 200, 4))
	if boar == null or merchant == null:
		_check("les deux créatures apparaissent", false)
		return
	_check("bandit et marchand partagent le MÊME script",
		boar.get_script() == merchant.get_script(),
		boar.get_script().resource_path.get_file())
	# Les champs sociaux existent sur les DEUX : c'est ce qui permet au reste du
	# code de ne jamais tester l'espèce.
	# La RELATION ne figure volontairement pas dans cette liste : elle ne vit pas
	# sur l'instance. Les habitants n'étant pas persistés, une relation portée
	# par la créature disparaîtrait dès que le joueur s'éloigne — elle est donc
	# dans `Player.reputation`, retrouvée par `social_key`.
	for field: String in ["village_cell", "job", "home_building", "social_key", "race_id"]:
		_check("le bandit porte aussi le champ « %s »" % field,
			boar.get(field) != null)
	_check("un bandit n'est PAS un résident", not boar.call("is_resident"))
	CreatureManager.despawn(boar)
	CreatureManager.despawn(merchant)


## Les onze postes du GDD (8.4) doivent tous avoir un titulaire possible. Sans
## candidat, l'habitant correspondant est silencieusement omis et le village se
## retrouve sous-peuplé sans que rien ne le signale.
func _check_jobs_have_candidates() -> void:
	var orphans: Array[String] = []
	for job: String in VillagePopulation.JOBS:
		if VillagePopulation.candidates_for_job(job).is_empty():
			orphans.append(job)
	_check("les %d postes ont un titulaire possible" % VillagePopulation.JOBS.size(),
		orphans.is_empty(), "" if orphans.is_empty() else "orphelins : " + ", ".join(orphans))


func _check_village_is_populated() -> void:
	var generator := WorldManager.generator
	var found := Vector2i(1 << 30, 0)
	var plan := {}
	# On cherche un village RÉELLEMENT construit, pas seulement tiré : c'est la
	# distinction qui a fait croire un jour que les villages n'existaient pas.
	for radius in range(0, 40):
		for dz in range(-radius, radius + 1):
			for dx in range(-radius, radius + 1):
				if maxi(absi(dx), absi(dz)) != radius:
					continue
				var cell := Vector2i(dx, dz)
				var candidate: Dictionary = generator.city_at_cell(cell)
				if not candidate.is_empty():
					found = cell
					plan = candidate
					break
			if plan.size() > 0:
				break
		if plan.size() > 0:
			break
	if plan.is_empty():
		_check("un village construit existe dans la zone de départ", false)
		return

	var roster := VillagePopulation.roster(found, generator.world_seed, plan)
	_check("le village a des habitants", roster.size() > 0,
		"%d pour %d bâtiment(s)" % [roster.size(), int(plan["buildings"])])
	_check("la population ne dépasse pas les logements",
		roster.size() <= int(plan["buildings"]) * VillagePopulation.RESIDENTS_PER_HOUSE)

	# DÉTERMINISME : entrer et sortir d'un village ne doit pas en changer les
	# habitants. Sans ça, chaque visite recomposerait le village et aucune
	# relation ne pourrait s'installer dans la durée.
	var again := VillagePopulation.roster(found, generator.world_seed, plan)
	_check("le roster est déterministe", str(roster) == str(again))

	var jobs := {}
	var homes := {}
	for entry: Dictionary in roster:
		jobs[entry["job"]] = true
		homes[entry["plot"]] = int(homes.get(entry["plot"], 0)) + 1
	_check("plusieurs métiers représentés", jobs.size() >= 2,
		", ".join(PackedStringArray(jobs.keys())))
	var overcrowded := 0
	for plot: int in homes:
		if homes[plot] > VillagePopulation.RESIDENTS_PER_HOUSE:
			overcrowded += 1
	_check("aucun logement surpeuplé", overcrowded == 0)

	# Le domicile doit tomber DANS le village, pas à côté : une erreur de
	# décalage y enverrait les habitants vivre dans la forêt voisine.
	var center := POIGenerator.cell_center_world(found)
	var far := 0
	for entry: Dictionary in roster:
		var home := VillagePopulation.home_position(found, plan, int(entry["plot"]))
		if Vector2(home.x, home.z).distance_to(Vector2(center.x, center.y)) > 128.0:
			far += 1
	_check("les domiciles tombent dans la cellule du village", far == 0,
		"%d hors cadre" % far)

	# ROUTINE : le point d'ancrage doit CHANGER entre le jour et la nuit.
	var home_pos := VillagePopulation.home_position(found, plan, int(roster[0]["plot"]))
	var work_pos := VillagePopulation.work_position(found, plan)
	var resident := CreatureManager.spawn(String(roster[0]["creature_id"]), Vector3(home_pos))
	if resident == null:
		_check("l'habitant apparaît", false)
		return
	resident.job = String(roster[0]["job"])
	resident.home_building = Vector3(home_pos)
	resident.work_place = Vector3(work_pos)
	_check("l'habitant est un résident", resident.call("is_resident"))

	var per_day := int(DayNightManager.TICKS_PER_DAY)
	TickManager.tick_index = int(12.0 / DayNightManager.HOURS_PER_DAY * per_day)
	var day_anchor: Vector3 = resident.call("_anchor")
	TickManager.tick_index = int(2.0 / DayNightManager.HOURS_PER_DAY * per_day)
	var night_anchor: Vector3 = resident.call("_anchor")
	_check("l'habitant travaille le jour", day_anchor.is_equal_approx(Vector3(work_pos)))
	_check("l'habitant rentre la nuit", night_anchor.is_equal_approx(Vector3(home_pos)))
	_check("les deux points diffèrent", not day_anchor.is_equal_approx(night_anchor),
		"%.0f m d'écart" % day_anchor.distance_to(night_anchor))
	CreatureManager.despawn(resident)


## RÉPUTATION ET RELATIONS (7.2). Ce que ces tests défendent, c'est que les
## méfaits COÛTENT quelque chose de durable et de propagé : un joueur qui tue
## des villageois doit finir par ne plus pouvoir entrer dans un village. Sans
## conséquence, les PNJ ne sont que du décor qu'on traverse.
func _check_reputation() -> void:
	var player_node := player
	var fresh := Reputation.new()
	player_node.reputation = fresh

	# Paliers, repris mot pour mot du GDD.
	for entry: Array in [[-80.0, "hostile"], [-30.0, "mefiant"], [0.0, "neutre"],
			[30.0, "amical"], [70.0, "devoue"]]:
		_check("palier %.0f = %s" % [entry[0], entry[1]],
			Reputation.tier(float(entry[0])) == String(entry[1]))
	_check("un client méfiant paie plus cher",
		Reputation.price_factor(-30.0) > 1.0, "×%.2f" % Reputation.price_factor(-30.0))
	_check("un client acquis paie moins cher",
		Reputation.price_factor(70.0) < 1.0, "×%.2f" % Reputation.price_factor(70.0))

	# PROPAGATION : nuire à quelqu'un doit se savoir dans son village et sa race.
	var cell := Vector2i(4, -7)
	fresh.record("4:-7#0", cell, "humain", -40.0)
	_check("la relation individuelle baisse", fresh.individual("4:-7#0") < 0.0,
		"%.0f" % fresh.individual("4:-7#0"))
	_check("le village en entend parler", fresh.village(cell) < 0.0,
		"%.0f" % fresh.village(cell))
	_check("la race en entend parler", fresh.race("humain") < 0.0,
		"%.0f" % fresh.race("humain"))
	_check("la réputation globale bouge aussi", fresh.global < 0.0,
		"%.1f" % fresh.global)

	# UN INCONNU DU MÊME VILLAGE n'est pas neutre : il a entendu parler de vous.
	var stranger := fresh.standing_with("4:-7#3", cell, "humain")
	_check("un inconnu du village vous juge déjà", stranger < 0.0,
		"%.1f" % stranger)

	# HOSTILITÉ À VUE : un civil bascule sous −50 sans changer d'ai_profile.
	var civil := CreatureManager.spawn("villageois", Vector3(0, 200, 0))
	if civil == null:
		_check("le villageois apparaît", false)
		return
	civil.village_cell = cell
	civil.social_key = "4:-7#9"
	_check("un villageois est pacifique par défaut", not civil.call("is_hostile"))
	fresh.record("4:-7#9", cell, String(civil.race_id), -120.0)
	_check("sous −50 le villageois devient hostile à vue", civil.call("is_hostile"),
		civil.call("relation_tier"))
	_check("son profil d'IA n'a PAS changé", String(civil.ai_profile) == "civil")
	CreatureManager.despawn(civil)

	# PERSISTANCE : une relation doit survivre au fait de quitter la région.
	var restored := Reputation.new()
	restored.restore_state(fresh.save_state())
	_check("la réputation survit à une sauvegarde",
		is_equal_approx(restored.individual("4:-7#0"), fresh.individual("4:-7#0")))
	var state: Dictionary = player_node.call("save_state")
	_check("save_state du joueur porte la réputation",
		(state.get("reputation", {}) as Dictionary).has("individuals"))


## DIALOGUE (E.23). Ce que ces tests défendent : que le dialogue reste DONNÉE.
## Le GDD refuse les arbres et le génératif — « la profondeur vient du nombre de
## gabarits et de la finesse des conditions ». Si une réplique finit codée en
## dur dans le panneau, le système cesse d'absorber du contenu sans code, ce qui
## était sa seule raison d'être.
func _check_dialogue() -> void:
	_check("des gabarits sont chargés", GameData.dialogue_lines.size() >= 20,
		"%d" % GameData.dialogue_lines.size())

	# Les CONDITIONS filtrent réellement : un forgeron ne doit pas recevoir les
	# répliques d'un fermier.
	var smith := {"key": "t#1", "job": "forgeron", "relation": 0.0, "hour": 12.0}
	var farmer := {"key": "t#2", "job": "fermier", "relation": 0.0, "hour": 12.0}
	var smith_lines := {}
	var farmer_lines := {}
	for i in 200:
		smith_lines[DialoguePool.pick(smith)] = true
		farmer_lines[DialoguePool.pick(farmer)] = true
	_check("le forgeron reçoit ses répliques de métier",
		smith_lines.has("dialogue.forgeron_1") or smith_lines.has("dialogue.forgeron_2"))
	_check("le forgeron ne reçoit PAS celles du fermier",
		not smith_lines.has("dialogue.fermier_1"))
	_check("le fermier ne reçoit PAS celles du forgeron",
		not farmer_lines.has("dialogue.forgeron_1"))

	# La RELATION change ce qu'on entend : c'est la récompense la plus lisible
	# d'une réputation soignée, et la sanction la plus lisible d'un méfait.
	var hated := {"key": "t#3", "job": "", "relation": -80.0, "hour": 12.0}
	var loved := {"key": "t#4", "job": "", "relation": 80.0, "hour": 12.0}
	var hated_lines := {}
	var loved_lines := {}
	for i in 200:
		hated_lines[DialoguePool.pick(hated)] = true
		loved_lines[DialoguePool.pick(loved)] = true
	_check("un PNJ hostile a ses propres répliques",
		hated_lines.has("dialogue.hostile_1") or hated_lines.has("dialogue.hostile_2"))
	_check("un PNJ hostile ne dit PAS les répliques amicales",
		not hated_lines.has("dialogue.amical_1") and not hated_lines.has("dialogue.devoue_1"))
	_check("un PNJ dévoué ne dit PAS les répliques hostiles",
		not loved_lines.has("dialogue.hostile_1"))

	# FENÊTRE HORAIRE FRANCHISSANT MINUIT : le cas qu'on oublie toujours, et
	# qui échoue en silence puisque le pool générique prend le relais.
	var night := {"key": "t#5", "job": "", "relation": 0.0, "hour": 2.0}
	var noon := {"key": "t#6", "job": "", "relation": 0.0, "hour": 12.0}
	var night_lines := {}
	var noon_lines := {}
	for i in 200:
		night_lines[DialoguePool.pick(night)] = true
		noon_lines[DialoguePool.pick(noon)] = true
	_check("la réplique nocturne sort la nuit", night_lines.has("dialogue.nuit"))
	_check("la réplique nocturne ne sort PAS à midi", not noon_lines.has("dialogue.nuit"))

	# ANTI-RÉPÉTITION : deux tirages d'affilée ne doivent pas donner la même
	# phrase tant qu'il en reste d'autres.
	var context := {"key": "t#7", "job": "", "relation": 0.0, "hour": 12.0}
	var first := DialoguePool.pick(context)
	var second := DialoguePool.pick(context)
	_check("deux répliques consécutives diffèrent", first != second,
		"%s puis %s" % [first, second])

	# Toute réplique doit avoir sa TRADUCTION : une clé non traduite s'affiche
	# brute à l'écran, et personne ne le remarque avant de jouer en français.
	var untranslated: Array[String] = []
	for line: Dictionary in GameData.dialogue_lines:
		var key := String(line["text_key"])
		if tr(key) == key:
			untranslated.append(key)
	_check("toutes les répliques sont traduites", untranslated.is_empty(),
		"" if untranslated.is_empty() else "manquantes : " + ", ".join(untranslated))


## DÉCIMATION (3.4/E.25). Ce que ces tests défendent : que tuer un habitant
## COÛTE quelque chose de durable. La population étant dérivée de (cellule,
## graine), un mort réapparaissait intact à la visite suivante — le meurtre
## était littéralement gratuit, et vider un village n'avait aucune conséquence.
func _check_decimation() -> void:
	VillageManager.casualties.clear()
	var cell := Vector2i(11, -3)

	_check("un village intact ne coûte rien en sauvegarde",
		VillageManager.casualties.is_empty())
	_check("personne n'est mort au départ", not VillageManager.is_dead(cell, 0))

	VillageManager.record_death(cell, 0)
	VillageManager.record_death(cell, 2)
	_check("le rang 0 est mort", VillageManager.is_dead(cell, 0))
	_check("le rang 2 est mort", VillageManager.is_dead(cell, 2))
	_check("le rang 1 est vivant", not VillageManager.is_dead(cell, 1))

	# IDEMPOTENCE : une créature peut être signalée morte par plusieurs chemins
	# (coup fatal côté joueur, nettoyage de tick). Compter deux fois la même
	# mort viderait un village deux fois plus vite que le joueur ne tue.
	VillageManager.record_death(cell, 0)
	var census: Dictionary = VillageManager.census(cell, 6)
	_check("une mort signalée deux fois ne compte qu'une",
		int(census["perdus"]) == 2, "%d perdus" % int(census["perdus"]))
	_check("le recensement décompte les vivants", int(census["vivants"]) == 4,
		"%d/%d" % [int(census["vivants"]), int(census["capacite"])])

	# VILLAGE ABANDONNÉ (3.4) : vidé de ses habitants, mais toujours debout.
	_check("un village avec des survivants n'est pas abandonné",
		not VillageManager.is_abandoned(cell, 6))
	for index in range(0, 6):
		VillageManager.record_death(cell, index)
	_check("un village entièrement vidé devient abandonné",
		VillageManager.is_abandoned(cell, 6))

	# PERSISTANCE : c'est tout l'objet du système.
	var state := VillageManager.save_state()
	VillageManager.casualties.clear()
	_check("registre vidé avant relecture", not VillageManager.is_dead(cell, 0))
	VillageManager.restore_state(state)
	_check("les morts survivent à la sauvegarde", VillageManager.is_dead(cell, 0))
	_check("le monde entier tient dans les écarts",
		VillageManager.casualties.size() == 1,
		"%d village(s) endeuillé(s) enregistré(s)" % VillageManager.casualties.size())

	VillageManager.casualties.clear()


## INTÉGRATION : le registre est-il RÉELLEMENT consulté au peuplement ?
##
## Les tests précédents prouvent que le registre fonctionne seul. Ils ne
## prouvent pas qu'il est branché — et un registre parfait que personne
## n'interroge est exactement le genre de panne qui ne se voit qu'en jouant,
## des semaines plus tard. On tue donc pour de bon, on relâche le village, on
## le repeuple, et on compte.
func _check_decimation_is_wired() -> void:
	var generator := WorldManager.generator
	var cell := Vector2i(1 << 30, 0)
	var plan := {}
	for radius in range(0, 40):
		for dz in range(-radius, radius + 1):
			for dx in range(-radius, radius + 1):
				if maxi(absi(dx), absi(dz)) != radius:
					continue
				var candidate: Dictionary = generator.city_at_cell(Vector2i(dx, dz))
				if not candidate.is_empty():
					cell = Vector2i(dx, dz)
					plan = candidate
					break
			if plan.size() > 0:
				break
		if plan.size() > 0:
			break
	if plan.is_empty():
		_check("un village construit existe pour l'essai", false)
		return

	VillageManager.casualties.clear()
	CreatureManager.call("_release_village", cell)
	_populate_and_drain(cell, plan)
	var before: int = (CreatureManager._populated_villages.get(cell, []) as Array).size()
	_check("le village se peuple", before > 0, "%d habitant(s)" % before)
	if before == 0:
		return

	# On en tue un, par le chemin normal : la créature meurt, le tick la
	# ramasse, le registre l'enregistre.
	var victim: Node = (CreatureManager._populated_villages[cell] as Array)[0]
	var victim_index: int = int(victim.roster_index)
	victim.health = 0.0
	CreatureManager.call("_note_resident_death", victim)
	_check("la victime est inscrite au registre",
		VillageManager.is_dead(cell, victim_index), "rang %d" % victim_index)

	# Puis on quitte la région et on revient : c'est le geste qui ressuscitait
	# tout le monde avant ce système.
	CreatureManager.call("_release_village", cell)
	_populate_and_drain(cell, plan)
	var after: int = (CreatureManager._populated_villages.get(cell, []) as Array).size()
	_check("le mort NE REVIENT PAS après un aller-retour", after == before - 1,
		"%d puis %d habitant(s)" % [before, after])
	var resurrected := false
	# Boucle NON typée : annoter `: Node` tenterait la conversion À
	# L'AFFECTATION, donc avant tout garde de validité — c'est le piège qui
	# faisait planter `_release_village` en boucle dans une vraie partie.
	for creature in CreatureManager._populated_villages[cell]:
		if int(creature.roster_index) == victim_index:
			resurrected = true
	_check("son rang reste vide", not resurrected)

	CreatureManager.call("_release_village", cell)
	VillageManager.casualties.clear()


## L'IDENTITÉ D'UN HABITANT (2026-08-09, demande de l'auteur : « il faut que
## chaque famille ait un nom et un prénom, un lieu d'origine, une généalogie, un
## âge, un habitat, une race, une classe, un rôle, un inventaire, un
## équipement »).
##
## CE QUI EST DÉFENDU, et rien de tout ça ne se voit en lisant le code :
##
## 1. LE FOYER EST UNE FAMILLE. Deux personnes sous le même toit portaient deux
##    noms de famille différents — un village n'était pas une communauté, mais
##    une liste de gens qui se trouvaient là. C'est l'assertion centrale.
## 2. TOUT EST RENSEIGNÉ. Un champ vide ne lève aucune erreur : il affiche un
##    blanc dans une fiche, et on le découvre six mois plus tard.
## 3. C'EST REPRODUCTIBLE. Rien n'est persisté : deux appels doivent rendre le
##    MÊME village, sinon s'éloigner et revenir changerait les habitants.
func _check_identity() -> void:
	var generator: NoiseGenerator = WorldManager.generator
	if generator == null:
		return
	var found := Vector2i(1 << 30, 1 << 30)
	var plan := {}
	for radius in 12:
		for dx in range(-radius, radius + 1):
			for dz in range(-radius, radius + 1):
				var candidate: Dictionary = generator.city_at_cell(Vector2i(dx, dz))
				if not candidate.is_empty() and int(candidate.get("population", 0)) >= 4:
					found = Vector2i(dx, dz)
					plan = candidate
					break
			if not plan.is_empty():
				break
		if not plan.is_empty():
			break
	if plan.is_empty():
		print("[%s] aucun village peuplé trouvé — test d'identité sauté." % TAG)
		return

	var roster := VillagePopulation.roster(found, generator.world_seed, plan)
	_check("un village peuplé pour examiner ses habitants", roster.size() >= 2,
		"%d habitant(s)" % roster.size())
	if roster.size() < 2:
		return

	# 1. LE FOYER EST UNE FAMILLE : même toit, même nom, même race, et des liens.
	var households := {}
	for entry: Dictionary in roster:
		var key := int(entry["foyer"])
		if not households.has(key):
			households[key] = []
		(households[key] as Array).append(entry)
	var shared := true
	var shared_race := true
	var linked := false
	for key: int in households:
		var members: Array = households[key]
		var first: Dictionary = members[0]
		for member: Dictionary in members:
			if String(member["nom_famille"]) != String(first["nom_famille"]):
				shared = false
			if String(member["race"]) != String(first["race"]):
				shared_race = false
			if int(member.get("conjoint", -1)) >= 0 or not (member.get("parents", []) as Array).is_empty():
				linked = true
	_check("les membres d'un foyer portent LE MÊME nom de famille", shared)
	_check("et la même race — un foyer n'est pas une auberge", shared_race)
	_check("et ils sont LIÉS : conjoints, ou parent et enfant", linked)

	# 2. TOUT EST RENSEIGNÉ, et on NOMME le champ manquant : « identité
	# incomplète » n'apprend rien, c'est LEQUEL qui désigne le maillon coupé.
	var required := ["prenom", "nom_famille", "genre", "affichage", "race",
		"classe", "origine", "culture"]
	var missing: Array[String] = []
	for entry: Dictionary in roster:
		for field: String in required:
			if String(entry.get(field, "")) == "" and not (field in missing):
				missing.append(field)
	_check("chaque habitant a une identité complète", missing.is_empty(),
		"manquants : %s" % ", ".join(missing) if not missing.is_empty() else "")

	# L'ÂGE EST PLAUSIBLE. Un village d'adultes de trente ans n'a ni passé ni
	# avenir — et l'âge sert au dialogue comme à la succession.
	var youngest := 999
	var oldest := 0
	for entry: Dictionary in roster:
		youngest = mini(youngest, int(entry["age"]))
		oldest = maxi(oldest, int(entry["age"]))
	_check("les âges sont plausibles", youngest >= 7 and oldest <= 95,
		"de %d à %d ans" % [youngest, oldest])

	# UN ENFANT NE TIENT PAS LA FORGE. Lui donner un métier fausserait le compte
	# des postes du village autant que la scène qu'on y verrait.
	var working_child := false
	for entry: Dictionary in roster:
		if int(entry["age"]) < 18 and String(entry["job"]) != "":
			working_child = true
	_check("aucun enfant n'occupe un poste", not working_child)

	# 3. REPRODUCTIBLE.
	var again := VillagePopulation.roster(found, generator.world_seed, plan)
	var same := again.size() == roster.size()
	if same:
		for i in roster.size():
			if String(again[i]["affichage"]) != String(roster[i]["affichage"]) 					or int(again[i]["age"]) != int(roster[i]["age"]):
				same = false
	_check("deux appels rendent le MÊME village — dérivé, jamais tiré", same)

	var sample: Dictionary = roster[0]
	print("[%s] exemple : %s, %d ans, %s/%s, rôle « %s », de %s, %d objet(s)" % [
		TAG, sample["affichage"], int(sample["age"]), sample["race"], sample["classe"],
		sample["role"], sample["origine"], (sample["equipement"] as Array).size()])

	# LA CRÉATURE EN JEU PORTE-T-ELLE CETTE IDENTITÉ ? Tout ce qui précède
	# vérifie le ROSTER, c'est-à-dire le papier. Si rien ne la transmet à
	# l'habitant qu'on croise, le village reste anonyme à l'écran et aucune de
	# ces assertions ne s'en apercevrait.
	var probe: Node = CreatureManager.spawn("villageois",
		player.get_position_for_ai() + Vector3(3, 0, 0))
	if probe != null:
		probe.call("apply_identity", roster[0])
		var shown := String(probe.call("display_name"))
		var line := String(probe.call("identity_line"))
		_check("un habitant croisé porte SON nom, pas celui de son espèce",
			shown == String(roster[0]["affichage"]), shown)
		_check("et sa ligne de présentation dit son âge, son rôle et son origine",
			line.contains(String(roster[0]["origine"])), line)
		# UNE BÊTE N'A PAS DE NOM, et doit retomber sur son espèce — sans ce
		# repli, un sanglier s'appellerait « » et la ligne serait vide.
		var beast: Node = CreatureManager.spawn("bandit",
			player.get_position_for_ai() + Vector3(5, 0, 0))
		if beast != null:
			_check("une créature sans identité garde le nom de son espèce",
				String(beast.call("display_name")) != "" and String(beast.call("identity_line")) == "")
			CreatureManager.despawn(beast)
		CreatureManager.despawn(probe)


## ON NE TRAVERSE PLUS LES PNJ (2026-08-09, demande de l'auteur : « fais en sorte
## que les PNJ aient des collisions, qu'on ne puisse pas passer à travers »).
##
## L'assertion interroge `_body_blocked_at` — le POINT DE PASSAGE UNIQUE du
## déplacement, consulté par les deux axes et par l'auto-step. Tester la position
## finale du joueur après un pas mesurerait aussi le terrain sous ses pieds et
## rendrait un verdict vrai pour la mauvaise raison.
##
## Trois faits, pas un : on est bloqué DANS le corps, LIBRE à côté, et LIBRE
## au-dessus. Le seul premier passerait avec une fonction qui rend toujours true.
func _check_collision() -> void:
	var creature: Node = null
	for c in CreatureManager.creatures:
		if is_instance_valid(c) and not c.is_dead() and c.dimension == WorldManager.active_dimension:
			creature = c
			break
	if creature == null:
		_check("collision", false, "aucune créature vivante à tester")
		return
	var body: Vector3 = creature.logical_position
	var feet := body.y
	# LES TROIS FAITS SE LISENT SUR `_creature_blocked_at` : `_body_blocked_at`
	# répond aussi du TERRAIN, et un « on passe » y échouerait dès que la
	# créature se tient sous un toit — un verdict rouge qui ne dirait rien des
	# collisions de PNJ. (Constaté : le test « six mètres plus haut » tombait sur
	# le plafond de la maison du villageois.)
	var inside: bool = camera.call("_creature_blocked_at", body.x, body.z, feet)
	var beside: bool = camera.call("_creature_blocked_at", body.x + 2.0, body.z, feet)
	var above: bool = camera.call("_creature_blocked_at", body.x, body.z, feet + 6.0)
	_check("collision PNJ : le corps bloque", inside, creature.display_name())
	_check("collision PNJ : deux mètres à côté, on passe", not beside)
	_check("collision PNJ : six mètres plus haut, on passe", not above)
	# ET C'EST BIEN BRANCHÉ SUR LE DÉPLACEMENT. Sans cette ligne, les trois
	# précédentes décriraient une fonction que personne n'appelle.
	# ON NE RESTE PAS PRISONNIER D'UN CORPS. Les créatures traversent le joueur :
	# l'une d'elles peut s'arrêter sur lui, et si le blocage était inconditionnel
	# toutes les directions se fermeraient d'un coup. Depuis L'INTÉRIEUR du
	# cylindre, plus rien ne doit bloquer.
	var was := camera.position
	camera.position = Vector3(body.x, was.y, body.z)
	_check("collision PNJ : depuis l'intérieur, on peut sortir",
			not bool(camera.call("_creature_blocked_at", body.x, body.z, feet)))
	camera.position = was
	_check("collision PNJ : le déplacement la consulte",
			bool(camera.call("_body_blocked_at", body.x, body.z, feet)))


## LES CORPS NE SE SUPERPOSENT PAS NON PLUS ENTRE EUX (2026-08-09).
##
## Le premier correctif n'allait que dans un sens : le joueur ne traversait plus
## les PNJ, mais les PNJ se traversaient entre eux et traversaient le joueur.
##
## Le test PROVOQUE le chevauchement — deux créatures posées au même endroit —
## au lieu d'espérer le rencontrer. Une sonde qui se contenterait d'observer un
## village passerait tant que le hasard des déambulations ne colle personne, et
## serait donc verte sans rien prouver.
func _check_bodies_separate() -> void:
	var living: Array = []
	for c in CreatureManager.creatures:
		if is_instance_valid(c) and not c.is_dead() and c.dimension == WorldManager.active_dimension:
			living.append(c)
		if living.size() == 2:
			break
	if living.size() < 2:
		_check("séparation des corps", false, "moins de deux créatures vivantes")
		return
	var a: Node = living[0]
	var b: Node = living[1]
	# EXACTEMENT SUPERPOSÉS : c'est le cas dégénéré, celui où une direction de
	# poussée doit être inventée. Une division par zéro y rendrait NAN et la
	# créature quitterait le monde sans que rien ne le signale.
	b.logical_position = a.logical_position
	a.call("_move_by", Vector3.ZERO)
	b.call("_move_by", Vector3.ZERO)
	var gap: float = Vector2(a.logical_position.x - b.logical_position.x,
			a.logical_position.z - b.logical_position.z).length()
	_check("séparation des corps : deux créatures superposées s'écartent",
			gap >= a.BODY_RADIUS * 2.0 - 0.01, "écart %.2f m" % gap)
	_check("séparation des corps : aucune position NAN",
			not (is_nan(b.logical_position.x) or is_nan(b.logical_position.z)))
	# LA CRÉATURE CÈDE DEVANT LE JOUEUR, jamais l'inverse : il ne doit pas être
	# déplacé par une décision qu'il n'a pas prise.
	# ON POSE LE JOUEUR SOI-MÊME, LOIN DE TOUT. `last_player_position` n'est
	# rafraîchie qu'au TICK et vaut l'origine tant qu'aucun n'a tourné : la
	# première version de ce test mesurait donc l'écart à un joueur imaginaire
	# posé en (0,0,0), et le 0.24 m obtenu venait en réalité de l'autre
	# créature. Un chiffre reproductible qui ne mesurait pas ce qu'il annonçait.
	var player_pos: Vector3 = a.logical_position + Vector3(50.0, 0.0, 50.0)
	CreatureManager.last_player_position = player_pos
	b.logical_position = player_pos
	b.call("_move_by", Vector3.ZERO)
	var from_player: float = Vector2(b.logical_position.x - player_pos.x,
			b.logical_position.z - player_pos.z).length()
	_check("séparation des corps : une créature sort du joueur",
			from_player >= b.BODY_RADIUS * 2.0 - 0.01, "écart %.2f m" % from_player)
	_check("séparation des corps : le joueur n'a pas bougé",
			CreatureManager.last_player_position.is_equal_approx(player_pos))
