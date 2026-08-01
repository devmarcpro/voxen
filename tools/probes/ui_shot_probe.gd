extends Probe
## Sonde `--test-ui` — CAPTURES de toutes les interfaces (fenêtré obligatoire).
##
## L'apparence d'une interface ne se démontre pas, elle se regarde : aucune
## assertion ne dira jamais si une police est lisible, si un panneau est trop
## aéré ou si deux colonnes sont mal alignées. Cette sonde n'existe donc que
## pour produire, en une commande, une image de CHAQUE écran du jeu — le seul
## moyen de juger une standardisation d'interface sans cliquer partout à la main
## et sans en oublier la moitié.
##
## Elle vérifie tout de même une chose mesurable : que la police pixel est bien
## celle qui sert, et pas la police par défaut du moteur. C'est l'erreur
## silencieuse par excellence — un thème qui ne s'applique pas ne casse rien, il
## laisse simplement tout comme avant.

const TAG := "SHOTUI"

var _ok := true


func run() -> void:
	await _check_theme()
	if not can_capture():
		print("[%s] captures impossibles en --headless : relancer AVEC fenêtre." % TAG)
		finish(_ok, TAG)
		return
	TickManager.tick_index = int(DayNightManager.TICKS_PER_DAY / 2)
	await wait_seconds(3.0)

	await _shot_hud()
	await _shot_game_menu()
	await _shot_cheat_menu()
	finish(_ok, TAG)


## Le thème est-il RÉELLEMENT en place ? Un thème non appliqué est invisible :
## l'interface reste fonctionnelle, simplement inchangée, et on peut passer une
## session entière à retoucher des constantes qui ne servent à rien.
func _check_theme() -> void:
	# On n'interroge PAS `root.theme` : le thème vient de ProjectSettings
	# (`gui/theme/custom`), que le moteur applique en interne sans le recopier
	# sur la fenêtre. Un test sur `root.theme` échouerait alors que tout va bien.
	var declared := String(ProjectSettings.get_setting("gui/theme/custom", ""))
	print("[%s] thème de projet déclaré (%s) : %s" % [TAG,
		"aucun" if declared == "" else declared, "OK" if declared != "" else "ÉCHEC"])
	_ok = _ok and declared != ""

	# On interroge un VRAI Label dans l'arbre, pas `theme.default_font` : ce
	# champ n'est qu'une valeur de secours interne au thème, et il peut être
	# correctement rempli pendant que l'écran affiche encore la police du
	# moteur. C'est exactement le piège qui a été rencontré ici — une première
	# version du thème passait ce test tout en ne changeant rien à l'affichage.
	var probe_label := Label.new()
	main.add_child(probe_label)
	# UNE FRAME D'ATTENTE, obligatoire : Godot propage le thème d'un ancêtre au
	# moment de la notification, pas au retour de add_child(). Interroger tout de
	# suite renvoie la police du moteur et fait croire à une régression — piège
	# rencontré ici même.
	await wait_frame()
	var resolved: Font = probe_label.get_theme_font("font")
	var is_pixel := resolved != null and resolved.resource_path == UITheme.FONT_PATH
	print("[%s] police pixel réellement résolue sur un Label (%s) : %s" % [TAG,
		"aucune" if resolved == null else resolved.resource_path,
		"OK" if is_pixel else "ÉCHEC"])
	_ok = _ok and is_pixel
	probe_label.queue_free()
	# Un glyphe accentué manquant ne se voit qu'à l'usage, en français, sur un
	# mot précis — autant dire jamais pendant une relecture.
	var missing := ""
	# Les symboles comptent autant que les accents : le moteur n'a pas ✗ ni ⚔
	# dans sa police de secours, un oubli s'affiche donc en carré vide.
	for glyph: String in ["é", "è", "ê", "à", "ç", "ô", "û", "î", "«", "»", "°", "—",
			"✓", "✗", "⚔", "±", "≥", "≤", "·", "…", "’", "×"]:
		if resolved == null or not resolved.has_char(glyph.unicode_at(0)):
			missing += glyph
	print("[%s] glyphes français présents%s : %s" % [TAG,
		"" if missing == "" else " (manquants : " + missing + ")",
		"OK" if missing == "" else "ÉCHEC"])
	_ok = _ok and missing == ""


func _shot_hud() -> void:
	await wait_seconds(0.4)
	await screenshot("ui_hud.png")
	print("[%s] %s" % [TAG, capture_path("ui_hud.png")])


func _shot_game_menu() -> void:
	var menu := main.get_node_or_null("GameMenu")
	if menu == null:
		print("[%s] GameMenu introuvable" % TAG)
		_ok = false
		return
	menu.call("_open")
	await wait_seconds(0.5)
	for tab: String in menu.get("TABS"):
		menu.call("_select_tab", tab)
		await wait_seconds(0.5)
		await screenshot("ui_menu_%s.png" % tab)
		print("[%s] %s" % [TAG, capture_path("ui_menu_%s.png" % tab)])
	menu.call("_close")
	await wait_seconds(0.2)


func _shot_cheat_menu() -> void:
	var menu := main.get_node_or_null("CheatMenu")
	if menu == null:
		print("[%s] CheatMenu introuvable" % TAG)
		_ok = false
		return
	menu.call("_open")
	await wait_seconds(0.5)
	var tabs := _find_tabs(menu)
	if tabs == null:
		await screenshot("ui_triche.png")
		return
	for index in tabs.get_tab_count():
		tabs.current_tab = index
		await wait_seconds(0.4)
		await screenshot("ui_triche_%d.png" % index)
		print("[%s] %s" % [TAG, capture_path("ui_triche_%d.png" % index)])


func _find_tabs(node: Node) -> TabContainer:
	if node is TabContainer:
		return node
	for child in node.get_children():
		var found := _find_tabs(child)
		if found != null:
			return found
	return null
