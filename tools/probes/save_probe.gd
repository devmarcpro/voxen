extends Probe
## Sonde `--probe-save` — extraite de main.gd le 2026-07-28 (audit architectural).
## Logique inchangée : seuls les accès à la scène ont été réécrits
## ($Player -> player, get_tree() -> main.get_tree(), etc.).


## Sonde de sauvegarde E.10, phase 1 (écriture) — à lancer avec
## `--save-dir <dossier de test>` pour ne jamais toucher la vraie sauvegarde.
## Mute le monde (bloc, sous-grille), claim, XP, or, ticks, puis sauvegarde
## SYNCHRONE et quitte. La phase 2 (--probe-save-verify, processus séparé)
## relit tout et compare.
func run() -> void:
	await main.get_tree().process_frame
	var g := WorldManager.generator
	var player := player
	var h := g.height_at(10, 10)
	print("[SAVEPROBE] écriture dans : %s" % SaveManager.save_dir)
	# Mutations du monde : un bloc cassé, un bloc posé, une sous-grille.
	var granit: int = GameData.material_runtime_ids["granit"]
	print("[SAVEPROBE] casse (10,%d,10) : %s" % [h, WorldManager.set_block(Vector3i(10, h, 10), 0)])
	print("[SAVEPROBE] pose granit (10,%d,10) : %s" % [h + 3, WorldManager.set_block(Vector3i(10, h + 3, 10), granit)])
	print("[SAVEPROBE] sous-grille 8px : %s" % WorldManager.set_sub_region(Vector3i(12, h + 1, 10), Vector3i(0, 0, 0), 2, granit))
	# État de jeu : claim + rôle, XP, or, inventaire, temps.
	var cell := ClaimManager.cell_of_block(10, 10)
	print("[SAVEPROBE] claim %s : %s, rôle après cycle : %s" % [cell, ClaimManager.claim(cell), ClaimManager.cycle_role(cell)])
	player.skills.gain_xp("minage", 500.0)
	player.gold = 42
	player.inventory.add_material("pierre", 7)
	TickManager.push_ticks(123)
	print("[SAVEPROBE] minage=%d or=%d pierre=%d ticks=%d" % [
		player.skills.level("minage"), player.gold,
		player.inventory.material_stacks.get("pierre", 0), TickManager.tick_index])
	SaveManager.save_now(true)
	print("[SAVEPROBE] sauvegarde synchrone écrite.")
	main.get_tree().quit(0)
