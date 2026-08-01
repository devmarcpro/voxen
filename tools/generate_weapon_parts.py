#!/usr/bin/env python3
"""Genere les pieces d'arme (MANCHES et TETES) en .glb + .bbmodel.

  models/weapons/manche_<id>.glb / .bbmodel
  models/weapons/tete_<id>.glb   / .bbmodel

MEME METHODE QUE LE GABARIT HUMANOIDE, pour les memes raisons : la geometrie
est une TABLE LISIBLE en tete de ce fichier, pas un binaire opaque. Ajuster une
proportion se fait ici et se regenere ; et le .bbmodel permet de reprendre la
piece dans Blockbench sans repartir de zero.

CONVENTION D'ASSEMBLAGE
  - Une arme pointe vers +Y : la PRISE est a y = 0, la pointe vers le haut.
  - Un manche occupe y = 0 -> `longueur`. La tete se greffe a son sommet.
  - Une tete est modelisee A PARTIR DE y = 0 : c'est l'assemblage qui la
    remonte de la longueur du manche. Elle peut deborder lateralement (hache)
    ou vers le bas (contre-poids, crochet).
  - Rien n'est colore ici : la teinte vient des MATERIAUX CHOISIS AU CRAFT et
    est appliquee a l'execution (material_override). Une piece qui embarquerait
    sa couleur casserait tout le systeme de materiaux.

Usage :  python tools/generate_weapon_parts.py
"""

import json
import struct
import uuid
from pathlib import Path

PX = 32.0  # 1 bloc = 32 px = 1.0 unite Godot (meme echelle que le corps)

UUID_NS = uuid.UUID("2c8e5b17-9a44-4f0e-b3d2-77c1e6a90f45")


def uid(label):
    return str(uuid.uuid5(UUID_NS, label))


# --- MANCHES : (id, longueur px, epaisseur px, commentaire) ---------------
# `grip_main` / `grip_offhand` (fractions de la longueur) vivent dans
# data/weapon_parts.json : ce sont des donnees de GAMEPLAY, pas de geometrie.
HANDLES = {
    # id            longueur  epaisseur
    "court":        (12, 3),   # dague, hachette, gourdin
    "moyen":        (22, 3),   # epee, masse, coutelas
    "long":         (34, 4),   # epee longue, hache d'armes, marteau
    # 70 px et non 58 : a 58, un espadon (manche long + lame longue) portait
    # PLUS LOIN qu'une pique, ce qui vide l'arme d'hast de sa raison d'etre.
    "tres_long":    (70, 4),   # lance, hallebarde, pique
    "baton":        (46, 4),   # baton, arme d'hast legere
    "arc":          (30, 3),   # corps d'arc (les branches sont dans la tete)
    "arbalete":     (18, 5),   # fut epais
    # BOUCLIERS. Une poignee, pas un manche : le bouclier se tient par le
    # CENTRE de sa plaque, pas par le bas. La poignee est donc minuscule et la
    # plaque, greffee a son sommet, deborde largement sous ce point — c'est
    # exactement pour ce cas que les tetes ont le droit de descendre sous y=0.
    "poignee":      (4, 4),    # ecu, rondache, pavois
}

