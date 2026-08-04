class_name ItemFactory
extends RefCounted
## Instanciation d'objets depuis les recettes B.3 (étape D.3.3 : voie de base
## du craft simple, 4.2). Formules copiées de l'Annexe A :
##   stat_base_materiaux = moyenne pondérée des stats des matériaux selon
##     stat_weights (A.4) ; stat_finale = stat_base * qualité — la qualité
##     n'est appliquée qu'UNE fois (A.4.1), les stats étendues ne sont PAS
##     multipliées par la qualité (A.4.5).
##   poids = Σ densité × quantité des entrées (la densité pilote le poids,
##     A.4.1 — poids_reference des fonctionnalités calibré ainsi).

## Qualité produite (A.3) — copiée à la lettre :
##   qualite = clamp_min(0.1, (N/(N+25)) * 2 * random(0.85, 1.15))
## Asymptote ×2 pour un artisan chevronné ; le random permet des pics.
static func craft_quality(craft_skill_level: int) -> float:
	var n := float(craft_skill_level)
	return maxf(0.1, (n / (n + 25.0)) * 2.0 * randf_range(0.85, 1.15))


## Palier nommé d'une qualité (A.3) — pour l'affichage.
static func quality_tier_key(quality: float) -> String:
	if quality < 0.5:
		return "ui.qualite.miserable"
	if quality < 0.8:
		return "ui.qualite.pauvre"
	if quality < 1.2:
		return "ui.qualite.correct"
	if quality < 1.6:
		return "ui.qualite.bon"
	if quality < 2.0:
		return "ui.qualite.excellent"
	if quality < 3.0:
		return "ui.qualite.chef_oeuvre"
	if quality < 5.0:
		return "ui.qualite.legendaire"
	return "ui.qualite.mythique"


## Identifiant d'instance, monotone. Sert aux liaisons de hotbar : un objet
## doit rester désignable même quand l'inventaire est trié ou réordonné, et
## deux instances identiques ne doivent pas être confondues.
static var _next_uid := 1


static func next_uid() -> int:
	_next_uid += 1
	return _next_uid


## Déclare un uid VENU D'AILLEURS (chargement de sauvegarde, réseau) pour que le
## compteur ne le redistribue jamais.
##
## SANS ÇA, LE BUG EST SILENCIEUX ET GRAVE : le compteur est statique et repart à
## 1 à chaque lancement, alors que la sauvegarde ramène des objets portant déjà
## les uids 2, 3, 4… Le premier objet crafté après un chargement reçoit donc un
## uid DÉJÀ PRIS, et toute recherche par uid (liaison de hotbar, retrait
## d'inventaire) tombe sur l'autre objet — on croit tenir son épée neuve et on
## tient la pioche du kit de départ. Repéré par la sonde de captures, qui
## photographiait un objet différent de celui qu'elle venait de forger.
static func note_uid(uid: int) -> void:
	_next_uid = maxi(_next_uid, uid)


## Instance d'une RESSOURCE de créature (viande, peau — 7.7). Même modèle que
## les objets craftés (une entrée dans `Inventory.objects`), pas une pile de
## matériau : ce n'est pas un bloc, ça ne se pose pas, et ça pourra porter des
## données par instance (fraîcheur, qualité de découpe) sans rien changer.
## `count` : unités identiques regroupées sur une même instance — sans lui,
## dix chasses produiraient des dizaines de lignes strictement identiques.
static func resource_instance(resource_id: String, count: int = 1) -> Dictionary:
	var definition: Dictionary = GameData.resources.get(resource_id, {})
	if definition.is_empty():
		push_error("ItemFactory : ressource inconnue « %s »." % resource_id)
		return {}
	var stats: Dictionary = definition.get("stats", {})
	return {
		"uid": next_uid(),
		"item_id": String(definition.get("item_kind", "ressource")),
		"resource_id": resource_id,
		"name_key": String(definition.get("name_key", "")),
		"source_name_key": String(definition.get("source_name_key", "")),
		"color": String(definition.get("color", "#FFFFFF")),
		"count": maxi(1, count),
		"weight": float(stats.get("densite", 1.0)),
		"value": float(stats.get("valeur_base", 1.0)),
		"nutrition": definition.get("nutrition", {}),
		"potentiel": definition.get("potentiel", {}),
		"tags": definition.get("tags", []),
	}


