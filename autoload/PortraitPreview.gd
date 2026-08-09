extends Node
## PORTRAIT DE PNJ (2026-08-09, demande de l'auteur : « portrait du PNJ en haut à
## droite de la fenêtre, plutôt grand »).
##
## ---------------------------------------------------------------------------
## UN SEUL RENDU, TEINTÉ ENSUITE
## ---------------------------------------------------------------------------
## Tous les habitants partagent le même modèle (`humanoide.glb`) : rendre un
## portrait par PNJ produirait des centaines de fois la même image. On rend donc
## LE BUSTE UNE FOIS, et la couleur du personnage est appliquée à l'affichage.
##
## C'est exactement la leçon des vignettes de bloc, payée le 2026-08-07 : la
## FORME ne dépend pas de la couleur, et redessiner une image par teinte coûtait
## 1 735 ms pour 210 lignes d'inventaire. Ici le coût serait pire — un rendu 3D,
## pas un cube en 48×48.
##
## Le rendu est ASYNCHRONE et tenté UNE SEULE FOIS. En headless il échoue
## (RenderingServer factice) : on garde alors le repli, plutôt que de retenter à
## chaque ouverture de dialogue et de payer un readback GPU par frame — la faute
## exacte qui avait détruit le framerate de la carte le 2026-07-26.

const SIZE := 320

var _texture: Texture2D
var _attempted := false


## RENDU AU DÉMARRAGE, et pas à la première ouverture de dialogue. Il est
## ASYNCHRONE (deux frames d'attente pour que le UPDATE_ONCE soit dessiné) :
## déclenché au moment où le joueur parle, il rend `null` et la fenêtre affiche
## son repli — c'est exactement ce qu'on a vu en capture, une silhouette rose à
## la place du portrait. Lancé au démarrage, il est prêt bien avant la première
## conversation.
func _ready() -> void:
	_attempt.call_deferred()


func _attempt() -> void:
	if _attempted:
		return
	_attempted = true
	_render()


## Portrait générique, à teindre par l'appelant (`modulate`). Null tant que le
## rendu n'a pas abouti — l'appelant doit prévoir sa silhouette de repli.
func portrait() -> Texture2D:
	_attempt()
	return _texture


func _render() -> void:
	var body_script := preload("res://scenes/entities/player_body.gd")
	var model: Node3D = body_script.new()
	if not model.setup(false):
		model.queue_free()
		return
	var vp := SubViewport.new()
	vp.size = Vector2i(SIZE, SIZE)
	vp.transparent_bg = true
	vp.own_world_3d = true
	vp.render_target_update_mode = SubViewport.UPDATE_DISABLED
	add_child(vp)
	var cam := Camera3D.new()
	cam.projection = Camera3D.PROJECTION_ORTHOGONAL
	# CADRÉ SUR LE BUSTE, pas sur le corps entier : un portrait montre un
	# visage. À pleine hauteur, la tête ferait quinze pixels de haut dans une
	# vignette qu'on a justement demandée grande.
	cam.size = 1.15
	cam.look_at_from_position(Vector3(0.0, 1.45, 0.0) + Vector3(0.25, 0.12, 1.0).normalized() * 4.0,
		Vector3(0.0, 1.42, 0.0), Vector3.UP)
	cam.current = true
	vp.add_child(cam)
	# ÉCLAIRAGE PROPRE AU PORTRAIT. `own_world_3d` isole ce viewport du monde :
	# il n'hérite donc ni du soleil, ni de l'ambiance — la première capture a
	# rendu une silhouette ENTIÈREMENT NOIRE, parfaitement découpée, ce qui a
	# fait croire un instant à un problème de matériau.
	#
	# Une clé et une ambiance, pas plus : un portrait doit être lisible, pas
	# mis en scène. L'ambiance seule aplatirait le visage, la clé seule
	# laisserait un côté dans le noir.
	var key := DirectionalLight3D.new()
	key.rotation_degrees = Vector3(-25.0, 35.0, 0.0)
	key.light_energy = 1.4
	vp.add_child(key)
	var env := WorldEnvironment.new()
	var environment := Environment.new()
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.ambient_light_color = Color(0.72, 0.76, 0.85)
	environment.ambient_light_energy = 0.9
	# FOND TRANSPARENT conservé : le portrait se découpe sur le cadre de la
	# fenêtre, il n'apporte pas son propre ciel.
	environment.background_mode = Environment.BG_CANVAS
	env.environment = environment
	vp.add_child(env)
	vp.add_child(model)
	vp.render_target_update_mode = SubViewport.UPDATE_ONCE
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	var img := vp.get_texture().get_image()
	if img != null and _has_opaque(img):
		_texture = ImageTexture.create_from_image(img)
	vp.queue_free()


## Une image ENTIÈREMENT TRANSPARENTE veut dire que le rendu n'a rien produit
## (headless, modèle absent). La garder ferait un portrait invisible que rien ne
## signalerait — on préfère rendre null et laisser le repli s'afficher.
func _has_opaque(img: Image) -> bool:
	for y in range(0, img.get_height(), 8):
		for x in range(0, img.get_width(), 8):
			if img.get_pixel(x, y).a > 0.1:
				return true
	return false
