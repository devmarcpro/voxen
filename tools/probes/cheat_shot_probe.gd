extends Probe
## Sonde `--test-triche` — CAPTURES du menu de triche (fenêtré obligatoire).
##
## Aucune assertion sur l'apparence : un onglet, une grille, une lisibilité,
## ça se regarde. Elle vérifie en revanche ce qui se MESURE — que l'atelier
## d'armes forge réellement des exemplaires différents selon les matériaux.

const TAG := "SHOTTRICHE"


func run() -> void:
	await wait_seconds(2.5)
	var menu := main.get_node_or_null("CheatMenu")
	if menu == null:
		print("[%s] menu de triche introuvable" % TAG)
		finish(false, TAG)
		return
	menu.call("_open")
	await wait_seconds(0.4)

	# L'ATELIER FORGE-T-IL VRAIMENT DIFFÉREMMENT ? C'est tout l'intérêt de
	# pouvoir combiner : deux exemplaires de la même arme doivent différer.
	var before: int = player.inventory.objects.size()
	menu.set("_forge_wood", "balsa")
	menu.set("_forge_ore", "cuivre")
	menu.call("_forge_weapon", "epee")
	menu.set("_forge_wood", "gaiac")
	menu.set("_forge_ore", "plomb")
	menu.call("_forge_weapon", "epee")
	var made: int = player.inventory.objects.size() - before
	var light := {}
	var heavy := {}
	for obj: Dictionary in player.inventory.objects:
		if String(obj.get("item_id", "")) != "epee":
			continue
		if String((obj.get("materials", {}) as Dictionary).get("bois", "")) == "balsa":
			light = obj
		elif String((obj.get("materials", {}) as Dictionary).get("bois", "")) == "gaiac":
			heavy = obj
	var differ: bool = not light.is_empty() and not heavy.is_empty() \
		and float(heavy["weight"]) > float(light["weight"])
	print("[%s] 2 épées forgées (%d objets) : balsa/cuivre %.0f vs gaiac/plomb %.0f : %s" % [
		TAG, made, float(light.get("weight", 0.0)), float(heavy.get("weight", 0.0)),
		"OK" if differ else "ÉCHEC"])

	# LES BOUTONS SONT-ILS FONCTIONNELS ? Une capture montre qu'ils EXISTENT et
	# ne dit rien de plus : une action qui plante à l'appel a exactement la même
	# apparence. On exerce donc les actions nommées de la section modules/livres,
	# celles qui ne sont pas de simples fermetures d'une ligne.
	var modules_ok := true
	menu.call("_learn_module", "boule_de_feu")
	modules_ok = modules_ok and (player.known_modules as Dictionary).has("boule_de_feu")
	menu.call("_give_book", "grimoire", 0.5)
	var livres := 0
	for obj: Dictionary in player.inventory.objects:
		if BookFactory.is_book(obj):
			livres += 1
	modules_ok = modules_ok and livres > 0
	menu.call("_fill_example_assemblies")
	var skill_id: String = String(player.weapon_skill_id())
	var range_ok: bool = skill_id.is_empty() or not (player.assembly_at(skill_id, 0) as Array).is_empty()
	menu.call("_read_all_books")
	var restants := 0
	for obj: Dictionary in player.inventory.objects:
		if BookFactory.is_book(obj):
			restants += 1
	print("[%s] triche modules : appris=%s livre donné=%d assemblage posé=%s livres après lecture=%d" % [
		TAG, (player.known_modules as Dictionary).has("boule_de_feu"), livres, range_ok, restants])
	modules_ok = modules_ok and range_ok and restants == 0

	if can_capture():
		await screenshot("triche_general.png")
		print("[%s] %s" % [TAG, capture_path("triche_general.png")])
		# BAS DE L'ONGLET GÉNÉRAL (2026-08-03). Une seule capture ne montrait
		# que le haut : tout ce qui a été ajouté ensuite — créatures, modules,
		# livres, assemblages — restait invisible, donc invérifiable.
		var scroll := _find_scroll(menu)
		if scroll != null:
			scroll.scroll_vertical = 1 << 20   # borné par Godot au maximum réel
			await wait_seconds(0.4)
			var bas: int = scroll.scroll_vertical
			await screenshot("triche_general_bas.png")
			print("[%s] %s" % [TAG, capture_path("triche_general_bas.png")])
			# MILIEU : la grille des modules, la plus longue section ajoutée,
			# tombe entre les deux extrêmes et n'apparaissait sur aucune des deux.
			scroll.scroll_vertical = int(float(bas) * 0.62)
			await wait_seconds(0.4)
			await screenshot("triche_general_milieu.png")
			print("[%s] %s" % [TAG, capture_path("triche_general_milieu.png")])
		# Bascule sur l'onglet Armes pour la seconde capture.
		var tabs := _find_tabs(menu)
		if tabs != null:
			tabs.current_tab = 1
			await wait_seconds(0.4)
			await screenshot("triche_armes.png")
			print("[%s] %s" % [TAG, capture_path("triche_armes.png")])
	else:
		print("[%s] captures ignorées : mode headless" % TAG)
	finish(differ and modules_ok, TAG)


## Premier ScrollContainer trouvé — celui de l'onglet « Général ».
func _find_scroll(node: Node) -> ScrollContainer:
	for child in node.get_children():
		if child is ScrollContainer:
			return child
		var found := _find_scroll(child)
		if found != null:
			return found
	return null


func _find_tabs(node: Node) -> TabContainer:
	if node is TabContainer:
		return node
	for child in node.get_children():
		var found := _find_tabs(child)
		if found != null:
			return found
	return null
