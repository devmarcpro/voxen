extends Probe
## Sonde `--probe-refonte-donjon` (2026-08-02) — valide la refonte des donjons :
## tour de pierre taillée, étage en labyrinthe, peuplement, butin au sol.
##
## POURQUOI UNE SONDE DE PLUS. `--probe-dungeon` vérifie la MÉCANIQUE (entrer,
## sortir, miner, persister) et doit continuer à le faire. Celle-ci vérifie la
## FORME, qui est l'objet de la demande : la tour occupe-t-elle vraiment la
## cellule, ses entrées débouchent-elles, le labyrinthe est-il connexe, ses deux
## escaliers sont-ils atteignables. Mélanger les deux aurait donné une sonde
## dont l'échec ne désigne rien de précis.
##
## Elle CAPTURE aussi. La leçon du LOD lointain (2026-08-02) vaut ici : deux
## défauts de géométrie n'ont été trouvés que par l'image, aucun chiffre ne les
## voyait.


## Assertion tracée. Cette sonde comparait jusqu'ici chaque condition à la main
## (`ok = ... and ok` plus un print) : un helper évite d'oublier l'un des deux.
var _ok := true


func _expect(condition: bool, message: String) -> void:
	print("[REFONTE] %s — %s" % ["ok" if condition else "ANOMALIE", message])
	if not condition:
		_ok = false


func run() -> void:
	await wait_frame()
	var gen := WorldManager.generator
	if gen == null:
		print("[REFONTE] aucun générateur — sonde inexploitable.")
		main.get_tree().quit(1)
		return

	# `: Variant` explicite : `:=` sur une fonction qui rend Variant déclenche
	# « type inféré depuis un Variant », traité comme une ERREUR dans ce projet.
	var cell: Variant = _find_dungeon_cell()
	if cell == null:
		print("[REFONTE] aucune cellule de donjon trouvée dans la fenêtre de recherche.")
		main.get_tree().quit(1)
		return
	var donjon: Vector2i = cell
	var centre := POIGenerator.cell_center_world(donjon)
	var ground: int = gen.height_at(centre.x, centre.y)
	print("[REFONTE] cellule de donjon %s, centre monde (%d, %d), sol %d" % [
			donjon, centre.x, centre.y, ground])

	var ok := true
	ok = _check_tower(donjon, centre, ground, gen) and ok
	ok = _check_maze(donjon) and ok
	ok = _check_books() and ok
	await _capture_tower(donjon, centre, ground)
	# L'ENTRÉE EST INCONDITIONNELLE, la capture ne l'est pas. Elle vivait dans
	# `_capture_maze`, qui sort immédiatement en `--headless` (pas de rendu) :
	# les deux vérifications suivantes lisent l'état RÉELLEMENT construit —
	# créatures peuplées, butin posé — et ne trouvaient donc rien du tout dès
	# que la sonde tournait sans fenêtre, c'est-à-dire en intégration continue.
	DungeonManager._enter_dungeon(donjon, camera.global_position)
	await wait_seconds(6.0)
	ok = _check_enemies(donjon) and ok
	ok = _check_ground_loot() and ok
	ok = _check_chests(donjon) and ok
	await _capture_maze(donjon)
	finish(ok, "REFONTE")


## TOUS les types d'ennemis doivent être représentés (demande explicite).
func _check_enemies(cell: Vector2i) -> bool:
	var attendus := DungeonManager._enemy_types()
	print("[REFONTE] types d'ennemis au catalogue : %d %s" % [attendus.size(), attendus])
	if attendus.is_empty():
		print("[REFONTE]   ANOMALIE : aucun type d'ennemi (profil hostile/bete_sauvage) au catalogue.")
		return false
	# On lit le peuplement réellement construit, pas l'intention du code.
	var vus := {}
	for c in CreatureManager.creatures:
		if is_instance_valid(c) and c.dimension == &"donjon":
			vus[c.creature_id] = true
	print("[REFONTE] types présents dans l'étage courant : %d/%d %s" % [
			vus.size(), attendus.size(), vus.keys()])
	if vus.size() < attendus.size():
		print("[REFONTE]   ANOMALIE : des types d'ennemis manquent à l'appel.")
		return false
	return true


