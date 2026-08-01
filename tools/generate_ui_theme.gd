extends SceneTree
## Écrit le thème d'interface sur disque depuis UITheme.build().
##   godot --headless --path . --script tools/generate_ui_theme.gd
##
## POURQUOI UN FICHIER PLUTÔT QU'UNE AFFECTATION AU RUNTIME. Poser le thème sur
## la fenêtre racine (`get_tree().root.theme = ...`) ne suffit pas : dans Voxen,
## les interfaces sont des Control accrochés sous des nœuds 3D et des
## CanvasLayer, et l'héritage de thème ne les atteint pas de façon fiable. Le
## symptôme est traître — tout compile, la fenêtre porte bien un thème, et
## l'écran reste inchangé.
##
## `gui/theme/custom` est le mécanisme prévu par le moteur : il est appliqué au
## démarrage, avant toute scène, et vaut pour absolument tout Control du projet
## sans qu'aucun panneau ait à s'en occuper.
##
## Le thème reste DÉFINI EN CODE (autoload/UITheme.gd) et seulement SÉRIALISÉ
## ici. Un .tres édité à la main dans l'inspecteur redeviendrait un fichier
## illisible de 300 lignes sans commentaire, et le raisonnement derrière chaque
## couleur serait perdu — c'est précisément ce qu'on cherchait à supprimer.

const OUTPUT := "res://assets/ui/voxen_theme.tres"


func _init() -> void:
	var builder: Node = load("res://autoload/UITheme.gd").new()
	var theme: Theme = builder.build()
	var error := ResourceSaver.save(theme, OUTPUT)
	builder.free()
	if error != OK:
		print("échec de l'écriture de %s (code %d)" % [OUTPUT, error])
		quit(1)
		return
	print("thème écrit : %s" % OUTPUT)
	print("types stylés : %s" % ", ".join(theme.get_type_list()))
	quit(0)
