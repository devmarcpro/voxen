extends Probe
## Sonde `--probe-assemblage` (2026-08-03) — valide l'assemblage de sorts et
## d'attaques spéciales (GDD 5.1 « façon Noita », A.6 pour le coût).
##
## POURQUOI ELLE EXISTE. La promesse de Noita tient en une phrase : les mêmes
## modules rangés autrement donnent un sort différent. C'est une propriété
## COMBINATOIRE, donc exactement le genre de chose qui se casse sans que rien ne
## le signale — un multi-cast qui duplique au lieu de consommer, un modificateur
## qui s'applique rétroactivement, un déclencheur qui avale la mauvaise moitié
## de la liste. Rien de tout cela ne plante ; tout se voit uniquement en
## comparant deux ordres.
##
## Elle ne demande NI monde NI joueur : `SpellAssembly` est pur, c'est
## précisément ce qui rend la combinatoire testable.

const TAG := "ASSEMBLAGE"

var _ok := true


func _expect(condition: bool, message: String) -> void:
	print("[%s] %s — %s" % [TAG, "ok" if condition else "ÉCHEC", message])
	if not condition:
		_ok = false


func run() -> void:
	await wait_frame()
	_check_catalogue()
	_check_ordering()
	_check_multicast()
	_check_triggers()
	_check_cost()
	_check_slots()
	_check_player_rules()
	await _check_projectiles()
	_check_statuses()
	await _check_zones()
	_check_behaviour()
	await _capture_editor()
	finish(_ok, TAG)


## LES PROJECTILES VOLENT-ILS VRAIMENT ? (2026-08-03)
##
## Tant qu'ils ne volaient pas, `vitesse`, `portee`, `guidage` et `ricochet`
## étaient des nombres rangés dans un dictionnaire que personne ne lisait — et
## le déclencheur partait aussitôt après son porteur au lieu d'attendre
## l'impact. Rien de tout cela ne plantait : c'est exactement le genre de trou
## qu'une sonde de compilation ne voit pas.
func _check_projectiles() -> void:
	var p := player
	p.known_modules = {
		"boule_de_feu": 0, "portee_accrue": 0, "triple_lancer": 0,
		"declencheur_impact": 0, "eclat_de_glace": 0,
	}
	p.assemblies = {}
	p.mana.current = 999.0

	# CIEL DÉGAGÉ, ET C'EST INDISPENSABLE (2026-08-04).
	#
	# Cette sonde partait de la position SAUVEGARDÉE du joueur, donc d'un endroit
	# quelconque : dans une maison qu'il a bâtie, dans une grotte, contre une
	# paroi. La boule de feu heurtait alors le décor à QUARANTE CENTIMÈTRES et
	# s'éteignait avant la frame suivante — `flying_count()` rendait zéro, et les
	# trois assertions de vol échouaient en accusant le code des projectiles,
	# qui marchait parfaitement.
	#
	# C'est la même famille de fragilité que les sondes qui ÉCRIVAIENT dans la
	# sauvegarde : une sonde ne doit dépendre ni de ce que le joueur a construit,
	# ni de l'endroit où il s'est arrêté de jouer. On se place donc haut au-dessus
	# du terrain, là où le seul obstacle possible est le ciel.
	var ground := 64
	if WorldManager.generator != null:
		ground = WorldManager.generator.height_at(0, 0)
	camera.input_locked = true
	p.input_locked = true
	p.teleport_to(Vector3(0.5, float(ground) + 40.0, 0.5))
	camera.rotation_degrees = Vector3(0.0, 0.0, 0.0)   # Horizontale : rien devant.
	await wait_frame()

	# 1. UN EFFET À PROJECTILE MET RÉELLEMENT UN PROJECTILE EN VOL.
	var avant := ProjectileManager.flying_count()
	p.set_assembly(p.SPELL_FAMILY, 0, ["boule_de_feu"])
	var lance: bool = p.cast_assembly(p.SPELL_FAMILY, 0)
	await wait_frame()
	var apres := ProjectileManager.flying_count()
	print("[%s] lancement=%s — projectiles en vol : %d → %d" % [TAG, lance, avant, apres])
	_expect(apres > avant, "un effet à projectile met un projectile en vol")

	# 2. UNE VOLÉE MET AUTANT DE PROJECTILES QUE D'EFFETS CONSOMMÉS. C'est la
	# preuve OBSERVABLE du multi-cast : la compilation dit trois, le monde doit
	# en montrer trois.
	ProjectileManager._clear_all()
	p.known_modules["boule_de_feu"] = 0
	# NIVEAU SUFFISANT, ET C'EST LE PIÈGE. Un assemblage est TRONQUÉ au nombre de
	# slots de modules (`2 + N/25`) : à bas niveau, ["triple", "feu", "feu",
	# "feu"] devient ["triple", "feu"], le multi-cast n'a plus qu'un effet à
	# consommer et n'envoie qu'un projectile. La première version de ce test
	# accusait le code alors que c'était la sonde qui n'avait pas les slots.
	# Il faut N >= 50 pour quatre modules.
	while p.skills.level(p.SPELL_SLOT_SKILL) < 50:
		p.skills.gain_xp(p.SPELL_SLOT_SKILL, 20000.0)
	p.set_assembly(p.SPELL_FAMILY, 0,
			["triple_lancer", "boule_de_feu", "boule_de_feu", "boule_de_feu"])
	print("[%s] sorts niveau %d → %d slots de %d modules ; assemblage retenu : %s" % [
			TAG, p.skills.level(p.SPELL_SLOT_SKILL),
			p.assembly_slot_count(p.SPELL_FAMILY), p.assembly_module_count(p.SPELL_FAMILY),
			p.assembly_at(p.SPELL_FAMILY, 0)])
	p.mana.current = 999.0
	p._module_cooldown_ticks = 0
	p.cast_assembly(p.SPELL_FAMILY, 0)
	await wait_frame()
	var volee := ProjectileManager.flying_count()
	print("[%s] triple lancer → %d projectile(s) en vol" % [TAG, volee])
	_expect(volee >= 3, "un triple lancer met trois projectiles en vol, pas un")

	# 3. LA PORTÉE ÉTEINT LE PROJECTILE. Sans elle, `portee_accrue` n'a aucun
	# effet mesurable et le modificateur est un placebo qui coûte de la mana.
	ProjectileManager._clear_all()
	p.mana.current = 999.0
	p._module_cooldown_ticks = 0
	p.set_assembly(p.SPELL_FAMILY, 0, ["boule_de_feu"])
	p.cast_assembly(p.SPELL_FAMILY, 0)
	await wait_seconds(3.0)
	var reste := ProjectileManager.flying_count()
	print("[%s] après 3 s de vol libre : %d projectile(s) restant(s)" % [TAG, reste])
	_expect(reste == 0, "un projectile s'éteint au bout de sa portée")
	ProjectileManager._clear_all()


