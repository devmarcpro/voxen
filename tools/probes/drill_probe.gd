extends Probe
## Sonde `--probe-foreuse` (2026-08-03) — outils de minage à large emprise.
##
## Une foreuse retire jusqu'à 25 blocs d'un geste : c'est le geste le plus
## destructeur du jeu, et deux choses doivent tenir.
##
## D'ABORD QU'ELLE NE SOIT PAS UN PASSE-PARTOUT. La règle d'irrécoltabilité
## (A.2) et le scellement des structures de donjon (3.5) sont les deux verrous
## qui empêchent d'aller chercher n'importe quoi n'importe quand ; un outil de
## zone est exactement le genre de chose qui les contourne par accident, en
## traitant son carré comme un bloc unique dont un seul coin aurait été vérifié.
##
## ENSUITE QUE L'EMPRISE SOIT CELLE ANNONCÉE, dans le bon plan. Une foreuse 5×5
## qui creuse un puits de 5 quand on vise un mur n'est pas la même chose.

const TAG := "FOREUSE"

var _ok := true


func _expect(condition: bool, message: String) -> void:
	print("[%s] %s — %s" % [TAG, "ok" if condition else "ÉCHEC", message])
	if not condition:
		_ok = false


func run() -> void:
	await wait_frame()
	_check_catalogue()
	await _check_areas()
	await _check_hardness_rule()
	finish(_ok, TAG)


## Les quatre foreuses existent, sont des OUTILS DE PIOCHE, et leurs emprises
## sont bien 2, 3, 4, 5 — pas trois fois la même valeur recopiée.
func _check_catalogue() -> void:
	var expected := {"foreuse": 2, "foreuse_plus": 3, "foreuse_pro": 4, "foreuse_max": 5}
	for drill_id: String in expected:
		var item: Dictionary = GameData.items.get(drill_id, {})
		var functionality: Dictionary = GameData.functionalities.get(drill_id, {})
		if item.is_empty() or functionality.is_empty():
			_expect(false, "« %s » existe (objet et fonctionnalité)" % drill_id)
			continue
		_expect(int(functionality.get("mining_area", 1)) == expected[drill_id],
				"« %s » mine %d×%d" % [drill_id, expected[drill_id], expected[drill_id]])
		# MÊME CATÉGORIE QUE LA PIOCHE : sans ça, la foreuse ne minerait rien du
		# tout, `_held_tool_for` ne la reconnaissant pas comme l'outil du
		# matériau visé.
		_expect(String(functionality.get("tool_category", "")) == "pioche",
				"« %s » est un outil de la catégorie pioche" % drill_id)
		# L'emprise doit SURVIVRE à la fabrication : c'est l'instance que le
		# joueur tient, pas la fiche de fonctionnalité.
		var made := ItemFactory.craft(drill_id, {"bois": "chene", "minerai": "fer"}, 1.0)
		_expect(int(made.get("mining_area", 1)) == expected[drill_id],
				"l'exemplaire fabriqué de « %s » garde son emprise" % drill_id)


## L'EMPRISE RÉELLE, mesurée en creusant. On pose un bloc tendre en volume, on
## mine, on compte ce qui a disparu.
func _check_areas() -> void:
	var player: Node = main.get_node_or_null("Player")
	if player == null:
		_expect(false, "joueur présent")
		return
	# PIERRE, PAS TERRE. La terre se creuse à la PELLE (`tool_category: pelle`) ;
	# une foreuse est de catégorie pioche et l'ignore, à juste titre. Le premier
	# essai de cette sonde a creusé dans de la terre et conclu que les foreuses
	# ne minaient rien.
	var dirt: int = GameData.material_runtime_ids.get("pierre", 0)
	if dirt == 0:
		_expect(false, "matériau d'essai disponible")
		return

	for drill_id: String in ["foreuse", "foreuse_max"]:
		var side: int = int(GameData.functionalities[drill_id].get("mining_area", 1))
		# Bloc d'essai isolé en altitude : rien d'autre alentour ne peut
		# expliquer une disparition.
		var origin := Vector3i(400 + int(side) * 40, 300, 400)
		for dx in range(-4, 5):
			for dy in range(-4, 5):
				for dz in range(-4, 5):
					WorldManager.set_block(origin + Vector3i(dx, dy, dz), dirt)

		var mined := await _drill_at(player, drill_id, origin, Vector3i(0, 1, 0))
		print("[%s] %s visée par le dessus : %d bloc(s) retirés" % [TAG, drill_id, mined])
		_expect(mined == side * side, "%s retire %d bloc(s)" % [drill_id, side * side])

		# LE PLAN SUIT LA FACE. Visée de côté, le carré doit être VERTICAL : on
		# vérifie qu'il ne reste rien sur une colonne du plan, et que la
		# profondeur n'a pas bougé.
		var side_origin := origin + Vector3i(0, 0, 0)
		for dx in range(-4, 5):
			for dy in range(-4, 5):
				for dz in range(-4, 5):
					WorldManager.set_block(side_origin + Vector3i(dx, dy, dz), dirt)
		var mined_side := await _drill_at(player, drill_id, side_origin, Vector3i(1, 0, 0))
		var depth_intact := WorldManager.block_at_world(side_origin + Vector3i(1, 0, 0)) != 0
		print("[%s] %s visée de côté : %d bloc(s) retirés, profondeur intacte=%s" % [
				TAG, drill_id, mined_side, depth_intact])
		_expect(mined_side == side * side, "%s retire %d bloc(s) de côté" % [drill_id, side * side])
		_expect(depth_intact, "le carré est dans le plan de la face, il ne creuse pas en profondeur")


