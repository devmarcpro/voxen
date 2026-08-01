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

	if can_capture():
		await screenshot("triche_general.png")
		print("[%s] %s" % [TAG, capture_path("triche_general.png")])
		# Bascule sur l'onglet Armes pour la seconde capture.
		var tabs := _find_tabs(menu)
		if tabs != null:
			tabs.current_tab = 1
			await wait_seconds(0.4)
			await screenshot("triche_armes.png")
			print("[%s] %s" % [TAG, capture_path("triche_armes.png")])
	else:
		print("[%s] captures ignorées : mode headless" % TAG)
	finish(differ, TAG)


func _find_tabs(node: Node) -> TabContainer:
	if node is TabContainer:
		return node
	for child in node.get_children():
		var found := _find_tabs(child)
		if found != null:
			return found
	return null
