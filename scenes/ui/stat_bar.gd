class_name StatBar
extends Control
## Jauge étiquetée réutilisable : intitulé, barre, valeur chiffrée, sur UNE ligne.
##
## POURQUOI UN COMPOSANT ET PAS UNE ProgressBar. Une valeur nue (« 42 / 60 »)
## oblige à faire une division mentale pour savoir si c'est grave ; une barre
## nue ne dit pas combien il reste. Les deux ensemble se lisent d'un coup d'œil
## de loin ET donnent le chiffre exact quand on le cherche. C'est la raison
## d'être de ce composant, et c'est pour ça qu'il refuse de séparer les deux.
##
## Chaque jauge du jeu passe par ici — HUD, fiche de personnage, panneau de
## créature. La couleur vient de `UITheme.GAUGE`, jamais de l'appelant : une
## barre de vie doit être du même rouge partout, sinon l'étiquette redevient
## nécessaire et la lecture d'un coup d'œil est perdue.

## Hauteur totale d'une ligne. La barre est plus fine que la ligne : le texte a
## besoin de respirer au-dessus et en dessous, sinon la police pixel « colle ».
const LINE_H := 16

## Largeur réservée à l'intitulé. Fixe, pour que plusieurs jauges empilées
## alignent leurs barres — des barres en escalier se lisent mal.
const LABEL_W := 74

## Largeur réservée à la valeur chiffrée, à droite de la barre. Fixe aussi, et
## pour la même raison : une valeur qui passe de « 9 » à « 10 » ne doit pas
## faire respirer la barre.
## 52 px : de quoi écrire « 999/999 » en petite police, pas davantage. À 78 la
## valeur mangeait un tiers de la largeur et il ne restait qu'un moignon de
## barre — or c'est la barre qui porte l'information de loin.
const VALUE_W := 52

var _label: Label
var _value: Label
var _track: ColorRect
var _fill: ColorRect
var _color := Color.WHITE
var _ratio := 0.0


## `gauge` est une clé de `UITheme.GAUGE` (« vie », « mana », « xp »…). Une clé
## inconnue tombe sur la couleur de progression neutre plutôt que d'échouer :
## une jauge grise reste utilisable, une erreur au chargement d'UI ne l'est pas.
func setup(label_text: String, gauge: String) -> void:
	_color = UITheme.GAUGE.get(gauge, UITheme.GAUGE["progression"])
	custom_minimum_size = Vector2(0, LINE_H)
	mouse_filter = Control.MOUSE_FILTER_IGNORE

	_label = Label.new()
	_label.text = label_text
	_label.add_theme_font_size_override("font_size", UITheme.FONT_SMALL)
	_label.add_theme_color_override("font_color", UITheme.TEXT_DIM)
	_label.position = Vector2(0, 0)
	_label.size = Vector2(LABEL_W, LINE_H)
	_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	add_child(_label)

	_track = ColorRect.new()
	_track.color = Color(0, 0, 0, 0.55)
	_track.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_track)

	_fill = ColorRect.new()
	_fill.color = _color
	_fill.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_track.add_child(_fill)

	_value = Label.new()
	_value.add_theme_font_size_override("font_size", UITheme.FONT_SMALL)
	_value.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_value.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	add_child(_value)

	resized.connect(_relayout)
	_relayout()


func _relayout() -> void:
	if _track == null:
		return
	var bar_w: float = maxf(20.0, size.x - LABEL_W - VALUE_W - UITheme.GAP_WIDE * 2)
	var bar_y := (LINE_H - UITheme.BAR_H) * 0.5
	_track.position = Vector2(LABEL_W + UITheme.GAP_WIDE, bar_y)
	_track.size = Vector2(bar_w, UITheme.BAR_H)
	_fill.position = Vector2(1, 1)
	_fill.size = Vector2((bar_w - 2) * _ratio, UITheme.BAR_H - 2)
	_value.position = Vector2(size.x - VALUE_W, 0)
	_value.size = Vector2(VALUE_W, LINE_H)


## `current` / `maximum` bruts : le composant fait lui-même la division et le
## formatage. Un appelant qui passerait déjà un ratio devrait aussi composer le
## texte, et c'est exactement là que les formats divergent d'un panneau à l'autre.
func set_values(current: float, maximum: float) -> void:
	var safe_max: float = maxf(maximum, 0.0001)
	_ratio = clampf(current / safe_max, 0.0, 1.0)
	var text := "%d/%d" % [roundi(current), roundi(maximum)]
	if _value.text != text:
		_value.text = text
	# Une jauge presque vide doit ALERTER sans changer de couleur — un rouge qui
	# devient un autre rouge ne se remarque pas. On assombrit le reste de la
	# piste, ce qui fait ressortir le peu qui reste.
	_value.add_theme_color_override("font_color",
		UITheme.TEXT_WARN if _ratio < 0.2 else UITheme.TEXT)
	_relayout()


## Change l'intitulé après coup. Sert aux jauges dont le titre porte une donnée
## variable — une compétence affiche son niveau dans son propre nom, ce qui
## évite une troisième colonne pour un seul chiffre.
func set_label(text: String) -> void:
	if _label.text != text:
		_label.text = text


## Variante sans dénominateur (progression d'une compétence, avancement d'une
## récolte) : le chiffre devient un pourcentage.
func set_ratio(ratio: float, suffix: String = "%") -> void:
	_ratio = clampf(ratio, 0.0, 1.0)
	var text := "%d%s" % [roundi(_ratio * 100.0), suffix]
	if _value.text != text:
		_value.text = text
	_relayout()
