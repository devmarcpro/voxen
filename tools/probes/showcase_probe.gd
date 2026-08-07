extends Probe
## Sonde `--probe-vitrine` (2026-08-06) — le monde plat, les rangées, et la
## pose d'objets au sol.
##
## ---------------------------------------------------------------------------
## CE QU'ELLE DÉFEND, ET POURQUOI CHAQUE ASSERTION EXISTE
## ---------------------------------------------------------------------------
## 1. LA DÉRIVE SILENCIEUSE DE LA VITRINE. C'est l'assertion centrale, celle
##    qui a été exigée avant même que le code soit écrit : le nombre d'entrées
##    posées doit valoir la TAILLE DU CATALOGUE. Une vitrine construite depuis
##    une liste écrite à la main serait périmée dès le matériau suivant, et
##    personne ne le verrait — on regarderait une vitrine complète en croyant
##    voir tout le jeu. Le pire mode d'échec possible pour un outil dont le
##    seul métier est de montrer ce qui existe.
##
##    Et elle ne se contente PAS de compter : elle RELIT LE MONDE à chaque
##    position. Un compteur incrémenté par le constructeur ne prouverait que
##    l'existence d'une boucle, pas celle d'un bloc — c'est exactement le genre
##    d'assertion vraie pour la mauvaise raison qui a déjà validé du code mort
##    ici (un chunk non maillé comparé à un chunk maillé, un test de bridage qui
##    ne bridait rien).
##
## 2. LE MONDE PLAT QUI NE L'EST PAS. Le paramètre `terrain: "plat"` est une
##    branche dans `_terrain` ; tout le reste du pipeline continue de tourner.
##    Une garde oubliée (cavernes, rivières, ville, tour) ne lève aucune erreur,
##    elle creuse un trou ou plante une tour au milieu des rangées.
##
## 3. LA MACHINE À RÉPARER. Poser un objet puis le reprendre doit rendre
##    L'EXEMPLAIRE, pas un objet neuf de même type. Si la reprise reconstruisait
##    depuis la fiche, une épée usée de qualité médiocre reviendrait neuve et
##    parfaite — un exploit qui ne se verrait qu'une fois exploité, et jamais
##    par une capture.
##
## 4. CE QU'AUCUNE ASSERTION NE DIT : à quoi ça RESSEMBLE. D'où les captures.
##    C'est la raison d'être de tout ce travail.

const TAG := "VITRINE"

var _ok := true


func _expect(condition: bool, message: String) -> void:
	print("[%s] %s — %s" % [TAG, "ok" if condition else "ÉCHEC", message])
	if not condition:
		_ok = false


func run() -> void:
	await wait_frame()
	_check_flat()
	await _wait_for_showcase()
	_check_catalogue_coverage()
	_check_object_round_trip()
	await _capture()
	finish(_ok, TAG)


# --- 1. Le monde est-il vraiment plat, et vraiment vide de l'overworld ? ---

