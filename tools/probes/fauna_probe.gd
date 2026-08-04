extends Probe
## Sonde `--probe-faune` — extraite de main.gd le 2026-07-28 (audit architectural).
## Logique inchangée : seuls les accès à la scène ont été réécrits
## ($Player -> player, get_tree() -> main.get_tree(), etc.).


## Sonde faune headless (F.3/B.5) : catalogue chargé, cohérence de la
## répartition par biome, composition du pool de spawn, profils d'IA.
##
## RÉÉCRITE le 2026-08-02 : la faune ANIMALE a été supprimée (décision auteur,
## périmètre réduit aux humains le temps que les modèles existent). Trois de
## ses vérifications portaient sur des espèces disparues, et une quatrième est
## désormais INVERSÉE :
##
##   - « aucun civil dans le pool de spawn » était vrai tant que la nature
##     n'était peuplée que de bêtes. Les humains errants (villageois, chasseur,
##     nomade, marchand ambulant) y sont maintenant VOULUS ; ce sont les
##     métiers sédentaires qui doivent en rester absents.
##   - le garde-fou « pas d'ours polaire dans le désert » testait des espèces
##     qui n'existent plus. Même idée, autres sujets : le nomade est un
##     spécialiste des terres sèches, le chasseur des forêts.
##   - le profil `fuit` n'est plus déclaré par AUCUNE créature (il n'existait
##     que chez les herbivores). Le code le gère toujours ; il n'y a
##     simplement plus rien à tester tant qu'aucune espèce ne le porte.
const EXPECTED_CREATURES := 18

## Humains attachés à un village : ils viennent de la population de village
## (3.4/E.25) et ne doivent JAMAIS apparaître seuls en pleine nature.
const SEDENTARY := ["forgeron", "tavernier", "souverain", "garde_village",
		"erudit", "maitre_guilde", "pretre_sanctuaire", "fermier"]

## Hostiles retirés du spawn naturel : bandit est le seul ennemi sauvage
## (décision auteur). Le chef de bande reste vivant comme boss de donjon.
const NON_SPAWNING_HOSTILES := ["chef_de_bande", "deserteur", "pillard"]