## Crée une instance d'objet : `material_choices` associe chaque catégorie de
## la recette au matériau choisi (ex. {"bois": "chene", "minerai": "fer"}).
static func craft(item_id: String, material_choices: Dictionary, quality: float) -> Dictionary:
	var item: Variant = GameData.items.get(item_id)
	if item == null:
		push_error("ItemFactory : objet inconnu « %s »." % item_id)
		return {}
	# Une armure (6.2) n'a pas de fonctionnalité : elle ne frappe ni ne récolte.
	var functionality: Dictionary = GameData.functionalities.get(item.get("functionality", ""), {})

	# Dureté de base : moyenne pondérée selon stat_weights.durete (A.4).
	#
	# RENORMALISATION SUR LES CATÉGORIES RÉELLEMENT FOURNIES (2026-08-03).
	# Deux objets du catalogue (`arc`, `rondache`) pondèrent leur dureté sur une
	# catégorie que leur RECETTE ne demande pas : 0,1 et 0,3 de « minerai » pour
	# des recettes en bois pur. L'ancien code poussait une erreur et SAUTAIT le
	# terme — la somme des poids ne valait donc plus 1, et l'objet sortait
	# silencieusement 10 % (arc) à 30 % (rondache) plus tendre que sa fiche ne
	# l'annonce. Le défaut existe depuis toujours ; il ne s'est vu que le jour où
	# le butin de donjon en a fabriqué assez pour inonder la console.
	#
	# On répartit désormais le poids manquant sur ce qui est présent, ce qui rend
	# la dureté cohérente avec la matière réellement employée. Le signalement
	# reste, en AVERTISSEMENT : c'est une incohérence de données à trancher
	# (ajouter le métal à la recette, ou retirer le poids), pas un cas normal.
	var hardness_weights: Dictionary = (item["stat_weights"] as Dictionary).get("durete", {})
	var base_hardness := 0.0
	var weight_total := 0.0
	for category in hardness_weights:
		if GameData.materials.has(String(material_choices.get(category, ""))):
			weight_total += float(hardness_weights[category])
	for category in hardness_weights:
		var mat_id: String = material_choices.get(category, "")
		var mat: Variant = GameData.materials.get(mat_id)
		if mat == null:
			push_warning("ItemFactory : « %s » pondère sa dureté sur « %s », absent de sa recette — poids redistribué." % [item_id, category])
			continue
		var share: float = float(hardness_weights[category]) / maxf(weight_total, 0.0001)
		base_hardness += share * float(mat["stats"]["durete"])

	# Poids : Σ densité × quantité des entrées de la recette (A.4.1).
	var weight := 0.0
	for input: Dictionary in item["recipe"].get("inputs", []):
		var mat_id: String = material_choices.get(input["category"], "")
		var mat: Variant = GameData.materials.get(mat_id)
		if mat != null:
			weight += float(mat["stats"]["densite"]) * int(input["amount"])

	var instance := {
		"uid": next_uid(),
		"item_id": item_id,
		"name_key": item["name_key"],
		"functionality": item.get("functionality", ""),
		"tool_category": functionality.get("tool_category", ""),
		# EMPRISE DE MINAGE (foreuses, 2026-08-03) : côté du carré miné d'un coup,
		# 1 pour tout outil normal. Recopiée à plat sur l'instance comme
		# `tool_category` : le joueur tient une instance, pas une fonctionnalité, et
		# rouvrir la fiche de fonctionnalité à chaque coup de pioche serait absurde.
		"mining_area": int(functionality.get("mining_area", 1)),
		"quality": quality,
		# Dureté de BASE (avant qualité) — A.2 multiplie durete_outil par
		# qualite_outil séparément, ne jamais pré-multiplier (double comptage).
		"base_hardness": base_hardness,
		"weight": weight,
		"materials": material_choices.duplicate(),
	}
	_set_gem(instance, String(material_choices.get(GEM_CATEGORY, "")))
	return instance


