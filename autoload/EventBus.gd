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