func _check_flat() -> void:
	var generator: NoiseGenerator = WorldManager.generator
	if generator == null:
		_expect(false, "aucun générateur — le monde n'a pas démarré.")
		return
	var expected := int(generator.FLAT_HEIGHT)
	var flat := true
	var worst := 0
	# Balayage LARGE : la dalle doit tenir bien au-delà des rangées, sinon on
	# marcherait jusqu'au bord de la vitrine et on tomberait dans du relief.
	for i in 400:
		var wx := (i % 20) * 61 - 610
		var wz := (i / 20) * 61 - 610
		var h := generator.height_at(wx, wz)
		if h != expected:
			flat = false
			worst = h
	_expect(flat, "sol constant à y=%d sur 400 colonnes réparties sur 1 200 blocs%s" % [
		expected, "" if flat else " (trouvé %d)" % worst])

	# LES SYSTÈMES DE L'OVERWORLD DOIVENT ÊTRE MUETS ICI. On ne teste pas leurs
	# drapeaux, on teste leur EFFET : un drapeau juste avec un système qui passe
	# quand même par un autre chemin, c'est ce qui a fait vivre des mois au
	# défaut des tours tronquées.
	var underground_solid := true
	var open := 0
	for i in 300:
		var wx := (i % 20) * 37 - 370
		var wz := (i / 20) * 37 - 370
		# 24 blocs sous la surface : la profondeur où le karst de l'overworld
		# creuse le plus (CAVE_MAX_DEPTH le borne bien plus bas).
		if generator.block_at(wx, expected - 24, wz) == 0:
			underground_solid = false
			open += 1
	_expect(underground_solid, "aucune caverne sous la dalle (%d colonne(s) percée(s) sur 300)" % open)

	var no_tower := true
	for i in 40:
		if generator.tower_top_for_column(Vector2i(i * 7 - 140, i * 11 - 220)) >= 0:
			no_tower = false
	_expect(no_tower, "aucune tour de donjon sur 40 colonnes de chunks")


# --- 2. La couverture du catalogue ---

func _wait_for_showcase() -> void:
	# ON ATTEND LE DRAPEAU DE FIN, pas un signe de vie. `rows` se remplit rangée
	# par rangée : le tester revenait à photographier la vitrine pendant qu'on
	# la montait, et à conclure qu'il manquait 474 entrées.
	if main.showcase == null or not bool(main.showcase.get("done")):
		await main.showcase_built


## L'ASSERTION CENTRALE. Le catalogue ATTENDU est recalculé ici, depuis
## `GameData`, par un chemin INDÉPENDANT de celui du constructeur : si les deux
## se trompaient de la même façon, ils devraient s'être trompés deux fois de la
## même manière, ce qu'une liste partagée aurait rendu gratuit.
func _check_catalogue_coverage() -> void:
	var builder: RefCounted = main.showcase
	if builder == null:
		_expect(false, "aucune vitrine construite.")
		return
	var positions: Dictionary = builder.get("positions")

	var expected_blocks: Array[String] = []   # Matériaux : id → bloc du même id.
	var expected_other: Array[String] = []    # Arbres, structures : bloc quelconque.
	for id: String in GameData.materials:
		expected_blocks.append("materiau:" + id)
	for species_id: String in GameData.trees:
		expected_other.append("arbre:" + species_id)
	for archetype: String in CityGenerator.ARCHETYPES:
		expected_other.append("structure:" + archetype)

	var total := expected_blocks.size() + expected_other.size()
	_expect(positions.size() == total,
			"%d entrée(s) posée(s) pour %d au catalogue (%d matériau(x), %d essence(s), %d archétype(s))" % [
				positions.size(), total, expected_blocks.size(),
				GameData.trees.size(), CityGenerator.ARCHETYPES.size()])

	# CHAQUE ENTRÉE MANQUANTE EST NOMMÉE. « 312 au lieu de 313 » n'apprend rien :
	# ce qu'il faut savoir, c'est LAQUELLE est tombée, parce que c'est elle qui
	# désigne le maillon débranché.
	var missing: Array[String] = []
	for id: String in expected_blocks + expected_other:
		if not positions.has(id):
			missing.append(id)
	_expect(missing.is_empty(), "aucune entrée de catalogue sans position%s" % (
			"" if missing.is_empty() else " (manquantes : %s)" % ", ".join(missing.slice(0, 12))))

	# RELECTURE DU MONDE. C'est ce qui distingue « le constructeur a compté »
	# de « le bloc est là ».
	var wrong: Array[String] = []
	for id: String in expected_blocks:
		if not positions.has(id):
			continue
		var expected_id: int = GameData.material_runtime_ids.get(id.trim_prefix("materiau:"), 0)
		if WorldManager.block_at_world(positions[id]) != expected_id:
			wrong.append(id)
	_expect(wrong.is_empty(), "chaque matériau relu dans le monde à sa position%s" % (
			"" if wrong.is_empty() else " (faux : %s)" % ", ".join(wrong.slice(0, 12))))

	var empty_other: Array[String] = []
	for id: String in expected_other:
		if positions.has(id) and WorldManager.block_at_world(positions[id]) == 0:
			empty_other.append(id)
	_expect(empty_other.is_empty(), "chaque arbre et chaque structure a de la matière à son ancre%s" % (
			"" if empty_other.is_empty() else " (vides : %s)" % ", ".join(empty_other.slice(0, 12))))

	# LES OBJETS SONT DANS LE COMPTE, et par le même chemin que le reste : un
	# matériau `objet_<id>` par objet du catalogue, plus le repli générique.
	var object_blocks := 0
	for id: String in GameData.materials:
		if String((GameData.materials[id] as Dictionary).get("category", "")) == "objet":
			object_blocks += 1
	_expect(object_blocks == GameData.items.size() + 1,
			"%d bloc(s) d'objet pour %d objet(s) au catalogue + 1 repli" % [
				object_blocks, GameData.items.size()])

	# UN BLOC D'OBJET SANS INSTANCE EST INVISIBLE, et rien ne le dit. Il n'est
	# pas maillé — c'est `PlacedItemManager` qui monte son vrai modèle depuis
	# l'exemplaire. La rangée d'objets de la vitrine a été RIGOUREUSEMENT VIDE
	# sans qu'une seule assertion bronche : les blocs étaient bien là, ils
	# n'avaient rien à montrer. Il a fallu regarder une capture. Plus maintenant.
	var without_instance: Array[String] = []
	for id: String in expected_blocks:
		if String((GameData.materials[id.trim_prefix("materiau:")] as Dictionary)
				.get("category", "")) != "objet":
			continue
		if not positions.has(id):
			continue
		if PlacedItemManager.peek(positions[id]).is_empty():
			without_instance.append(id)
	_expect(without_instance.is_empty(),
			"chaque bloc d'objet porte un exemplaire (sans quoi il ne montre rien)%s" % (
				"" if without_instance.is_empty() else " (vides : %s)" % ", ".join(without_instance.slice(0, 12))))