## Livres (5.1) : génération, contenu, et jet de lecture (A.7).
func _check_books() -> bool:
	var ok := true
	var rng := RandomNumberGenerator.new()
	rng.seed = 12345
	for book_type: String in ["grimoire", "manuel"]:
		var facile := BookFactory.create(book_type, 0.0, rng)
		var dur := BookFactory.create(book_type, 1.0, rng)
		if facile.is_empty() or dur.is_empty():
			print("[REFONTE]   ANOMALIE : aucun module de type « %s » au catalogue." % book_type)
			ok = false
			continue
		print("[REFONTE] livre « %s » : facile difficulté=%d %d module(s) | difficile difficulté=%d %d module(s)" % [
				book_type, facile["difficulty"], (facile["modules"] as Array).size(),
				dur["difficulty"], (dur["modules"] as Array).size()])
		# La difficulté DOIT croître avec la puissance : c'est par elle que la
		# profondeur d'un donjon se traduit en qualité de butin (E.29).
		if int(dur["difficulty"]) <= int(facile["difficulty"]):
			print("[REFONTE]   ANOMALIE : la difficulté ne suit pas la puissance.")
			ok = false

	# Jet de lecture : un lecteur nul face à un livre redoutable doit
	# majoritairement ÉCHOUER, un maître face à un livre facile doit réussir.
	# Sans cet écart, la compétence Lecture ne servirait à rien.
	var dur_book := BookFactory.create("grimoire", 1.0, rng)
	var novice_ok := 0
	var maitre_ok := 0
	for i in 200:
		if bool(BookFactory.resolve_reading(dur_book, 0, 5, rng).get("reussite", false)):
			novice_ok += 1
		if bool(BookFactory.resolve_reading(dur_book, 60, 15, rng).get("reussite", false)):
			maitre_ok += 1
	print("[REFONTE] lecture d'un livre difficile (DD %d) : novice %d %%, maître %d %% de réussite" % [
			10 + int(dur_book["difficulty"]) / 2, novice_ok / 2, maitre_ok / 2])
	if novice_ok >= maitre_ok:
		print("[REFONTE]   ANOMALIE : la compétence Lecture ne change rien au résultat.")
		ok = false
	# Un échec doit produire un effet nommé, sinon le joueur perd son livre sans
	# aucune explication — le pire retour possible sur une mécanique voulue.
	var rate := BookFactory.resolve_reading(dur_book, 0, 0, rng)
	if not bool(rate.get("reussite", true)) and (rate.get("echec", {}) as Dictionary).is_empty():
		print("[REFONTE]   ANOMALIE : échec de lecture sans effet associé (data/reading_failures.json).")
		ok = false
	return ok


## Le butin de l'étage est-il posé au sol, et rendu comme de VRAIS objets ?
func _check_ground_loot() -> bool:
	var caches := 0
	var objets := 0
	var livres := 0
	for cache: Dictionary in DropManager.caches:
		if StringName(cache.get("dimension", &"overworld")) != &"donjon":
			continue
		caches += 1
		for obj: Dictionary in (cache.get("objects", []) as Array):
			objets += 1
			if BookFactory.is_book(obj):
				livres += 1
	print("[REFONTE] butin au sol de l'étage : %d caches, %d objets dont %d livres" % [
			caches, objets, livres])
	if caches == 0 or objets == 0:
		print("[REFONTE]   ANOMALIE : aucun butin posé dans l'étage.")
		return false
	# Chaque objet doit avoir sa propre représentation au sol (demande
	# explicite : « des items par terre », un par objet).
	var rendus := 0
	for marker in DropManager._markers:
		if is_instance_valid(marker):
			rendus += 1
	print("[REFONTE] représentations au sol construites : %d (objets + repères d'or)" % rendus)
	if rendus < objets:
		print("[REFONTE]   ANOMALIE : moins de représentations que d'objets — le rendu par objet ne se fait pas.")
		return false
	return true


