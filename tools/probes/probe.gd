class_name Probe
extends RefCounted
## Classe de base des sondes de diagnostic (--probe-*, --test-*).
##
## Une sonde est un scénario automatisé qui démarre un monde, agit dessus,
## imprime un rapport et quitte avec un code de sortie. Elles vivaient toutes
## dans main.gd (2 845 lignes, 23 fonctions de sonde) — le script de la scène
## principale était en réalité la suite de tests d'intégration, et chaque
## nouveau système y ajoutait la sienne. Extraites ici : un fichier par sonde,
## enregistré dans ProbeRegistry (2026-07-28).
##
## RefCounted et non Node : une sonde n'a pas besoin d'être dans l'arbre, elle
## emprunte celui de `main` pour ses `await`. Elle est maintenue en vie par la
## référence que ProbeRegistry conserve le temps de la coroutine.

## Nœud Main (scenes/main.gd) — racine de la scène, accès aux enfants.
var main: Node3D
var player: Node
var camera: Node3D


func setup(main_node: Node3D) -> void:
	main = main_node
	player = main_node.get_node("Player")
	camera = main_node.get_node("FlyCamera")


## Point d'entrée, redéfini par chaque sonde. Peut être une coroutine (await).
func run() -> void:
	push_error("Probe.run() non redéfini par %s" % get_script().resource_path)


# --- Utilitaires communs ---

## Dossier des captures de debug (benchs, sondes, tests) — JAMAIS la racine du
## projet : elles s'y accumulaient et noyaient l'arborescence. Hors du versionné
## (.gitignore) : ce sont des artefacts régénérables.
const CAPTURE_DIR := "res://debug/"


## Chemin absolu d'une capture, dossier créé au besoin.
func capture_path(file_name: String) -> String:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(CAPTURE_DIR))
	return ProjectSettings.globalize_path(CAPTURE_DIR) + file_name


## Une capture d'écran est-elle possible ? FAUX en `--headless` : le
## RenderingServer y est un DUMMY, `frame_post_draw` ne se déclenche JAMAIS et
## `get_viewport().get_texture()` est null. Une sonde qui l'attend quand même se
## BLOQUE INDÉFINIMENT — le pire mode d'échec possible pour de l'automatisation
## (constaté le 2026-07-28 : deux lots tués après 40 min de silence).
static func can_capture() -> bool:
	return DisplayServer.get_name() != "headless"


## Capture d'écran après la prochaine frame rendue. En headless : ne bloque pas,
## prévient, et rend la main — la sonde poursuit ses vérifications logiques.
func screenshot(file_name: String) -> void:
	if not can_capture():
		push_warning("Capture « %s » ignorée : mode headless (relancer sans --headless pour l'obtenir)." % file_name)
		return
	await RenderingServer.frame_post_draw
	main.get_viewport().get_texture().get_image().save_png(capture_path(file_name))


func wait_seconds(seconds: float) -> void:
	await main.get_tree().create_timer(seconds).timeout


func wait_frame() -> void:
	await main.get_tree().process_frame


## Fin de sonde : imprime le verdict et quitte avec le code attendu par la CI.
func finish(ok: bool, tag: String) -> void:
	print("[%s] RÉSULTAT : %s" % [tag, "OK" if ok else "ÉCHEC"])
	main.get_tree().quit(0 if ok else 1)


# --- Sélection d'objets/matériaux (partagée par plusieurs sondes) ---

## Déplace la sélection hors de l'emplacement de COMBAT, qui n'accepte aucune
## liaison : il montre l'arme ÉQUIPÉE. Une sonde qui veut tenir un outil ou un
## bloc doit donc viser un autre emplacement.
static func _leave_combat_slot(target: Node) -> void:
	if int(target.selected_slot) == int(target.COMBAT_SLOT):
		target.selected_slot = 1


## Met EN MAIN le matériau `mat_id` (sondes).
func _select_material(target: Node, mat_id: String) -> bool:
	for entry: Dictionary in target.all_entries():
		if entry.get("kind", "") == "material" and String(entry.get("id", "")) == mat_id:
			# La hotbar est ASSIGNABLE (2026-07-27) : on lie l'entrée à
			# l'emplacement courant au lieu de calculer un index de fenêtre.
			# L'emplacement 1 est RÉSERVÉ AU COMBAT depuis le 2026-08-02 : il
			# suit l'arme équipée et refuse toute liaison. Une sonde qui y
			# assignait se retrouvait les mains nues sans le savoir.
			_leave_combat_slot(target)
			target.bind_hotbar(target.active_hotbar * target.HOTBAR_SLOTS + target.selected_slot, entry)
			return true
	return false


## Met EN MAIN l'instance de ressource `resource_id` (sondes).
func _select_object(target: Node, resource_id: String) -> bool:
	for entry: Dictionary in target.all_entries():
		if entry.get("kind", "") != "object":
			continue
		if String((entry["object"] as Dictionary).get("resource_id", "")) == resource_id:
			# L'emplacement 1 est RÉSERVÉ AU COMBAT depuis le 2026-08-02 : il
			# suit l'arme équipée et refuse toute liaison. Une sonde qui y
			# assignait se retrouvait les mains nues sans le savoir.
			_leave_combat_slot(target)
			target.bind_hotbar(target.active_hotbar * target.HOTBAR_SLOTS + target.selected_slot, entry)
			return true
	return false


## Nombre total d'unités de la ressource `resource_id` dans l'inventaire.
func _resource_units(target: Node, resource_id: String) -> int:
	var total := 0
	for obj: Dictionary in target.inventory.objects:
		if String(obj.get("resource_id", "")) == resource_id:
			total += int(obj.get("count", 1))
	return total
