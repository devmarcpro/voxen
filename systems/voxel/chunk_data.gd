class_name ChunkData
extends RefCounted
## Données voxel d'un chunk cubique 16×16×16 (D.2, G.2).
## Stockage : PackedByteArray de 2 octets/bloc (id matériau runtime, 0 = air)
## = 8 Ko par chunk plein. Les chunks 100 % air ou 100 % même matériau sont
## stockés comme constante (`uniform_id`, tableau vide) — la majorité du
## monde (ciel, sous-sol profond) ne coûte presque rien.

const SIZE := 16
const VOLUME := SIZE * SIZE * SIZE

## Vide si le chunk est uniforme (voir uniform_id).
var blocks := PackedByteArray()
## Id matériau unique du chunk quand il est uniforme (0 = air).
var uniform_id: int = 0
## Sous-grilles de subdivision (4.1/G.2) : indice de bloc → PackedInt32Array
## de 512 cellules (SubdivGrid). Pour un bloc subdivisé, `blocks` porte l'id
## DOMINANT (représentation LOD/visée) — la vérité fine est ici.
## Budget : 512 entrées max par chunk (G.2, contrôlé par WorldManager).
var subdivs := {}
## Nombre de cellules PLEINES par sous-grille (indice de bloc → int),
## maintenu à chaque écriture — précalculé pour la règle de collision E.22
## (« solide si >= 50 % du volume ») sans payer un count_solid O(512) par
## coin de joueur et par frame (audit 2026-07-21).
var subdiv_solid := {}
## Roche/terre HÔTE d'un bloc-masque (2026-07-24) : indice de bloc → id
## matériau de l'hôte. Un minerai stocke la ROCHE qui l'entoure, un bloc
## d'herbe stocke la TERRE dessous — le shader rend l'hôte + un masque
## (pépites de minerai / brins d'herbe) par-dessus, pour que le minerai se
## fonde dans sa roche et l'herbe dans sa terre (demande utilisateur). Passé
## au mesher via UV.y. Vide pour la plupart des blocs (coût nul).
var block_host := {}


static func create_uniform(material_id: int) -> ChunkData:
	var c := ChunkData.new()
	c.uniform_id = material_id
	return c


func is_uniform() -> bool:
	return blocks.is_empty()


## Indice linéaire d'un bloc local — ordre x, puis z, puis y.
static func index_of(x: int, y: int, z: int) -> int:
	return x | (z << 4) | (y << 8)


func get_block(x: int, y: int, z: int) -> int:
	if blocks.is_empty():
		return uniform_id
	return blocks.decode_u16(index_of(x, y, z) * 2)


func get_block_by_index(index: int) -> int:
	if blocks.is_empty():
		return uniform_id
	return blocks.decode_u16(index * 2)


func set_block(x: int, y: int, z: int, material_id: int) -> void:
	set_block_by_index(index_of(x, y, z), material_id)


func set_block_by_index(index: int, material_id: int) -> void:
	if blocks.is_empty():
		if material_id == uniform_id and subdivs.is_empty():
			return
		_allocate()
	blocks.encode_u16(index * 2, material_id)
	# Poser/casser un bloc PLEIN efface toute subdivision résiduelle + l'hôte
	# (un bloc posé par le joueur n'a pas d'hôte de génération).
	subdivs.erase(index)
	subdiv_solid.erase(index)
	block_host.erase(index)


## Installe (ou remplace) la sous-grille d'un bloc ; `dominant` alimente
## `blocks` pour la visée et le LOD.
func set_subdiv(index: int, grid: PackedInt32Array, dominant: int) -> void:
	if blocks.is_empty():
		_allocate()
	blocks.encode_u16(index * 2, dominant)
	attach_subdiv(index, grid)


## Attache une sous-grille SANS toucher `blocks` (l'id dominant y est déjà —
## génération procédurale, restauration de diff) ; maintient le compte de
## cellules pleines pour la collision (voir subdiv_solid).
func attach_subdiv(index: int, grid: PackedInt32Array) -> void:
	subdivs[index] = grid
	subdiv_solid[index] = SubdivGrid.count_solid(grid)


## Copie profonde (instantané pour les tâches de meshing — les threads ne
## doivent jamais partager un tableau mutable avec le thread principal).
func duplicate_data() -> ChunkData:
	var c := ChunkData.new()
	c.uniform_id = uniform_id
	c.blocks = blocks.duplicate()
	for index in subdivs:
		c.subdivs[index] = (subdivs[index] as PackedInt32Array).duplicate()
	c.subdiv_solid = subdiv_solid.duplicate()
	c.block_host = block_host.duplicate()
	return c


## Passe du stockage constant au tableau plein (rempli avec uniform_id).
func _allocate() -> void:
	blocks.resize(VOLUME * 2)
	if uniform_id != 0:
		for i in VOLUME:
			blocks.encode_u16(i * 2, uniform_id)
