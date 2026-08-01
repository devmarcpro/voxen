#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Génère la police pixel de Voxen : assets/ui/voxen_pixel.png + .fnt (BMFont).

POURQUOI GÉNÉRER PLUTÔT QU'EMBARQUER UN .TTF. Le projet n'a aucune police et ne
peut pas en télécharger une. Surtout, une police pixel matricielle est de la
DONNÉE, pas un binaire opaque : chaque glyphe ci-dessous se lit, se corrige et
se relit dans une revue de code, exactement comme les tables de pièces d'arme.
Un .ttf tiers serait au contraire intouchable et poserait une question de
licence.

FORMAT DE SORTIE : BMFont texte (.fnt) + une page PNG. Godot 4 l'importe
nativement en FontFile — pas d'API de construction de glyphes à deviner au
runtime, et la police apparaît dans l'éditeur comme n'importe quelle ressource.

GÉOMÉTRIE D'UNE CELLULE (5 px de large, 11 de haut) :

      lignes 0-1   zone d'ACCENT (aigu, grave, circonflexe, tréma, tilde)
      lignes 2-8   CORPS 5x7 — les capitales l'occupent entièrement
      lignes 9-10  JAMBAGES (g j p q y , ; ç)

  La ligne de base est donc à 9 px du haut de la cellule.

Les glyphes accentués ne sont PAS dessinés à la main : ils sont composés d'un
corps existant + une marque. Sans cette composition il faudrait maintenir « é »
et « e » en parallèle, et ils finiraient par diverger.

CE QUE CETTE POLICE NE COUVRE PAS : le japonais et le chinois, deux des quatre
langues du jeu. C'est assumé — Godot retombe sur la police par défaut pour tout
caractère absent (voir `fallbacks` dans systems/ui/ui_theme.gd). Une police
pixel latine dessinée à la main ne pourra jamais couvrir des milliers de
sinogrammes, et prétendre le contraire produirait des carrés vides à l'écran.

    python tools/generate_pixel_font.py