func run() -> void:
	await main.get_tree().process_frame
	var ok := true

	# 1. Catalogue.
	var by_profile := {}
	for cid: String in GameData.creatures:
		var profile := String((GameData.creatures[cid] as Dictionary).get("ai_profile", "?"))
		by_profile[profile] = int(by_profile.get(profile, 0)) + 1
	print("[FAUNE] créatures chargées : %d — par profil : %s" % [GameData.creatures.size(), by_profile])
	ok = ok and GameData.creatures.size() == EXPECTED_CREATURES

	# Périmètre humain : plus aucune fiche non humaine ne doit subsister.
	var non_humans: Array[String] = []
	for cid: String in GameData.creatures:
		if String((GameData.creatures[cid] as Dictionary).get("race", "")) != "humain":
			non_humans.append(cid)
	print("[FAUNE] créatures non humaines : %s (attendu aucune)" % [non_humans])
	ok = ok and non_humans.is_empty()

	# 2. Composition du pool de spawn naturel.
	var pool: Array[String] = CreatureManager._spawn_pool
	var intruders: Array[String] = []
	for cid in pool:
		if cid in SEDENTARY or cid in NON_SPAWNING_HOSTILES:
			intruders.append(cid)
	var hostiles_in_pool: Array[String] = []
	for cid in pool:
		if String((GameData.creatures[cid] as Dictionary).get("ai_profile", "")) == "hostile":
			hostiles_in_pool.append(cid)
	print("[FAUNE] pool de spawn : %d entrée(s) -> %s" % [pool.size(), pool])
	print("[FAUNE] intrus (sédentaires ou hostiles retirés) : %s (attendu aucun)" % [intruders])
	print("[FAUNE] hostiles du pool : %s (attendu [\"bandit\"] seul)" % [hostiles_in_pool])
	ok = ok and pool.size() > 0 and intruders.is_empty() and hostiles_in_pool == ["bandit"]

	# 3. Cohérence par biome : on échantillonne le monde et on vérifie que
	# chaque créature tirée déclare bien un tag du biome de l'endroit.
	var gen := WorldManager.generator
	var sampled := 0
	var mismatches := 0
	var per_biome := {}
	for i in 400:
		var x := randi_range(-4000, 4000)
		var z := randi_range(-4000, 4000)
		var biome: Dictionary = gen.biome_at(x, z)
		if biome.is_empty():
			continue
		var cid: String = CreatureManager._pick_for_biome(x, z)
		if cid == "":
			continue
		sampled += 1
		var biome_id := String(biome.get("id", "?"))
		if not per_biome.has(biome_id):
			per_biome[biome_id] = {}
		per_biome[biome_id][cid] = true
		var tags: Array = (GameData.creatures[cid].get("world_gen", {}) as Dictionary).get("biome_tags", [])
		var matched := false
		for tag: String in tags:
			if tag in (biome.get("tags", []) as Array):
				matched = true
				break
		if not matched:
			mismatches += 1
			print("[FAUNE]   INCOHÉRENT : %s tiré en %s" % [cid, biome_id])
	print("[FAUNE] %d tirages sur %d biomes : %d incohérences (attendu 0)" % [
			sampled, per_biome.size(), mismatches])
	ok = ok and sampled > 0 and mismatches == 0
	var biome_ids: Array = per_biome.keys()
	biome_ids.sort()
	for bid: String in biome_ids:
		var names: Array = (per_biome[bid] as Dictionary).keys()
		names.sort()
		print("[FAUNE]   %-24s %s" % [bid, ", ".join(names)])

	# 4. Garde-fou explicite : une espèce spécialisée ne doit JAMAIS être
	# candidate hors de son domaine. Le nomade appartient aux terres sèches,
	# le chasseur aux forêts — l'un ne doit pas remplacer l'autre.
	var misplaced := 0
	for probe: Array in [["foret_temperee", ["nomade"]], ["desert_aride", ["chasseur"]]]:
		var biome_id: String = probe[0]
		var forbidden: Array = probe[1]
		var b: Dictionary = GameData.biomes.get(biome_id, {})
		if b.is_empty():
			print("[FAUNE]   biome « %s » introuvable — garde-fou non évalué." % biome_id)
			ok = false
			continue
		# `_candidates_for_tags` filtre aussi sur l'heure : on interroge donc
		# les DEUX moments, sans quoi une espèce diurne passerait le test la
		# nuit simplement parce qu'elle n'est candidate à aucune heure.
		for cid: String in CreatureManager._candidates_for_tags(b.get("tags", [])):
			if cid in forbidden:
				misplaced += 1
				print("[FAUNE]   HORS DOMAINE : %s candidat en %s" % [cid, biome_id])
	print("[FAUNE] espèces hors de leur domaine : %d (attendu 0)" % misplaced)
	ok = ok and misplaced == 0

	# 5. Profils d'IA : un hostile l'est d'emblée ; une « bête sauvage » est
	# neutre AVANT d'être frappée et hostile APRÈS (F.3) ; un civil ne l'est
	# jamais spontanément.
	#
	# Le profil `fuit` n'est plus testé : aucune créature ne le déclare depuis
	# la suppression des herbivores. Le code le gère toujours — c'est le
	# CONTENU qui manque, pas la mécanique.
	CreatureManager.creature_root = Node3D.new()
	main.add_child(CreatureManager.creature_root)
	var bandit := CreatureManager.spawn("bandit", Vector3(0, 40, 0))
	var braconnier := CreatureManager.spawn("braconnier", Vector3(10, 40, 0))
	var villageois := CreatureManager.spawn("villageois", Vector3(20, 40, 0))
	var bandit_ok: bool = bandit != null and bandit.is_hostile()
	var brac_avant: bool = braconnier != null and not braconnier.is_hostile()
	if braconnier != null:
		braconnier.provoke()
	var brac_apres: bool = braconnier != null and braconnier.is_hostile()
	var civil_ok: bool = villageois != null and not villageois.is_hostile()
	print("[FAUNE] bandit : hostile d'emblée=%s (attendu true)" % bandit_ok)
	print("[FAUNE] braconnier : hostile avant provocation=%s après=%s (attendu false/true)" % [
			not brac_avant, brac_apres])
	print("[FAUNE] villageois : hostile=%s (attendu false)" % [not civil_ok])
	ok = ok and bandit_ok and brac_avant and brac_apres and civil_ok

	print("[FAUNE] RÉSULTAT : %s" % ("OK" if ok else "ÉCHEC"))
	main.get_tree().quit(0 if ok else 1)