## COFFRES (F.6, 2026-08-03). Le coffre de boss est désormais un VRAI coffre
## posé, identique au coffre craftable — plus une cache au sol déguisée. On
## vérifie donc qu'il EXISTE comme bloc, qu'il se vide dans l'inventaire, et
## surtout que le CASSER rend son contenu : c'est la règle qui distingue un
## rangement d'un piège, et la seule dont l'oubli coûterait trente objets.
func _check_chests(cell: Vector2i) -> bool:
	_ok = true
	_expect(GameData.materials.has("coffre") and GameData.materials.has("grand_coffre"),
			"les deux coffres de F.6 sont au catalogue")
	_expect(ContainerManager.is_chest_material("coffre"),
			"le coffre est reconnu comme conteneur (tag)")
	_expect(not ContainerManager.is_chest_material("pierre"),
			"un bloc ordinaire n'est pas un conteneur")

	# Le coffre de boss du DERNIER étage doit exister en tant que bloc.
	var floors := DungeonManager._floor_count(cell)
	DungeonManager._enter_dungeon(cell, camera.global_position)
	while DungeonManager._current_depth < floors - 1:
		DungeonManager._descend()
	var trouve := Vector3i(-1, -1, -1)
	for pos: Vector3i in ContainerManager.chests:
		trouve = pos
		break
	print("[REFONTE] coffres posés dans l'étage du boss : %d (premier en %s)" % [
			ContainerManager.chests.size(), trouve])
	_expect(ContainerManager.chests.size() > 0, "le boss a un coffre POSÉ, pas une cache")
	if trouve.x < 0:
		return false

	var block := DungeonManager.dimension_block_at(trouve)
	var nom := _material_name(block)
	print("[REFONTE] bloc à cet emplacement : « %s »" % nom)
	_expect(nom == "coffre", "l'emplacement porte bien un bloc coffre")

	# VIDAGE : le contenu part dans l'inventaire.
	var use := ContainerManager.usage(trouve)
	var avant: int = (player.inventory.objects as Array).size()
	var or_recu: int = ContainerManager.take_all(trouve, player.inventory)
	var apres: int = (player.inventory.objects as Array).size()
	print("[REFONTE] coffre de boss : %d/%d lignes → %d objet(s) et %d or récupérés" % [
			use.x, use.y, apres - avant, or_recu])
	_expect(apres > avant, "vider le coffre transfère son contenu")
	_expect(or_recu > 0, "le coffre de boss porte de l'or")

	# LE PANNEAU DE COFFRE (2026-08-03). Il remplace le « tout rafler » de la
	# touche d'interaction, qui suffisait à vider un coffre de boss mais rendait
	# le coffre inutilisable pour ce à quoi il sert : ranger et reprendre.
	var panel := main.get_node_or_null("ChestPanel")
	if panel == null:
		_expect(false, "le panneau de coffre est instancié dans la scène")
	else:
		ContainerManager.fill(trouve, "coffre", [], 0)
		var ouvert: bool = panel.call("open_at", trouve)
		_expect(ouvert, "le panneau s'ouvre sur un coffre")
		# DÉPÔT SÉLECTIF : c'est la fonction qui manquait entièrement.
		var dague: Dictionary = ItemFactory.craft("dague",
				{"bois": "chene", "minerai": "fer"}, 1.0)
		player.inventory.add_object(dague)
		panel.call("_deposit_object", dague)
		var dedans: int = ((ContainerManager.contents(trouve)["objects"]) as Array).size()
		print("[REFONTE] dépôt d'un objet → %d dans le coffre" % dedans)
		_expect(dedans == 1, "déposer un objet le transfère dans le coffre")
		panel.call("_take_all")
		_expect(((ContainerManager.contents(trouve)["objects"]) as Array).is_empty(),
				"tout prendre vide le coffre")
		panel.call("_close")
		_expect(not bool(panel.get("is_open")), "le panneau se referme")

	# CASSER REND LE CONTENU. On remplit puis on casse, et le butin doit
	# réapparaître au sol.
	ContainerManager.fill(trouve, "coffre", [ItemFactory.craft("dague",
			{"bois": "chene", "minerai": "fer"}, 1.0)], 25)
	var caches_avant: int = DropManager.caches.size()
	ContainerManager._on_block_destroyed(trouve, 0)
	var caches_apres: int = DropManager.caches.size()
	print("[REFONTE] coffre cassé : caches au sol %d → %d" % [caches_avant, caches_apres])
	_expect(caches_apres > caches_avant,
			"casser un coffre recrache son contenu au lieu de le détruire")
	_expect(not ContainerManager.chests.has(trouve), "le coffre cassé disparaît")
	return _ok


