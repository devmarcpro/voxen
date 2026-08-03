extends Node
## InputManager — table unique des commandes, enregistrée dans l'InputMap.
##
## POURQUOI. Le jeu testait des touches en dur (`Input.is_physical_key_pressed(KEY_W)`,
## `key.physical_keycode == KEY_E`) dans six fichiers. Ce n'était pas cassé —
## les codes PHYSIQUES désignent la position de la touche, donc ZQSD sur AZERTY
## et WASD sur QWERTY sont bien les mêmes touches — mais ça interdisait toute
## remappe, toute manette, et surtout ça laissait deux commandes se poser
## silencieusement sur la même touche (constaté le 2026-08-01) :
##
##   - KEY_E testé DEUX FOIS dans le même `elif` de player.gd : `_try_talk()`
##     gagnait, `_try_equip()` était du code mort — on ne pouvait pas
##     s'équiper au clavier, du tout.
##   - KEY_F pris par « manger » (player.gd) ET « voler/marcher »
##     (fly_camera.gd), tous deux en `_unhandled_input` sans consommer
##     l'événement : manger faisait aussi décoller le joueur.
##   - KEY_C pris par « ramasser » (player.gd) ET « descendre » en vol
##     (fly_camera.gd), même cause : ramasser un objet en vol faisait
##     plonger.
##
## Une table unique rend ces collisions IMPOSSIBLES : `_validate_defaults()`
## échoue au démarrage si deux actions partagent une touche.
##
## CHOIX : les actions sont déclarées ICI et non dans le `[input]` de
## project.godot. Godot y sérialise des `Object(InputEventKey, ...)` à la main,
## illisibles en diff et impossibles à commenter — or c'est exactement le
## genre de table qu'il faut pouvoir relire. Contrepartie assumée : les
## actions n'apparaissent pas dans l'éditeur Godot.

## Touches réassignées le 2026-08-01 pour lever les collisions ci-dessus.
## « manger » et « équiper » ont bougé parce que F (vol) et E (parler) sont
## les deux seules des quatre à être documentées dans l'aide du HUD.
const DEFAULTS := {
	# --- Déplacement (fly_camera.gd) ---
	"move_forward":   {"keys": [KEY_W], "cat": "deplacement"},
	"move_back":      {"keys": [KEY_S], "cat": "deplacement"},
	"move_left":      {"keys": [KEY_A], "cat": "deplacement"},
	"move_right":     {"keys": [KEY_D], "cat": "deplacement"},
	"jump":           {"keys": [KEY_SPACE], "cat": "deplacement"},
	"descend":        {"keys": [KEY_C], "cat": "deplacement"},
	"sneak":          {"keys": [KEY_SHIFT], "cat": "deplacement"},
	"sprint":         {"keys": [KEY_CTRL], "cat": "deplacement"},
	"toggle_fly":     {"keys": [KEY_F], "cat": "deplacement"},

	# --- Monde (player.gd) ---
	"cycle_grid":     {"keys": [KEY_R], "cat": "monde"},
	# INTERACTION UNIQUE (2026-08-03) : elle remplace « parler » (E),
	# « ramasser » (G) et « encaisser l'étal » (Y). Une seule touche pour tout
	# ce qui se trouve dans le monde ; c'est le contexte qui décide, pas le
	# joueur (voir Player._try_interact).
	"interact":       {"keys": [KEY_E], "cat": "monde"},
	"equip":          {"keys": [KEY_H], "cat": "monde"},   # était KEY_E — code mort.
	"sleep":          {"keys": [KEY_N], "cat": "monde"},
	"toggle_claim":   {"keys": [KEY_V], "cat": "monde"},
	"cycle_claim_role": {"keys": [KEY_B], "cat": "monde"},
	"stall_stock":    {"keys": [KEY_T], "cat": "monde"},

	# --- Modules de compétence (5.1) ---
	"module_1":       {"keys": [KEY_J], "cat": "modules"},
	"module_2":       {"keys": [KEY_K], "cat": "modules"},
	"module_3":       {"keys": [KEY_L], "cat": "modules"},

	# --- Interface ---
	"inventory":      {"keys": [KEY_TAB], "cat": "interface"},
	"world_map":      {"keys": [KEY_M], "cat": "interface"},
	"map_legend":     {"keys": [KEY_L], "cat": "interface"},
	"debug_hud":      {"keys": [KEY_F3], "cat": "interface"},
	"cheat_menu":     {"keys": [KEY_F1], "cat": "interface"},
	"reload_data":    {"keys": [KEY_F5], "cat": "interface"},  # Rechargement à chaud (D.2, debug).
	"save_game":      {"keys": [KEY_F9], "cat": "interface"},
}

## Actions dont la collision est LÉGITIME parce que leurs contextes sont
## disjoints : `map_legend` (L) n'existe que carte ouverte, où `module_3`
## (L aussi) est inerte. Sans cette liste, la validation refuserait de
## démarrer. Toute paire ajoutée ici est une dette : elle suppose que les
## deux écrans ne seront jamais actifs en même temps.
const ALLOWED_OVERLAPS := [["module_3", "map_legend"]]

