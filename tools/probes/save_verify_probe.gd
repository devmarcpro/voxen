extends Probe
## Sonde `--probe-save-verify` — extraite de main.gd le 2026-07-28 (audit architectural).
## Logique inchangée : seuls les accès à la scène ont été réécrits
## ($Player -> player, get_tree() -> main.get_tree(), etc.).


## Sonde de sauvegarde E.10, phase 2 (relecture dans un processus neuf).
##
## ⚠ SONDE APPARIÉE : elle relit la sauvegarde écrite par `--probe-save`, et n'a
## aucun sens sans elle. Lancée seule, ou après qu'une autre sonde a retouché le
## monde, elle rapportait un échec sur les six lignes à la fois — un tableau
## alarmant qui ne signalait rien d'autre que « la phase 1 n'a pas eu lieu ».
## D'où le garde-fou ci-dessous : le diagnostic doit désigner la cause, pas
## afficher six symptômes.
##
##   godot --headless --path . -- --probe-save
##   godot --headless --path . -- --probe-save-verify
func run() -> void:
	# L'état différé (SaveManager._apply_state) s'applique après _ready.
	await main.get_tree().process_frame
	await main.get_tree().process_frame
	if not _phase_one_ran():
		print("[SAVEVERIFY] la sauvegarde de la phase 1 est absente ou périmée.")
		print("[SAVEVERIFY] lancer d'abord : godot --headless --path . -- --probe-save")
		finish(false, "SAVEVERIFY")
		return
	var g := WorldManager.generator
	var player := player
	var h := g.height_at(10, 10)
	var granit: int = GameData.material_runtime_ids["granit"]
	var broken := WorldManager.block_at_world(Vector3i(10, h, 10))
	var placed := WorldManager.block_at_world(Vector3i(10, h + 3, 10))
	# La sous-grille vit dans le DIFF restauré (le chunk n'est pas encore en
	# cache au démarrage — subdiv_grid_at ne verrait rien) : lecture directe.
	var sub_pos := Vector3i(12, h + 1, 10)
	var sck := Vector3i(sub_pos.x >> 4, sub_pos.y >> 4, sub_pos.z >> 4)
	var sindex := (sub_pos.x & 15) | ((sub_pos.z & 15) << 4) | ((sub_pos.y & 15) << 8)
	var grid: PackedInt32Array = (WorldManager.sub_edits_for_save().get(sck, {}) as Dictionary).get(sindex, PackedInt32Array())
	var solid := SubdivGrid.count_solid(grid) if grid.size() == SubdivGrid.CELLS else -1
	var cell := ClaimManager.cell_of_block(10, 10)
	print("[SAVEVERIFY] bloc cassé=%d (attendu 0) posé=%d (attendu %d = granit)" % [broken, placed, granit])
	print("[SAVEVERIFY] sous-grille restaurée : %d cellules pleines (attendu 8)" % solid)
	print("[SAVEVERIFY] claim %s rôle=%s (attendu habitation)" % [cell, ClaimManager.role_of(cell)])
	print("[SAVEVERIFY] minage=%d (attendu >= 1) or=%d (attendu 42) pierre=%d (attendu 7)" % [
		player.skills.level("minage"), player.gold, player.inventory.material_stacks.get("pierre", 0)])
	print("[SAVEVERIFY] ticks=%d (attendu >= 123)" % TickManager.tick_index)
	var ok: bool = broken == 0 and placed == granit and solid == 8 \
		and ClaimManager.role_of(cell) == "habitation" and player.gold == 42 \
		and player.skills.level("minage") >= 1 \
		and int(player.inventory.material_stacks.get("pierre", 0)) == 7 \
		and TickManager.tick_index >= 123
	print("[SAVEVERIFY] RÉSULTAT : %s" % ("OK" if ok else "ÉCHEC"))
	main.get_tree().quit(0 if ok else 1)


## La phase 1 a-t-elle bien tourné ? On cherche son marqueur le plus net : le
## bloc de granit qu'elle pose à main nue au-dessus du sol. Il ne peut pas
## apparaître par génération — le granit ne se forme pas en l'air.
func _phase_one_ran() -> bool:
	var generator := WorldManager.generator
	if generator == null:
		return false
	var height := generator.height_at(10, 10)
	return WorldManager.block_at_world(Vector3i(10, height + 3, 10)) \
		== int(GameData.material_runtime_ids.get("granit", -1))
