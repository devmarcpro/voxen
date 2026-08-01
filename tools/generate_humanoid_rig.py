#!/usr/bin/env python3
"""Genere le gabarit humanoide riggé, en DEUX formats.

  models/creatures/humanoide.glb      -> consomme par Godot (Skeleton3D)
  models/creatures/humanoide.bbmodel  -> OUVRABLE DANS BLOCKBENCH pour editer

Les deux sortent des MEMES tables BONES/BODY ci-dessous : une seule source de
verite, aucun risque que le modele editable diverge du modele joue.

POURQUOI LES DEUX. Blockbench n'IMPORTE PAS le glTF (c'est un format d'export
seulement chez eux) — un .glb seul serait un cul-de-sac : impossible de
retoucher les formes sans tout re-rigger. Le .bbmodel est le format de PROJET
natif de Blockbench, donc le seul qui permette de reprendre le travail.


POURQUOI CE SCRIPT PLUTOT QU'UN FICHIER BINAIRE POSE LA. Le rig doit respecter
des contraintes que l'oeil ne verifie pas (chaines de 2 os exactement, un
maillage par os, poids a 1.0, pivots aux articulations, hauteur totale 2.0).
Un .glb est opaque : si une contrainte casse, on ne le voit qu'au moment ou
l'IK disloque un bras. Ici la geometrie EST la specification, relisible et
regenerable — modifier une proportion se fait dans le tableau BODY ci-dessous,
pas a la main dans un binaire.

Sortie : glTF 2.0 binaire (.glb), maillages SKINNES sur un vrai squelette
(Godot en fait un Skeleton3D, condition de l'IK et du demembrement).

Usage :  python tools/generate_humanoid_rig.py
Voir models/creatures/LISEZMOI.md pour la specification complete.
"""

import json
import struct
import uuid
from pathlib import Path

# Espace de noms fixe : les UUID du .bbmodel sont DETERMINISTES d'une
# generation a l'autre. Sans ca, regenerer le fichier changerait toutes les
# references et rendrait le diff illisible.
UUID_NS = uuid.UUID("6f0c1a5e-51d5-4a1e-9f1f-2a3b4c5d6e7f")


def uid(label):
    return str(uuid.uuid5(UUID_NS, label))

# 1 bloc = 32 px = 1.0 unite Godot. Le personnage fait 64 px = 2.0 unites,
# valeur imposee par PLAYER_HEIGHT (scenes/entities/fly_camera.gd).
PX = 32.0

# Palette par defaut, copiee de scenes/entities/player_model.gd pour que le
# placeholder actuel et ce modele se ressemblent.
COLORS = {
    "peau": (0.85, 0.68, 0.52),
    "cheveux": (0.35, 0.22, 0.12),
    "haut": (0.30, 0.45, 0.75),
    "bas": (0.35, 0.28, 0.22),
}

