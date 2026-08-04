extends Probe
## Sonde `--probe-triche` (2026-08-03) — COUVERTURE du menu de triche.
##
## « Absolument tout dans le jeu doit être accessible dans le menu de triche »
## est une exigence qu'on ne peut pas tenir à l'œil : le catalogue compte 278
## matériaux, 72 transformations, 53 compétences, 38 essences d'arbre. Personne
## ne relira ces grilles à chaque ajout de contenu, et c'est précisément à
## l'ajout suivant qu'un trou se creuse — un matériau nouveau atterrit dans un
## dossier, et rien ne signale qu'il n'est atteignable nulle part.
##
## La sonde ouvre donc le menu, ramasse le libellé de TOUS ses boutons, et
## vérifie que chaque entrée de chaque registre y figure. Elle échoue le jour où
## quelqu'un ajoute du contenu sans l'exposer, ce qui est le seul moment utile.
##
## Elle ne teste PAS que les boutons font ce qu'ils promettent — c'est le rôle
## des sondes de chaque système. Elle teste l'ACCÈS, rien d'autre.

const TAG := "TRICHE"

var _ok := true


func _expect(condition: bool, message: String) -> void:
	print("[%s] %s — %s" % [TAG, "ok" if condition else "ÉCHEC", message])
	if not condition:
		_ok = false


func run() -> void:
	await wait_seconds(1.0)
	var menu := main.get_node_or_null("CheatMenu")
	if menu == null:
		print("[%s] menu de triche introuvable." % TAG)
		main.get_tree().quit(1)
		return
	menu.call("_open")
	await wait_frame()

	var labels := {}
	_collect_button_labels(menu, labels)
	print("[%s] %d bouton(s) dans le menu" % [TAG, labels.size()])
	_expect(labels.size() > 300, "le menu expose un catalogue, pas une poignée de raccourcis")

	# Chaque famille de contenu du jeu. La liste est écrite ici À LA MAIN, et
	# c'est volontaire : c'est le seul endroit du projet qui déclare « voici
	# tout ce que le joueur peut posséder, poser ou devenir ». Un registre
	# nouveau doit être ajouté ici sciemment, pas découvert par hasard.
	_check_registry(labels, "matériaux", GameData.materials)
	_check_registry(labels, "objets", GameData.items)
	_check_registry(labels, "ressources/plats/munitions", GameData.resources)
	_check_registry(labels, "essences d'arbre", GameData.trees)
	_check_registry(labels, "plantes", GameData.plants)
	_check_registry(labels, "transformations", GameData.transformations)
	_check_registry(labels, "races", GameData.races)
	_check_registry(labels, "classes", GameData.classes)
	_check_registry(labels, "compétences", GameData.skills)
	_check_registry(labels, "statuts", GameData.status_effects)
	_check_registry(labels, "créatures", GameData.creatures)
	_check_registry(labels, "biomes", GameData.biomes)
	_check_registry(labels, "modules", GameData.modules)

	menu.call("_close")
	finish(_ok, TAG)


## Toutes les entrées d'un registre ont-elles un bouton ?
##
## On compare sur le LIBELLÉ TRADUIT, pas sur l'id : c'est ce que le menu
## affiche, donc ce qu'un joueur cherche. Deux entrées qui partagent un libellé
## seraient d'ailleurs un problème d'interface en soi.
func _check_registry(labels: Dictionary, family: String, registry: Dictionary) -> void:
	var missing: Array[String] = []
	for id: String in registry:
		var entry: Dictionary = registry[id]
		var label := tr(String(entry.get("name_key", id)))
		if not _reachable(labels, label):
			missing.append(id)
	if missing.is_empty():
		_expect(true, "%s : les %d entrées sont atteignables" % [family, registry.size()])
		return
	# On nomme les manquants : « 3 entrées absentes » n'aide personne à les
	# ajouter, la liste si.
	var shown := missing.slice(0, 8)
	_expect(false, "%s : %d/%d absent(s) du menu — %s%s" % [
			family, missing.size(), registry.size(), ", ".join(shown),
			"…" if missing.size() > shown.size() else ""])


## Un libellé est-il porté par un bouton ?
##
## ÉGALITÉ D'ABORD, PUIS CONTENANCE. Certains boutons décorent le nom d'une
## information utile — les modules affichent leur rôle et leur coût en mana,
## « [E] Boule de feu · 12 ». Exiger l'égalité stricte faisait échouer la sonde
## sur 35 modules pourtant tous présents à l'écran : c'est la sonde qui avait
## tort, pas le menu.
##
## La contenance peut en théorie valider à tort (« Fer » se trouve dans
## « Ferronnerie »). C'est un risque accepté pour une sonde d'ACCÈS : elle
## répond à « peut-on l'atteindre », pas à « quel bouton exactement ».
func _reachable(labels: Dictionary, label: String) -> bool:
	if labels.has(label):
		return true
	for text: String in labels:
		if text.contains(label):
			return true
	return false


## Ramasse le texte de tous les boutons du menu, à n'importe quelle profondeur.
func _collect_button_labels(node: Node, out: Dictionary) -> void:
	if node is Button:
		out[(node as Button).text] = true
	for child in node.get_children():
		_collect_button_labels(child, out)
