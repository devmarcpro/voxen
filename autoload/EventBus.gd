extends Node
## EventBus — signaux globaux inter-systèmes (E.12).
## Règle : aucun système de gameplay n'appelle directement un autre système ;
## tout couplage passe par les données (tags) ou par ces signaux.

# --- Signaux standards (table E.12) ---

@warning_ignore("unused_signal")
signal block_placed(block_pos: Vector3i, material_id: int)
@warning_ignore("unused_signal")
signal block_destroyed(block_pos: Vector3i, material_id: int)
@warning_ignore("unused_signal")
signal creature_killed(killer, victim)
@warning_ignore("unused_signal")
signal item_crafted(item_id: String, quality: float, crafter)
@warning_ignore("unused_signal")
signal item_sold(item_id: String, price: int, seller, buyer)
@warning_ignore("unused_signal")
signal skill_level_up(skill_id: String, new_level: int, entity)
@warning_ignore("unused_signal")
signal creature_recruited(creature)
@warning_ignore("unused_signal")
signal book_read(book_id: String, success: bool, reader)
@warning_ignore("unused_signal")
signal raid_resolved(report: Dictionary)
@warning_ignore("unused_signal")
signal cell_role_changed(cell: Vector2i, new_role: String)
@warning_ignore("unused_signal")
signal locale_changed(new_locale: String)
@warning_ignore("unused_signal")
signal chunk_explored(chunk: Vector3i)
@warning_ignore("unused_signal")
signal dungeon_cleared(cell: Vector2i)

## TÉLÉGRAPHIE d'attaque (combat directionnel, 2026-07-28) : émis dès que la
## direction d'une frappe est verrouillée, AVANT que la lame parte. C'est
## l'unique canal de perception du combat pour l'IA — un adversaire ne
## « regarde » pas le joueur, il reçoit sa déclaration d'intention et dispose
## du wind-up pour y répondre. Un temps de réaction propre à chaque profil
## empêche l'IA de parer parfaitement à chaque fois.
@warning_ignore("unused_signal")
signal attack_telegraphed(attacker, direction: String)

## Dégâts infligés, AU POINT D'IMPACT (2026-07-28). Le retour visuel de
## combat en dépend : sans lui le joueur ne perçoit pas l'effet de son coup,
## et ne peut donc corriger ni sa distance, ni sa visée, ni son timing.
## `glancing` = coup porté au manche (aucun dégât, erreur de DISTANCE).
@warning_ignore("unused_signal")
signal damage_dealt(world_position: Vector3, amount: int, critical: bool, glancing: bool)

## CONTACT d'arme, pour le retour d'impact (2026-08-02). Distinct de
## `damage_dealt`, et il faut les deux : `damage_dealt` porte un RÉSULTAT
## chiffré (combien, où, critique), celui-ci porte la NATURE du choc (le fer
## est-il entré dans la chair, a-t-il sonné sur une armure, la garde a-t-elle
## tenu, les deux lames se sont-elles entrechoquées).
##
## Les fusionner obligerait le retour d'impact à deviner la nature du contact à
## partir du nombre de dégâts — or une parade, un coup glissant et un
## chambering valent tous les trois zéro, et n'ont rigoureusement rien à faire
## sentir de commun.
##
## `kind` : voir les constantes IMPACT_* d'ImpactFeedback.
## `force` : produit des multiplicateurs offensifs (zone × sweet spot ×
## vitesse) ; 1.0 = coup nominal.
@warning_ignore("unused_signal")
signal combat_impact(kind: String, world_position: Vector3, force: float)

## SORT LANCÉ (2026-08-08) : lieu du départ et module qui part. Un signal, et
## non un appel direct au rendu : le lanceur n'a pas à savoir qu'il existe un
## système d'effets, et le jour où un PNJ lancera des sorts il sera vu sans
## qu'on touche à son code (E.12).
@warning_ignore("unused_signal")
signal spell_cast(world_position: Vector3, module_id: String)

## Mort du joueur (A.10) : lieu, nombre d'objets tombés, or perdu.
signal player_died(position: Vector3, dropped_count: int, lost_gold: int)

# --- Signaux techniques (hors gameplay) ---

## Émis après un rechargement des données (hot-reload F5, D.2) —
## les systèmes qui dérivent des structures des données (palettes, ids
## runtime...) doivent se reconstruire.
@warning_ignore("unused_signal")
signal data_reloaded

## Notification à afficher au joueur (clé de traduction, 10.1) — ex. budget
## de subdivision atteint (G.2 : « message clair au joueur »).
@warning_ignore("unused_signal")
signal ui_notification(message_key: String)