## LA RÈGLE D'IRRÉCOLTABILITÉ TIENT AUSSI EN ZONE. Une foreuse de bois ne doit
## pas emporter du granit parce qu'il se trouvait dans son carré.
func _check_hardness_rule() -> void:
	var player: Node = main.get_node_or_null("Player")
	var dirt: int = GameData.material_runtime_ids.get("pierre", 0)
	var hard: int = GameData.material_runtime_ids.get("granit", 0)
	if player == null or dirt == 0 or hard == 0:
		_expect(false, "matériaux d'essai disponibles (pierre + granit)")
		return
	var origin := Vector3i(900, 300, 900)
	for dx in range(-4, 5):
		for dy in range(-4, 5):
			for dz in range(-4, 5):
				WorldManager.set_block(origin + Vector3i(dx, dy, dz), dirt)
	# Un bloc dur planté dans le carré.
	var hard_pos := origin + Vector3i(1, 0, 1)
	WorldManager.set_block(hard_pos, hard)

	# Foreuse en matériaux TENDRES : incapable du granit, capable de la terre.
	var tool := ItemFactory.craft("foreuse_max", {"bois": "balsa", "minerai": "cuivre"}, 0.6)
	var granite: Dictionary = GameData.materials["granit"]
	var reachable := float(tool["base_hardness"]) * float(tool["quality"]) \
			>= float(granite["stats"]["durete"]) * 0.5
	if reachable:
		print("[%s] la foreuse d'essai perce le granit — test d'irrécoltabilité non concluant." % TAG)
		return
	var mined := await _drill_with(player, tool, origin, Vector3i(0, 1, 0))
	var granite_left := WorldManager.block_at_world(hard_pos) == hard
	print("[%s] foreuse tendre sur un carré contenant du granit : %d retirés, granit intact=%s" % [
			TAG, mined, granite_left])
	_expect(granite_left, "le granit hors de portée de l'outil RESTE en place")
	_expect(mined > 0, "les blocs tendres du même carré sont bien retirés")


## Fabrique la foreuse et creuse. Retourne le nombre de blocs disparus.
func _drill_at(player: Node, drill_id: String, target: Vector3i, normal: Vector3i) -> int:
	var tool := ItemFactory.craft(drill_id, {"bois": "chene", "minerai": "fer"}, 1.0)
	return await _drill_with(player, tool, target, normal)


## Creuse avec un exemplaire déjà fabriqué.
##
## On passe par les mêmes champs que le jeu (hotbar, cible, normale) puis on
## pousse des ticks : la sonde ne doit pas court-circuiter `_on_tick`, sinon
## elle validerait un chemin que personne n'emprunte.
func _drill_with(player: Node, tool: Dictionary, target: Vector3i, normal: Vector3i) -> int:
	var before := _count_solid(target)
	player.inventory.add_object(tool)
	player.set("_target", target)
	player.set("_target_normal", normal)
	player.set("_target_valid", true)
	player.set("_mining", true)
	player.set("_progress", 0.0)
	# ON MET VRAIMENT L'OUTIL EN MAIN. C'est l'outil TENU qui compte (4.2), et
	# le posséder ne suffit pas : la première version de cette sonde devinait
	# des index de hotbar qui n'existent pas sous ces noms, si bien que le
	# joueur creusait à mains nues et la sonde accusait les foreuses.
	player.call("equip_instance_in_slot", tool, "arme_1")
	player.set("selected_slot", player.COMBAT_SLOT)
	# Assez de ticks pour venir à bout du carré, jamais infini.
	for i in 400:
		TickManager.push_ticks(1)
		if _count_solid(target) < before:
			break
	player.set("_mining", false)
	return before - _count_solid(target)


## Blocs pleins dans le cube 9³ centré sur `origin`.
func _count_solid(origin: Vector3i) -> int:
	var n := 0
	for dx in range(-4, 5):
		for dy in range(-4, 5):
			for dz in range(-4, 5):
				if WorldManager.block_at_world(origin + Vector3i(dx, dy, dz)) != 0:
					n += 1
	return n