## STATUTS (F.4, 2026-08-03). Un statut n'est utile que si son effet est
## MESURABLE : « appliqué » ne veut rien dire si la vitesse ne bouge pas et si
## les dégâts arrivent quand même en entier. Chaque test compare donc un avant
## et un après, jamais la seule présence du statut.
func _check_statuses() -> void:
	var p := player
	_expect(GameData.status_effects.size() >= 14,
			"les 14 statuts de F.4 sont en données (%d)" % GameData.status_effects.size())

	# 1. RALENTISSEMENT : la vitesse de déplacement doit réellement tomber.
	p.statuses.remove("ralentissement")
	var nu: float = p.movement_multiplier()
	p.statuses.apply("ralentissement", 0, 1.0)
	var ralenti: float = p.movement_multiplier()
	print("[%s] vitesse : nue ×%.2f → ralentie ×%.2f" % [TAG, nu, ralenti])
	_expect(ralenti < nu, "le ralentissement réduit la vitesse")
	p.statuses.remove("ralentissement")
	_expect(is_equal_approx(p.movement_multiplier(), nu),
			"retirer le statut rend la vitesse d'origine")

	# 2. GEL : immobilise pour de bon (×0), ce qu'aucun autre chemin n'exprimait.
	p.statuses.apply("gel", 0, 1.0)
	_expect(p.movement_multiplier() <= 0.001, "le gel immobilise réellement")
	p.statuses.remove("gel")

	# 3. PEAU DE PIERRE : les dégâts subis doivent baisser. C'est le test qui
	# donne enfin un effet aux modules de protection, qui ne produisaient rien.
	p.health = p.health_max
	p.take_damage(20)
	var sans: float = p.health_max - p.health
	p.health = p.health_max
	p.statuses.apply("peau_de_pierre", 0, 1.0)
	p.take_damage(20)
	var avec: float = p.health_max - p.health
	print("[%s] 20 dégâts : nu %.0f subis → peau de pierre %.0f subis" % [TAG, sans, avec])
	_expect(avec < sans, "la peau de pierre réduit les dégâts subis")
	p.statuses.remove("peau_de_pierre")
	p.health = p.health_max

	# 4. PÉRIODIQUE : un poison doit blesser tout seul, au fil des ticks.
	p.statuses.apply("poison", 0, 1.0)
	var total := 0.0
	for i in 40:
		total += p.statuses.tick()
	print("[%s] poison sur 40 ticks : %.0f dégâts périodiques" % [TAG, total])
	_expect(total > 0.0, "un statut périodique inflige ses dégâts au fil des ticks")
	p.statuses.remove("poison")

	# 5. EXPIRATION : un statut doit s'éteindre seul et rendre ce qu'il a pris.
	p.statuses.apply("hate", 5, 1.0)
	var haste: float = p.movement_multiplier()
	for i in 6:
		p.statuses.tick()
	print("[%s] hâte : ×%.2f pendant, ×%.2f après expiration" % [
			TAG, haste, p.movement_multiplier()])
	_expect(haste > 1.0, "la hâte accélère")
	_expect(not p.statuses.has("hate"), "le statut expire de lui-même")
	_expect(is_equal_approx(p.movement_multiplier(), 1.0),
			"l'expiration retire le modificateur (pas de fuite)")

	# 6. UN MODULE DE PROTECTION POSE BIEN SON STATUT. C'était précisément ce qui
	# ne produisait rien : le module compilait, coûtait sa mana, et rien ne se
	# passait.
	p.known_modules["carapace_de_roche"] = 0
	p.assemblies = {}
	p.mana.current = 999.0
	p._module_cooldown_ticks = 0
	p.set_assembly(p.SPELL_FAMILY, 0, ["carapace_de_roche"])
	p.cast_assembly(p.SPELL_FAMILY, 0)
	_expect(p.statuses.has("peau_de_pierre"),
			"un module de protection pose réellement son statut")
	p.statuses.remove("peau_de_pierre")