## Le labyrinthe est-il de la bonne taille, connexe, et ses deux escaliers
## atteignables ? Un escalier de descente enfermé dans une poche isolée est le
## défaut le plus grave possible : le donjon devient infranchissable et rien ne
## le signale au joueur, qui cherche indéfiniment.
func _check_maze(cell: Vector2i) -> bool:
	var ok := true
	var span := DungeonGenerator.SPAN
	var quart := ClaimManager.CELL_SIZE / 2   # Côté d'un quart d'AIRE de cellule.
	print("[REFONTE] emprise d'un étage : %d×%d blocs (quart de l'aire d'une cellule = %d×%d)" % [
			span, span, quart, quart])
	if span != quart:
		print("[REFONTE]   ANOMALIE : l'étage ne fait pas un quart de l'aire de la cellule.")
		ok = false

	# Tous les étages du donjon, pas seulement le premier : le tirage change à
	# chaque profondeur et un seul plan ne prouve rien sur les autres.
	var floors := DungeonManager._floor_count(cell)
	for depth in floors:
		DungeonManager._ensure_floor_data(cell, depth)
		var plan: Dictionary = DungeonManager._floors[DungeonManager._floor_key(cell, depth)]
		var reachable := DungeonGenerator.reachable_blocks(plan)
		var open_count := 0
		for b: int in (plan["open"] as PackedByteArray):
			open_count += b
		var up: Vector3i = plan["up_stair"]
		var down: Vector3i = plan["down_stair"]
		var dernier := depth == floors - 1
		var up_ok := reachable.has(Vector2i(up.x, up.z))
		var down_ok := dernier or reachable.has(Vector2i(down.x, down.z))
		# Un labyrinthe dont une partie n'est pas reliée gaspille de la surface
		# et peut y enfermer du butin. On tolère une marge, mais pas une poche.
		var connexite := float(reachable.size()) / maxf(float(open_count), 1.0)
		print("[REFONTE] étage %d : %d salles, %d blocs praticables, %.0f %% reliés — escalier montant=%s descendant=%s" % [
				depth, (plan["rooms"] as Array).size(), open_count, connexite * 100.0,
				up_ok, "absent (dernier étage)" if dernier else str(down_ok)])
		if not up_ok or not down_ok:
			print("[REFONTE]   ANOMALIE : un escalier est hors de la zone atteignable.")
			ok = false
		if connexite < 0.99:
			print("[REFONTE]   ANOMALIE : le labyrinthe a des poches isolées.")
			ok = false
		if (plan["rooms"] as Array).is_empty():
			print("[REFONTE]   ANOMALIE : étage sans aucune salle.")
			ok = false
	return ok


## Vue en plan d'un étage. Comme pour la tour, c'est l'image qui tranche :
## « connexe » et « lisible » sont deux choses différentes, et seule la seconde
## dit si le labyrinthe est agréable à parcourir.
func _capture_maze(cell: Vector2i) -> void:
	if not can_capture():
		_print_plan(cell, DungeonManager._current_depth)
		return
	# Vue À HAUTEUR D'HOMME dans un couloir, et pas en plan zénithal. Une vue du
	# dessus ne montre que le plafond — l'étage est un volume fermé, pas une
	# maquette ouverte ; la première tentative n'a produit qu'une dalle beige.
	# Le plan, lui, se lit bien mieux en texte (voir _print_plan).
	var spawn := DungeonManager._entrance_center()
	camera.position = spawn + Vector3(0, 1.6, 0)
	camera.rotation_degrees = Vector3(-4.0, 0.0, 0.0)
	await wait_seconds(4.0)
	await screenshot("donjon_labyrinthe.png")
	print("[REFONTE] capture du labyrinthe : debug/donjon_labyrinthe.png")
	_print_plan(cell, DungeonManager._current_depth)