# --- TETES : (id, [boites], commentaire) ---------------------------------
# Une boite = (x0, y0, z0, x1, y1, z1) en px, y = 0 au sommet du manche.
HEADS = {
    # Lames : plates, dans le plan XY, epaisseur faible en Z.
    "lame_courte":   [(-2, 0, -1, 2, 12, 1), (-3, 0, -1.5, 3, 2, 1.5)],
    "lame_moyenne":  [(-2.5, 0, -1, 2.5, 24, 1), (-4, 0, -1.5, 4, 2, 1.5)],
    "lame_longue":   [(-3, 0, -1.5, 3, 38, 1.5), (-5, 0, -2, 5, 2.5, 2)],
    "rapiere":       [(-1, 0, -1, 1, 30, 1), (-3.5, 0, -3.5, 3.5, 2, 3.5)],
    # Plaques de bouclier : larges, plates, CENTREES sur le point de greffe.
    # La face avant est en +Z, l'avant-bras passe derriere en -Z.
    "rondache":      [(-7, -7, 0, 7, 7, 1.5), (-2, -2, 1.5, 2, 2, 3)],
    "ecu":           [(-9, -13, 0, 9, 11, 1.5), (-9, -17, 0, 9, -13, 1.5),
                      (-2, -2, 1.5, 2, 2, 2.5)],
    "pavois":        [(-11, -15, 0, 11, 17, 2), (-3, -3, 2, 3, 3, 3)],
    # Pointes : perforantes, fines et symetriques.
    "pointe":        [(-1.5, 0, -1.5, 1.5, 10, 1.5), (-2.5, 0, -2.5, 2.5, 3, 2.5)],
    "trident":       [(-5, 2, -1, -3, 12, 1), (-1, 2, -1, 1, 14, 1),
                      (3, 2, -1, 5, 12, 1), (-5, 0, -1.5, 5, 2, 1.5)],
    # Haches : masse deportee d'un cote — c'est ce qui cree l'inertie.
    "hache":         [(1, 0, -1.5, 10, 10, 1.5), (-1.5, -1, -1.5, 1.5, 11, 1.5)],
    "hache_double":  [(1, 0, -1.5, 9, 10, 1.5), (-9, 0, -1.5, -1, 10, 1.5),
                      (-1.5, -1, -1.5, 1.5, 11, 1.5)],
    "hallebarde":    [(1, 4, -1.5, 9, 12, 1.5), (-1.5, 0, -1.5, 1.5, 20, 1.5),
                      (-6, 6, -1, -1.5, 9, 1)],
    "faux":          [(-1.5, 0, -1.5, 1.5, 4, 1.5), (-16, 2, -1, -1.5, 5, 1),
                      (-16, 5, -1, -9, 8, 1)],
    # Contondantes : bloc compact, tout le poids au bout.
    "masse":         [(-3.5, 0, -3.5, 3.5, 9, 3.5)],
    "masse_ailettes": [(-2.5, 0, -2.5, 2.5, 9, 2.5), (-5, 2, -1, 5, 7, 1),
                       (-1, 2, -5, 1, 7, 5)],
    "marteau":       [(-4, 0, -4, 4, 11, 4), (-6, 3, -2, 6, 8, 2)],
    "gourdin":       [(-3, 0, -3, 3, 10, 3), (-2, -4, -2, 2, 0, 2)],
    # Perforantes lourdes.
    "bec":           [(1, 2, -1.5, 11, 8, 1.5), (-4, 0, -2, 4, 4, 2)],
    # Tir.
    "branches_arc":  [(-1, 0, -1, 1, 16, 1), (-1, -32, -1, 1, -16, 1),
                      (-1, 14, -1, 1, 18, 1), (-1, -34, -1, 1, -30, 1)],
    "arc_arbalete":  [(-16, 0, -1, 16, 3, 1), (-2, -2, -2, 2, 8, 2)],
    # Magiques.
    "cristal":       [(-3, 2, -3, 3, 10, 3), (-1.5, 0, -1.5, 1.5, 3, 1.5)],
    "orbe":          [(-4, 1, -4, 4, 9, 4)],
}

FACES = [
    ((0, 0, 1),  [(0, 0, 1), (1, 0, 1), (1, 1, 1), (0, 1, 1)]),
    ((0, 0, -1), [(1, 0, 0), (0, 0, 0), (0, 1, 0), (1, 1, 0)]),
    ((1, 0, 0),  [(1, 0, 1), (1, 0, 0), (1, 1, 0), (1, 1, 1)]),
    ((-1, 0, 0), [(0, 0, 0), (0, 0, 1), (0, 1, 1), (0, 1, 0)]),
    ((0, 1, 0),  [(0, 1, 1), (1, 1, 1), (1, 1, 0), (0, 1, 0)]),
    ((0, -1, 0), [(0, 0, 0), (1, 0, 0), (1, 0, 1), (0, 0, 1)]),
]