## ZONES PERSISTANTES (2026-08-03). Une nappe de flammes qui ne dure pas n'est
## pas une nappe, c'est une explosion — et le paramètre `duree` de ces modules ne
## voulait rien dire. On vérifie donc qu'elle EXISTE, qu'elle AGIT sur ce qui
## entre dedans, et qu'elle DISPARAÎT.
func _check_zones() -> void:
	var p := player
	ZoneManager.clear_all()
	p.known_modules["nappe_de_flammes"] = 0
	p.assemblies = {}
	p.mana.current = 999.0
	p._module_cooldown_ticks = 0
	p.set_assembly(p.SPELL_FAMILY, 0, ["nappe_de_flammes"])
	p.cast_assembly(p.SPELL_FAMILY, 0)
	print("[%s] nappe de flammes lancée → %d zone(s) active(s)" % [TAG, ZoneManager.zone_count()])
	_expect(ZoneManager.zone_count() > 0, "un module de zone pose une zone persistante")
	if ZoneManager.zone_count() == 0:
		return

	# La zone doit AGIR sur une créature placée dedans : statut posé et dégâts.
	var zone: Dictionary = ZoneManager.zones[0]
	var victime: Node = CreatureManager.spawn("bandit", zone["position"])
	if victime == null:
		print("[%s] aucune créature disponible — effet de zone non vérifié" % TAG)
	else:
		await wait_frame()
		var avant: float = victime.health
		for i in ZoneManager.PULSE_INTERVAL + 1:
			ZoneManager._on_tick(0)
		print("[%s] créature dans la nappe : %.0f → %.0f PV, brûlure=%s" % [
				TAG, avant, victime.health, victime.has_status("brulure")])
		_expect(victime.health < avant, "la zone blesse ce qui se trouve dedans")
		_expect(victime.has_status("brulure"), "la zone pose son statut")
		CreatureManager.despawn(victime)

	# EXPIRATION : une zone éternelle transformerait un sort en modification
	# permanente du terrain.
	var restant := int((ZoneManager.zones[0] as Dictionary)["ticks"])
	for i in restant + 2:
		ZoneManager._on_tick(0)
	print("[%s] après expiration : %d zone(s)" % [TAG, ZoneManager.zone_count()])
	_expect(ZoneManager.zone_count() == 0, "une zone finit par disparaître")
	ZoneManager.clear_all()


