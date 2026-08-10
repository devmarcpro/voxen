class_name WuXing
extends RefCounted
## Wu Xing (5.2/A.4.6, amendement du 2026-08-09) — les cinq éléments daoïstes
## et leurs deux cycles, comme GRAMMAIRE TRANSVERSALE : combat (multiplicateur
## de domination en étape 3 du pipeline E.3), combos d'engendrement entre
## modules, coût de mana par biome, cuisine. Cette classe est LA seule table :
## personne d'autre ne recopie les cycles, sous peine de divergence.
##
## Orthogonal au combat directionnel E.3.1 : la géométrie décide du toucher et
## de la zone, l'élément ne module que les dégâts, après les dés, avant la
## mitigation d'armure.

## Les cinq éléments, en français comme tout id de contenu (conventions).
## L'absence d'élément (chaîne vide) = NEUTRE : hors cycle, ni bonus ni malus,
## ne combote pas — les builds neutres restent viables (5.2).
const ELEMENTS: Array[String] = ["bois", "feu", "terre", "metal", "eau"]

## Cycle de DOMINATION (克) : clé DOMINE valeur.
## Bois ⊳ Terre ⊳ Eau ⊳ Feu ⊳ Métal ⊳ Bois.
const DOMINATES := {
	"bois": "terre", "terre": "eau", "eau": "feu", "feu": "metal", "metal": "bois",
}

## Cycle d'ENGENDREMENT (生) : clé NOURRIT valeur.
## Bois → Feu → Terre → Métal → Eau → Bois.
const GENERATES := {
	"bois": "feu", "feu": "terre", "terre": "metal", "metal": "eau", "eau": "bois",
}

## Multiplicateurs de domination (A.4.6).
const MULT_DOMINATES := 1.5     # A domine B.
const MULT_DOMINATED := 0.65    # B domine A.
const MULT_GENERATES := 0.8     # A nourrit B — on n'attaque pas ce qu'on alimente.

## Combo d'engendrement (A.4.6) : fenêtre en ticks, bonus non cumulable.
const COMBO_WINDOW_TICKS := 30
const COMBO_BONUS_DICE := 1
const COMBO_STATUS_DURATION_MULT := 1.5

## Coût de mana par biome (A.4.6).
const BIOME_COST_MATCH := 0.85     # Élément du module = élément du biome.
const BIOME_COST_DOMINATED := 1.15 # Élément du module dominé par celui du biome.

## Mapping des domaines de grimoire vers les éléments (C.6 amendé) :
## Feu→Feu · Eau/Glace→Eau · Terre→Terre · Métal→Métal · Foudre et Vie→Bois
## (le tonnerre du printemps, la croissance) · Arcane/Espace/Corruption→neutre.
const DOMAIN_ELEMENT := {
	"feu": "feu", "eau": "eau", "glace": "eau", "terre": "terre",
	"metal": "metal", "foudre": "bois", "vie": "bois",
}

## Dérivation des tags de créature (B.5) quand `element` est nul :
## aquatique→Eau, volant→Bois, souterrain→Terre.
const CREATURE_TAG_ELEMENT := {
	"aquatique": "eau", "volant": "bois", "souterrain": "terre",
}

## Catégories de matériaux d'armure → élément (A.4.6). La flammabilité ≥ 60
## est testée à part (element_of_material) : elle prime en Feu.
const CATEGORY_ELEMENT := {
	"metal": "metal", "metaux": "metal",
	"bois": "bois", "fibre": "bois", "cuir": "bois", "fibres": "bois",
	"roche": "terre", "pierre": "terre", "terre": "terre",
	"glace": "eau", "liquide": "eau", "liquides": "eau",
}


## Multiplicateur de dégâts d'une attaque d'élément `a` sur une cible `b`.
## Neutre (chaîne vide ou inconnue) des deux côtés ou d'un seul : ×1.0 sauf
## les trois relations du pentagramme.
static func multiplier(a: String, b: String) -> float:
	if a == "" or b == "" or not (a in ELEMENTS) or not (b in ELEMENTS):
		return 1.0
	if DOMINATES.get(a, "") == b:
		return MULT_DOMINATES
	if DOMINATES.get(b, "") == a:
		return MULT_DOMINATED
	if GENERATES.get(a, "") == b:
		return MULT_GENERATES
	return 1.0


static func generates(a: String, b: String) -> bool:
	return a != "" and GENERATES.get(a, "") == b


## « 2d6 » → « 3d6 » : le +1 dé du combo d'engendrement. Une notation fixe
## (« 12 ») ou illisible est rendue telle quelle — pas de bonus inventé.
static func add_die(notation: String) -> String:
	var parts := notation.split("d")
	if parts.size() != 2:
		return notation
	return str(int(parts[0]) + COMBO_BONUS_DICE) + "d" + parts[1]