class Buffer:
    def __init__(self):
        self.data = bytearray()
        self.views = []
        self.accessors = []

    def add(self, raw, count, kind, comp_type, target, minmax=None):
        while len(self.data) % 4:
            self.data.append(0)
        offset = len(self.data)
        self.data += raw
        self.views.append({"buffer": 0, "byteOffset": offset, "byteLength": len(raw),
                           **({"target": target} if target else {})})
        accessor = {"bufferView": len(self.views) - 1, "componentType": comp_type,
                    "count": count, "type": kind}
        if minmax:
            accessor["min"], accessor["max"] = minmax
        self.accessors.append(accessor)
        return len(self.accessors) - 1


FLOAT, USHORT = 5126, 5123
ARRAY_BUFFER, ELEMENT_ARRAY_BUFFER = 34962, 34963


def build_boxes(boxes):
    """Un seul maillage pour toutes les boites d'une piece : une piece = un
    seul draw call, ce qui compte quand chaque creature en porte une."""
    positions, normals, indices = [], [], []
    for (x0, y0, z0, x1, y1, z1) in boxes:
        lo = (min(x0, x1), min(y0, y1), min(z0, z1))
        hi = (max(x0, x1), max(y0, y1), max(z0, z1))
        corner = (lo, hi)
        for normal, quad in FACES:
            base = len(positions)
            for cx, cy, cz in quad:
                positions.append((corner[cx][0] / PX, corner[cy][1] / PX, corner[cz][2] / PX))
                normals.append(normal)
            indices += [base, base + 1, base + 2, base, base + 2, base + 3]
    return positions, normals, indices


def write_glb(path, boxes):
    positions, normals, indices = build_boxes(boxes)
    buf = Buffer()
    p_acc = buf.add(b"".join(struct.pack("<3f", *v) for v in positions), len(positions),
                    "VEC3", FLOAT, ARRAY_BUFFER,
                    minmax=([min(v[i] for v in positions) for i in range(3)],
                            [max(v[i] for v in positions) for i in range(3)]))
    n_acc = buf.add(b"".join(struct.pack("<3f", *map(float, v)) for v in normals),
                    len(normals), "VEC3", FLOAT, ARRAY_BUFFER)
    i_acc = buf.add(b"".join(struct.pack("<H", v) for v in indices), len(indices),
                    "SCALAR", USHORT, ELEMENT_ARRAY_BUFFER)
    gltf = {
        "asset": {"version": "2.0", "generator": "Voxen generate_weapon_parts.py"},
        "scene": 0,
        "scenes": [{"nodes": [0]}],
        "nodes": [{"name": path.stem, "mesh": 0}],
        "meshes": [{"name": path.stem, "primitives": [{
            "attributes": {"POSITION": p_acc, "NORMAL": n_acc}, "indices": i_acc}]}],
        "accessors": buf.accessors,
        "bufferViews": buf.views,
        "buffers": [{"byteLength": len(buf.data)}],
    }
    json_chunk = json.dumps(gltf, separators=(",", ":")).encode("utf-8")
    json_chunk += b" " * ((4 - len(json_chunk) % 4) % 4)
    bin_chunk = bytes(buf.data)
    bin_chunk += b"\x00" * ((4 - len(bin_chunk) % 4) % 4)
    total = 12 + 8 + len(json_chunk) + 8 + len(bin_chunk)
    glb = struct.pack("<III", 0x46546C67, 2, total)
    glb += struct.pack("<II", len(json_chunk), 0x4E4F534A) + json_chunk
    glb += struct.pack("<II", len(bin_chunk), 0x004E4942) + bin_chunk
    path.write_bytes(glb)