## STATUTS COMPORTEMENTAUX (F.4). Ils n'agissaient que sur le lancement de
## sorts : « perd son tour », « agit au hasard » et « fuit la source » étaient
## écrits en données et nulle part dans le comportement.
func _check_behaviour() -> void:
	var creature: Node = CreatureManager.spawn("bandit", Vector3(0, 2, 0))
	if creature == null:
		print("[%s] aucune créature disponible — comportements non vérifiés" % TAG)
		return

	# TERREUR : la créature doit FUIR, ce que le code appelle « craintive ».
	var avant: bool = creature.is_skittish()
	creature.apply_status("terreur", 0, 1.0)
	print("[%s] craintive : %s → %s sous terreur" % [TAG, avant, creature.is_skittish()])
	_expect(not avant and creature.is_skittish(), "la terreur fait fuir")

	# ÉTOURDI : la créature ne décide plus rien — son tick ne rend aucun
	# événement, même collée au joueur.
	creature.apply_status("etourdi", 0, 1.0)
	var event: Dictionary = creature.tick_step(creature.logical_position, player)
	print("[%s] étourdie : le tick rend %s (attendu vide)" % [TAG, event])
	_expect(event.is_empty(), "un étourdi perd son tour de décision")
	CreatureManager.despawn(creature)


## Capture l'ÉDITEUR RÉELLEMENT PEUPLÉ. Une première capture, prise sans arme
## ni module, ne montrait que le message « équipe une arme » : l'interface était
## techniquement affichée et ne prouvait rien. Il faut équiper une arme et
## apprendre des modules pour voir les listes déroulantes, le résumé compilé et
## le coût — c'est-à-dire l'objet de la fonctionnalité.
func _capture_editor() -> void:
	if not can_capture():
		return
	var p := player
	# Une épée fabriquée, équipée en main forte : c'est elle qui donne la
	# compétence d'arme dont dérivent les slots.
	var sword: Dictionary = ItemFactory.craft("epee",
			{"bois": "chene", "minerai": "fer"}, 1.0)
	if not sword.is_empty():
		p.inventory.add_object(sword)
		p.equipment.equip(sword)
	# Niveau d'épée relevé : à 0 il n'y a que 2 slots de 2 modules, trop peu
	# pour montrer un assemblage intéressant.
	p.skills.gain_xp("epee", 40000.0)
	p.known_modules = {
		# Côté SORTS.
		"boule_de_feu": 3, "eclat_de_glace": 1, "triple_lancer": 0,
		"portee_accrue": 2, "declencheur_impact": 0, "guidage": 1,
		# Côté ARMES — les deux zones doivent être peuplées, sinon la capture
		# ne montre pas la séparation, qui est l'objet de l'écran.
		"taillade_large": 5, "estoc_perforant": 2, "enchainement_double": 0,
		"allonge_accrue": 1, "garde_de_fer": 0,
	}
	p.assemblies = {}
	var skill_id := String(p.weapon_skill_id())
	print("[%s] compétence d'arme équipée : « %s » (niveau %d) → %d slots de %d modules" % [
			TAG, skill_id, p.skills.level(skill_id),
			p.assembly_slot_count(skill_id), p.assembly_module_count(skill_id)])
	while p.skills.level(p.SPELL_SLOT_SKILL) < 60:
		p.skills.gain_xp(p.SPELL_SLOT_SKILL, 40000.0)
	if not skill_id.is_empty():
		p.set_assembly(skill_id, 0, ["enchainement_double", "taillade_large", "estoc_perforant"])
		p.set_assembly(skill_id, 1, ["allonge_accrue", "estoc_perforant"])
	p.set_assembly(p.SPELL_FAMILY, 0, ["triple_lancer", "boule_de_feu", "boule_de_feu", "boule_de_feu"])
	p.set_assembly(p.SPELL_FAMILY, 1, ["portee_accrue", "eclat_de_glace", "declencheur_impact", "boule_de_feu"])

	var menu := main.get_node_or_null("GameMenu")
	if menu == null:
		return
	menu.call("_open")
	await wait_seconds(0.4)
	menu.call("_select_tab", "combat")
	await wait_seconds(0.6)
	await screenshot("assemblage_editeur.png")
	print("[%s] capture : debug/assemblage_editeur.png" % TAG)
	menu.call("_close")


