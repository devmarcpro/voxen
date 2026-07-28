extends Probe
## Sonde `--probe-butin` — extraite de main.gd le 2026-07-28 (audit architectural).
## Logique inchangée : seuls les accès à la scène ont été réécrits
## ($Player -> player, get_tree() -> main.get_tree(), etc.).


## Sonde butin headless (7.7/A.9.1/B.1) : matériaux paramétriques générés
## depuis les créatures, unicité des couleurs préservée, palette dimensionnée
## au catalogue, dépeçage à la mort, et viande mangeable via la boucle A.9.
func run() -> void:
	await main.get_tree().process_frame
	var player: Node = player
	player.apply_default_character()
	var ok := true

	# 1. Génération : une viande + une peau par créature à corps (les amorphes
	# — essaims, nuées — n'en ont pas).
	var viandes: Array[String] = []
	var peaux: Array[String] = []
	for mid: String in GameData.resources:
		if mid.begins_with("viande_de_"):
			viandes.append(mid)
		elif mid.begins_with("peau_de_"):
			peaux.append(mid)
	var amorphes := 0
	for cid: String in GameData.creatures:
		if "amorphe" in (GameData.creatures[cid].get("tags", []) as Array):
			amorphes += 1
	var attendu: int = GameData.creatures.size() - amorphes
	print("[BUTIN] paramétriques : %d viandes, %d peaux (attendu %d = %d créatures - %d amorphes)" % [
			viandes.size(), peaux.size(), attendu, GameData.creatures.size(), amorphes])
	ok = ok and viandes.size() == attendu and peaux.size() == attendu
	print("[BUTIN] aucune viande d'amorphe : %s" % [not GameData.resources.has("viande_de_essaim_abeilles")])
	ok = ok and not GameData.resources.has("viande_de_essaim_abeilles")

	# 1bis. Ce sont des OBJETS, pas des blocs (2026-07-27) : aucune ressource
	# ne doit avoir d'id runtime, sinon elle serait posable dans le monde.
	var posables: Array[String] = []
	for rid: String in GameData.resources:
		if GameData.material_runtime_ids.has(rid) or GameData.is_placeable(rid):
			posables.append(rid)
	print("[BUTIN] ressources posables comme blocs : %d (attendu 0)" % posables.size())
	ok = ok and posables.is_empty()

	# 2. Unicité des couleurs sur TOUT le catalogue (B.1) — c'est la règle que
	# la génération pouvait le plus facilement casser.
	var par_couleur := {}
	var doublons := 0
	for mid: String in GameData.materials:
		var hex := String(GameData.materials[mid]["color"]).to_upper()
		if par_couleur.has(hex):
			doublons += 1
			print("[BUTIN]   DOUBLON %s : %s et %s" % [hex, par_couleur[hex], mid])
		par_couleur[hex] = mid
	print("[BUTIN] palette : %d matériaux, %d couleurs distinctes, %d doublons (attendu 0) — %d ressources hors palette" % [
			GameData.materials.size(), par_couleur.size(), doublons, GameData.resources.size()])
	ok = ok and doublons == 0

	# 3. Palette : la largeur doit couvrir tous les ids runtime — c'est le
	# plafond de 256 qui a été levé (le catalogue le dépasse maintenant).
	var ids := GameData.material_by_runtime.size()
	print("[BUTIN] ids runtime=%d, largeur de palette=%d (doit couvrir), masque liquides=%d" % [
			ids, GameData.palette_size(), GameData.liquid_mask.size()])
	ok = ok and GameData.palette_size() >= ids and GameData.liquid_mask.size() >= ids

	# 4. Bonus de potentiel A.9.1 : stat_source / 10, arrondi, plafond 8.
	var ours: Dictionary = GameData.creatures["ours_brun"]
	var viande_ours: Dictionary = GameData.resources["viande_de_ours_brun"]
	var force_source := float((ours["base_stats"] as Dictionary)["force"])
	var attendu_force := mini(8, int(round(force_source / 10.0)))
	var obtenu_force := int((viande_ours.get("potentiel", {}) as Dictionary).get("force", 0))
	print("[BUTIN] viande d'ours brun : Force source=%.0f → potentiel=%d (attendu %d, A.9.1)" % [
			force_source, obtenu_force, attendu_force])
	ok = ok and obtenu_force == attendu_force

	# 5. Dépeçage : tuer une créature remplit l'inventaire.
	CreatureManager.creature_root = Node3D.new()
	main.add_child(CreatureManager.creature_root)
	var cerf := CreatureManager.spawn("cerf", Vector3(0, 40, 0))
	player._creature_defeated(cerf)
	var apres_viande := _resource_units(player, "viande_de_cerf")
	var apres_peau := _resource_units(player, "peau_de_cerf")
	print("[BUTIN] cerf dépecé : viande=%d peau=%d (attendu > 0 des deux, en INSTANCES)" % [
			apres_viande, apres_peau])
	ok = ok and apres_viande > 0 and apres_peau > 0

	# Modèle INSTANCE (2026-07-27) : rien dans les piles de matériaux, tout
	# dans les objets — avec regroupement des unités identiques.
	var en_pile: bool = player.inventory.material_stacks.has("viande_de_cerf")
	var lignes := 0
	for obj: Dictionary in player.inventory.objects:
		if String(obj.get("resource_id", "")) == "viande_de_cerf":
			lignes += 1
	print("[BUTIN] viande en pile de matériau=%s (attendu false) — lignes d'inventaire=%d (attendu 1, regroupées)" % [
			en_pile, lignes])
	ok = ok and not en_pile and lignes == 1

	# Un deuxième dépeçage ne doit PAS créer une seconde ligne.
	var cerf2 := CreatureManager.spawn("cerf", Vector3(2, 40, 0))
	player._creature_defeated(cerf2)
	var lignes2 := 0
	for obj: Dictionary in player.inventory.objects:
		if String(obj.get("resource_id", "")) == "viande_de_cerf":
			lignes2 += 1
	print("[BUTIN] après 2e dépeçage : lignes=%d (attendu 1) unités=%d (attendu > %d)" % [
			lignes2, _resource_units(player, "viande_de_cerf"), apres_viande])
	ok = ok and lignes2 == 1 and _resource_units(player, "viande_de_cerf") > apres_viande

	# 6. La viande alimente la boucle de faim (A.9) : cru = 50 % (A.9.1).
	var nutrition: Dictionary = GameData.resources["viande_de_cerf"].get("nutrition", {})
	player.hunger = 30.0
	_select_object(player, "viande_de_cerf")
	player._try_eat()
	var gagne: float = player.hunger - 30.0
	print("[BUTIN] viande de cerf mangée crue : +%.1f faim (attendu %.1f = 50%% de %.0f)" % [
			gagne, float(nutrition.get("faim", 0)) * 0.5, float(nutrition.get("faim", 0))])
	ok = ok and is_equal_approx(gagne, float(nutrition["faim"]) * 0.5)

	# 7. Une peau ne se mange pas.
	player.hunger = 30.0
	if _select_object(player, "peau_de_cerf"):
		player._try_eat()
	print("[BUTIN] peau non comestible : faim inchangée=%s" % [is_equal_approx(player.hunger, 30.0)])
	ok = ok and is_equal_approx(player.hunger, 30.0)

	print("[BUTIN] RÉSULTAT : %s" % ("OK" if ok else "ÉCHEC"))
	main.get_tree().quit(0 if ok else 1)
