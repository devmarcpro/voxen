extends Node
## Thème unique de toutes les interfaces de Voxen (autoload).
##
## POURQUOI CE FICHIER EXISTE. Avant lui, chaque panneau réinventait son
## apparence : 17 `add_theme_font_size_override` dispersés dans six fichiers, des
## tailles allant de 11 à 52 sans échelle commune, des couleurs écrites en dur
## trois fois chacune, et des `separation` tirés au jugé (4, 6, 8, 10). Résultat :
## deux panneaux voisins ne se ressemblaient pas, et changer l'allure du jeu
## demandait de relire tout le dossier `scenes/ui`.
##
## Ici, une seule source : une palette, une échelle de tailles, une grille
## d'espacements. Un panneau qui a besoin d'une valeur la PREND ICI. S'il lui en
## faut une qui n'existe pas, c'est le signe qu'il faut l'ajouter au barème, pas
## la coder sur place — sinon on retombe exactement dans l'état précédent.
##
## Le thème est appliqué à la fenêtre racine : tout Control en hérite sans avoir
## à s'y abonner. Un panneau n'a donc RIEN à faire pour être cohérent, et c'est
## volontaire : la cohérence par défaut est la seule qui tienne dans le temps.

# --- Police ------------------------------------------------------------------
#
# Police PIXEL matricielle générée par tools/generate_pixel_font.py. Elle est
# importée en « mise à l'échelle entière uniquement » : un glyphe pixel n'a de
# sens qu'à ×1, ×2, ×3. À une échelle fractionnaire, une colonne de pixels sur
# deux disparaît et le texte devient sale — c'est le défaut classique des
# interfaces pixel, et il est ici rendu impossible par construction.
#
# Conséquence directe : les tailles disponibles sont les MULTIPLES de 11, et pas
# autre chose. L'échelle ci-dessous n'est pas un choix esthétique, c'est la
# seule qui existe.

const FONT_PATH := "res://assets/ui/voxen_pixel.fnt"

## Taille de base = hauteur d'une cellule de glyphe. Toute autre taille est un
## multiple entier de celle-ci.
const FONT_UNIT := 11

## Données denses : cellules de tableau, rappels de touche, infobulles. Hauteur
## de capitale 7 px — lisible, et surtout compact là où il y a beaucoup à lire.
const FONT_SMALL := FONT_UNIT

## Texte courant de toutes les interfaces.
const FONT_BODY := FONT_UNIT * 2

## En-tête de section à l'intérieur d'un panneau.
const FONT_HEADING := FONT_UNIT * 2

## Titre de panneau, et titre du menu principal.
const FONT_TITLE := FONT_UNIT * 3


# --- Palette -----------------------------------------------------------------
#
# Sombre et désaturée pour le châssis, saturée pour l'information. Règle de
# lecture : la couleur ne DÉCORE jamais, elle CLASSE. Si deux éléments ont la
# même couleur, ils sont de même nature.

const BG_DEEP := Color(0.055, 0.063, 0.086, 0.94)     # fond de panneau plein
const BG_PANEL := Color(0.086, 0.098, 0.133, 0.94)    # fond de sous-bloc
const BG_SLOT := Color(0.130, 0.145, 0.190, 0.96)     # emplacement (hotbar, grille)
const BG_HOVER := Color(0.180, 0.200, 0.255, 0.98)
const BG_ACTIVE := Color(0.255, 0.215, 0.110, 1.0)

const LINE := Color(0.255, 0.280, 0.345, 1.0)         # filet de séparation
const LINE_STRONG := Color(0.45, 0.50, 0.60, 1.0)     # bord d'élément sélectionné

const TEXT := Color(0.88, 0.90, 0.94, 1.0)
const TEXT_DIM := Color(0.58, 0.62, 0.70, 1.0)        # secondaire, unités, aides
const TEXT_ACCENT := Color(1.00, 0.82, 0.35, 1.0)     # titres de section
const TEXT_OK := Color(0.45, 0.88, 0.50, 1.0)
const TEXT_WARN := Color(0.95, 0.42, 0.38, 1.0)

