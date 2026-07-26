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


## Crée une instance d'objet : `material_choices` associe chaque catégorie de
## la recette au matériau choisi (ex. {"bois": "chene", "minerai": "fer"}).
static func craft(item_id: String, material_choices: Dictionary, quality: float) -> Dictionary:
	var item: Variant = GameData.items.get(item_id)
	if item == null:
		push_error("ItemFactory : objet inconnu « %s »." % item_id)
		return {}
	var functionality: Dictionary = GameData.functionalities.get(item["functionality"], {})

	# Dureté de base : moyenne pondérée selon stat_weights.durete (A.4).
	var hardness_weights: Dictionary = (item["stat_weights"] as Dictionary).get("durete", {})
	var base_hardness := 0.0
	for category in hardness_weights:
		var mat_id: String = material_choices.get(category, "")
		var mat: Variant = GameData.materials.get(mat_id)
		if mat == null:
			push_error("ItemFactory : matériau manquant pour la catégorie « %s » de « %s »." % [category, item_id])
			continue
		base_hardness += float(hardness_weights[category]) * float(mat["stats"]["durete"])

	# Poids : Σ densité × quantité des entrées de la recette (A.4.1).
	var weight := 0.0
	for input: Dictionary in item["recipe"].get("inputs", []):
		var mat_id: String = material_choices.get(input["category"], "")
		var mat: Variant = GameData.materials.get(mat_id)
		if mat != null:
			weight += float(mat["stats"]["densite"]) * int(input["amount"])

	return {
		"item_id": item_id,
		"name_key": item["name_key"],
		"functionality": item["functionality"],
		"tool_category": functionality.get("tool_category", ""),
		"quality": quality,
		# Dureté de BASE (avant qualité) — A.2 multiplie durete_outil par
		# qualite_outil séparément, ne jamais pré-multiplier (double comptage).
		"base_hardness": base_hardness,
		"weight": weight,
		"materials": material_choices.duplicate(),
	}