# --- Gemme sertie (support d'enchantement) -----------------------------------
#
# La gemme n'est PAS une entrée de recette : elle est facultative, et une recette
# ne sait pas exprimer « zéro ou un ». Elle voyage donc dans `material_choices`
# sous la catégorie `cristal`, comme n'importe quel choix de craft, mais elle est
# recopiée à plat sur l'instance sous `gem` : le reste du jeu (rendu, futur
# enchantement, revente) n'a alors pas à savoir qu'une gemme est un « cristal »
# ni à fouiller le dictionnaire de matériaux.
#
# Elle ne touche NI la dureté NI les dégâts. Sertir un rubis ne doit pas rendre
# une épée meilleure à trancher — sinon la gemme devient un simple bonus de stat
# et l'enchantement n'aura plus rien à apporter. Elle n'ajoute que son poids
# (elle est bien là, physiquement) et sa conductivité de mana, qui est
# exactement la grandeur dont l'enchantement se servira.

## Catégorie de matériau acceptée dans le logement de gemme.
const GEM_CATEGORY := "cristal"

## Conductivité de mana d'une arme sans gemme. Zéro et non « un peu » : c'est ce
## qui rendra le sertissage nécessaire plutôt que confortable.
const NO_GEM_MANA := 0.0


## Retourne les identifiants de matériaux sertissables, triés par conductivité
## de mana décroissante — l'ordre dans lequel un joueur veut les comparer.
static func gem_materials() -> Array[String]:
	var out: Array[String] = []
	for mat_id: String in GameData.materials:
		if String((GameData.materials[mat_id] as Dictionary).get("category", "")) == GEM_CATEGORY:
			out.append(mat_id)
	out.sort_custom(func(a: String, b: String) -> bool:
		return _gem_mana(a) > _gem_mana(b))
	return out


static func _gem_mana(mat_id: String) -> float:
	var mat: Dictionary = GameData.materials.get(mat_id, {})
	return float((mat.get("stats", {}) as Dictionary).get("conductivite_mana", 0.0))


## Sertit (ou retire, si `gem_id` est vide) la gemme d'une instance déjà forgée.
## Utilisable après coup : c'est ce qui permettra de dessertir pour changer
## d'enchantement sans refondre l'arme.
static func _set_gem(instance: Dictionary, gem_id: String) -> void:
	var mat: Dictionary = GameData.materials.get(gem_id, {})
	if gem_id == "" or mat.is_empty():
		instance.erase("gem")
		instance["mana_conductivity"] = NO_GEM_MANA
		return
	var stats: Dictionary = mat.get("stats", {})
	instance["gem"] = gem_id
	instance["gem_color"] = String(mat.get("color", "#FFFFFF"))
	instance["mana_conductivity"] = float(stats.get("conductivite_mana", 0.0))
	# Le poids de la pierre compte : une gemme dense alourdit l'arme, ce qui la
	# ralentit via WeaponStats. C'est le seul effet mécanique du sertissage, et
	# il est volontairement DÉFAVORABLE — la contrepartie viendra de l'enchantement.
	instance["weight"] = float(instance.get("weight", 0.0)) + float(stats.get("densite", 0.0)) * GEM_WEIGHT_SHARE


## Une gemme sertie est TAILLÉE : quelques grammes, pas un bloc entier. Sans ce
## facteur, un diamant doublait le poids d'une dague.
const GEM_WEIGHT_SHARE := 0.15


## Sertit une gemme sur une instance existante (API publique).
static func set_gem(instance: Dictionary, gem_id: String) -> void:
	_set_gem(instance, gem_id)


## Un objet accepte-t-il une gemme ? Critère : c'est une ARME ASSEMBLÉE, donc
## dotée de `parts`. Ce n'est pas un caprice de rendu — le logement de la gemme
## est un point de géométrie précis (la jonction manche/tête), et un objet sans
## pièces n'a pas ce point. Ça exclut naturellement les armures et les outils à
## sprite, qui n'ont nulle part où sertir.
static func accepts_gem(item_id: String) -> bool:
	var item: Dictionary = GameData.items.get(item_id, {})
	return not (item.get("parts", {}) as Dictionary).is_empty()
