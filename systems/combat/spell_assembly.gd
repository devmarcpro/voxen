class_name SpellAssembly
extends RefCounted
## Assemblage de modules en SORT ou ATTAQUE SPÉCIALE (GDD 5.1 « façon Noita »,
## A.6 pour le coût) — 2026-08-03.
##
## CE QU'EST UN ASSEMBLAGE. Une liste ORDONNÉE d'ids de modules, rangée dans un
## slot de compétence d'un TYPE d'arme (épée, bâton magique…). Le nombre de
## slots et leur profondeur suivent le niveau dans la compétence d'arme
## (GDD 5.1 : `2 + N/20` slots de compétence, `2 + N/25` modules par slot).
##
## POURQUOI L'ORDRE COMPTE, ET C'EST TOUT L'INTÉRÊT. Les mêmes modules rangés
## autrement donnent un sort différent. C'est la promesse de Noita, et elle ne
## tient que si l'exécution est réellement séquentielle :
##
##   [feu] [projectile]              → un projectile enflammé
##   [projectile] [feu]              → un projectile nu, puis un effet de feu
##   [multicast:3] [projectile]×3    → trois projectiles en volée
##   [projectile] [declencheur] [explosion] → un projectile qui explose à l'impact
##
## TROIS RÔLES (champ `module_type`, schéma B.4) :
##   - `effet`         : produit quelque chose (projectile, soin, frappe) ;
##   - `modificateur`  : altère ce qui SUIT — s'accumule jusqu'à ce qu'un effet
##                       le consomme, ou consomme N effets (multi-cast) ;
##   - `declencheur`   : accroche TOUT LE RESTE de l'assemblage comme charge
##                       utile du dernier effet émis, déclenchée à l'impact ou
##                       au bout d'un délai. C'est la récursion : la charge
##                       utile est elle-même un assemblage complet, qui peut
##                       contenir son propre déclencheur.
##
## CE FICHIER NE LANCE RIEN. Il COMPILE une liste plate en arbre d'exécution et
## calcule son coût. Le lancement (projectiles, dégâts, mana dépensé) vit chez
## le joueur. La séparation est délibérée : elle rend toute la combinatoire
## testable sans monde, sans joueur et sans frame — et avec la sémantique de
## Noita, la combinatoire est précisément ce qui peut casser.

## Bornes de sécurité. Un assemblage mal formé ne doit jamais boucler ni faire
## exploser la pile : les déclencheurs sont récursifs, et rien n'empêche un
## joueur d'en empiler autant que ses slots le permettent.
const MAX_DEPTH := 4
const MAX_VOLLEY := 16

## Réduction maximale du coût par la conductivité mana de l'arme (A.6 :
## `cout *= (1 - conductivite/140)`, plafonnée à ~-65 %).
const CONDUCTIVITY_DIVISOR := 140.0
const MAX_CONDUCTIVITY_CUT := 0.65


## Slots de compétence d'un type d'arme (GDD 5.1) : `2 + N/20`, plafond 6.
static func skill_slots(weapon_level: int) -> int:
	return mini(2 + weapon_level / 20, 6)


## Slots de modules dans une compétence (GDD 5.1) : `2 + N/25`, plafond 5.
static func module_slots(weapon_level: int) -> int:
	return mini(2 + weapon_level / 25, 5)


## Compile une liste plate d'ids en ARBRE D'EXÉCUTION.
##
## `levels` : id de module → niveau connu du joueur (pour la puissance).
##
## Retour : { "casts": Array }, où chaque `cast` vaut
##   { "volley": [ {"module": id, "power": float, "mods": Dictionary} ],
##     "trigger": { "kind": String, "delay": float, "casts": Array } ou {} }
##
## `volley` groupe les effets qui partent ENSEMBLE (multi-cast). `trigger` porte
## la charge utile récursive.
static func compile(module_ids: Array, levels: Dictionary = {}) -> Dictionary:
	var result := _parse(module_ids, 0, levels, 0)
	return {"casts": result["casts"]}