## Couleurs des JAUGES. Une jauge garde sa couleur partout où elle apparaît :
## la barre de vie du HUD, celle au-dessus d'un mob et celle de la fiche de
## personnage sont le même rouge, sinon le joueur doit relire l'étiquette.
const GAUGE := {
	"vie": Color(0.85, 0.20, 0.20),
	"mana": Color(0.25, 0.50, 0.95),
	"faim": Color(0.90, 0.62, 0.20),
	"fatigue": Color(0.55, 0.50, 0.85),
	"endurance": Color(0.95, 0.80, 0.30),
	"xp": Color(0.55, 0.85, 0.45),
	"progression": Color(0.60, 0.70, 0.85),
}


# --- Grille d'espacement -----------------------------------------------------
#
# Multiples de 4 uniquement. Une marge de 6 px à côté d'une de 8 se voit et ne
# se justifie jamais ; la contrainte supprime la question.

const GAP_TIGHT := 2
const GAP := 4
const GAP_WIDE := 8
const PAD := 8
const PAD_WIDE := 12

## Hauteur d'une ligne cliquable (bouton, entrée de liste). Unique, pour que
## deux colonnes voisines s'alignent sans réglage.
const ROW_H := 26

## Épaisseur d'une jauge de statut.
const BAR_H := 12

## Côté d'un emplacement d'inventaire ou de hotbar.
const SLOT := 44


var font: Font

## Police par défaut du MOTEUR, capturée avant toute substitution. C'est elle
## qui affiche le japonais et le chinois ; la perdre de vue reviendrait à ne
## plus pouvoir la donner en secours.
static var _engine_font: Font = ThemeDB.fallback_font


func _ready() -> void:
	# Le thème LUI-MÊME est appliqué par ProjectSettings (gui/theme/custom), pas
	# ici : voir tools/generate_ui_theme.gd pour la raison. L'autoload ne sert
	# plus qu'à exposer la palette, l'échelle et les fabriques aux panneaux.
	# On charge tout de même la police pour que `font` soit disponible et pour
	# que le secours CJK soit branché sur la ressource réellement utilisée.
	_load_font()


## Construit le thème complet. Séparé de `_ready` pour que les sondes puissent
## le fabriquer et l'inspecter sans dépendre de l'arbre de scène.
func build() -> Theme:
	var theme := Theme.new()
	theme.default_font = _load_font()
	theme.default_font_size = FONT_BODY
	_apply_font(theme)

	_style_panels(theme)
	_style_buttons(theme)
	_style_inputs(theme)
	_style_text(theme)
	_style_containers(theme)
	return theme


## Charge la police pixel et lui donne la police par défaut du moteur en
## SECOURS. Sans ce secours, le japonais et le chinois — deux des quatre langues
## du jeu — s'afficheraient en carrés vides : une police pixel latine dessinée à
## la main ne couvrira jamais les sinogrammes. Mieux vaut un mélange visible
## qu'un texte illisible.
func _load_font() -> Font:
	if font != null:
		return font
	if not ResourceLoader.exists(FONT_PATH):
		push_warning(("UITheme : police pixel absente (%s) — relancer "
			+ "`python tools/generate_pixel_font.py`.") % FONT_PATH)
		font = ThemeDB.fallback_font
		return font
	var pixel: FontFile = load(FONT_PATH)
	# `_engine_font` et NON `ThemeDB.fallback_font` : ce dernier a pu être
	# remplacé par notre propre police au passage précédent, et se donner
	# soi-même en secours est une boucle que le moteur refuse (« Cyclic font
	# fallback »). Le cas se produit dès qu'on construit le thème deux fois dans
	# le même processus — exactement ce que fait l'outil de génération.
	if pixel.fallbacks != [_engine_font]:
		pixel.fallbacks = [_engine_font]
	font = pixel
	return font