## Facteur de coût de mana d'un module d'élément `module_el` lancé dans un
## biome d'élément `biome_el` (A.4.6). Neutre → ×1.0.
static func biome_cost_factor(module_el: String, biome_el: String) -> float:
	if module_el == "" or biome_el == "":
		return 1.0
	if module_el == biome_el:
		return BIOME_COST_MATCH
	if DOMINATES.get(biome_el, "") == module_el:
		return BIOME_COST_DOMINATED
	return 1.0


## Élément d'un MODULE : champ `element` explicite (B.4), sinon premier domaine
## de grimoire mappé (C.6), sinon premier tag mappé, sinon neutre.
static func element_of_module(module: Dictionary) -> String:
	var explicit := String(module.get("element", "")) if module.get("element") != null else ""
	if explicit != "":
		return explicit if explicit in ELEMENTS else ""
	for domain in (module.get("grimoire_domains", []) as Array):
		var el: String = DOMAIN_ELEMENT.get(String(domain), "")
		if el != "":
			return el
	for tag in (module.get("tags", []) as Array):
		var el: String = DOMAIN_ELEMENT.get(String(tag), "")
		if el != "":
			return el
	return ""


## Élément d'un ASSEMBLAGE : celui du premier module EFFET non neutre — c'est
## lui qui porte les dégâts, les modificateurs n'ont pas de couleur propre.
static func element_of_assembly(module_ids: Array) -> String:
	for module_id in module_ids:
		var module: Dictionary = GameData.modules.get(String(module_id), {})
		if String(module.get("module_type", "")) != "effet":
			continue
		var el := element_of_module(module)
		if el != "":
			return el
	return ""


## Élément d'une CRÉATURE : champ `element` de sa fiche (B.5), sinon dérivé de
## ses tags (`special_tags` puis `world_gen.biome_tags`), sinon neutre.
static func element_of_creature(fiche: Dictionary) -> String:
	var explicit := String(fiche.get("element", "")) if fiche.get("element") != null else ""
	if explicit != "":
		return explicit if explicit in ELEMENTS else ""
	for tag in (fiche.get("special_tags", []) as Array):
		var el: String = CREATURE_TAG_ELEMENT.get(String(tag), "")
		if el != "":
			return el
	for tag in ((fiche.get("world_gen", {}) as Dictionary).get("biome_tags", []) as Array):
		var el: String = CREATURE_TAG_ELEMENT.get(String(tag), "")
		if el != "":
			return el
	return ""


## Élément d'un MATÉRIAU (par sa fiche GameData) : flammabilité ≥ 60 → Feu,
## sinon sa catégorie mappée, sinon neutre.
static func element_of_material(material: Dictionary) -> String:
	if float((material.get("stats", {}) as Dictionary).get("flammabilite", 0.0)) >= 60.0:
		return "feu"
	return CATEGORY_ELEMENT.get(String(material.get("category", "")), "")


## Élément d'un PERSONNAGE ÉQUIPÉ (A.4.6) : la catégorie de matériau
## MAJORITAIRE parmi ses pièces d'armure portées. Sans armure : neutre.
## `armor_material_ids` : les ids TEXTE des matériaux des pièces équipées.
static func element_of_armor(armor_material_ids: Array) -> String:
	var counts := {}
	for mat_id in armor_material_ids:
		var material: Dictionary = GameData.materials.get(String(mat_id), {})
		if material.is_empty():
			continue
		var el := element_of_material(material)
		if el != "":
			counts[el] = int(counts.get(el, 0)) + 1
	var best := ""
	var best_count := 0
	for el: String in counts:
		if int(counts[el]) > best_count:
			best_count = int(counts[el])
			best = el
	return best


## Élément d'un BIOME : champ `element` (B.6), sinon dérivé de son id par
## famille (forêt=Bois, volcan=Feu, montagne=Métal, marécage=Eau,
## plaine/désert=Terre — 5.2), sinon neutre. La dérivation par mots-clés est
## un REPLI : la donnée explicite fait toujours foi.
static func element_of_biome(biome: Dictionary) -> String:
	var explicit := String(biome.get("element", "")) if biome.get("element") != null else ""
	if explicit != "":
		return explicit if explicit in ELEMENTS else ""
	var id := String(biome.get("id", ""))
	for needle in ["foret", "jungle", "mangrove", "bosquet", "bois"]:
		if id.contains(needle):
			return "bois"
	for needle in ["volcan", "lave", "cendre"]:
		if id.contains(needle):
			return "feu"
	for needle in ["montagne", "pic", "cristallin", "alpin"]:
		if id.contains(needle):
			return "metal"
	for needle in ["marecage", "marais", "ocean", "mer", "lac", "riviere", "glace", "banquise"]:
		if id.contains(needle):
			return "eau"
	for needle in ["plaine", "desert", "steppe", "savane", "prairie", "toundra", "colline"]:
		if id.contains(needle):
			return "terre"
	return ""