## Le catalogue doit couvrir les TROIS rôles et les 12 domaines (C.6). Sans
## modificateurs ni déclencheurs, l'assemblage n'a rien à assembler.
func _check_catalogue() -> void:
	var by_type := {}
	var domains := {}
	for id: String in GameData.modules:
		var module: Dictionary = GameData.modules[id]
		var t := String(module.get("module_type", ""))
		by_type[t] = int(by_type.get(t, 0)) + 1
		for d: String in (module.get("grimoire_domains", []) as Array):
			domains[d] = true
	print("[%s] catalogue : %s — %d domaines" % [TAG, by_type, domains.size()])
	_expect(int(by_type.get("effet", 0)) >= 10, "assez d'effets (%d)" % by_type.get("effet", 0))
	_expect(int(by_type.get("modificateur", 0)) >= 4, "des modificateurs existent (%d)" % by_type.get("modificateur", 0))
	_expect(int(by_type.get("declencheur", 0)) >= 2, "des déclencheurs existent (%d)" % by_type.get("declencheur", 0))
	# 12 domaines au GDD (8 grimoires + 4 manuels) ; « destruction » du schéma
	# B.4 s'y ajoute comme domaine transverse.
	_expect(domains.size() >= 12, "les 12 domaines de C.6 sont couverts (%d)" % domains.size())


## L'ORDRE CHANGE LE RÉSULTAT. C'est la propriété centrale : un modificateur
## placé AVANT un effet l'altère, placé APRÈS il ne le concerne pas.
func _check_ordering() -> void:
	var avant := SpellAssembly.compile(["portee_accrue", "boule_de_feu"])
	var apres := SpellAssembly.compile(["boule_de_feu", "portee_accrue"])
	var mods_avant: Dictionary = (avant["casts"][0]["volley"][0] as Dictionary)["mods"]
	var mods_apres: Dictionary = (apres["casts"][0]["volley"][0] as Dictionary)["mods"]
	print("[%s] [portée][boule] → mods %s | [boule][portée] → mods %s" % [
			TAG, mods_avant, mods_apres])
	_expect(not mods_avant.is_empty(), "un modificateur placé AVANT altère l'effet")
	_expect(mods_apres.is_empty(), "un modificateur placé APRÈS ne l'altère pas (pas de rétroactivité)")

	# Deux modificateurs de même nature doivent s'ADDITIONNER et non s'écraser.
	var cumul := SpellAssembly.compile(["portee_accrue", "portee_accrue", "boule_de_feu"])
	var portee := float(((cumul["casts"][0]["volley"][0] as Dictionary)["mods"] as Dictionary).get("portee", 0.0))
	_expect(portee > 20.0, "deux modificateurs identiques se cumulent (portée %.0f)" % portee)


## MULTI-CAST : le modificateur doit CONSOMMER les effets suivants, pas dupliquer
## le premier. La distinction est toute la différence entre Noita et une simple
## répétition — après un `multicast:3`, les trois effets suivants n'existent
## plus séparément dans la suite de l'assemblage.
func _check_multicast() -> void:
	var compiled := SpellAssembly.compile(
			["triple_lancer", "boule_de_feu", "eclat_de_glace", "arc_electrique"])
	var casts: Array = compiled["casts"]
	var volley: Array = (casts[0] as Dictionary)["volley"]
	var noms: Array[String] = []
	for shot: Dictionary in volley:
		noms.append(String(shot["module"]))
	print("[%s] [triple][feu][glace][foudre] → %d volée(s), la 1re contient %s" % [
			TAG, casts.size(), noms])
	_expect(volley.size() == 3, "le triple lancer groupe TROIS effets en une volée")
	_expect(casts.size() == 1, "les effets consommés ne repartent pas séparément")

	# Sans multi-cast, les mêmes effets partent séparément : c'est le témoin.
	var sans := SpellAssembly.compile(["boule_de_feu", "eclat_de_glace", "arc_electrique"])
	_expect((sans["casts"] as Array).size() == 3,
			"sans multi-cast, les trois effets partent séparément (%d)" % (sans["casts"] as Array).size())


