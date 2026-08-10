extends Probe
## Sonde `--probe-wuxing` (2026-08-10) — le système Wu Xing (5.2/A.4.6).
##
## Vérifie les TABLES (cycles fermés, chaque élément domine/nourrit exactement
## un pair), les MULTIPLICATEURS (les cinq relations), le COMBO (engendrement,
## +1 dé), le COÛT PAR BIOME, et les DÉRIVATIONS d'alignement (module par
## domaine, créature par tags, biome par repli de mots-clés, la donnée
## explicite primant partout). Chaque condition s'imprime séparément avec sa
## valeur — un verdict booléen de N conditions muettes ne désigne jamais le
## coupable (leçon --probe-ore).

const TAG := "WUXING"

var _ok := true


func _expect(condition: bool, message: String) -> void:
	print("[%s] %s — %s" % [TAG, "ok" if condition else "ÉCHEC", message])
	if not condition:
		_ok = false


func run() -> void:
	await wait_frame()

	# --- Les cycles : fermés, complets, sans doublon -----------------------
	var dominated := {}
	var generated := {}
	for el: String in WuXing.ELEMENTS:
		dominated[WuXing.DOMINATES[el]] = int(dominated.get(WuXing.DOMINATES[el], 0)) + 1
		generated[WuXing.GENERATES[el]] = int(generated.get(WuXing.GENERATES[el], 0)) + 1
	_expect(dominated.size() == 5 and generated.size() == 5,
			"chaque élément est dominé par UN pair et nourri par UN pair")
	# Un cycle de 5 se referme en 5 pas, jamais avant.
	var walker := "bois"
	for i in 5:
		walker = WuXing.GENERATES[walker]
	_expect(walker == "bois", "le cycle d'engendrement se referme en 5 pas (%s)" % walker)
	walker = "bois"
	for i in 5:
		walker = WuXing.DOMINATES[walker]
	_expect(walker == "bois", "le cycle de domination se referme en 5 pas (%s)" % walker)
	# Personne ne se domine ni ne se nourrit soi-même, et dominer ≠ nourrir.
	var sane := true
	for el: String in WuXing.ELEMENTS:
		if WuXing.DOMINATES[el] == el or WuXing.GENERATES[el] == el \
				or WuXing.DOMINATES[el] == WuXing.GENERATES[el]:
			sane = false
	_expect(sane, "aucun élément ne se domine/nourrit lui-même, domination ≠ engendrement")

	# --- Les multiplicateurs : les cinq relations --------------------------
	_expect(WuXing.multiplier("feu", "metal") == 1.5, "feu domine métal : ×1,5 (%s)" % WuXing.multiplier("feu", "metal"))
	_expect(WuXing.multiplier("metal", "feu") == 0.65, "métal dominé par feu : ×0,65 (%s)" % WuXing.multiplier("metal", "feu"))
	_expect(WuXing.multiplier("bois", "feu") == 0.8, "bois nourrit feu : ×0,8 (%s)" % WuXing.multiplier("bois", "feu"))
	_expect(WuXing.multiplier("feu", "feu") == 1.0, "même élément : ×1,0")
	_expect(WuXing.multiplier("", "feu") == 1.0 and WuXing.multiplier("feu", "") == 1.0,
			"neutre d'un côté ou de l'autre : ×1,0")
	_expect(WuXing.multiplier("eau", "terre") == 0.65, "eau dominée par terre : ×0,65")

	# --- Le combo : engendrement et +1 dé ----------------------------------
	_expect(WuXing.generates("bois", "feu") and not WuXing.generates("feu", "bois"),
			"bois nourrit feu, jamais l'inverse")
	_expect(not WuXing.generates("", "feu"), "le neutre ne combote pas")
	_expect(WuXing.add_die("2d6") == "3d6", "add_die(2d6) = %s" % WuXing.add_die("2d6"))
	_expect(WuXing.add_die("12") == "12", "une valeur fixe ne gagne pas de dé (%s)" % WuXing.add_die("12"))

	# --- Le coût par biome --------------------------------------------------
	_expect(WuXing.biome_cost_factor("feu", "feu") == 0.85, "élément du biome : ×0,85")
	_expect(WuXing.biome_cost_factor("metal", "feu") == 1.15,
			"élément dominé par le biome : ×1,15 (feu domine métal)")
	_expect(WuXing.biome_cost_factor("eau", "feu") == 1.0, "autre relation : ×1,0")
	_expect(WuXing.biome_cost_factor("", "feu") == 1.0, "module neutre : ×1,0 partout")

	# --- Les dérivations d'alignement --------------------------------------
	var boule: Dictionary = GameData.modules.get("boule_de_feu", {})
	if boule.is_empty():
		_expect(false, "module boule_de_feu introuvable (catalogue)")
	else:
		_expect(WuXing.element_of_module(boule) == "feu",
				"boule_de_feu → feu par son domaine (%s)" % WuXing.element_of_module(boule))
	_expect(WuXing.element_of_module({"element": "eau", "grimoire_domains": ["feu"]}) == "eau",
			"le champ element EXPLICITE prime sur le domaine")
	_expect(WuXing.element_of_module({"grimoire_domains": ["arcane"]}) == "",
			"arcane est hors cycle (neutre)")
	_expect(WuXing.element_of_creature({"special_tags": ["aquatique"]}) == "eau",
			"créature aquatique → eau par ses tags")
	_expect(WuXing.element_of_creature({"element": "feu", "special_tags": ["aquatique"]}) == "feu",
			"le champ element d'une créature prime sur ses tags")
	_expect(WuXing.element_of_creature({}) == "", "créature sans rien : neutre")
	_expect(WuXing.element_of_biome({"id": "foret_temperee"}) == "bois",
			"biome forestier → bois par repli de mots-clés")
	_expect(WuXing.element_of_biome({"id": "desert_ocre"}) == "terre", "désert → terre")
	_expect(WuXing.element_of_biome({"id": "x", "element": "feu"}) == "feu",
			"le champ element d'un biome prime sur son id")

	# --- L'étape 3 du pipeline : resolve_hit applique le multiplicateur ----
	# Notation FIXE (« 12 ») : aucun aléa, le rapport des dégâts bruts doit être
	# EXACTEMENT le multiplicateur (avant arrondi final, lu sur "raw").
	var neutral := CombatResolver.resolve_hit(5, 5, "12", 20.0, 1.0, false, "", 1.0, 0.0, 0, 1.0)
	var dominant := CombatResolver.resolve_hit(5, 5, "12", 20.0, 1.0, false, "", 1.0, 0.0, 0, 1.5)
	_expect(int(neutral["raw"]) == 13 and int(dominant["raw"]) == 20,
			"resolve_hit : brut 13 en neutre, 20 en domination ((12+1,25)×1,5 arrondi) — mesuré %d/%d" % [
					int(neutral["raw"]), int(dominant["raw"])])

	# --- L'armure : catégorie dominante → élément ---------------------------
	_expect(WuXing.element_of_armor([]) == "", "sans armure : neutre")

	finish(_ok, TAG)