# --- 3. Poser et reprendre un objet ---

## LA VÉRIFICATION QUI COMPTE : l'instance reprise est-elle L'EXEMPLAIRE POSÉ ?
##
## On forge délibérément un objet ABÎMÉ ET MÉDIOCRE. Avec un objet neuf de
## qualité par défaut, une reprise qui reconstruirait depuis la fiche rendrait
## un objet identique et le test passerait — vrai pour la mauvaise raison.
func _check_object_round_trip() -> void:
	var instance := ItemFactory.craft("epee", {"bois": _first_of("bois"), "minerai": _first_of("minerai")}, 0.37)
	if instance.is_empty():
		_expect(false, "impossible de forger l'épée témoin.")
		return
	# Marqueur d'usure : le champ n'existe pas encore dans le jeu, et c'est
	# justement pourquoi il est le bon témoin — il prouve que la reprise rend le
	# dictionnaire STOCKÉ, sans rien en savoir ni rien en reconstruire.
	instance["usure"] = 0.63
	var expected_uid := int(instance["uid"])
	var expected_quality := float(instance["quality"])
	var expected_materials: Dictionary = (instance["materials"] as Dictionary).duplicate()

	player.inventory.add_object(instance)
	if not _bind_object(instance):
		_expect(false, "impossible de mettre l'épée témoin en main.")
		return

	# CIBLAGE POSÉ À LA MAIN. Le raycast est recalculé à chaque frame : viser
	# « pour de vrai » demanderait de placer la caméra, d'attendre le streaming
	# du chunk, et ferait dépendre ce test de la géométrie du monde — la même
	# famille de fragilité qui a fait échouer `--probe-assemblage` sur le mur de
	# la maison du joueur. On ne mesure ici que la pose et la reprise.
	var cell := Vector3i(-40, ShowcaseBuilderScript.PLACE_Y, -40)
	WorldManager.set_block(cell, 0)
	player._target = cell + Vector3i(0, -1, 0)
	player._target_normal = Vector3i(0, 1, 0)
	player._target_valid = true
	player.selected_slot = 1

	var placed: bool = player._try_place_object()
	_expect(placed, "l'épée se pose au sol en tant que bloc")
	var block_id := WorldManager.block_at_world(cell)
	_expect(block_id == GameData.material_runtime_ids.get("objet_epee", -1),
			"le bloc posé est bien « objet_epee » (id runtime %d)" % block_id)
	_expect(player.inventory.object_by_uid(expected_uid).is_empty(),
			"l'épée a quitté l'inventaire (elle est dans le monde, pas dans les deux)")

	# Reprise par le MÊME geste, sur le bloc posé.
	player._target = cell
	player._target_valid = true
	var taken: bool = player._try_take_object()
	_expect(taken, "l'épée se reprend par le même geste")
	_expect(WorldManager.block_at_world(cell) == 0, "le bloc a disparu du monde")

	var back: Dictionary = player.inventory.object_by_uid(expected_uid)
	_expect(not back.is_empty(), "c'est le MÊME exemplaire qui revient (uid %d)" % expected_uid)
	if back.is_empty():
		return
	_expect(is_equal_approx(float(back.get("quality", -1.0)), expected_quality),
			"qualité conservée : %.3f (posée %.3f) — une reprise qui reconstruit rendrait un objet neuf" % [
				float(back.get("quality", -1.0)), expected_quality])
	_expect(is_equal_approx(float(back.get("usure", -1.0)), 0.63),
			"usure conservée : %.2f" % float(back.get("usure", -1.0)))
	_expect(back.get("materials", {}) == expected_materials,
			"matériaux conservés : %s" % str(back.get("materials", {})))

	# LA ROTATION. Un objet posé se pose DROIT ET À PLAT — tous pareil, sans quoi
	# une rangée d'objets ressemble à un tas renversé — et le clic droit à main
	# vide le fait pivoter d'un quart de tour. Deux choses à vérifier : que le
	# quart de tour est bien appliqué, et qu'il REVIENT à l'orientation de départ
	# au quatrième, faute de quoi l'angle dériverait sans jamais se refermer.
	PlacedItemManager.remember(cell, instance)
	_expect(int((PlacedItemManager.placed[cell] as Dictionary).get("yaw", -1)) == 0,
			"un objet fraîchement posé est droit (yaw 0)")
	PlacedItemManager.rotate(cell)
	_expect(int((PlacedItemManager.placed[cell] as Dictionary).get("yaw", -1)) == 1,
			"le clic droit à main vide fait pivoter d'un quart de tour")
	for _i in 3:
		PlacedItemManager.rotate(cell)
	_expect(int((PlacedItemManager.placed[cell] as Dictionary).get("yaw", -1)) == 0,
			"quatre quarts de tour ramènent à l'orientation de départ")
	_expect(not PlacedItemManager.rotate(cell + Vector3i(0, 4, 0)),
			"tourner là où il n'y a aucun objet ne fait rien (et le dit)")
	PlacedItemManager.take(cell)

	# LE REGISTRE NE DOIT PAS FUIR. Une entrée laissée derrière ferait
	# réapparaître l'objet au sol le jour où le bloc serait miné — donc un
	# duplicata, l'exploit dans l'autre sens.
	_expect(PlacedItemManager.peek(cell).is_empty(), "le registre ne garde rien après la reprise")