## DÉCLENCHEUR : tout ce qui SUIT devient la charge utile du dernier effet émis,
## et cette charge est elle-même un assemblage complet (récursion).
func _check_triggers() -> void:
	var compiled := SpellAssembly.compile(
			["boule_de_feu", "declencheur_impact", "double_lancer", "eclat_de_glace", "eclat_de_glace"])
	var casts: Array = compiled["casts"]
	_expect(casts.size() == 1, "le déclencheur ne laisse qu'un cast au niveau racine (%d)" % casts.size())
	var trigger: Dictionary = (casts[0] as Dictionary)["trigger"]
	_expect(not trigger.is_empty(), "le porteur a bien une charge utile")
	if trigger.is_empty():
		return
	var payload: Array = trigger["casts"]
	var inner: Array = (payload[0] as Dictionary)["volley"]
	print("[%s] [feu][decl][double][glace][glace] → charge utile : %d cast(s), volée de %d" % [
			TAG, payload.size(), inner.size()])
	_expect(inner.size() == 2, "le multi-cast fonctionne À L'INTÉRIEUR de la charge utile")
	_expect(String(trigger.get("kind", "")) == "impact", "le type de déclencheur est conservé")

	# Un déclencheur en TÊTE n'a rien à accrocher : il doit être ignoré sans
	# faire disparaître le reste de l'assemblage.
	var orphelin := SpellAssembly.compile(["declencheur_impact", "boule_de_feu"])
	_expect((orphelin["casts"] as Array).size() == 1,
			"un déclencheur sans porteur est ignoré, la suite survit")

	# Tous les modules doivent être crédités, charges utiles comprises : sinon
	# les modules enfouis ne progresseraient jamais.
	var fired := SpellAssembly.modules_fired(compiled)
	_expect(fired.size() == 3, "les modules de la charge utile comptent pour la montée de niveau (%d)" % fired.size())


## COÛT (A.6) : somme des coûts de base divisés par skill_factor, puis réduction
## par la conductivité mana de l'arme.
func _check_cost() -> void:
	var ids := ["triple_lancer", "boule_de_feu", "boule_de_feu", "boule_de_feu"]
	var brut := SpellAssembly.mana_cost(ids, {}, 0.0)
	var attendu := 9.0 + 9.0 * 3.0   # triple_lancer 9 + 3× boule_de_feu 9
	print("[%s] coût brut = %.1f (attendu %.1f)" % [TAG, brut, attendu])
	_expect(is_equal_approx(brut, attendu), "la somme des coûts suit A.6")

	# Un module MONTÉ coûte moins cher (A.6 : `cout_base / skill_factor`).
	var monte := SpellAssembly.mana_cost(ids, {"boule_de_feu": 50}, 0.0)
	_expect(monte < brut, "monter un module réduit son coût (%.1f < %.1f)" % [monte, brut])

	# La conductivité mana de l'arme réduit le coût, plafonnée.
	var conducteur := SpellAssembly.mana_cost(ids, {}, 100.0)
	var plafond := SpellAssembly.mana_cost(ids, {}, 10000.0)
	print("[%s] coût : nu %.1f | arme conductrice %.1f | plafond %.1f" % [
			TAG, brut, conducteur, plafond])
	_expect(conducteur < brut, "la conductivité de l'arme réduit le coût")
	_expect(plafond >= brut * (1.0 - SpellAssembly.MAX_CONDUCTIVITY_CUT) - 0.01,
			"la réduction est plafonnée (jamais gratuite)")

	# UN MODIFICATEUR INUTILE COÛTE QUAND MÊME. C'est ce qui rend un assemblage
	# bâclé réellement pénalisant, et pas seulement inefficace.
	var gaspille := SpellAssembly.mana_cost(["boule_de_feu", "portee_accrue"], {}, 0.0)
	var propre := SpellAssembly.mana_cost(["boule_de_feu"], {}, 0.0)
	_expect(gaspille > propre, "un modificateur qui ne sert à rien coûte quand même (%.1f > %.1f)" % [
			gaspille, propre])


## SLOTS (GDD 5.1) : `2 + N/20` compétences (max 6), `2 + N/25` modules (max 5).
func _check_slots() -> void:
	print("[%s] slots de compétence : N=0 → %d, N=40 → %d, N=200 → %d" % [
			TAG, SpellAssembly.skill_slots(0), SpellAssembly.skill_slots(40),
			SpellAssembly.skill_slots(200)])
	_expect(SpellAssembly.skill_slots(0) == 2, "2 slots de compétence au niveau 0")
	_expect(SpellAssembly.skill_slots(40) == 4, "4 slots au niveau 40")
	_expect(SpellAssembly.skill_slots(200) == 6, "plafonné à 6")
	_expect(SpellAssembly.module_slots(0) == 2, "2 slots de module au niveau 0")
	_expect(SpellAssembly.module_slots(200) == 5, "plafonné à 5")


