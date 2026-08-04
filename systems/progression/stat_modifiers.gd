class_name StatModifiers
extends RefCounted
## Résolveur de modificateurs (E.4) — le point d'entrée UNIQUE par lequel toute
## valeur de jeu interrogeable doit passer.
##
##     valeur = (base + Σ add) × Π mult
##
## E.4 est catégorique : « aucun système ne modifie jamais une valeur en dur ».
## C'est la règle que ce fichier fait exister. Sans elle, chaque système qui
## veut infléchir une stat le fait à sa manière, dans sa propre fonction, et
## trois choses deviennent impossibles : cumuler proprement deux sources,
## RETIRER une source (déséquiper un anneau, voir expirer un poison), et
## afficher au joueur d'où vient un chiffre.
##
## LES SOURCES prévues par le GDD, dans l'ordre où elles arriveront :
##   - équipement (A.4.4) : anneaux, amulettes, accessoires, dos — ils
##     s'équipent déjà et ne font rien, faute de ce résolveur ;
##   - statuts actifs (F.4) : brûlure, gel, poison… ;
##   - bonus de race (C.2) — aujourd'hui fondus dans la stat de base à la
##     création, ce qui est acceptable puisqu'ils ne changent jamais ;
##   - auras/buffs de modules (5.1) ;
##   - humeur des PNJ (12).
##
## ÉTAT AU 2026-08-02 : la classe est en place et testée
## (`--probe-modificateurs`), et le joueur y fait passer ses malus de faim et
## de fatigue (A.9/E.21), qui étaient jusqu'ici codés en dur dans
## `Player.effective_stat`. Les quatre autres sources restent à brancher — ce
## qui est désormais un travail d'ajout, plus un travail de conception.
##
## COÛT. Ce résolveur est lu dans des chemins chauds (chaque coup porté lit
## For ou Dex). Il est donc conçu pour que le cas courant — AUCUN modificateur
## actif — soit un test de dictionnaire vide et rien d'autre. Les modificateurs
## sont indexés par stat, pas par source : appliquer coûte le nombre de sources
## qui touchent CETTE stat, jamais le nombre total de sources.

## stat_id -> { source_id: Vector2(add, mult) }
## Un source_id est une chaîne libre mais doit être STABLE et UNIQUE par
## source vivante — c'est la clé de retrait. Conventions retenues :
##   "faim", "fatigue"                  état du porteur
##   "equip:<slot>"                     pièce équipée (A.4.4)
##   "statut:<id>"                      statut actif (F.4)
##   "module:<id>"                      aura/buff (5.1)
## Une source qui se ré-enregistre écrase la précédente, ce qui rend
## l'opération idempotente : un tick qui repose le même malus ne l'empile pas.
var _by_stat := {}


## Pose (ou remplace) le modificateur d'une source sur une stat.
## `add` s'additionne à la base, `mult` multiplie le total — 0 et 1 sont les
## neutres. Poser les deux neutres RETIRE la source : une source sans effet ne
## doit pas rester à coûter une itération.
func set_modifier(stat_id: String, source_id: String, add: float, mult: float = 1.0) -> void:
	if is_zero_approx(add) and is_equal_approx(mult, 1.0):
		clear_source(stat_id, source_id)
		return
	if not _by_stat.has(stat_id):
		_by_stat[stat_id] = {}
	(_by_stat[stat_id] as Dictionary)[source_id] = Vector2(add, mult)


## Retire une source d'une stat. Sans effet si elle n'y était pas — le
## rétablissement d'un état doit pouvoir être appelé sans savoir ce qui était
## posé (« plus de malus de faim » ne devrait pas exiger de vérifier d'abord).
func clear_source(stat_id: String, source_id: String) -> void:
	var entry: Variant = _by_stat.get(stat_id)
	if entry == null:
		return
	(entry as Dictionary).erase(source_id)
	if (entry as Dictionary).is_empty():
		_by_stat.erase(stat_id)


## Retire une source de TOUTES les stats. C'est la forme qu'appellent le
## déséquipement et l'expiration d'un statut, qui ne savent pas forcément
## quelles stats leur source touchait.
func clear_source_everywhere(source_id: String) -> void:
	for stat_id: String in _by_stat.keys():
		clear_source(stat_id, source_id)


func clear_all() -> void:
	_by_stat.clear()


## Applique (base + Σ add) × Π mult. Le résultat n'est pas arrondi ni borné :
## c'est à l'appelant de décider, parce qu'une stat entière et un multiplicateur
## de vitesse n'ont pas la même règle d'arrondi.
func apply(base: float, stat_id: String) -> float:
	var entry: Variant = _by_stat.get(stat_id)
	if entry == null:
		return base   # Cas courant : sortie immédiate, aucune allocation.
	var total_add := 0.0
	var total_mult := 1.0
	for source_id: String in (entry as Dictionary):
		var m: Vector2 = (entry as Dictionary)[source_id]
		total_add += m.x
		total_mult *= m.y
	return (base + total_add) * total_mult


## Détail des sources qui agissent sur une stat, pour l'interface : la fiche de
## personnage doit pouvoir dire POURQUOI la Force affichée n'est pas celle qui
## a été répartie. Retourne [{ "source": String, "add": float, "mult": float }].
func breakdown(stat_id: String) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var entry: Variant = _by_stat.get(stat_id)
	if entry == null:
		return out
	for source_id: String in (entry as Dictionary):
		var m: Vector2 = (entry as Dictionary)[source_id]
		out.append({"source": source_id, "add": m.x, "mult": m.y})
	return out


## Nombre de sources actives, toutes stats confondues (diagnostic et sondes :
## une source qui ne se retire jamais est une fuite qui ne se voit pas
## autrement).
func source_count() -> int:
	var n := 0
	for stat_id: String in _by_stat:
		n += (_by_stat[stat_id] as Dictionary).size()
	return n


# --- Sauvegarde ---
#
# VOLONTAIREMENT NON SÉRIALISÉ. Tous les modificateurs sont DÉRIVÉS d'un état
# qui, lui, est sauvegardé : la faim, la fatigue, les pièces équipées, les
# statuts actifs. Les persister créerait une seconde vérité, qui divergerait au
# premier changement de données (un anneau ré-équilibré garderait son ancien
# bonus dans les parties en cours). Ils se reposent au chargement, à partir de
# l'état restauré.