# --- SQUELETTE : (nom, parent, pivot en px) -------------------------------
# Le pivot est A L'ARTICULATION, jamais au centre du cube : un pivot central
# ferait tourner l'avant-bras autour de son milieu au lieu du coude, et l'IK
# disloquerait le bras des la premiere resolution.
BONES = [
    ("racine",              None,             (0.0,  0.0,  0.0)),
    ("bassin",              "racine",         (0.0, 28.0,  0.0)),
    ("colonne_1",           "bassin",         (0.0, 34.0,  0.0)),
    ("colonne_2",           "colonne_1",      (0.0, 41.0,  0.0)),
    ("cou",                 "colonne_2",      (0.0, 50.0,  0.0)),
    ("tete",                "cou",            (0.0, 52.0,  0.0)),
    ("attach_tete",         "tete",           (0.0, 64.0,  0.0)),
    ("attach_dos",          "colonne_2",      (0.0, 45.0,  5.0)),
    # Bras droit (+X). epaule_* est HORS chaine IK : elle porte, elle ne
    # flechit pas — la chaine resolue est bras -> avantbras -> main.
    ("epaule_droite",       "colonne_2",      (9.0,  48.0, 0.0)),
    ("bras_droit",          "epaule_droite",  (11.5, 48.0, 0.0)),
    ("avantbras_droit",     "bras_droit",     (11.5, 37.0, 0.0)),
    ("main_droite",         "avantbras_droit",(11.5, 26.0, 0.0)),
    ("attach_arme",         "main_droite",    (11.5, 23.0, 0.0)),
    # Bras gauche (-X).
    ("epaule_gauche",       "colonne_2",      (-9.0,  48.0, 0.0)),
    ("bras_gauche",         "epaule_gauche",  (-11.5, 48.0, 0.0)),
    ("avantbras_gauche",    "bras_gauche",    (-11.5, 37.0, 0.0)),
    ("main_gauche",         "avantbras_gauche",(-11.5, 26.0, 0.0)),
    ("attach_arme_gauche",  "main_gauche",    (-11.5, 23.0, 0.0)),
    # Jambes.
    ("cuisse_droite",       "bassin",         (4.5, 28.0, 0.0)),
    ("mollet_droite",       "cuisse_droite",  (4.5, 16.0, 0.0)),
    ("pied_droite",         "mollet_droite",  (4.5,  4.0, 0.0)),
    ("cuisse_gauche",       "bassin",         (-4.5, 28.0, 0.0)),
    ("mollet_gauche",       "cuisse_gauche",  (-4.5, 16.0, 0.0)),
    ("pied_gauche",         "mollet_gauche",  (-4.5,  4.0, 0.0)),
]

# --- MAILLAGES : (nom, os porteur, min px, max px, couleur) ---------------
# UN maillage par os, jamais a cheval : c'est ce qui rend le demembrement
# possible (echelle de l'os a zero) et la tete masquable seule en premiere
# personne. Le personnage regarde vers -Z, donc l'avant est en -Z.
BODY = [
    ("mesh_bassin",           "bassin",           (-8.5, 28.0, -4.5), (8.5, 34.0, 4.5), "bas"),
    ("mesh_torse_bas",        "colonne_1",        (-8.5, 34.0, -4.5), (8.5, 42.0, 4.5), "haut"),
    ("mesh_torse_haut",       "colonne_2",        (-9.0, 41.0, -4.5), (9.0, 50.0, 4.5), "haut"),
    ("mesh_cou",              "cou",              (-3.0, 50.0, -3.0), (3.0, 52.0, 3.0), "peau"),
    ("mesh_tete",             "tete",             (-6.0, 52.0, -6.0), (6.0, 64.0, 6.0), "peau"),
    # Porte par le MEME os que la tete, mais objet distinct : il doit se
    # masquer avec elle en premiere personne et se recolorer a part.
    ("mesh_cheveux",          "tete",             (-6.5, 60.0, -6.5), (6.5, 64.0, 6.5), "cheveux"),
    ("mesh_bras_droit",       "bras_droit",       (9.0, 37.0, -3.5), (14.0, 48.0, 3.5), "haut"),
    ("mesh_avantbras_droit",  "avantbras_droit",  (9.0, 26.0, -3.0), (14.0, 37.0, 3.0), "peau"),
    ("mesh_main_droite",      "main_droite",      (9.0, 20.0, -3.0), (14.0, 26.0, 3.0), "peau"),
    ("mesh_bras_gauche",      "bras_gauche",      (-14.0, 37.0, -3.5), (-9.0, 48.0, 3.5), "haut"),
    ("mesh_avantbras_gauche", "avantbras_gauche", (-14.0, 26.0, -3.0), (-9.0, 37.0, 3.0), "peau"),
    ("mesh_main_gauche",      "main_gauche",      (-14.0, 20.0, -3.0), (-9.0, 26.0, 3.0), "peau"),
    ("mesh_cuisse_droite",    "cuisse_droite",    (0.5, 15.0, -4.5), (8.5, 28.0, 4.5), "bas"),
    ("mesh_mollet_droite",    "mollet_droite",    (1.0,  3.0, -4.0), (8.0, 16.0, 4.0), "bas"),
    # Le pied deborde vers l'AVANT (-Z) : profondeur 10 contre 8 au mollet.
    ("mesh_pied_droite",      "pied_droite",      (1.0,  0.0, -6.5), (8.0,  4.0, 3.5), "bas"),
    ("mesh_cuisse_gauche",    "cuisse_gauche",    (-8.5, 15.0, -4.5), (-0.5, 28.0, 4.5), "bas"),
    ("mesh_mollet_gauche",    "mollet_gauche",    (-8.0,  3.0, -4.0), (-1.0, 16.0, 4.0), "bas"),
    ("mesh_pied_gauche",      "pied_gauche",      (-8.0,  0.0, -6.5), (-1.0,  4.0, 3.5), "bas"),
]