## Analyse récursive. `index` = position de lecture, `depth` = profondeur de
## déclencheurs déjà franchie. Retourne { "casts", "index" }.
static func _parse(ids: Array, index: int, levels: Dictionary, depth: int) -> Dictionary:
	var casts: Array = []
	# Modificateurs ACCUMULÉS en attente d'un effet à altérer. Ils ne
	# s'appliquent pas rétroactivement : un modificateur placé APRÈS un effet ne
	# le concerne pas, c'est ce qui donne son sens à l'ordre des slots.
	var pending := {}
	var multicast := 1

	while index < ids.size():
		var module_id := String(ids[index])
		var module: Dictionary = GameData.modules.get(module_id, {})
		if module.is_empty():
			index += 1
			continue
		var params: Dictionary = module.get("params", {})

		match String(module.get("module_type", "effet")):
			"modificateur":
				if params.has("multicast"):
					multicast = clampi(int(params["multicast"]), 1, MAX_VOLLEY)
				# Les altérations s'ADDITIONNENT : deux modificateurs de portée
				# se cumulent au lieu que le second écrase le premier.
				for key: String in (params.get("mods", {}) as Dictionary):
					pending[key] = float(pending.get(key, 0.0)) + float(params["mods"][key])
				index += 1

			"effet":
				# MULTI-CAST : consomme les `multicast` effets qui suivent et les
				# fait partir en une seule volée. C'est la sémantique de Noita —
				# le modificateur ne se contente pas de dupliquer le premier
				# effet, il MANGE les suivants, qui n'existent donc plus
				# séparément dans la suite de l'assemblage.
				var volley: Array = []
				var taken := 0
				while taken < multicast and index < ids.size():
					var next_id := String(ids[index])
					var next: Dictionary = GameData.modules.get(next_id, {})
					if String(next.get("module_type", "")) != "effet":
						break
					var level := int(levels.get(next_id, 0))
					volley.append({
						"module": next_id,
						# A.6 : monter un module le rend plus puissant.
						"power": float(next.get("power_base", 0.0)) * PlayerSkills.skill_factor(level),
						"mods": pending.duplicate(),
					})
					index += 1
					taken += 1
				if volley.is_empty():
					index += 1
					continue
				casts.append({"volley": volley, "trigger": {}})
				pending = {}
				multicast = 1

			"declencheur":
				index += 1
				# RIEN À ACCROCHER : un déclencheur en tête d'assemblage n'a pas
				# d'effet porteur. On l'ignore plutôt que de perdre la suite —
				# le joueur voit alors simplement que son sort ne déclenche rien,
				# au lieu de le voir ne rien faire du tout.
				if casts.is_empty():
					continue
				# PROFONDEUR BORNÉE : au-delà, le reste est exécuté à plat.
				# Sans cette borne, cinq déclencheurs enchaînés donneraient un
				# arbre de récursion que rien ne limite.
				if depth >= MAX_DEPTH:
					continue
				var payload := _parse(ids, index, levels, depth + 1)
				index = int(payload["index"])
				var carried: Array = payload["casts"]
				if not carried.is_empty():
					casts[casts.size() - 1]["trigger"] = {
						"kind": String(params.get("trigger", "impact")),
						"delay": float(params.get("delay", 0.0)),
						"casts": carried,
					}
				# Le reste de la liste A ÉTÉ CONSOMMÉ par la charge utile : ce
				# bloc-ci est terminé.
				break

			_:
				index += 1

	return {"casts": casts, "index": index}


## Coût en mana de l'assemblage (A.6) :
##   `cout_total = Σ cout_base_module / skill_factor(N_module)`
## puis réduction par la conductivité mana de l'arme tenue (A.6 des matériaux) :
##   `cout *= (1 - conductivite / 140)`, plafonnée.
##
## TOUS les modules comptent, y compris ceux qu'aucun effet ne consomme : un
## modificateur inutile coûte quand même sa mana. C'est ce qui rend un
## assemblage bâclé réellement pénalisant, et pas seulement inefficace.
static func mana_cost(module_ids: Array, levels: Dictionary = {},
		weapon_conductivity: float = 0.0) -> float:
	var total := 0.0
	for id: Variant in module_ids:
		var module: Dictionary = GameData.modules.get(String(id), {})
		if module.is_empty():
			continue
		var level := int(levels.get(String(id), 0))
		total += float(module.get("mana_cost_base", 0.0)) / PlayerSkills.skill_factor(level)
	var cut := minf(maxf(weapon_conductivity, 0.0) / CONDUCTIVITY_DIVISOR, MAX_CONDUCTIVITY_CUT)
	return total * (1.0 - cut)


## Tous les ids de module d'un assemblage, charges utiles comprises. Sert à la
## MONTÉE DE NIVEAU à l'usage (5.1 : « les modules montent en étant utilisés ») :
## lancer un sort doit créditer chaque module qui y a réellement participé, y
## compris ceux enfouis derrière un déclencheur.
static func modules_fired(compiled: Dictionary) -> Array[String]:
	var out: Array[String] = []
	_collect(compiled.get("casts", []), out)
	return out


static func _collect(casts: Array, out: Array[String]) -> void:
	for cast: Dictionary in casts:
		for shot: Dictionary in (cast.get("volley", []) as Array):
			out.append(String(shot["module"]))
		var trigger: Dictionary = cast.get("trigger", {})
		if not trigger.is_empty():
			_collect(trigger.get("casts", []), out)


## Résumé lisible d'un assemblage, pour l'interface et les sondes.
## Ex. « 3× projectile de mana (feu, portée +10) → à l'impact : explosion ».
static func describe(compiled: Dictionary) -> String:
	return _describe_casts(compiled.get("casts", []))


static func _describe_casts(casts: Array) -> String:
	var parts: Array[String] = []
	for cast: Dictionary in casts:
		var volley: Array = cast.get("volley", [])
		if volley.is_empty():
			continue
		var first: Dictionary = volley[0]
		# `TranslationServer.translate` et non `tr()` : ce dernier est une méthode
		# de Node, inaccessible depuis une fonction statique.
		var name := String(TranslationServer.translate(
				String((GameData.modules[first["module"]] as Dictionary)["name_key"])))
		var text := name if volley.size() == 1 else "%d× %s" % [volley.size(), name]
		var mods: Dictionary = first.get("mods", {})
		if not mods.is_empty():
			var mod_parts: Array[String] = []
			for key: String in mods:
				mod_parts.append("%s %+.0f" % [key, mods[key]])
			text += " (" + ", ".join(mod_parts) + ")"
		var trigger: Dictionary = cast.get("trigger", {})
		if not trigger.is_empty():
			var kind := String(trigger.get("kind", "impact"))
			text += " → " + String(TranslationServer.translate("ui.module.declenche." + kind))
			text += " : " + _describe_casts(trigger.get("casts", []))
		parts.append(text)
	return " puis ".join(parts) if not parts.is_empty() 			else String(TranslationServer.translate("ui.module.vide"))
