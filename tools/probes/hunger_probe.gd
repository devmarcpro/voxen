extends Probe
## Sonde `--probe-faim` — extraite de main.gd le 2026-07-28 (audit architectural).
## Logique inchangée : seuls les accès à la scène ont été réécrits
## ($Player -> player, get_tree() -> main.get_tree(), etc.).


## Sonde faim headless (A.9/A.9.1) : vérifie la boucle complète — matériaux
## comestibles chargés, consommation depuis l'inventaire (cru = 50 %),
## refus d'un matériau non comestible, malus de stats sous 25, régénération
## de santé modulée par les seuils, et famine à 0 qui ne descend pas sous
## 1 PV. Aucune capture d'écran : sûre en --headless.
func run() -> void:
	await main.get_tree().process_frame
	var player: Node = player
	player.apply_default_character()
	var ok := true

	# 1. Données : au moins un matériau porte un bloc nutrition valide (B.1).
	var edibles: Array[String] = []
	for mid: String in GameData.materials:
		if (GameData.materials[mid] as Dictionary).has("nutrition"):
			edibles.append(mid)
	edibles.sort()
	print("[FAIM] comestibles en données : %d %s" % [edibles.size(), edibles])
	ok = ok and edibles.size() > 0

	# 2. Manger CRU : 50 % de la nutrition (A.9.1), 1 unité consommée.
	var food: String = edibles[0]
	var full_value := float((GameData.materials[food]["nutrition"] as Dictionary)["faim"])
	player.inventory.add_material(food, 2)
	player.hunger = 40.0
	_select_material(player, food)
	var before_stock: int = int(player.inventory.material_stacks.get(food, 0))
	player._try_eat()
	var gained: float = player.hunger - 40.0
	var after_stock: int = int(player.inventory.material_stacks.get(food, 0))
	var eat_ok: bool = is_equal_approx(gained, full_value * 0.5) and after_stock == before_stock - 1
	print("[FAIM] mangé %s : +%.1f faim (attendu %.1f = 50%% de %.0f) stock %d→%d" % [
			food, gained, full_value * 0.5, full_value, before_stock, after_stock])
	ok = ok and eat_ok

	# 3. Refus : matériau sans bloc nutrition (la pierre ne se mange pas).
	player.hunger = 40.0
	player.inventory.add_material("pierre", 1)
	var stone_before: int = int(player.inventory.material_stacks.get("pierre", 0))
	if _select_material(player, "pierre"):
		player._try_eat()
	var stone_ok: bool = player.hunger == 40.0 and int(player.inventory.material_stacks.get("pierre", 0)) == stone_before
	print("[FAIM] pierre non comestible : faim inchangée=%s stock inchangé=%s (attendu true/true)" % [
			player.hunger == 40.0, int(player.inventory.material_stacks.get("pierre", 0)) == stone_before])
	ok = ok and stone_ok

	# 4. Malus de stats sous 25 de faim (A.9 : -10 %).
	player.hunger = 80.0
	var full_force: int = player.effective_stat("force")
	player.hunger = 10.0
	var starved_force: int = player.effective_stat("force")
	var malus_ok: bool = starved_force == int(floor(int(player.stats["force"]) * 0.9)) and starved_force < full_force
	print("[FAIM] Force : rassasié=%d affamé=%d (attendu -10%%)" % [full_force, starved_force])
	ok = ok and malus_ok

	# 5. Régénération : pleine >= 50, réduite sous 50, nulle sous 25 (A.9).
	var regen_samples := {}
	for level: float in [80.0, 40.0, 10.0]:
		player.hunger = level
		player.health = 10.0
		player._regen_tick_counter = 0
		for i in player.HEALTH_REGEN_INTERVAL_TICKS:
			player._hunger_tick_effects()
		regen_samples[level] = player.health - 10.0
	var regen_ok: bool = regen_samples[80.0] > regen_samples[40.0] and regen_samples[10.0] == 0.0
	print("[FAIM] régén/intervalle : faim80=%.2f faim40=%.2f faim10=%.2f (attendu décroissant, 0 sous 25)" % [
			regen_samples[80.0], regen_samples[40.0], regen_samples[10.0]])
	ok = ok and regen_ok

	# 6. Famine à 0 : la faim BLESSE, et elle PEUT TUER (A.9 amendé le
	# 2026-07-27 — le plancher de 1 PV a été retiré à la demande de l'auteur).
	# La mort déclenche la pénalité A.10 normale, jamais un game over.
	player.hunger = 0.0
	player.health = player.health_max
	player.gold = 1000
	player._starve_tick_counter = 0
	for i in player.STARVE_INTERVAL_TICKS:
		player._hunger_tick_effects()
	var after_one: float = player.health
	print("[FAIM] famine : 1 intervalle %.1f → %.1f (doit blesser)" % [
			player.health_max, after_one])
	ok = ok and after_one < player.health_max

	# Poursuivie assez longtemps, elle doit finir par tuer : on le détecte à
	# la pénalité d'or (A.10), pas à la santé — le respawn la remet à plein.
	var gold_before: int = player.gold
	for i in player.STARVE_INTERVAL_TICKS * 200:
		player.hunger = 0.0
		player._hunger_tick_effects()
	var died: bool = player.gold < gold_before
	print("[FAIM] famine prolongée : or %d → %d (baisse = mort survenue, A.10)" % [
			gold_before, player.gold])
	ok = ok and died

	print("[FAIM] RÉSULTAT : %s" % ("OK" if ok else "ÉCHEC"))
	main.get_tree().quit(0 if ok else 1)