## Types de Control qui affichent du texte. La liste est explicite et c'est
## nécessaire : `Theme.default_font` ne sert QUE de valeur de secours pour les
## entrées `font` invalides DE CE THÈME. Un thème qui n'en déclare aucune ne
## remplace rien du tout — la recherche continue jusqu'au thème par défaut du
## moteur, qui impose sa propre police. Symptôme : tout compile, la sonde
## confirme que le thème est appliqué, et l'écran reste en Open Sans.
const FONT_TYPES := [
	"Label", "RichTextLabel", "Button", "OptionButton", "MenuButton",
	"CheckBox", "CheckButton", "LinkButton", "LineEdit", "TextEdit",
	"ProgressBar", "PopupMenu", "ItemList", "Tree", "TabContainer", "TabBar",
	"TooltipLabel", "AcceptDialog", "SpinBox", "HeaderSmall", "HeaderMedium",
	"HeaderLarge",
]


func _apply_font(theme: Theme) -> void:
	var pixel := _load_font()
	for type: String in FONT_TYPES:
		theme.set_font("font", type, pixel)
		theme.set_font_size("font_size", type, FONT_BODY)
	# Les infobulles sont denses par nature : elles prennent la petite taille.
	theme.set_font_size("font_size", "TooltipLabel", FONT_SMALL)
	# Filet de sécurité pour tout type non listé (et pour les Control créés par
	# le moteur lui-même, comme les champs internes d'un SpinBox).
	ThemeDB.fallback_font = pixel
	ThemeDB.fallback_font_size = FONT_BODY


## Fond plein, filet fin, coins droits. AUCUN arrondi nulle part : un rayon de
## coin sur une interface pixel produit un escalier d'anticrénelage qui jure
## avec la police.
func _box(bg: Color, border: Color = LINE, border_width: int = 1,
		padding: int = PAD) -> StyleBoxFlat:
	var box := StyleBoxFlat.new()
	box.bg_color = bg
	box.set_border_width_all(border_width)
	box.border_color = border
	box.set_content_margin_all(padding)
	return box


func _style_panels(theme: Theme) -> void:
	theme.set_stylebox("panel", "PanelContainer", _box(BG_PANEL))
	theme.set_stylebox("panel", "Panel", _box(BG_DEEP, LINE, 1, PAD_WIDE))
	theme.set_stylebox("panel", "TabContainer", _box(BG_PANEL))
	theme.set_stylebox("panel", "PopupMenu", _box(BG_DEEP, LINE_STRONG))
	theme.set_stylebox("panel", "Tree", _box(BG_PANEL))
	theme.set_stylebox("panel", "ItemList", _box(BG_PANEL))


func _style_buttons(theme: Theme) -> void:
	for type: String in ["Button", "OptionButton", "MenuButton", "CheckBox", "CheckButton"]:
		theme.set_stylebox("normal", type, _box(BG_SLOT, LINE, 1, GAP_WIDE))
		theme.set_stylebox("hover", type, _box(BG_HOVER, LINE_STRONG, 1, GAP_WIDE))
		theme.set_stylebox("pressed", type, _box(BG_ACTIVE, LINE_STRONG, 1, GAP_WIDE))
		theme.set_stylebox("focus", type, _box(Color(0, 0, 0, 0), LINE_STRONG, 1, GAP_WIDE))
		# Un bouton désactivé doit se lire comme désactivé SANS être illisible :
		# on éteint le fond, pas le texte, sinon le joueur ne sait plus ce que
		# l'action aurait fait.
		theme.set_stylebox("disabled", type, _box(BG_DEEP, LINE, 1, GAP_WIDE))
		theme.set_color("font_color", type, TEXT)
		theme.set_color("font_hover_color", type, Color.WHITE)
		theme.set_color("font_pressed_color", type, Color.WHITE)
		theme.set_color("font_disabled_color", type, TEXT_DIM)
	theme.set_constant("h_separation", "Button", GAP_WIDE)