## RÈGLES CÔTÉ JOUEUR : on n'assemble que ce qu'on a APPRIS, et la profondeur
## est bornée par les slots. C'est le modèle qui doit tenir la règle, pas
## l'interface — sinon n'importe quel autre chemin (sonde, réseau) la contourne.
func _check_player_rules() -> void:
	var p := player
	# MODULES DE MANUEL pour la famille « epee » (2026-08-03) : depuis que les
	# deux zones du menu combat sont étanches, un grimoire ne s'assemble pas
	# dans une technique d'arme. Le test portait sur `boule_de_feu`, qui est
	# désormais légitimement refusé — c'était la sonde qui violait la règle.
	p.known_modules = {"taillade_large": 0, "allonge_accrue": 0}
	p.assemblies = {}

	# `: bool` explicite : `player` est typé Node, ses méthodes rendent Variant.
	var pose: bool = p.set_assembly("epee", 0, ["taillade_large", "allonge_accrue"])
	_expect(pose, "un assemblage se range dans un slot valide")
	_expect((p.assembly_at("epee", 0) as Array).size() == 2, "les deux modules connus sont retenus")

	# Module INCONNU : refusé silencieusement, pas rangé.
	p.set_assembly("epee", 1, ["taillade_large", "estoc_perforant"])
	var filtre: Array = p.assembly_at("epee", 1)
	print("[%s] assemblage avec un module non appris → %s" % [TAG, filtre])
	_expect(filtre.size() == 1, "un module jamais appris ne peut pas être assemblé")

	# Slot HORS BORNES : refusé (au niveau 0 il n'y a que 2 slots).
	_expect(not bool(p.set_assembly("epee", 5, ["taillade_large"])),
			"un slot au-delà du niveau d'arme est refusé")

	# Profondeur bornée par les slots de module (2 au niveau 0).
	p.known_modules["estoc_perforant"] = 0
	p.set_assembly("epee", 0, ["taillade_large", "allonge_accrue", "estoc_perforant"])
	_expect((p.assembly_at("epee", 0) as Array).size() == 2,
			"l'assemblage est tronqué au nombre de slots de modules")

	# ÉTANCHÉITÉ DES DEUX ZONES (2026-08-03). C'est la règle que la séparation
	# de l'écran rend nécessaire : sans elle les deux panneaux ne seraient qu'un
	# affichage, et rien n'empêcherait une boule de feu dans une technique
	# d'épée. Écart assumé avec le GDD 5.1, demandé explicitement.
	p.known_modules["boule_de_feu"] = 0
	p.set_assembly("epee", 0, ["boule_de_feu"])
	print("[%s] grimoire dans une technique d'arme → %s" % [TAG, p.assembly_at("epee", 0)])
	_expect((p.assembly_at("epee", 0) as Array).is_empty(),
			"un grimoire est refusé dans une technique d'arme")
	p.set_assembly(p.SPELL_FAMILY, 0, ["taillade_large"])
	print("[%s] manuel dans un sort → %s" % [TAG, p.assembly_at(p.SPELL_FAMILY, 0)])
	_expect((p.assembly_at(p.SPELL_FAMILY, 0) as Array).is_empty(),
			"un manuel est refusé dans un sort")
	p.set_assembly(p.SPELL_FAMILY, 0, ["boule_de_feu"])
	_expect(not (p.assembly_at(p.SPELL_FAMILY, 0) as Array).is_empty(),
			"un grimoire est accepté dans un sort")

	# Chaque zone doit disposer des TROIS rôles, sinon la séparation prive un
	# côté d'une mécanique entière (le multi-cast a manqué aux sorts une heure).
	for famille: String in ["manuel", "grimoire"]:
		var roles := {}
		for module_id: String in GameData.modules:
			var module: Dictionary = GameData.modules[module_id]
			if (module.get("grimoire_domains", []) as Array).is_empty():
				continue
			if String(module.get("book_type", "")) != famille:
				continue
			roles[String(module.get("module_type", ""))] = true
		print("[%s] côté « %s » : rôles disponibles %s" % [TAG, famille, roles.keys()])
		_expect(roles.size() == 3, "le côté « %s » a les trois rôles" % famille)
