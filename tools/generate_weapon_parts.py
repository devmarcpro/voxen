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


# --- MANCHES : (id, longueur px, epaisseur px, [pommeau px]) --------------
# `grip_main` / `grip_offhand` (fractions de la longueur) vivent dans
# data/weapon_parts.json : ce sont des donnees de GAMEPLAY, pas de geometrie.
#
# DEUX FAMILLES, ET LA DISTINCTION EST LE POINT (2026-08-02). Le catalogue
# confondait POIGNEE et FUT : `moyen` faisait 22 px, ce qui est une hampe de
# masse mais trois fois la poignee d'une epee. Consequence, l'epee se tenait au
# tiers d'un manche de 69 cm, avec 48 cm de « manche » entre le poing et la
# lame — une arme que personne n'a jamais forgee. Et comme la prise decide de
# l'allonge, la geometrie fausse contaminait le gameplay.
#
#   POIGNEES (poignee_*) : la main les couvre presque entierement, un pommeau
#     les termine. Ce sont celles des armes BLANCHES, ou la lame commence juste
#     au-dessus du poing.
#   FUTS (court/moyen/long/tres_long/baton) : on les tient BAS, et la longueur
#     restante est ce qui donne l'allonge et l'inertie. Ce sont celles des armes
#     a percussion et d'hast.
#
# Il n'y a plus besoin de corriger la prise au niveau de la tete : le manche
# porte enfin l'information, parce qu'il y a enfin deux sortes de manches.
HANDLES = {
    # id                longueur  epaisseur  pommeau
    "poignee_dague":    (4, 3, 5),    # dague : la main la couvre entierement
    "poignee_epee":     (6, 3, 5),    # epee, rapiere, epee courte
    "poignee_longue":   (13, 3, 6),   # espadon : deux mains, gauche au pommeau
    "court":            (8, 3),    # hachette, gourdin : une hache a main fait 50 cm
    "moyen":            (13, 3),   # masse, pioche : une masse a une main fait 70 cm
    "long":             (34, 4),   # hache d'armes, marteau a deux mains (1,40 m)
    # HAMPE ET PIQUE SONT DEUX PIECES (2026-08-02). Elles n'en faisaient qu'une,
    # de 2,19 m, ce qui donnait une hallebarde de 2,81 m — une hallebarde fait
    # 1,80 a 2,20 m, c'est une lance qui fait 2,50. Le fut unique avait ete
    # pousse a cette longueur pour qu'un espadon ne porte pas plus loin qu'une
    # pique ; l'espadon etant repasse de 2,02 a 1,59 m avec sa vraie poignee, la
    # contrainte s'est desserree d'elle-meme et la hampe peut redescendre.
    "hampe":            (48, 4),   # hallebarde, trident, faux (1,50 m)
    "hampe_longue":     (64, 4),   # lance, pique (2,00 m)
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
    "lame_dague":    [(-1.5, 0, -0.8, 1.5, 8, 0.8), (-2.5, 0, -1.2, 2.5, 1.5, 1.2)],
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
    for handle_id, spec in HANDLES.items():
        length, thickness = spec[0], spec[1]
        half = thickness / 2.0
        boxes = [(-half, 0, -half, half, length, half)]
        # POMMEAU, a la base de la poignee et NON sous y = 0 : il doit rester
        # dans la longueur declaree, sinon la piece deborderait derriere la main
        # sans que `longueur` — d'ou l'allonge se deduit — en sache rien.
        if len(spec) > 2 and spec[2]:
            pommel = spec[2] / 2.0
            boxes.append((-pommel, 0, -pommel, pommel, 2, pommel))
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
    root = out.parent.parent
    _sync_data(root / "data" / "weapon_parts.json")
    _derive_recipes(root)


# --- Materiaux composites -------------------------------------------------
# Part de BOIS d'une tete dont la boite est majoritairement autre chose que du
# metal. Un plateau de bouclier est une planche cerclee (umbo et bordure en
# fer), des branches d'arc sont du bois, un gourdin est un rondin. Sans ce
# chiffre, la derivation par volume ferait forger un ecu dans 6 lingots.
HEAD_WOOD_SHARE = {
    "rondache": 0.9, "ecu": 0.9, "pavois": 0.9,   # planche + umbo de fer
    "gourdin": 1.0,                                # un rondin
    "branches_arc": 1.0,                           # bois (et corne)
}

# Volume, en px3, consomme par UNE unite de matiere premiere. Calibre pour que
# la masse TOTALE du catalogue soit inchangee (ratio 0,99) : la derivation
# redistribue les poids selon la taille reelle des pieces, elle ne les inflate
# pas globalement.
UNIT_VOLUME_PX3 = 140.0

# Materiaux de REFERENCE, ceux dans lesquels `poids_reference` est exprime.
# Consequence voulue : une arme forgee en chene et fer tourne exactement a sa
# `vitesse_base`, et seul un ecart a cette reference la ralentit ou l'accelere.
REFERENCE_DENSITY = {"bois": 6.0, "minerai": 12.0}   # chene, fer


def _volume(boxes):
    return sum(abs(b[3] - b[0]) * abs(b[4] - b[1]) * abs(b[5] - b[2]) for b in boxes)


def _handle_boxes(spec):
    half = spec[1] / 2.0
    boxes = [(-half, 0, -half, half, spec[0], half)]
    if len(spec) > 2 and spec[2]:
        pommel = spec[2] / 2.0
        boxes.append((-pommel, 0, -pommel, pommel, 2, pommel))
    return boxes


def _derive_recipes(root):
    """Recalcule la RECETTE et la MASSE de chaque arme depuis le volume de ses
    pieces.

    POURQUOI (2026-08-02). Les deux etaient tapees a la main, et ne suivaient
    plus rien : le metal consomme allait de 28 a 424 px3 par unite selon l'arme
    — un facteur 15 sans justification —, une masse a une main pesait 2 kg
    quand un espadon en pesait 2,1, et une hallebarde de 2,80 m etait plus
    legere qu'une masse. Rien de tout cela ne pouvait se voir en lisant les
    fiches, et tout redevenait faux au premier ajustement de geometrie.

    Desormais : cout de craft et masse SORTENT du modele. Rallonger une hampe
    la rend plus lourde et plus chere, du meme geste.
    """
    items_dir = root / "data" / "items"
    fn_dir = root / "data" / "functionalities"
    if not items_dir.exists():
        print("  (data/items absent : recettes non derivees)")
        return
    changed = 0
    for item_path in sorted(items_dir.glob("*.json")):
        item = json.loads(item_path.read_text(encoding="utf-8"))
        parts = item.get("parts")
        if not parts or parts.get("manche") not in HANDLES or parts.get("tete") not in HEADS:
            continue
        tint = item.get("sprite_tint", {})
        volumes = {}
        handle_cat = tint.get("manche", "bois")
        volumes[handle_cat] = volumes.get(handle_cat, 0.0) + _volume(_handle_boxes(HANDLES[parts["manche"]]))
        head_volume = _volume(HEADS[parts["tete"]])
        wood_share = HEAD_WOOD_SHARE.get(parts["tete"], 0.0)
        head_cat = tint.get("tete", "minerai")
        if wood_share > 0.0:
            # Piece composite : la part boisee va au bois, le reste au metal
            # (umbo, cerclage, ferrures).
            volumes["bois"] = volumes.get("bois", 0.0) + head_volume * wood_share
            rest = head_volume * (1.0 - wood_share)
            if rest > 0.0:
                volumes["minerai"] = volumes.get("minerai", 0.0) + rest
        else:
            volumes[head_cat] = volumes.get(head_cat, 0.0) + head_volume

        inputs = []
        for category in ("bois", "minerai"):
            if category not in volumes:
                continue
            amount = int(round(volumes[category] / UNIT_VOLUME_PX3))
            # Une piece plus petite qu'une unite en coute quand meme une : on ne
            # forge pas une lame avec un demi-lingot.
            if amount < 1:
                amount = 1 if volumes[category] > UNIT_VOLUME_PX3 * 0.25 else 0
            if amount > 0:
                inputs.append({"category": category, "amount": amount})
        if not inputs:
            continue
        item.setdefault("recipe", {})["inputs"] = inputs
        item_path.write_text(json.dumps(item, indent=2, ensure_ascii=False) + chr(10),
                             encoding="utf-8")
        changed += 1

        # `poids_reference` = la masse de CETTE recette dans les materiaux de
        # reference. Ce n'est plus un chiffre a l'estime : c'est la meme formule
        # que la masse d'une instance (ItemFactory), donc les deux ne peuvent
        # plus diverger.
        fn_id = item.get("functionality", "")
        fn_path = fn_dir / ("%s.json" % fn_id)
        if fn_id and fn_path.exists():
            fn = json.loads(fn_path.read_text(encoding="utf-8"))
            fn["poids_reference"] = int(round(sum(
                i["amount"] * REFERENCE_DENSITY[i["category"]] for i in inputs)))
            fn_path.write_text(json.dumps(fn, indent=2, ensure_ascii=False) + chr(10),
                               encoding="utf-8")
    print("  %d recette(s) et masse(s) derivees du volume des pieces" % changed)


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
    for handle_id, spec in HANDLES.items():
        length = spec[0]
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