## Section de settings.cfg où vivent les remappes du joueur.
const CFG_SECTION := "input"

signal bindings_changed


func _ready() -> void:
	_validate_defaults()
	_register_all()


## Refuse de démarrer sur une table incohérente. C'est volontairement bruyant :
## une collision de touches est invisible à l'exécution (la commande perdante
## ne fait simplement « rien »), donc elle doit sauter aux yeux ici.
func _validate_defaults() -> void:
	var seen := {}
	for action: String in DEFAULTS:
		for keycode: int in DEFAULTS[action]["keys"]:
			if seen.has(keycode):
				var pair := [seen[keycode], action]
				pair.sort()
				if pair in ALLOWED_OVERLAPS.map(func(p: Array) -> Array:
						var s := p.duplicate(); s.sort(); return s):
					continue
				push_error("InputManager : « %s » et « %s » partagent la touche %s." % [
						seen[keycode], action, OS.get_keycode_string(keycode)])
			seen[keycode] = action


## (Re)pose toutes les actions dans l'InputMap, remappes du joueur comprises.
func _register_all() -> void:
	for action: String in DEFAULTS:
		if InputMap.has_action(action):
			InputMap.erase_action(action)
		InputMap.add_action(action)
		for keycode: int in _keys_for(action):
			var ev := InputEventKey.new()
			# PHYSIQUE et non `keycode` : c'est la POSITION de la touche qui
			# compte. Sur `keycode`, un clavier AZERTY ferait avancer sur « Z »
			# la commande déclarée sur W, et le joueur ne pourrait plus jouer.
			ev.physical_keycode = keycode
			InputMap.action_add_event(action, ev)


## Touches effectives : remappe du joueur si elle existe, défaut sinon.
##
## L'ABSENCE de clé signifie « pas de remappe » ; une liste VIDE signifie
## « commande volontairement non liée » — deux choses différentes. Les
## confondre (tester `is_empty()` plutôt que la présence) faisait revenir par
## le défaut une touche qu'on venait de retirer à son ancienne action, donc
## recréait exactement la collision que `rebind` cherche à éviter. Trouvé par
## --probe-touches, qui a échoué sur sa propre vérification anti-collision.
func _keys_for(action: String) -> Array:
	var saved: Variant = SettingsManager.get_value(CFG_SECTION, action, null)
	if saved is Array:
		return (saved as Array).map(func(k: Variant) -> int: return int(k))
	return (DEFAULTS[action]["keys"] as Array).duplicate()


# --- API de remappe (écran des paramètres) ---

## Action à laquelle `keycode` est déjà affectée, ou "" si la touche est libre.
## À appeler AVANT `rebind` pour prévenir le joueur du conflit.
func action_using(keycode: int, except: String = "") -> String:
	for action: String in DEFAULTS:
		if action != except and keycode in _keys_for(action):
			return action
	return ""


## Réaffecte `action` à `keycode`. Retire la touche à son ancienne action
## plutôt que de créer une collision silencieuse — c'est le bug de 2026-08-01.
func rebind(action: String, keycode: int) -> void:
	if not DEFAULTS.has(action):
		push_error("InputManager : action inconnue « %s »." % action)
		return
	var previous := action_using(keycode, action)
	if previous != "":
		var freed := _keys_for(previous).filter(func(k: int) -> bool: return k != keycode)
		SettingsManager.set_value(CFG_SECTION, previous, freed, false)
	SettingsManager.set_value(CFG_SECTION, action, [keycode], false)
	_register_all()
	bindings_changed.emit()


func reset_to_defaults() -> void:
	for action: String in DEFAULTS:
		SettingsManager.set_value(CFG_SECTION, action, null, false)
	_register_all()
	bindings_changed.emit()


## Libellé lisible de la touche d'une action, pour l'aide du HUD et l'écran
## des paramètres — qui affichaient jusqu'ici des touches ÉCRITES EN DUR dans
## les fichiers de localisation, donc fausses dès la première remappe.
func key_label(action: String) -> String:
	var keys := _keys_for(action)
	if keys.is_empty():
		return "—"
	return OS.get_keycode_string(int(keys[0]))


## Touches de plusieurs actions accolées, pour les groupes qui se lisent d'un
## bloc — « ZQSD » plutôt que « Z : avancer · Q : gauche · S : reculer ».
func keys_label(actions: Array) -> String:
	var out := ""
	for action: String in actions:
		out += key_label(action)
	return out


## Clé de localisation du nom d'une action (« ui.input.jump »). Le HUD et
## l'écran des paramètres s'en servent pour ÉTIQUETER une touche qu'ils lisent
## de l'InputMap, au lieu de la réécrire en dur dans les fichiers de langue.
func label_key(action: String) -> String:
	return "ui.input." + action


## Actions d'une catégorie, dans l'ordre de déclaration (l'écran des
## paramètres les regroupe ainsi).
func actions_in(category: String) -> Array:
	var out: Array = []
	for action: String in DEFAULTS:
		if DEFAULTS[action]["cat"] == category:
			out.append(action)
	return out