# 6 faces : (normale, 4 coins exprimes en (choix_x, choix_y, choix_z) ou 0=min,
# 1=max). Ordre anti-horaire vu de l'exterieur (glTF est en front-face CCW).
FACES = [
    ((0, 0, 1),  [(0, 0, 1), (1, 0, 1), (1, 1, 1), (0, 1, 1)]),
    ((0, 0, -1), [(1, 0, 0), (0, 0, 0), (0, 1, 0), (1, 1, 0)]),
    ((1, 0, 0),  [(1, 0, 1), (1, 0, 0), (1, 1, 0), (1, 1, 1)]),
    ((-1, 0, 0), [(0, 0, 0), (0, 0, 1), (0, 1, 1), (0, 1, 0)]),
    ((0, 1, 0),  [(0, 1, 1), (1, 1, 1), (1, 1, 0), (0, 1, 0)]),
    ((0, -1, 0), [(0, 0, 0), (1, 0, 0), (1, 0, 1), (0, 0, 1)]),
]


def build_cube(lo, hi, color, joint):
    """24 sommets (4 par face, normales franches) + 36 indices."""
    positions, normals, colors, joints, weights, indices = [], [], [], [], [], []
    corner = (lo, hi)
    for normal, quad in FACES:
        base = len(positions)
        for cx, cy, cz in quad:
            positions.append((corner[cx][0] / PX, corner[cy][1] / PX, corner[cz][2] / PX))
            normals.append(normal)
            colors.append((color[0], color[1], color[2], 1.0))
            # Poids 1.0 sur UN SEUL os : aucun sommet partage entre deux os,
            # sinon la coupe s'etirerait au lieu de trancher net.
            joints.append((joint, 0, 0, 0))
            weights.append((1.0, 0.0, 0.0, 0.0))
        indices += [base, base + 1, base + 2, base, base + 2, base + 3]
    return positions, normals, colors, joints, weights, indices


class Buffer:
    """Accumule le blob binaire et declare les bufferViews/accessors."""

    def __init__(self):
        self.data = bytearray()
        self.views = []
        self.accessors = []

    def _align(self):
        while len(self.data) % 4:
            self.data.append(0)

    def add(self, raw, fmt, count, kind, comp_type, target, minmax=None):
        self._align()
        offset = len(self.data)
        self.data += raw
        self.views.append({
            "buffer": 0, "byteOffset": offset, "byteLength": len(raw),
            **({"target": target} if target else {}),
        })
        accessor = {
            "bufferView": len(self.views) - 1, "componentType": comp_type,
            "count": count, "type": kind,
        }
        if minmax:
            accessor["min"], accessor["max"] = minmax
        self.accessors.append(accessor)
        return len(self.accessors) - 1


FLOAT, USHORT = 5126, 5123
ARRAY_BUFFER, ELEMENT_ARRAY_BUFFER = 34962, 34963


# Teinte d'onglet Blockbench par region du corps (0-7) — confort d'edition
# uniquement, sans effet sur le rendu en jeu.
BBCOLOR = {"peau": 4, "cheveux": 2, "haut": 0, "bas": 6}