## Imprime le plan de l'étage en texte. Pour un labyrinthe c'est la
## vérification la plus dense qui soit : on voit d'un coup les couloirs, les
## salles, les impasses, les boucles du tressage et la position des deux
## escaliers — ce qu'aucune capture 3D d'un volume fermé ne peut montrer.
##   `#` mur   `.` praticable   `M` escalier montant   `D` escalier descendant
func _print_plan(cell: Vector2i, depth: int) -> void:
	var plan: Dictionary = DungeonManager._floors.get(
			DungeonManager._floor_key(cell, depth), {})
	if plan.is_empty():
		return
	var open: PackedByteArray = plan["open"]
	var span: int = plan["span"]
	var up: Vector3i = plan["up_stair"]
	var down: Vector3i = plan["down_stair"]
	print("[REFONTE] plan de l'étage %d (# mur, . praticable, M montée, D descente) :" % depth)
	for z in span:
		var line := ""
		for x in span:
			if x == up.x and z == up.z:
				line += "M"
			elif down.y >= 0 and x == down.x and z == down.z:
				line += "D"
			else:
				line += "." if open[z * span + x] == 1 else "#"
		print("[REFONTE] " + line)


## Première cellule de donjon autour de l'origine. Balayage en carré croissant :
## la densité est de 6 % par cellule (E.2), une fenêtre de quelques dizaines de
## cellules en contient forcément.
func _find_dungeon_cell() -> Variant:
	for ring in range(0, 45):
		for dx in range(-ring, ring + 1):
			for dz in range(-ring, ring + 1):
				# Seul le pourtour de l'anneau est neuf.
				if ring > 0 and absi(dx) != ring and absi(dz) != ring:
					continue
				var candidate := Vector2i(dx, dz)
				if DungeonManager.is_dungeon_cell(candidate):
					return candidate
	return null