def write_bbmodel(path, name, boxes):
    elements = []
    for i, (x0, y0, z0, x1, y1, z1) in enumerate(boxes):
        elements.append({
            "name": "%s_%d" % (name, i), "box_uv": False, "rescale": False,
            "from": [min(x0, x1), min(y0, y1), min(z0, z1)],
            "to": [max(x0, x1), max(y0, y1), max(z0, z1)],
            "autouv": 0, "color": 0, "origin": [0, 0, 0],
            "faces": {f: {"uv": [0, 0, 16, 16], "texture": None} for f in
                      ("north", "east", "south", "west", "up", "down")},
            "uuid": uid("%s:%d" % (name, i)),
        })
    model = {
        "meta": {"format_version": "4.5", "model_format": "free", "box_uv": False},
        "name": name, "model_identifier": name,
        "resolution": {"width": 64, "height": 64},
        "elements": elements,
        "outliner": [{"name": name, "origin": [0, 0, 0], "color": 0,
                      "uuid": uid("group:" + name), "export": True, "isOpen": True,
                      "children": [e["uuid"] for e in elements]}],
        "textures": [],
    }
    path.write_text(json.dumps(model, indent=2), encoding="utf-8")


def main():
    out = Path(__file__).resolve().parent.parent / "models" / "weapons"
    out.mkdir(parents=True, exist_ok=True)
    count = 0
    for handle_id, (length, thickness) in HANDLES.items():
        half = thickness / 2.0
        boxes = [(-half, 0, -half, half, length, half)]
        name = "manche_" + handle_id
        write_glb(out / (name + ".glb"), boxes)
        write_bbmodel(out / (name + ".bbmodel"), name, boxes)
        count += 1
    for head_id, boxes in HEADS.items():
        name = "tete_" + head_id
        write_glb(out / (name + ".glb"), boxes)
        write_bbmodel(out / (name + ".bbmodel"), name, boxes)
        count += 1
    print("%d pieces ecrites dans %s" % (count, out))
    print("  %d manche(s), %d tete(s)" % (len(HANDLES), len(HEADS)))
    _sync_data(out.parent.parent / "data" / "weapon_parts.json")


def _sync_data(path):
    """Reecrit les LONGUEURS dans data/weapon_parts.json depuis la geometrie.

    Sans ca, la longueur d'un manche existerait a DEUX endroits — ici et dans
    les donnees — et les deux divergeraient au premier ajustement. La geometrie
    fait foi : `longueur` d'un manche = sa hauteur, `portee_tete` d'une tete =
    sa hauteur maximale. Les points de PRISE, eux, restent dans le JSON : ce
    sont des choix de gameplay, pas des mesures.
    """
    if not path.exists():
        print("  (data/weapon_parts.json absent : longueurs non synchronisees)")
        return
    data = json.loads(path.read_text(encoding="utf-8"))
    created = 0
    for handle_id, (length, _thickness) in HANDLES.items():
        # CREE l'entree si elle manque. Avant, une piece nouvellement ajoutee ici
        # produisait bien ses .glb/.bbmodel mais restait ABSENTE des donnees : le
        # jeu ne la voyait pas, et le generateur annoncait pourtant un succes.
        entry = data.setdefault("manches", {}).setdefault(handle_id, {})
        if not entry:
            created += 1
            # Prise au MILIEU par defaut : reglage le moins surprenant, et choix
            # de gameplay que l'auteur ajustera ensuite dans le JSON.
            entry.update({"grip_main": 0.5, "grip_offhand": None})
        entry["model"] = "res://models/weapons/manche_%s.glb" % handle_id
        entry["longueur"] = round(length / PX, 4)
    for head_id, boxes in HEADS.items():
        entry = data.setdefault("tetes", {}).setdefault(head_id, {})
        if not entry:
            created += 1
        entry["model"] = "res://models/weapons/tete_%s.glb" % head_id
        top = max(max(b[1], b[4]) for b in boxes)
        entry["portee_tete"] = round(max(top, 0.0) / PX, 4)
    path.write_text(json.dumps(data, indent=2, ensure_ascii=False) + chr(10), encoding="utf-8")
    print("  donnees synchronisees dans %s (%d entree(s) creee(s))" % (path.name, created))


if __name__ == "__main__":
    main()