def write_bbmodel(path):
    """Projet Blockbench natif. Les GROUPES de l'outliner sont les os, et leur
    `origin` est le pivot — c'est exactement la meme information que les noeuds
    du glTF, exprimee dans le format que Blockbench sait rouvrir."""
    color_of = {name: BBCOLOR[key] for name, _, _, _, key in BODY}
    bone_of = {name: bone for name, bone, _, _, _ in BODY}

    elements = []
    for name, _, lo, hi, _ in BODY:
        # Blockbench travaille en unites de modele (nos pixels), pas en blocs.
        elements.append({
            "name": name,
            "box_uv": False, "rescale": False, "locked": False,
            "from": list(lo), "to": list(hi),
            "autouv": 0, "color": color_of[name],
            # Pivot du cube = pivot de SON os : une rotation manuelle dans
            # Blockbench se comporte alors comme la rotation en jeu.
            "origin": list(next(p for n, _, p in BONES if n == bone_of[name])),
            "faces": {face: {"uv": [0, 0, 16, 16], "texture": None} for face in
                      ("north", "east", "south", "west", "up", "down")},
            "uuid": uid("element:" + name),
        })

    # Outliner : un groupe par os, imbrique comme le squelette, contenant les
    # cubes qu'il porte.
    children_of = {name: [] for name, _, _ in BONES}
    for name, parent, _ in BONES:
        if parent is not None:
            children_of[parent].append(name)

    def build_group(bone_name):
        pivot = next(p for n, _, p in BONES if n == bone_name)
        kids = []
        # Les cubes portes par cet os d'abord, puis les os enfants.
        for mesh_name, bone, _, _, _ in BODY:
            if bone == bone_name:
                kids.append(uid("element:" + mesh_name))
        for child in children_of[bone_name]:
            kids.append(build_group(child))
        return {
            "name": bone_name, "origin": list(pivot), "color": 0,
            "uuid": uid("group:" + bone_name),
            "export": True, "mirror_uv": False, "isOpen": True,
            "visibility": True, "autouv": 0, "children": kids,
        }

    model = {
        "meta": {
            "format_version": "4.5",
            # « free » = Generic Model : le SEUL format Blockbench qui exporte
            # un squelette. Java Block/Item n'en exporte aucun.
            "model_format": "free",
            "box_uv": False,
        },
        "name": "humanoide",
        "model_identifier": "humanoide",
        "resolution": {"width": 64, "height": 64},
        "elements": elements,
        "outliner": [build_group("racine")],
        "textures": [],
    }
    path.write_text(json.dumps(model, indent=2), encoding="utf-8")
    return len(elements)