## La tour occupe-t-elle la cellule, et ses entrées débouchent-elles ?
func _check_tower(cell: Vector2i, centre: Vector2i, ground: int, gen: NoiseGenerator) -> bool:
	var ok := true
	var seed_value: int = WorldManager.world_seed

	# 1. Emprise : la masse doit couvrir l'essentiel de la cellule et s'arrêter
	# net avant la bordure, sinon deux donjons voisins se souderaient.
	var couverture := 2.0 * DungeonTower.RADIUS / float(ClaimManager.CELL_SIZE)
	print("[REFONTE] emprise : diamètre %d blocs sur une cellule de %d (%.0f %%)" % [
			int(DungeonTower.RADIUS * 2.0), ClaimManager.CELL_SIZE, couverture * 100.0])
	if couverture < 0.85:
		print("[REFONTE]   ANOMALIE : la tour n'occupe pas la cellule.")
		ok = false
	if DungeonTower.RADIUS >= float(ClaimManager.CELL_SIZE) / 2.0:
		print("[REFONTE]   ANOMALIE : le rayon dépasse la demi-cellule — débordement chez la voisine.")
		ok = false

	# 2. Matière : tout ce qui est plein doit être de la PIERRE TAILLÉE. C'est
	# la demande littérale (« tout en pierre taillée ») et c'est ce qui a changé.
	var palette := DungeonTower.palette_for(cell, seed_value)
	var noms: Array[String] = []
	for rid: int in palette:
		noms.append(_material_name(rid))
	var toutes_taillees := true
	for nom in noms:
		var mat: Dictionary = GameData.materials.get(nom, {})
		if not ("pierre_taillee" in (mat.get("tags", []) as Array)):
			toutes_taillees = false
	print("[REFONTE] palette de la cellule : %s (toutes taillées : %s)" % [noms, toutes_taillees])
	if not toutes_taillees:
		print("[REFONTE]   ANOMALIE : la tour n'est pas bâtie en pierre taillée.")
		ok = false

	# 3. Entrées : depuis le milieu de chaque tunnel cardinal, à hauteur d'homme,
	# le bloc doit être VIDE — une entrée murée est le pire défaut possible ici,
	# elle rend le donjon inaccessible à pied sans que rien ne le signale.
	var ouvertes := 0
	var mi := int(DungeonTower.RADIUS) / 2
	for dir: Vector2i in [Vector2i(mi, 0), Vector2i(-mi, 0), Vector2i(0, mi), Vector2i(0, -mi)]:
		var libre := true
		for h in range(1, DungeonTower.ENTRY_HEIGHT - 2):
			var b: int = gen.block_at(centre.x + dir.x, ground + h, centre.y + dir.y)
			if b != 0:
				libre = false
				break
		if libre:
			ouvertes += 1
	print("[REFONTE] tunnels d'entrée dégagés : %d sur 4" % ouvertes)
	if ouvertes < 4:
		print("[REFONTE]   ANOMALIE : une entrée est murée — donjon inaccessible à pied.")
		ok = false

	# 4. Salle centrale : creuse, et reconnue comme déclencheur d'entrée.
	var creux: bool = gen.block_at(centre.x, ground + 3, centre.y) == 0
	var declencheur := DungeonTower.inside_interior(cell, centre.x, ground + 3, centre.y, ground, seed_value)
	print("[REFONTE] salle centrale : creuse=%s, déclenche l'entrée=%s" % [creux, declencheur])
	if not creux or not declencheur:
		print("[REFONTE]   ANOMALIE : la salle d'entrée est pleine ou n'arme pas l'entrée en donjon.")
		ok = false
	return ok


## Nom texte d'un id runtime. `material_by_runtime` est un Array[String] indexé
## par l'id, PAS un Dictionary : `.get(id, defaut)` n'y existe pas (Array.get ne
## prend qu'un argument) et l'index doit être borné à la main.
func _material_name(rid: int) -> String:
	if rid < 0 or rid >= GameData.material_by_runtime.size():
		return "?"
	return GameData.material_by_runtime[rid]


func _capture_tower(_cell: Vector2i, centre: Vector2i, ground: int) -> void:
	if not can_capture():
		return
	camera.input_locked = true
	var cx := float(centre.x)
	var cz := float(centre.y)

	# 1. VUE ZÉNITHALE. C'est elle qui tranche, et elle est venue d'un échec :
	# la première capture, prise de trois quarts, était inexploitable — la tour
	# de calcaire taillé se confondait avec un relief de mesa de la même teinte
	# pâle, au point qu'on ne pouvait pas dire laquelle des quatre masses à
	# l'écran était la structure. Vue du dessus, le plan circulaire, les huit
	# tourelles et la croix des quatre tunnels ne ressemblent à aucun relief.
	camera.position = Vector3(cx, float(ground) + 210.0, cz + 0.1)
	camera.look_at(Vector3(cx, float(ground), cz), Vector3.FORWARD)
	await wait_seconds(22.0)
	await screenshot("donjon_tour_plan.png")
	print("[REFONTE] capture zénithale : debug/donjon_tour_plan.png")

	# 2. VUE AU RAS DU SOL, dans l'axe d'un tunnel d'entrée : la seule qui
	# montre ce que le joueur voit en arrivant, et si l'entrée est franchissable.
	camera.position = Vector3(cx - DungeonTower.RADIUS - 45.0, float(ground) + 4.0, cz)
	camera.look_at(Vector3(cx, float(ground) + 18.0, cz), Vector3.UP)
	await wait_seconds(12.0)
	await screenshot("donjon_tour_entree.png")
	print("[REFONTE] capture de l'entrée : debug/donjon_tour_entree.png")