func _style_inputs(theme: Theme) -> void:
	theme.set_stylebox("normal", "LineEdit", _box(BG_SLOT, LINE, 1, GAP_WIDE))
	theme.set_stylebox("focus", "LineEdit", _box(BG_SLOT, LINE_STRONG, 1, GAP_WIDE))
	theme.set_color("font_color", "LineEdit", TEXT)
	theme.set_color("caret_color", "LineEdit", TEXT_ACCENT)

	# Une ProgressBar sert de JAUGE : fond creux, remplissage plein, pas de
	# dégradé. Sa couleur de remplissage est fixée par appelant (voir GAUGE).
	theme.set_stylebox("background", "ProgressBar", _box(Color(0, 0, 0, 0.55), LINE, 1, 0))
	theme.set_stylebox("fill", "ProgressBar", _box(GAUGE["progression"], Color(0, 0, 0, 0), 0, 0))
	theme.set_color("font_color", "ProgressBar", TEXT)
	theme.set_font_size("font_size", "ProgressBar", FONT_SMALL)

	theme.set_stylebox("slider", "HSlider", _box(Color(0, 0, 0, 0.55), LINE, 1, 0))
	theme.set_stylebox("grabber_area", "HSlider", _box(TEXT_ACCENT, Color(0, 0, 0, 0), 0, 0))


func _style_text(theme: Theme) -> void:
	theme.set_color("font_color", "Label", TEXT)
	theme.set_color("font_color", "RichTextLabel", TEXT)
	# Ombre portée d'un pixel : le HUD se lit par-dessus le monde, où le fond
	# peut être n'importe quelle couleur. Sans elle, du texte clair sur de la
	# neige ou du sable disparaît — constaté sur les captures de plage.
	theme.set_color("font_shadow_color", "Label", Color(0, 0, 0, 0.85))
	theme.set_constant("shadow_offset_x", "Label", 1)
	theme.set_constant("shadow_offset_y", "Label", 1)
	theme.set_constant("shadow_outline_size", "Label", 0)


func _style_containers(theme: Theme) -> void:
	theme.set_constant("separation", "VBoxContainer", GAP)
	theme.set_constant("separation", "HBoxContainer", GAP)
	theme.set_constant("h_separation", "GridContainer", GAP)
	theme.set_constant("v_separation", "GridContainer", GAP)
	theme.set_constant("margin_left", "MarginContainer", PAD)
	theme.set_constant("margin_right", "MarginContainer", PAD)
	theme.set_constant("margin_top", "MarginContainer", PAD)
	theme.set_constant("margin_bottom", "MarginContainer", PAD)


# --- Fabriques partagées -----------------------------------------------------
#
# Un panneau ne construit PAS ses propres titres de section ni ses propres
# jauges : il les demande ici. C'est ce qui garantit qu'un en-tête de l'onglet
# craft et un en-tête du menu de triche sont le même objet, et non deux Label
# réglés séparément qui divergeront à la première retouche.

## Titre de section : accentué, taille d'en-tête, filet en dessous.
func heading(text: String) -> Label:
	var label := Label.new()
	label.text = text
	label.add_theme_font_size_override("font_size", FONT_HEADING)
	label.add_theme_color_override("font_color", TEXT_ACCENT)
	return label


## Ligne de séparation horizontale (1 px). Sert à découper un panneau en zones
## sans ajouter de marge — c'est ce qui permet de compacter sans entasser.
func rule() -> Control:
	var line := ColorRect.new()
	line.color = LINE
	line.custom_minimum_size = Vector2(0, 1)
	line.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	line.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return line


## Texte secondaire (unité, aide, valeur dérivée).
func dim(text: String, small: bool = true) -> Label:
	var label := Label.new()
	label.text = text
	label.add_theme_font_size_override("font_size", FONT_SMALL if small else FONT_BODY)
	label.add_theme_color_override("font_color", TEXT_DIM)
	return label


## Ligne « intitulé → valeur » à colonnes ALIGNÉES. L'intitulé occupe une
## largeur fixe : sans elle, chaque ligne pose sa valeur où elle veut et une
## liste de statistiques devient illisible en diagonale.
func field(label_text: String, value_text: String, label_width: int = 150) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", GAP_WIDE)
	var key := Label.new()
	key.text = label_text
	key.custom_minimum_size = Vector2(label_width, 0)
	key.add_theme_font_size_override("font_size", FONT_SMALL)
	key.add_theme_color_override("font_color", TEXT_DIM)
	row.add_child(key)
	var value := Label.new()
	value.text = value_text
	value.add_theme_font_size_override("font_size", FONT_SMALL)
	row.add_child(value)
	return row
