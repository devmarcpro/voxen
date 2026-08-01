extends Probe
## Sonde des commandes (InputManager) — ASSERTIVE, code de sortie 0/1.
##
## Elle existe à cause d'un lot de trois bugs constatés le 2026-08-01, tous de
## la même famille : deux commandes posées sur la même touche. La perdante ne
## plantait pas, ne prévenait pas — elle ne faisait simplement RIEN, et
## personne ne pouvait s'en apercevoir en lisant le code, la chaîne de `elif`
## faisant quinze lignes de long.
##
##   E : « parler » et « équiper »   -> on ne pouvait pas s'équiper au clavier.
##   F : « manger » et « voler »     -> manger faisait décoller le joueur.
##   C : « ramasser » et « descendre » -> ramasser en vol faisait plonger.
##
## Le test central est donc `_check_no_collisions()` : il échoue si DEUX
## actions partagent une touche. Le reste vérifie que la remappe ne peut pas
## en recréer une.

const TAG := "TOUCHES"

var _ok := true


func run() -> void:
	_check_all_registered()
	_check_no_collisions()
	_check_historical_collisions()
	_check_rebind_frees_previous()
	_check_persistence()
	_check_reset()
	# Remettre les défauts : la sonde écrit dans le VRAI settings.cfg du
	# joueur (il n'y a qu'un fichier de réglages, pas de variante de test).
	# Sans ceci, lancer la sonde reconfigurerait les touches de l'utilisateur.
	InputManager.reset_to_defaults()
	finish(_ok, TAG)


func _fail(message: String) -> void:
	_ok = false
	print("[%s] ÉCHEC : %s" % [TAG, message])


func _expect(condition: bool, message: String) -> void:
	if condition:
		print("[%s] ok — %s" % [TAG, message])
	else:
		_fail(message)


## Toute action déclarée doit exister dans l'InputMap avec au moins une touche.
func _check_all_registered() -> void:
	var missing: Array[String] = []
	for action: String in InputManager.DEFAULTS:
		if not InputMap.has_action(action) or InputMap.action_get_events(action).is_empty():
			missing.append(action)
	_expect(missing.is_empty(), "%d action(s) déclarée(s), toutes enregistrées%s" % [
			InputManager.DEFAULTS.size(),
			"" if missing.is_empty() else " — manquantes : %s" % ", ".join(missing)])


## LE test de la sonde : aucune touche ne porte deux actions.
func _check_no_collisions() -> void:
	var owner_of := {}
	var clashes: Array[String] = []
	var allowed := InputManager.ALLOWED_OVERLAPS.map(func(p: Array) -> Array:
		var s := p.duplicate(); s.sort(); return s)
	for action: String in InputManager.DEFAULTS:
		for event: InputEvent in InputMap.action_get_events(action):
			var key := event as InputEventKey
			if key == null:
				continue
			var code := key.physical_keycode
			if owner_of.has(code):
				var pair := [owner_of[code], action]
				pair.sort()
				if pair in allowed:
					continue
				clashes.append("%s partagée par « %s » et « %s »" % [
						OS.get_keycode_string(code), owner_of[code], action])
			owner_of[code] = action
	_expect(clashes.is_empty(), "aucune collision de touche%s" % [
			"" if clashes.is_empty() else " — " + " ; ".join(clashes)])


## Les trois touches historiquement doublées ne portent qu'une action chacune,
## et les commandes qui avaient été évincées existent bien quelque part.
func _check_historical_collisions() -> void:
	for entry: Array in [[KEY_E, "talk"], [KEY_F, "toggle_fly"], [KEY_C, "descend"]]:
		var holders: Array[String] = []
		for action: String in InputManager.DEFAULTS:
			if int(entry[0]) in InputManager._keys_for(action):
				holders.append(action)
		_expect(holders.size() == 1 and holders[0] == String(entry[1]),
				"%s -> %s (attendu « %s » seul)" % [
						OS.get_keycode_string(int(entry[0])), holders, entry[1]])
	for action: String in ["equip", "eat", "pickup"]:
		_expect(not InputManager._keys_for(action).is_empty(),
				"« %s » a bien une touche (%s)" % [action, InputManager.key_label(action)])


## Réaffecter une touche déjà prise la RETIRE à son ancienne action, au lieu
## de créer la collision silencieuse que la sonde entière traque.
func _check_rebind_frees_previous() -> void:
	var stolen: int = int(InputManager._keys_for("talk")[0])
	InputManager.rebind("sleep", stolen)
	var talk_keys := InputManager._keys_for("talk")
	_expect(not (stolen in talk_keys),
			"touche volée à « talk » (il lui reste %s)" % [talk_keys])
	_expect(stolen in InputManager._keys_for("sleep"),
			"touche bien attribuée à « sleep »")
	_check_no_collisions()
	InputManager.reset_to_defaults()


## Une remappe survit à un rechargement des réglages depuis le disque.
func _check_persistence() -> void:
	InputManager.rebind("jump", KEY_P)
	SettingsManager.flush()
	var reread := ConfigFile.new()
	var err := reread.load(SettingsManager.SETTINGS_CFG)
	var saved: Variant = reread.get_value(InputManager.CFG_SECTION, "jump", []) if err == OK else []
	_expect(err == OK and (saved as Array).map(func(k: Variant) -> int: return int(k)) == [KEY_P],
			"remappe écrite sur disque (relu : %s)" % [saved])


func _check_reset() -> void:
	InputManager.reset_to_defaults()
	var jump_keys := InputManager._keys_for("jump")
	_expect(jump_keys == [KEY_SPACE],
			"retour aux défauts : jump -> %s" % [jump_keys.map(OS.get_keycode_string)])