def main():
    root = Path(__file__).resolve().parent.parent
    out_path = root / "models" / "creatures" / "humanoide.glb"
    bb_path = root / "models" / "creatures" / "humanoide.bbmodel"

    bone_index = {name: i for i, (name, _, _) in enumerate(BONES)}
    buf = Buffer()

    # --- Noeuds d'os. Translation LOCALE = pivot - pivot du parent.
    nodes = []
    for name, parent, pivot in BONES:
        if parent is None:
            local = pivot
        else:
            p = next(p for n, _, p in BONES if n == parent)
            local = (pivot[0] - p[0], pivot[1] - p[1], pivot[2] - p[2])
        nodes.append({
            "name": name,
            "translation": [local[0] / PX, local[1] / PX, local[2] / PX],
            "children": [],
        })
    for name, parent, _ in BONES:
        if parent is not None:
            nodes[bone_index[parent]]["children"].append(bone_index[name])

    # --- Matrices de liaison inverse : les sommets sont ecrits en espace de
    # repos, donc l'IBM est simplement la translation inverse du pivot.
    ibm = bytearray()
    for _, _, pivot in BONES:
        m = [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0,
             -pivot[0] / PX, -pivot[1] / PX, -pivot[2] / PX, 1]
        ibm += struct.pack("<16f", *m)
    ibm_accessor = buf.add(bytes(ibm), None, len(BONES), "MAT4", FLOAT, None)

    # --- Maillages, un par partie du corps.
    meshes, mesh_nodes = [], []
    for name, bone, lo, hi, color_key in BODY:
        pos, nrm, col, jnt, wgt, idx = build_cube(lo, hi, COLORS[color_key], bone_index[bone])
        p_acc = buf.add(b"".join(struct.pack("<3f", *v) for v in pos), None, len(pos), "VEC3",
                        FLOAT, ARRAY_BUFFER,
                        minmax=([min(v[i] for v in pos) for i in range(3)],
                                [max(v[i] for v in pos) for i in range(3)]))
        n_acc = buf.add(b"".join(struct.pack("<3f", *map(float, v)) for v in nrm), None, len(nrm),
                        "VEC3", FLOAT, ARRAY_BUFFER)
        c_acc = buf.add(b"".join(struct.pack("<4f", *v) for v in col), None, len(col), "VEC4",
                        FLOAT, ARRAY_BUFFER)
        j_acc = buf.add(b"".join(struct.pack("<4H", *v) for v in jnt), None, len(jnt), "VEC4",
                        USHORT, ARRAY_BUFFER)
        w_acc = buf.add(b"".join(struct.pack("<4f", *v) for v in wgt), None, len(wgt), "VEC4",
                        FLOAT, ARRAY_BUFFER)
        i_acc = buf.add(b"".join(struct.pack("<H", v) for v in idx), None, len(idx), "SCALAR",
                        USHORT, ELEMENT_ARRAY_BUFFER)
        meshes.append({
            "name": name,
            "primitives": [{
                "attributes": {"POSITION": p_acc, "NORMAL": n_acc, "COLOR_0": c_acc,
                               "JOINTS_0": j_acc, "WEIGHTS_0": w_acc},
                "indices": i_acc, "material": 0,
            }],
        })
        # Un noeud skinne ne doit PAS etre enfant d'un joint et sa transforme
        # est ignoree (glTF 2.0, section skins) : racine de scene, identite.
        nodes.append({"name": name, "mesh": len(meshes) - 1, "skin": 0})
        mesh_nodes.append(len(nodes) - 1)

    gltf = {
        "asset": {"version": "2.0", "generator": "Voxen generate_humanoid_rig.py"},
        "scene": 0,
        "scenes": [{"name": "humanoide", "nodes": [0] + mesh_nodes}],
        "nodes": nodes,
        "meshes": meshes,
        "skins": [{
            "name": "squelette",
            "inverseBindMatrices": ibm_accessor,
            "skeleton": 0,
            "joints": list(range(len(BONES))),
        }],
        # Couleur par sommet (COLOR_0 multiplie la couleur de base en glTF) :
        # pas de texture a fournir pour un placeholder, et la palette reste
        # echangeable en shader comme le prevoit 12.4.
        "materials": [{
            "name": "humanoide",
            "pbrMetallicRoughness": {
                "baseColorFactor": [1.0, 1.0, 1.0, 1.0],
                "metallicFactor": 0.0, "roughnessFactor": 1.0,
            },
        }],
        "accessors": buf.accessors,
        "bufferViews": buf.views,
        "buffers": [{"byteLength": len(buf.data)}],
    }

    # --- Conteneur GLB : entete + chunk JSON + chunk BIN, chacun aligne sur 4.
    json_chunk = json.dumps(gltf, separators=(",", ":")).encode("utf-8")
    json_chunk += b" " * ((4 - len(json_chunk) % 4) % 4)
    bin_chunk = bytes(buf.data)
    bin_chunk += b"\x00" * ((4 - len(bin_chunk) % 4) % 4)

    total = 12 + 8 + len(json_chunk) + 8 + len(bin_chunk)
    glb = struct.pack("<III", 0x46546C67, 2, total)
    glb += struct.pack("<II", len(json_chunk), 0x4E4F534A) + json_chunk
    glb += struct.pack("<II", len(bin_chunk), 0x004E4942) + bin_chunk

    out_path.parent.mkdir(parents=True, exist_ok=True)
    out_path.write_bytes(glb)
    cubes = write_bbmodel(bb_path)
    print("Ecrit %s (%d octets)" % (out_path, len(glb)))
    print("Ecrit %s (%d cubes, editable dans Blockbench)" % (bb_path, cubes))
    print("  %d os, %d maillages, hauteur %.2f unite(s) en jeu" % (
        len(BONES), len(BODY), max(hi[1] for _, _, _, hi, _ in BODY) / PX))


if __name__ == "__main__":
    main()
