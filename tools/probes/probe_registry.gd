class_name ProbeRegistry
extends RefCounted
## Table de dispatch des sondes : drapeau CLI → script de sonde.
##
## SOURCE UNIQUE DE VÉRITÉ (2026-07-28) : main.gd portait à la fois une liste
## DIRECT_ARGS maintenue à la main ET une cascade de 24 `if flag in args` — les
## deux pouvaient diverger silencieusement (un drapeau ajouté à la cascade mais
## oublié dans DIRECT_ARGS lançait le menu de démarrage au lieu de la sonde).
## Les deux dérivent désormais de cette table.

const PROBES := {
	"--probe":                "res://tools/probes/diagnostic_probe.gd",
	"--probe-tour":            "res://tools/probes/tower_range_probe.gd",
	"--probe-heure":           "res://tools/probes/start_hour_probe.gd",
	"--probe-calendrier":     "res://tools/probes/calendar_probe.gd",
	"--probe-etages":          "res://tools/probes/floors_probe.gd",
	"--probe-subdiv":         "res://tools/probes/subdiv_probe.gd",
	"--probe-save":           "res://tools/probes/save_probe.gd",
	"--probe-save-verify":    "res://tools/probes/save_verify_probe.gd",
	"--probe-save-incr":      "res://tools/probes/incremental_save_probe.gd",
	"--probe-dungeon":        "res://tools/probes/dungeon_probe.gd",
	"--probe-dimensions":     "res://tools/probes/dimension_probe.gd",
	"--probe-interieur":      "res://tools/probes/dungeon_interior_probe.gd",
	"--probe-params":         "res://tools/probes/params_probe.gd",
	"--probe-city":           "res://tools/probes/city_probe.gd",
	"--probe-ore":            "res://tools/probes/ore_probe.gd",
	"--probe-terrain":        "res://tools/probes/terrain_probe.gd",
	"--probe-faim":           "res://tools/probes/hunger_probe.gd",
	"--probe-equipement":     "res://tools/probes/equipment_probe.gd",
	"--probe-foreuse":        "res://tools/probes/drill_probe.gd",
	"--probe-mort":           "res://tools/probes/death_probe.gd",
	"--probe-faune":          "res://tools/probes/fauna_probe.gd",
	"--probe-combat":         "res://tools/probes/combat_probe.gd",
	"--test-ui":              "res://tools/probes/ui_shot_probe.gd",
	"--test-carte":           "res://tools/probes/kingdom_map_probe.gd",
	"--probe-royaumes":       "res://tools/probes/kingdom_probe.gd",
	"--probe-royaumes-perf":  "res://tools/probes/kingdom_perf_probe.gd",
	"--probe-pnj":            "res://tools/probes/npc_probe.gd",
	"--probe-services":       "res://tools/probes/services_probe.gd",
	"--probe-villages":       "res://tools/probes/village_census_probe.gd",
	"--probe-village-vie":    "res://tools/probes/village_life_probe.gd",
	"--probe-collection":     "res://tools/probes/collection_probe.gd",
	"--probe-potentiel":      "res://tools/probes/potential_probe.gd",
	"--probe-modificateurs":  "res://tools/probes/modifiers_probe.gd",
	"--probe-gemme":          "res://tools/probes/gem_probe.gd",
	"--probe-corps":          "res://tools/probes/body_probe.gd",
	"--probe-rigs-animaux":   "res://tools/probes/creature_rigs_probe.gd",
	"--test-corps":           "res://tools/probes/body_shot_probe.gd",
	"--test-triche":          "res://tools/probes/cheat_shot_probe.gd",
	"--probe-triche":         "res://tools/probes/cheat_coverage_probe.gd",
	"--probe-butin":          "res://tools/probes/loot_probe.gd",
	"--probe-mesh":           "res://tools/probes/mesh_profile_probe.gd",
	"--probe-mesh-parite":    "res://tools/probes/mesh_parity_probe.gd",
	"--probe-assemblage":     "res://tools/probes/assembly_probe.gd",
	"--probe-mains":          "res://tools/probes/hands_probe.gd",
	"--probe-arbres":         "res://tools/probes/tree_probe.gd",
	"--probe-plantes":        "res://tools/probes/plant_probe.gd",
	"--probe-vitrine":        "res://tools/probes/showcase_probe.gd",
	"--probe-reseau":         "res://tools/probes/network_model_probe.gd",
	"--probe-pousses":        "res://tools/probes/sapling_probe.gd",
	"--test-arbres":          "res://tools/probes/tree_capture_probe.gd",
	"--probe-refonte-donjon": "res://tools/probes/dungeon_rework_probe.gd",
	"--probe-invui":          "res://tools/probes/inventory_ui_probe.gd",
	"--probe-survie":         "res://tools/probes/survival_probe.gd",
	"--probe-saves":          "res://tools/probes/saves_probe.gd",
	"--test-city":            "res://tools/probes/city_capture_probe.gd",
	"--test-textures":        "res://tools/probes/texture_showcase_probe.gd",
	"--test-ore":             "res://tools/probes/ore_visual_probe.gd",
	"--test-input":           "res://tools/probes/input_smoke_probe.gd",
	"--probe-touches":        "res://tools/probes/input_bindings_probe.gd",
	"--probe-police":         "res://tools/probes/font_coverage_probe.gd",
	"--probe-noms":           "res://tools/probes/names_probe.gd",
	"--bench-network-client": "res://tools/probes/network_bench_probe.gd",
}

