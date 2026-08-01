extends SceneTree
## Capture le gabarit humanoïde sous trois angles, pour l'INSPECTER.
##   godot --path . --script tools/shot_model.gd      (SANS --headless)
##
## En `--headless` le RenderingServer est un DUMMY : `frame_post_draw` ne se
## déclenche jamais et la capture bloquerait indéfiniment (piège documenté).
## Ce script refuse donc de tourner en headless plutôt que de se figer.

const OUT_DIR := "res://debug/"


func _init() -> void:
	if DisplayServer.get_name() == "headless":
		print("[SHOT] impossible en --headless (RenderingServer factice). Relancer avec fenêtre.")
		quit(1)
		return
	await process_frame

	var world := Node3D.new()
	get_root().add_child(world)

	var light := DirectionalLight3D.new()
	light.rotation_degrees = Vector3(-40.0, -35.0, 0.0)
	world.add_child(light)
	var env := WorldEnvironment.new()
	var environment := Environment.new()
	environment.background_mode = Environment.BG_COLOR
	environment.background_color = Color(0.25, 0.28, 0.32)
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.ambient_light_color = Color(0.7, 0.7, 0.75)
	environment.ambient_light_energy = 1.0
	env.environment = environment
	world.add_child(env)

	var model: PackedScene = load("res://models/creatures/humanoide.glb")
	var instance := model.instantiate()
	world.add_child(instance)
	# Même peau procédurale qu'en jeu : on inspecte ce que le joueur voit,
	# pas un modèle nu.
	var body_script := load("res://scenes/entities/player_body.gd")
	body_script.apply_procedural_skin(instance, body_script.DEFAULT_PALETTE)

	var camera := Camera3D.new()
	world.add_child(camera)
	camera.current = true

	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT_DIR))
	# Trois points de vue : face, profil, et une plongée depuis la position de
	# l'œil du joueur (c'est CETTE vue qui posait problème en jeu).
	var shots := [
		["face", Vector3(0.0, 1.0, 3.2), Vector3(0.0, 1.0, 0.0)],
		["profil", Vector3(3.2, 1.0, 0.0), Vector3(0.0, 1.0, 0.0)],
		["plongee_oeil", Vector3(0.0, 1.9, 0.0), Vector3(0.0, 0.0, -0.6)],
	]
	for shot: Array in shots:
		camera.global_position = shot[1]
		camera.look_at(shot[2], Vector3.UP)
		await process_frame
		await process_frame
		await RenderingServer.frame_post_draw
		var image := get_root().get_texture().get_image()
		var path := ProjectSettings.globalize_path(OUT_DIR) + "modele_%s.png" % shot[0]
		image.save_png(path)
		print("[SHOT] %s" % path)
	quit(0)