const ShowcaseBuilderScript = preload("res://systems/worldgen/showcase_builder.gd")


func _first_of(category: String) -> String:
	var ids: Array[String] = []
	for id: String in GameData.materials:
		if String((GameData.materials[id] as Dictionary).get("category", "")) == category:
			ids.append(id)
	ids.sort()
	return ids[0] if not ids.is_empty() else ""


func _bind_object(instance: Dictionary) -> bool:
	for entry: Dictionary in player.all_entries():
		if entry.get("kind", "") != "object":
			continue
		if int((entry["object"] as Dictionary).get("uid", -1)) != int(instance["uid"]):
			continue
		_leave_combat_slot(player)
		player.bind_hotbar(player.active_hotbar * player.HOTBAR_SLOTS + player.selected_slot, entry)
		return true
	return false


# --- 4. Les captures, qui sont tout le propos ---

func _capture() -> void:
	if not can_capture():
		print("[%s] captures impossibles (headless) — c'est pourtant le seul point de cette sonde." % TAG)
		return
	# MIDI, par l'horloge du jeu et jamais par une lumière forcée à côté : deux
	# sources d'heure divergent, et la capture de plantes a déjà été prise en
	# pleine nuit pour cette raison exacte.
	TickManager.tick_index = int(DayNightManager.TICKS_PER_DAY / 2.0)
	var builder: RefCounted = main.showcase
	if builder == null:
		return
	var origin: Vector3i = ShowcaseBuilderScript.ORIGIN
	# LE HUD MASQUE CE QU'ON VIENT REGARDER. Sept panneaux couvrent le tiers de
	# l'image, dont exactement la bande d'horizon où les rangées se lisent.
	var hud: CanvasLayer = main.get_node_or_null("HUD")
	if hud != null:
		hud.visible = false
	for row: Dictionary in (builder.get("rows") as Array):
		var label := String(row["label"])
		var z := int(row["z"])
		# ON ENFILE LA RANGÉE DANS L'AXE, et il a fallu une capture pour le
		# voir : sans lacet, la caméra regarde vers -Z par défaut, donc EN
		# TRAVERS des rangées. La première série photographiait vingt fois les
		# mêmes rangées empilées à l'horizon, dont pas un arbre.
		# CADRAGE PAR ÉCHELLE DE RANGÉE. Un cadrage unique ne peut pas convenir
		# aux deux : de loin, un bloc d'un mètre est un pixel ; de près, un arbre
		# de cinquante mètres est un tronc en travers de l'objectif — les deux
		# défauts constatés en capture.
		match String(row.get("scale", "bloc")):
			"arbre":
				camera.position = Vector3(float(origin.x) - 46.0, float(origin.y) + 30.0, float(z) - 16.0)
				camera.rotation_degrees = Vector3(-14.0, -72.0, 0.0)
			"structure":
				camera.position = Vector3(float(origin.x) - 22.0, float(origin.y) + 12.0, float(z) - 14.0)
				camera.rotation_degrees = Vector3(-12.0, -66.0, 0.0)
			_:
				camera.position = Vector3(float(origin.x) - 5.0, float(origin.y) + 2.6, float(z) - 3.2)
				camera.rotation_degrees = Vector3(-6.0, -76.0, 0.0)
		# LE STREAMING DOIT AVOIR RATTRAPÉ. Photographier tout de suite donne
		# des chunks vides et une capture qui accuse le contenu à tort.
		await wait_seconds(2.5)
		# LE NOM PORTE LE MONDE, sinon les rangées homonymes s'écrasent. La faille
		# de mana a ses propres bois, cristaux, minerais et végétaux : sur
		# vingt-six captures annoncées, six disparaissaient — et le compte
		# imprimé, lui, disait bien vingt-six.
		await screenshot("vitrine_%s_%s.png" % [
			String(row.get("set", "overworld")) if String(row.get("set", "")) != "" else "objets",
			label.replace(".", "_")])
	print("[%s] %d capture(s) dans debug/." % [TAG, (builder.get("rows") as Array).size()])
	if hud != null:
		hud.visible = true
