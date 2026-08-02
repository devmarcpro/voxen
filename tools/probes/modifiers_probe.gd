extends Probe
## Sonde `--probe-modificateurs` — le résolveur d'E.4.
##
## Ce que cette sonde défend, dans l'ordre d'importance :
##
## 1. **La non-régression.** `Player.effective_stat` testait la faim et la
##    fatigue en dur ; il délègue désormais à `StatModifiers`. Le résultat doit
##    être identique à l'ancien calcul dans les quatre combinaisons
##    faim/fatigue — un refactor de formule qui décale une stat de 1 point
##    déplacerait tout l'équilibrage du combat sans rien afficher.
##
## 2. **Le retrait.** C'est la raison d'être d'E.4 et ce qu'aucun code en dur ne
##    sait faire : une source posée doit pouvoir disparaître proprement. Si
##    manger annulait mal le malus de faim, le joueur traînerait un -10 %
##    invisible pour le reste de la partie.
##
## 3. **L'absence de fuite.** Un tick repose les mêmes sources en boucle. Si
##    `set_modifier` empilait au lieu d'écraser, le malus de famine se
##    composerait 10 fois par seconde et la stat tomberait à zéro en quelques
##    secondes. Le compteur de sources doit rester borné.

const TAG := "MODIFICATEURS"

var _ok := true


func _check(label: String, condition: bool, detail: String = "") -> void:
	if not condition:
		_ok = false
	print("[%s] %s%s : %s" % [TAG, label, "" if detail == "" else " (" + detail + ")",
		"OK" if condition else "ÉCHEC"])


func run() -> void:
	await main.get_tree().process_frame
	_check_algebra()
	_check_removal()
	_check_idempotence()
	_check_no_regression()
	_check_no_leak_on_player()
	finish(_ok, TAG)


## (base + Σ add) × Π mult, à la lettre.
func _check_algebra() -> void:
	var m := StatModifiers.new()
	_check("sans source, la base passe telle quelle",
		is_equal_approx(m.apply(10.0, "force"), 10.0))

	m.set_modifier("force", "anneau", 3.0)
	_check("un additif s'ajoute", is_equal_approx(m.apply(10.0, "force"), 13.0),
		"%.1f" % m.apply(10.0, "force"))

	m.set_modifier("force", "poison", 0.0, 0.5)
	# (10 + 3) * 0.5 = 6.5 — l'additif AVANT le multiplicatif, comme E.4.
	_check("le multiplicatif s'applique APRÈS la somme des additifs",
		is_equal_approx(m.apply(10.0, "force"), 6.5),
		"%.2f" % m.apply(10.0, "force"))

	m.set_modifier("force", "benediction", 0.0, 2.0)
	_check("les multiplicatifs se composent",
		is_equal_approx(m.apply(10.0, "force"), 13.0),
		"%.2f" % m.apply(10.0, "force"))
	_check("une autre stat reste intacte",
		is_equal_approx(m.apply(10.0, "dexterite"), 10.0))


func _check_removal() -> void:
	var m := StatModifiers.new()
	m.set_modifier("force", "anneau", 5.0)
	m.set_modifier("dexterite", "anneau", 2.0)
	m.set_modifier("force", "poison", 0.0, 0.5)

	m.clear_source("force", "poison")
	_check("retirer une source restaure la valeur",
		is_equal_approx(m.apply(10.0, "force"), 15.0),
		"%.1f" % m.apply(10.0, "force"))

	m.clear_source_everywhere("anneau")
	_check("clear_source_everywhere nettoie toutes les stats",
		is_equal_approx(m.apply(10.0, "force"), 10.0)
			and is_equal_approx(m.apply(10.0, "dexterite"), 10.0))
	_check("plus aucune source active", m.source_count() == 0,
		"%d" % m.source_count())

	# Retirer ce qui n'existe pas ne doit pas casser : les appelants remettent
	# un état sans savoir ce qui était posé.
	m.clear_source("force", "inexistante")
	m.clear_source_everywhere("jamais_posee")
	_check("retirer une source absente est sans effet", m.source_count() == 0)

	# Poser les neutres équivaut à retirer — sinon les sources mortes
	# s'accumulent et coûtent une itération pour rien.
	m.set_modifier("force", "neutre", 0.0, 1.0)
	_check("une source neutre n'est pas conservée", m.source_count() == 0,
		"%d" % m.source_count())


func _check_idempotence() -> void:
	var m := StatModifiers.new()
	for i in 100:
		m.set_modifier("force", "faim", 0.0, 0.9)
	_check("reposer la même source 100 fois ne l'empile pas",
		m.source_count() == 1, "%d source(s)" % m.source_count())
	_check("et la valeur reste celle d'une seule application",
		is_equal_approx(m.apply(10.0, "force"), 9.0),
		"%.2f" % m.apply(10.0, "force"))


## LE POINT CENTRAL : l'ancien calcul en dur et le nouveau doivent coïncider.
func _check_no_regression() -> void:
	var cases := [
		{"hunger": 100.0, "fatigue": 100.0, "label": "rassasié et reposé"},
		{"hunger": 10.0,  "fatigue": 100.0, "label": "affamé seulement"},
		{"hunger": 100.0, "fatigue": 10.0,  "label": "épuisé seulement"},
		{"hunger": 10.0,  "fatigue": 10.0,  "label": "affamé ET épuisé"},
	]
	var hunger_before: float = player.hunger
	var fatigue_before: float = player.fatigue

	for case: Dictionary in cases:
		player.hunger = float(case["hunger"])
		player.fatigue = float(case["fatigue"])
		player.call("_refresh_state_modifiers")
		for stat_id: String in player.stats:
			var base := float(player.stats[stat_id])
			# L'ANCIENNE formule, réécrite ici telle qu'elle était.
			var expected := base
			if player.hunger < player.HUNGER_STARVING:
				expected *= player.HUNGER_STAT_MALUS
			if player.fatigue < player.FATIGUE_EXHAUSTED:
				expected *= player.FATIGUE_STAT_MALUS
			var got: int = player.effective_stat(stat_id)
			if got != int(floor(expected)):
				_check("%s / %s" % [case["label"], stat_id], false,
					"attendu %d, obtenu %d" % [int(floor(expected)), got])
				return
		_check("identique à l'ancien calcul : %s" % case["label"], true)

	player.hunger = hunger_before
	player.fatigue = fatigue_before
	player.call("_refresh_state_modifiers")


## Le joueur repose ses sources d'état à chaque tick de faim. Leur nombre doit
## rester borné par (nombre de stats × 2), quoi qu'il arrive.
func _check_no_leak_on_player() -> void:
	var modifiers: StatModifiers = player.modifiers
	player.hunger = 10.0
	player.fatigue = 10.0
	for i in 200:
		player.call("_refresh_state_modifiers")
	var ceiling: int = player.stats.size() * 2
	_check("aucune fuite de source au fil des ticks",
		modifiers.source_count() <= ceiling,
		"%d source(s) pour un plafond de %d" % [modifiers.source_count(), ceiling])

	# Et l'inverse : redevenir rassasié doit VRAIMENT retirer les malus.
	player.hunger = 100.0
	player.fatigue = 100.0
	player.call("_refresh_state_modifiers")
	var restored := true
	for stat_id: String in player.stats:
		if player.effective_stat(stat_id) != int(player.stats[stat_id]):
			restored = false
			break
	_check("manger et se reposer retire réellement les malus", restored)
	_check("plus aucune source d'état active", modifiers.source_count() == 0,
		"%d" % modifiers.source_count())
