extends Probe
## Sonde de couverture de la police — ASSERTIVE, code de sortie 0/1.
##
## Elle garde la contrepartie du choix fait le 2026-08-01 : les idéogrammes de
## la police pixel sont RASTÉRISÉS pour les seuls caractères présents dans les
## traductions AU MOMENT DE LA GÉNÉRATION. Le jeu de glyphes est donc figé, et
## une traduction qui introduit un caractère inédit s'afficherait en carré vide.
##
## Sans cette sonde, ce défaut serait invisible jusqu'à ce qu'un joueur
## sinophone tombe dessus : rien dans le moteur ne signale un glyphe manquant,
## il se contente de ne rien dessiner. Avec elle, l'oubli de relancer
## `python tools/generate_pixel_font.py` après une traduction fait ÉCHOUER la
## suite de sondes.
##
## Elle vérifie TOUTES les locales, pas seulement le chinois : le latin accentué
## est généré par le même script et peut manquer de la même façon.

const TAG := "POLICE"

## Caractères qu'on n'exige jamais d'une police : ils ne se dessinent pas.
const IGNORED := " \t\n\r"

var _ok := true


func run() -> void:
	var font := UITheme.font
	if font == null:
		_fail("UITheme.font est null — la police n'est pas chargée du tout.")
		finish(false, TAG)
		return
	print("[%s] police : %s" % [TAG, font.get_font_name()])
	_check_detects_absence(font)
	for locale: String in TranslationServer.get_loaded_locales():
		_check_locale(font, locale)
	finish(_ok, TAG)


## Auto-vérification : une sonde de couverture qui ne sait pas repérer un
## glyphe manquant validerait n'importe quoi, y compris une police vide. On
## exige donc qu'un caractère qu'on N'A DÉLIBÉRÉMENT PAS généré soit bien
## rapporté absent. U+9F98 est un idéogramme rare, hors des traductions.
func _check_detects_absence(font: Font) -> void:
	if font.has_char(0x9F98):
		_fail("détection cassée : un caractère non généré est rapporté présent "
				+ "(la police a-t-elle un repli qui couvre tout ?).")
	else:
		print("[%s] ok — un glyphe absent est bien détecté comme absent." % TAG)


func _fail(message: String) -> void:
	_ok = false
	print("[%s] ÉCHEC : %s" % [TAG, message])


## Tous les caractères de toutes les chaînes d'une locale ont-ils un glyphe ?
func _check_locale(font: Font, locale: String) -> void:
	var translation := TranslationServer.get_translation_object(locale)
	if translation == null:
		_fail("locale « %s » déclarée mais aucune traduction chargée." % locale)
		return
	var missing := {}
	var checked := 0
	for key: StringName in translation.get_translated_message_list():
		var text := String(key)
		checked += 1
		for index in text.length():
			var glyph := text[index]
			if glyph in IGNORED or missing.has(glyph):
				continue
			# `has_char` interroge la police ET ses replis — exactement ce que
			# le moteur consultera au moment de dessiner.
			if not font.has_char(glyph.unicode_at(0)):
				missing[glyph] = true
	if missing.is_empty():
		print("[%s] ok — « %s » : %d chaîne(s), tous les caractères couverts." % [
				TAG, locale, checked])
	else:
		var list: Array = missing.keys()
		list.sort()
		_fail("« %s » : %d caractère(s) sans glyphe -> %s%s" % [
				locale, list.size(), "".join(list.slice(0, 40)),
				" …" if list.size() > 40 else ""])
		print("[%s]   relancer : python tools/generate_pixel_font.py" % TAG)