"""

import os
from PIL import Image

HERE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT_DIR = os.path.join(HERE, "assets", "ui")
BASENAME = "voxen_pixel"

GLYPH_W = 5           # largeur du corps
ACCENT_ROWS = 2       # lignes réservées aux accents, au-dessus du corps
BODY_ROWS = 7         # corps 5x7
DESCENT_ROWS = 2      # jambages sous la ligne de base
CELL_H = ACCENT_ROWS + BODY_ROWS + DESCENT_ROWS   # 11
BASELINE = ACCENT_ROWS + BODY_ROWS                # 9
ADVANCE = GLYPH_W + 1                             # 1 px de chasse entre lettres
LINE_HEIGHT = CELL_H + 2

# --- Corps des glyphes -------------------------------------------------------
#
# 7 lignes (corps seul) ou 9 lignes (corps + 2 lignes de jambage). Tout autre
# nombre est une erreur et le générateur le refuse : un glyphe mal aligné
# décalerait toute la ligne de base.

B = {
    " ": ["....."] * 7,
    "A": [".###.", "#...#", "#...#", "#####", "#...#", "#...#", "#...#"],
    "B": ["####.", "#...#", "#...#", "####.", "#...#", "#...#", "####."],
    "C": [".###.", "#...#", "#....", "#....", "#....", "#...#", ".###."],
    "D": ["####.", "#...#", "#...#", "#...#", "#...#", "#...#", "####."],
    "E": ["#####", "#....", "#....", "####.", "#....", "#....", "#####"],
    "F": ["#####", "#....", "#....", "####.", "#....", "#....", "#...."],
    "G": [".###.", "#...#", "#....", "#.###", "#...#", "#...#", ".###."],
    "H": ["#...#", "#...#", "#...#", "#####", "#...#", "#...#", "#...#"],
    "I": ["#####", "..#..", "..#..", "..#..", "..#..", "..#..", "#####"],
    "J": ["..###", "...#.", "...#.", "...#.", "...#.", "#..#.", ".##.."],
    "K": ["#...#", "#..#.", "#.#..", "##...", "#.#..", "#..#.", "#...#"],
    "L": ["#....", "#....", "#....", "#....", "#....", "#....", "#####"],
    "M": ["#...#", "##.##", "#.#.#", "#.#.#", "#...#", "#...#", "#...#"],
    "N": ["#...#", "##..#", "#.#.#", "#.#.#", "#..##", "#...#", "#...#"],
    "O": [".###.", "#...#", "#...#", "#...#", "#...#", "#...#", ".###."],
    "P": ["####.", "#...#", "#...#", "####.", "#....", "#....", "#...."],
    "Q": [".###.", "#...#", "#...#", "#...#", "#.#.#", "#..#.", ".##.#"],
    "R": ["####.", "#...#", "#...#", "####.", "#.#..", "#..#.", "#...#"],
    "S": [".####", "#....", "#....", ".###.", "....#", "....#", "####."],
    "T": ["#####", "..#..", "..#..", "..#..", "..#..", "..#..", "..#.."],
    "U": ["#...#", "#...#", "#...#", "#...#", "#...#", "#...#", ".###."],
    "V": ["#...#", "#...#", "#...#", "#...#", "#...#", ".#.#.", "..#.."],
    "W": ["#...#", "#...#", "#...#", "#.#.#", "#.#.#", "##.##", "#...#"],
    "X": ["#...#", "#...#", ".#.#.", "..#..", ".#.#.", "#...#", "#...#"],
    "Y": ["#...#", "#...#", ".#.#.", "..#..", "..#..", "..#..", "..#.."],
    "Z": ["#####", "....#", "...#.", "..#..", ".#...", "#....", "#####"],

    "a": [".....", ".....", ".###.", "....#", ".####", "#...#", ".####"],
    "b": ["#....", "#....", "####.", "#...#", "#...#", "#...#", "####."],
    "c": [".....", ".....", ".###.", "#....", "#....", "#....", ".###."],
    "d": ["....#", "....#", ".####", "#...#", "#...#", "#...#", ".####"],
    "e": [".....", ".....", ".###.", "#...#", "#####", "#....", ".###."],
    "f": ["..##.", ".#..#", ".#...", "####.", ".#...", ".#...", ".#..."],
    "g": [".....", ".....", ".####", "#...#", "#...#", ".####", "....#",
          "#...#", ".###."],
    "h": ["#....", "#....", "####.", "#...#", "#...#", "#...#", "#...#"],
    "i": ["..#..", ".....", ".##..", "..#..", "..#..", "..#..", ".###."],
    "j": ["...#.", ".....", "..##.", "...#.", "...#.", "...#.", "...#.",
          "#..#.", ".##.."],
    "k": ["#....", "#....", "#..#.", "#.#..", "##...", "#.#..", "#..#."],
    "l": [".##..", "..#..", "..#..", "..#..", "..#..", "..#..", ".###."],
    "m": [".....", ".....", "##.#.", "#.#.#", "#.#.#", "#...#", "#...#"],
    "n": [".....", ".....", "####.", "#...#", "#...#", "#...#", "#...#"],
    "o": [".....", ".....", ".###.", "#...#", "#...#", "#...#", ".###."],
    "p": [".....", ".....", "####.", "#...#", "#...#", "####.", "#....",
          "#....", "#...."],
    "q": [".....", ".....", ".####", "#...#", "#...#", ".####", "....#",
          "....#", "....#"],
    "r": [".....", ".....", "#.##.", "##..#", "#....", "#....", "#...."],
    "s": [".....", ".....", ".####", "#....", ".###.", "....#", "####."],
    "t": [".#...", ".#...", "####.", ".#...", ".#...", ".#..#", "..##."],
    "u": [".....", ".....", "#...#", "#...#", "#...#", "#..##", ".##.#"],
    "v": [".....", ".....", "#...#", "#...#", "#...#", ".#.#.", "..#.."],
    "w": [".....", ".....", "#...#", "#...#", "#.#.#", "#.#.#", ".#.#."],
    "x": [".....", ".....", "#...#", ".#.#.", "..#..", ".#.#.", "#...#"],
    "y": [".....", ".....", "#...#", "#...#", "#...#", ".####", "....#",
          "#...#", ".###."],
    "z": [".....", ".....", "#####", "...#.", "..#..", ".#...", "#####"],

    "0": [".###.", "#...#", "#..##", "#.#.#", "##..#", "#...#", ".###."],
    "1": ["..#..", ".##..", "..#..", "..#..", "..#..", "..#..", ".###."],
    "2": [".###.", "#...#", "....#", "...#.", "..#..", ".#...", "#####"],
    "3": ["#####", "...#.", "..#..", "...#.", "....#", "#...#", ".###."],
    "4": ["...#.", "..##.", ".#.#.", "#..#.", "#####", "...#.", "...#."],
    "5": ["#####", "#....", "####.", "....#", "....#", "#...#", ".###."],
    "6": ["..##.", ".#...", "#....", "####.", "#...#", "#...#", ".###."],
    "7": ["#####", "....#", "...#.", "..#..", ".#...", ".#...", ".#..."],
    "8": [".###.", "#...#", "#...#", ".###.", "#...#", "#...#", ".###."],
    "9": [".###.", "#...#", "#...#", ".####", "....#", "...#.", ".##.."],

    "!": ["..#..", "..#..", "..#..", "..#..", "..#..", ".....", "..#.."],
    '"': [".#.#.", ".#.#.", ".....", ".....", ".....", ".....", "....."],
    "#": [".#.#.", ".#.#.", "#####", ".#.#.", "#####", ".#.#.", ".#.#."],
    "$": ["..#..", ".####", "#.#..", ".###.", "..#.#", "####.", "..#.."],
    "%": ["##..#", "##..#", "...#.", "..#..", ".#...", "#..##", "#..##"],
    "&": [".##..", "#..#.", "#.#..", ".#...", "#.#.#", "#..#.", ".##.#"],
    "'": ["..#..", "..#..", ".....", ".....", ".....", ".....", "....."],
    "(": ["...#.", "..#..", ".#...", ".#...", ".#...", "..#..", "...#."],
    ")": [".#...", "..#..", "...#.", "...#.", "...#.", "..#..", ".#..."],
    "*": [".....", "#.#.#", ".###.", "#####", ".###.", "#.#.#", "....."],
    "+": [".....", "..#..", "..#..", "#####", "..#..", "..#..", "....."],
    ",": [".....", ".....", ".....", ".....", ".....", ".....", "..#..",
          "..#..", ".#..."],
    "-": [".....", ".....", ".....", "#####", ".....", ".....", "....."],
    ".": [".....", ".....", ".....", ".....", ".....", ".##..", ".##.."],
    "/": ["....#", "....#", "...#.", "..#..", ".#...", "#....", "#...."],
    ":": [".....", ".##..", ".##..", ".....", ".##..", ".##..", "....."],
    ";": [".....", ".##..", ".##..", ".....", ".##..", ".##..", "..#..",
          ".#...", "....."],
    "<": ["...#.", "..#..", ".#...", "#....", ".#...", "..#..", "...#."],
    "=": [".....", ".....", "#####", ".....", "#####", ".....", "....."],
    ">": [".#...", "..#..", "...#.", "....#", "...#.", "..#..", ".#..."],
    "?": [".###.", "#...#", "....#", "...#.", "..#..", ".....", "..#.."],
    "@": [".###.", "#...#", "#.###", "#.#.#", "#.###", "#....", ".###."],
    "[": ["..###", "..#..", "..#..", "..#..", "..#..", "..#..", "..###"],
    "\\": ["#....", "#....", ".#...", "..#..", "...#.", "....#", "....#"],
    "]": ["###..", "..#..", "..#..", "..#..", "..#..", "..#..", "###.."],
    "^": ["..#..", ".#.#.", "#...#", ".....", ".....", ".....", "....."],
    "_": [".....", ".....", ".....", ".....", ".....", ".....", "#####"],
    "`": [".#...", "..#..", ".....", ".....", ".....", ".....", "....."],
    "{": ["...##", "..#..", "..#..", ".##..", "..#..", "..#..", "...##"],
    "|": ["..#..", "..#..", "..#..", "..#..", "..#..", "..#..", "..#.."],
    "}": ["##...", "..#..", "..#..", "..##.", "..#..", "..#..", "##..."],
    "~": [".....", ".##.#", "#.##.", ".....", ".....", ".....", "....."],

    # Ponctuation typographique française et symboles de l'interface.
    "«": [".....", "..#.#", ".#.#.", "#.#..", ".#.#.", "..#.#", "....."],
    "»": [".....", "#.#..", ".#.#.", "..#.#", ".#.#.", "#.#..", "....."],
    "°": [".##..", "#..#.", ".##..", ".....", ".....", ".....", "....."],
    "·": [".....", ".....", ".....", "..#..", ".....", ".....", "....."],
    "…": [".....", ".....", ".....", ".....", ".....", ".....", "#.#.#"],
    "—": [".....", ".....", ".....", "#####", ".....", ".....", "....."],
    "–": [".....", ".....", ".....", ".###.", ".....", ".....", "....."],
    "’": ["..#..", "..#..", ".....", ".....", ".....", ".....", "....."],
    "×": [".....", ".....", "#...#", ".#.#.", "..#..", ".#.#.", "#...#"],
    "→": [".....", ".....", "..#..", "...#.", "#####", "...#.", "..#.."],
    "←": [".....", ".....", "..#..", ".#...", "#####", ".#...", "..#.."],
    "↑": ["..#..", ".###.", "#.#.#", "..#..", "..#..", "..#..", "..#.."],
    "↓": ["..#..", "..#..", "..#..", "..#..", "#.#.#", ".###.", "..#.."],
    "✓": [".....", "....#", "....#", "#..#.", "#.#..", ".##..", "....."],
    "€": ["..###", ".#...", "####.", ".#...", "####.", ".#...", "..###"],
    "Œ": [".####", "#.#..", "#.#..", "#.###", "#.#..", "#.#..", ".####"],
    "œ": [".....", ".....", ".####", "#.#.#", "#.###", "#.#..", ".####"],
    "Æ": [".####", "#.#..", "#.#..", "#.###", "####.", "#.#..", "#.###"],
    "æ": [".....", ".....", "##.#.", "..#.#", ".####", "#.#..", ".##.#"],
    "ß": ["####.", "#...#", "#...#", "####.", "#...#", "#...#", "#.##."],

    # Symboles qui apparaissent DANS DES CHAÎNES AFFICHÉES (pastille de recette,
    # comparateurs des infobulles, icône d'arme des fichiers de langue). Absents,
    # ils s'affichaient en carré vide : le moteur n'a pas non plus ces glyphes
    # dans sa police de secours, contrairement aux idéogrammes.
    "✗": [".....", "#...#", ".#.#.", "..#..", ".#.#.", "#...#", "....."],
    "±": ["..#..", "..#..", "#####", "..#..", "..#..", ".....", "#####"],
    "÷": [".....", "..#..", ".....", "#####", ".....", "..#..", "....."],
    "≈": [".....", ".....", ".##.#", "#..#.", ".##.#", "#..#.", "....."],
    "≤": ["...#.", "..#..", ".#...", "..#..", "...#.", ".....", "#####"],
    "≥": [".#...", "..#..", "...#.", "..#..", ".#...", ".....", "#####"],
    "−": [".....", ".....", ".....", "#####", ".....", ".....", "....."],
    "⚔": ["#...#", ".#.#.", "..#..", ".###.", "..#..", ".#.#.", "#...#"],
}

# --- Marques diacritiques ----------------------------------------------------
#
# Deux lignes, posées dans la zone d'accent au-dessus du corps.

ACCENTS_ABOVE = {
    "aigu":        ["...#.", "..#.."],
    "grave":       [".#...", "..#.."],
    "circonflexe": ["..#..", ".#.#."],
    "trema":       [".....", ".#.#."],
    "tilde":       [".##.#", "#.##."],
    "rond":        ["..#..", ".#.#."],
}

## La cédille pend SOUS la ligne de base : elle occupe les lignes de jambage, et
## un glyphe qui en porte une ne peut donc pas avoir de descendante propre.
CEDILLE = ["..#..", ".##.."]

# Composition : caractère → (corps de base, marque).
COMPOSED = {
    "à": ("a", "grave"),   "â": ("a", "circonflexe"), "ä": ("a", "trema"),
    "á": ("a", "aigu"),    "ã": ("a", "tilde"),       "å": ("a", "rond"),
    "è": ("e", "grave"),   "é": ("e", "aigu"),        "ê": ("e", "circonflexe"),
    "ë": ("e", "trema"),
    "ì": ("i", "grave"),   "í": ("i", "aigu"),        "î": ("i", "circonflexe"),
    "ï": ("i", "trema"),
    "ò": ("o", "grave"),   "ó": ("o", "aigu"),        "ô": ("o", "circonflexe"),
    "ö": ("o", "trema"),   "õ": ("o", "tilde"),
    "ù": ("u", "grave"),   "ú": ("u", "aigu"),        "û": ("u", "circonflexe"),
    "ü": ("u", "trema"),
    "ñ": ("n", "tilde"),
    "ý": ("y", "aigu"),
    "À": ("A", "grave"),   "Â": ("A", "circonflexe"), "Ä": ("A", "trema"),
    "Á": ("A", "aigu"),
    "È": ("E", "grave"),   "É": ("E", "aigu"),        "Ê": ("E", "circonflexe"),
    "Ë": ("E", "trema"),
    "Ì": ("I", "grave"),   "Í": ("I", "aigu"),        "Î": ("I", "circonflexe"),
    "Ï": ("I", "trema"),
    "Ò": ("O", "grave"),   "Ó": ("O", "aigu"),        "Ô": ("O", "circonflexe"),
    "Ö": ("O", "trema"),
    "Ù": ("U", "grave"),   "Ú": ("U", "aigu"),        "Û": ("U", "circonflexe"),
    "Ü": ("U", "trema"),
    "Ñ": ("N", "tilde"),
}

CEDILLED = {"ç": "c", "Ç": "C"}


def cell(char):
    """Matrice 5×11 finale d'un caractère, zones d'accent et de jambage incluses."""
    rows = [["." for _ in range(GLYPH_W)] for _ in range(CELL_H)]

    if char in COMPOSED:
        base_char, mark = COMPOSED[char]
        body = B[base_char]
        marks = ACCENTS_ABOVE[mark]
        for y, line in enumerate(marks):
            for x, pixel in enumerate(line):
                if pixel == "#":
                    rows[y][x] = "#"
    elif char in CEDILLED:
        body = B[CEDILLED[char]]
        for y, line in enumerate(CEDILLE):
            for x, pixel in enumerate(line):
                if pixel == "#":
                    rows[BASELINE + y][x] = "#"
    else:
        body = B[char]

    if len(body) not in (BODY_ROWS, BODY_ROWS + DESCENT_ROWS):
        raise ValueError("glyphe « %s » : %d lignes (attendu %d ou %d)"
                         % (char, len(body), BODY_ROWS, BODY_ROWS + DESCENT_ROWS))
    for y, line in enumerate(body):
        if len(line) != GLYPH_W:
            raise ValueError("glyphe « %s » ligne %d : %d colonnes (attendu %d)"
                             % (char, y, len(line), GLYPH_W))
        for x, pixel in enumerate(line):
            if pixel == "#":
                rows[ACCENT_ROWS + y][x] = "#"
    return rows


def main():
    chars = sorted(set(list(B.keys()) + list(COMPOSED.keys()) + list(CEDILLED.keys())),
                   key=ord)
    columns = 16
    lines = (len(chars) + columns - 1) // columns
    # 1 px de garde entre cellules : sans lui, le filtrage de bord d'une cellule
    # mordrait sur sa voisine et les lettres traîneraient un pixel parasite.
    cw, ch = GLYPH_W + 1, CELL_H + 1
    image = Image.new("RGBA", (columns * cw, lines * ch), (255, 255, 255, 0))
    pixels = image.load()

    records = []
    for index, char in enumerate(chars):
        cx = (index % columns) * cw
        cy = (index // columns) * ch
        for y, row in enumerate(cell(char)):
            for x, pixel in enumerate(row):
                if pixel == "#":
                    pixels[cx + x, cy + y] = (255, 255, 255, 255)
        records.append((ord(char), cx, cy))

    os.makedirs(OUT_DIR, exist_ok=True)
    png_name = BASENAME + ".png"
    image.save(os.path.join(OUT_DIR, png_name))

    fnt = [
        'info face="Voxen Pixel" size=%d bold=0 italic=0 charset="" unicode=1 '
        'stretchH=100 smooth=0 aa=1 padding=0,0,0,0 spacing=0,0' % CELL_H,
        'common lineHeight=%d base=%d scaleW=%d scaleH=%d pages=1 packed=0'
        % (LINE_HEIGHT, BASELINE, image.width, image.height),
        'page id=0 file="%s"' % png_name,
        'chars count=%d' % len(records),
    ]
    for code, cx, cy in records:
        fnt.append('char id=%d x=%d y=%d width=%d height=%d xoffset=0 yoffset=0 '
                   'xadvance=%d page=0 chnl=15'
                   % (code, cx, cy, GLYPH_W, CELL_H, ADVANCE))
    with open(os.path.join(OUT_DIR, BASENAME + ".fnt"), "w",
              encoding="utf-8", newline="\n") as handle:
        handle.write("\n".join(fnt) + "\n")

    print("%d glyphes -> %s (%dx%d px)"
          % (len(records), png_name, image.width, image.height))


if __name__ == "__main__":
    main()