## Drapeaux qui démarrent le monde DIRECTEMENT (sans menu) mais ne sont PAS des
## sondes : benchs mesurés dans main.gd (_process) et modes réseau.
const DIRECT_ONLY: Array[String] = [
	"--bench", "--statique", "--bench-mutation", "--bench-creatures",
	"--host", "--join",
]

## Référence gardée pendant l'exécution : une sonde est un RefCounted et sa
## coroutine ne suffit pas à la maintenir en vie.
static var _running: Probe = null


## Le monde doit-il démarrer sans passer par le menu de démarrage ?
static func is_direct(args: Array) -> bool:
	for flag: String in DIRECT_ONLY:
		if flag in args:
			return true
	for flag: String in PROBES:
		if flag in args:
			return true
	return false


## Lance la sonde correspondant aux arguments, si elle existe.
## Retourne true si une sonde a pris la main (main.gd doit alors s'arrêter là).
##
## ÉCHEC DE CHARGEMENT = SORTIE IMMÉDIATE EN CODE 1 (2026-07-28). Une sonde dont
## le script ne compile pas doit faire ÉCHOUER le lancement, jamais retomber
## silencieusement dans le chemin normal : sans monde ni bench à animer, le
## processus restait alors en vie indéfiniment sans rien faire, et l'automatisation
## ne pouvait pas distinguer « toujours en cours » de « cassé ». Constaté sur ce
## dépôt même : un `add_child()` oublié dans deux sondes s'était traduit par un
## `exit=0` trompeur au lieu d'un échec franc.
static func run(main_node: Node3D, args: Array) -> bool:
	for flag: String in PROBES:
		if not (flag in args):
			continue
		var path: String = PROBES[flag]
		var script: Script = load(path)
		# `can_instantiate()` est testé AVANT tout appel à `new()`, et c'est
		# essentiel : sur un script qui n'a pas compilé, `load()` rend un objet
		# NON NUL, et c'est `new()` qui échoue — or cette erreur d'exécution
		# INTERROMPT la fonction en cours. Un garde placé après l'appel n'est
		# jamais atteint (vérifié en cassant volontairement une sonde le
		# 2026-07-28 : le processus repartait en boucle d'attente infinie).
		if script == null or not script.can_instantiate():
			push_error("ProbeRegistry : %s illisible ou non compilable (%s)." % [flag, path])
			print("[PROBE] RÉSULTAT : ÉCHEC — script %s non chargeable." % path)
			main_node.get_tree().quit(1)
			return true
		var probe: Probe = script.new()
		probe.setup(main_node)
		_running = probe
		probe.run()   # coroutine : la sonde poursuit seule et appelle finish()
		return true
	return false
