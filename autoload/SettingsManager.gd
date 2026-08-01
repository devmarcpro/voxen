extends Node
## SettingsManager — réglages du JOUEUR, persistés hors de toute sauvegarde.
##
## Distinction essentielle avec SaveManager : ce qui vit ici appartient à la
## MACHINE et au joueur, pas au monde. La langue, la distance d'affichage et
## les touches doivent survivre à la suppression de tous les mondes, et ne
## doivent JAMAIS voyager dans une sauvegarde (un monde copié d'un poste à
## l'autre imposerait sinon la langue et les touches de son auteur).
##
## Existait avant sous forme éclatée : `user://display.cfg` écrit à la main
## par WorldManager pour le seul rayon de rendu, et la langue... nulle part —
## le sélecteur du menu appelait `TranslationServer.set_locale()` sans rien
## écrire, donc un joueur qui choisissait le japonais le rechoisissait à
## chaque lancement (constaté le 2026-08-01). Un fichier unique, une API
## unique, et la migration de l'ancien display.cfg.

## Fichier unique de réglages. `user://` et non `res://` : en build exporté,
## res:// est en lecture seule.
const SETTINGS_CFG := "user://settings.cfg"

## Ancien fichier, replié dans settings.cfg au premier lancement puis supprimé.
const LEGACY_DISPLAY_CFG := "user://display.cfg"

## Émis après tout changement appliqué, pour que l'interface se rafraîchisse.
## Porte la section et la clé afin qu'un écouteur puisse filtrer.
signal setting_changed(section: String, key: String, value: Variant)

var _cfg := ConfigFile.new()

## Écriture différée : un HSlider émet `value_changed` à CHAQUE pixel de
## déplacement. Sauver à chaque émission, c'est des dizaines d'écritures
## disque pour un seul geste de réglage.
var _save_pending := false


func _ready() -> void:
	_load()
	# Avant toute construction d'interface : les menus posent leurs textes à la
	# construction, donc appliquer la langue APRÈS les aurait laissés dans la
	# langue système jusqu'au prochain rebuild.
	apply_saved_locale()


func _load() -> void:
	var err := _cfg.load(SETTINGS_CFG)
	if err != OK and err != ERR_FILE_NOT_FOUND:
		push_warning("SettingsManager : %s illisible (%s) — réglages par défaut." % [SETTINGS_CFG, err])
	_migrate_legacy_display()


## Replie `user://display.cfg` (rayon de rendu seul) dans le fichier unique.
## Ne remplace pas une valeur déjà présente : si les deux existent, le
## nouveau fichier fait foi.
func _migrate_legacy_display() -> void:
	if not FileAccess.file_exists(LEGACY_DISPLAY_CFG):
		return
	var old := ConfigFile.new()
	if old.load(LEGACY_DISPLAY_CFG) == OK:
		if not _cfg.has_section_key("display", "render_distance"):
			_cfg.set_value("display", "render_distance",
					old.get_value("display", "render_distance", 8))
			_cfg.save(SETTINGS_CFG)
		print("[SETTINGS] display.cfg replié dans settings.cfg.")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(LEGACY_DISPLAY_CFG))


# --- Lecture / écriture ---

## `has_section_key` d'abord : ConfigFile.get_value() ÉCHOUE bruyamment quand
## le défaut fourni est `null` (« no default was given ») au lieu de le
## renvoyer — donc « réglage absent, prends le défaut du code » ne peut pas
## s'exprimer en passant null.
func get_value(section: String, key: String, default: Variant) -> Variant:
	if not _cfg.has_section_key(section, key):
		return default
	return _cfg.get_value(section, key, default)


## Écrit et planifie la sauvegarde. `emit` à faux pour les réglages qu'on
## applique soi-même juste après (évite un aller-retour de rafraîchissement).
func set_value(section: String, key: String, value: Variant, emit: bool = true) -> void:
	if _cfg.has_section_key(section, key) and _cfg.get_value(section, key, null) == value:
		return  # Rien à écrire : évite une sauvegarde par pixel de slider.
	_cfg.set_value(section, key, value)
	_request_save()
	if emit:
		setting_changed.emit(section, key, value)


## Sauvegarde groupée en fin de frame plutôt qu'à chaque appel.
func _request_save() -> void:
	if _save_pending:
		return
	_save_pending = true
	_flush_deferred.call_deferred()


func _flush_deferred() -> void:
	_save_pending = false
	flush()


## Force l'écriture immédiate (appelée à la fermeture du jeu).
func flush() -> void:
	var err := _cfg.save(SETTINGS_CFG)
	if err != OK:
		push_error("SettingsManager : écriture de %s impossible (%s)." % [SETTINGS_CFG, err])


func _notification(what: int) -> void:
	# Quitter par la croix ne passe pas par le menu : sans ceci, le dernier
	# réglage changé dans la même frame que la fermeture serait perdu.
	if what == NOTIFICATION_WM_CLOSE_REQUEST or what == NOTIFICATION_PREDELETE:
		if _save_pending:
			flush()


# --- Langue (10.1) ---

## Langue retenue, ou "" si le joueur n'a jamais choisi — auquel cas on laisse
## Godot décider depuis la locale système (avec repli `en` du project.godot).
func get_locale() -> String:
	return String(get_value("general", "locale", ""))


func apply_saved_locale() -> void:
	var locale := get_locale()
	if locale != "":
		TranslationServer.set_locale(locale)


func set_locale(locale: String) -> void:
	set_value("general", "locale", locale, false)
	TranslationServer.set_locale(locale)
	EventBus.locale_changed.emit(locale)
