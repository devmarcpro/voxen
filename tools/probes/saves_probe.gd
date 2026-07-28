extends Probe
## Sonde `--probe-saves` — extraite de main.gd le 2026-07-28 (audit architectural).
## Logique inchangée : seuls les accès à la scène ont été réécrits
## ($Player -> player, get_tree() -> main.get_tree(), etc.).


## Sonde gestion des sauvegardes (E.10) : nombre illimité de mondes, listage
## complet, suppression réelle et garde-fous. La suppression est la seule
## opération DESTRUCTIVE du jeu : elle doit être prouvée, pas supposée.
func run() -> void:
	await main.get_tree().process_frame
	var ok := true
	var racine := SaveManager.SAVES_ROOT
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(racine))

	# 12 mondes factices : bien au-delà des 8 que l'ancienne liste affichait.
	var noms: Array[String] = []
	for i in 12:
		var nom := "_sonde_monde_%d" % i
		noms.append(nom)
		var dir := "%s/%s" % [racine, nom]
		DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(dir + "/chunks"))
		var f := FileAccess.open(dir + "/world.json", FileAccess.WRITE)
		f.store_string(JSON.stringify({"version": SaveManager.SAVE_VERSION, "name": nom,
			"seed": 1000 + i, "ticks": 24000 * i, "last_saved": 1000 + i}))
		f.close()
		# Un chunk factice : la suppression doit vider le sous-dossier aussi.
		var c := FileAccess.open(dir + "/chunks/0_0_0.bin", FileAccess.WRITE)
		c.store_8(0)
		c.close()

	var listes := SaveManager.list_worlds()
	var trouves := 0
	for w: Dictionary in listes:
		if String(w["name"]).begins_with("_sonde_monde_"):
			trouves += 1
	print("[SAVES] %d mondes de test créés, %d retrouvés dans la liste (attendu 12)" % [12, trouves])
	ok = ok and trouves == 12

	# 1. Suppression réelle : dossier ET sous-dossier de chunks disparaissent.
	var cible := "%s/%s" % [racine, noms[0]]
	var supprime := SaveManager.delete_world(cible)
	var existe_encore := FileAccess.file_exists(cible + "/world.json")
	var chunk_encore := FileAccess.file_exists(cible + "/chunks/0_0_0.bin")
	print("[SAVES] suppression : retour=%s world.json restant=%s chunk restant=%s (attendu true/false/false)" % [
			supprime, existe_encore, chunk_encore])
	ok = ok and supprime and not existe_encore and not chunk_encore

	# 2. Les AUTRES mondes doivent être intacts — une suppression ne doit
	# jamais déborder sur ses voisins.
	var restants := 0
	for w: Dictionary in SaveManager.list_worlds():
		if String(w["name"]).begins_with("_sonde_monde_"):
			restants += 1
	print("[SAVES] mondes de test restants : %d (attendu 11)" % restants)
	ok = ok and restants == 11

	# 3. Garde-fou : refus de tout chemin HORS du dossier de sauvegardes.
	var hors := SaveManager.delete_world("user://display.cfg")
	var hors2 := SaveManager.delete_world("res://data")
	print("[SAVES] chemins hors sauvegardes refusés : %s / %s (attendu false/false)" % [hors, hors2])
	ok = ok and not hors and not hors2

	# 4. Garde-fou : refus de supprimer le monde EN COURS de jeu.
	var actif := SaveManager.save_dir
	SaveManager.world_active = true
	var refus := SaveManager.delete_world(actif)
	SaveManager.world_active = false
	print("[SAVES] suppression du monde actif refusée : %s (attendu false)" % [not refus])
	ok = ok and not refus

	# 5. « Continuer » ne doit pas pointer un monde supprimé.
	var cible2 := "%s/%s" % [racine, noms[1]]
	var dernier := FileAccess.open(racine + "/dernier.json", FileAccess.WRITE)
	dernier.store_string(JSON.stringify({"dir": cible2}))
	dernier.close()
	SaveManager.delete_world(cible2)
	var pointeur_restant := FileAccess.file_exists(racine + "/dernier.json")
	print("[SAVES] pointeur « dernier monde » nettoyé : %s (attendu true)" % [not pointeur_restant])
	ok = ok and not pointeur_restant

	# Ménage : la sonde ne laisse rien derrière elle.
	for nom in noms:
		SaveManager.delete_world("%s/%s" % [racine, nom])

	print("[SAVES] RÉSULTAT : %s" % ("OK" if ok else "ÉCHEC"))
	main.get_tree().quit(0 if ok else 1)
