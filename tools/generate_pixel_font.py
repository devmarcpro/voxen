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

JAPONAIS ET CHINOIS (2026-08-01). Ils n'étaient PAS couverts : aucun caractère
chinois ne s'affichait. Le repli existait pourtant (`UITheme._load_font` pose
`pixel.fallbacks = [_engine_font]`), mais la police intégrée de Godot est
latine elle aussi — il n'y avait donc AUCUNE source de sinogrammes dans le
projet, et le repli ne pouvait mener qu'à du vide.

Dessiner des milliers d'idéogrammes à la main est évidemment exclu. Ils sont
RASTÉRISÉS depuis Noto Sans SC (SIL OFL) en cellules 12×12 binaires, et
seulement pour les caractères RÉELLEMENT PRÉSENTS dans locale/ja.csv et
locale/zh_Hans.csv. Le principe « générer plutôt qu'embarquer » tient donc
toujours : le dépôt ne contient pas de .ttf, seulement le PNG produit — la
police source est lue sur la machine au moment de la génération.

  CONTREPARTIE, à connaître : le jeu de glyphes est FIGÉ sur les traductions
  du jour. Une traduction qui introduit un caractère jamais utilisé auparavant
  s'affichera en carré vide. Ce n'est pas silencieux : `--probe-police` relit
  les CSV et ÉCHOUE si un caractère n'est pas dans la police. Après toute
  traduction, relancer ce script puis la sonde.

    python tools/generate_pixel_font.py
"""

import os
import sys
from PIL import Image, ImageDraw, ImageFont

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


# --- Idéogrammes -------------------------------------------------------------
#
# Contrairement au latin ci-dessus, ces glyphes ne sont pas de la donnée
# relisible : ils sont rastérisés depuis une police source. Le compromis est
# assumé — 1300 idéogrammes ne se dessinent pas à la main, et un carré vide à
# l'écran est un pire défaut qu'un glyphe généré.

CJK_SIZE = 12        # cellule carrée, choisie au rendu (11 empâte les caractères denses)
CJK_DESCENT = 1      # combien la cellule descend sous la ligne de base
CJK_COLUMNS = 32     # colonnes de l'atlas idéographique
CJK_THRESHOLD = 110  # seuil de binarisation du rendu antialiasé

## Plages Unicode considérées comme « idéographiques » : ponctuation CJK,
## hiragana, katakana, idéogrammes unifiés, et formes pleine chasse.
CJK_RANGES = ((0x3000, 0x9FFF), (0xFF00, 0xFFEF))

## Polices sources acceptées, par ordre de préférence. Noto Sans SC est sous
## SIL OFL : son rendu est redistribuable. Les polices Microsoft (msyh, simhei)
## ne sont volontairement PAS listées — elles ne sont pas redistribuables, et
## un PNG dérivé le serait tout autant qu'un .ttf.
CJK_SOURCES = (
    r"C:\Windows\Fonts\NotoSansSC-VF.ttf",
    "/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc",
    "/usr/share/fonts/truetype/noto/NotoSansSC-Regular.otf",
    "/System/Library/Fonts/Supplemental/NotoSansSC-Regular.otf",
)

LOCALE_DIR = os.path.join(HERE, "locale")


def is_cjk(char):
    code = ord(char)
    return any(low <= code <= high for low, high in CJK_RANGES)


def needed_cjk():
    """Idéogrammes réellement employés par les traductions, triés."""
    found = set()
    if not os.path.isdir(LOCALE_DIR):
        return []
    for name in sorted(os.listdir(LOCALE_DIR)):
        if not name.endswith(".csv"):
            continue
        with open(os.path.join(LOCALE_DIR, name), encoding="utf-8") as handle:
            for char in handle.read():
                if is_cjk(char):
                    found.add(char)
    return sorted(found, key=ord)


def load_cjk_font():
    """Police source, ou None si aucune n'est installée (le latin reste généré)."""
    for path in CJK_SOURCES:
        if not os.path.exists(path):
            continue
        font = ImageFont.truetype(path, CJK_SIZE)
        # Police VARIABLE : sans fixer l'axe de graisse, PIL rend le tout
        # premier instantané nommé — « Thin » pour Noto Sans SC, dont les
        # traits disparaissent purement et simplement à la binarisation.
        try:
            font.set_variation_by_name("Regular")
        except (OSError, AttributeError):
            pass
        return font, path
    return None, None


def cjk_bitmap(font, char):
    """Matrice binaire CJK_SIZE×CJK_SIZE d'un idéogramme, ou None si vide."""
    tile = Image.new("L", (CJK_SIZE, CJK_SIZE), 0)
    draw = ImageDraw.Draw(tile)
    # Ancrage « left-ascender » : le rendu part du coin de la case, sans quoi
    # chaque glyphe se placerait selon sa propre chasse et la grille serait
    # irrégulière.
    draw.text((0, 0), char, font=font, fill=255, anchor="la")
    pixels = tile.load()
    rows = []
    lit = False
    for y in range(CJK_SIZE):
        row = []
        for x in range(CJK_SIZE):
            on = pixels[x, y] >= CJK_THRESHOLD
            lit = lit or on
            row.append("#" if on else ".")
        rows.append(row)
    return rows if lit else None


def main():
    chars = sorted(set(list(B.keys()) + list(COMPOSED.keys()) + list(CEDILLED.keys())),
                   key=ord)
    columns = 16
    lines = (len(chars) + columns - 1) // columns
    # 1 px de garde entre cellules : sans lui, le filtrage de bord d'une cellule
    # mordrait sur sa voisine et les lettres traîneraient un pixel parasite.
    cw, ch = GLYPH_W + 1, CELL_H + 1

    # L'atlas porte DEUX blocs de géométries différentes : le latin 5×11 en
    # haut, les idéogrammes 12×12 en dessous. BMFont décrit chaque glyphe
    # individuellement (x/y/width/height/xadvance), donc rien n'oblige à une
    # grille unique — et forcer le latin dans des cases de 12 px de large
    # aurait ruiné sa chasse.
    cjk_font, cjk_path = load_cjk_font()
    cjk_chars = needed_cjk() if cjk_font is not None else []
    ccw = cch = CJK_SIZE + 1
    cjk_lines = (len(cjk_chars) + CJK_COLUMNS - 1) // CJK_COLUMNS if cjk_chars else 0

    latin_height = lines * ch
    width = max(columns * cw, CJK_COLUMNS * ccw if cjk_chars else 0)
    image = Image.new("RGBA", (width, latin_height + cjk_lines * cch),
                      (255, 255, 255, 0))
    pixels = image.load()

    records = []
    for index, char in enumerate(chars):
        cx = (index % columns) * cw
        cy = (index // columns) * ch
        for y, row in enumerate(cell(char)):
            for x, pixel in enumerate(row):
                if pixel == "#":
                    pixels[cx + x, cy + y] = (255, 255, 255, 255)
        records.append((ord(char), cx, cy, GLYPH_W, CELL_H, 0, ADVANCE))

    # yoffset NÉGATIF : il place le haut de la cellule au-dessus du haut de
    # ligne pour que le BAS du carré idéographique tombe CJK_DESCENT px sous la
    # ligne de base, donc aligné sur le latin qui l'entoure.
    cjk_yoffset = BASELINE + CJK_DESCENT - CJK_SIZE
    skipped = []
    placed = 0
    for char in cjk_chars:
        bitmap = cjk_bitmap(cjk_font, char)
        if bitmap is None:
            skipped.append(char)  # Absent de la police source : signalé, jamais tu.
            continue
        cx = (placed % CJK_COLUMNS) * ccw
        cy = latin_height + (placed // CJK_COLUMNS) * cch
        for y, row in enumerate(bitmap):
            for x, pixel in enumerate(row):
                if pixel == "#":
                    pixels[cx + x, cy + y] = (255, 255, 255, 255)
        records.append((ord(char), cx, cy, CJK_SIZE, CJK_SIZE,
                        cjk_yoffset, CJK_SIZE + 1))
        placed += 1

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
    for code, cx, cy, gw, gh, yoff, adv in records:
        fnt.append('char id=%d x=%d y=%d width=%d height=%d xoffset=0 yoffset=%d '
                   'xadvance=%d page=0 chnl=15'
                   % (code, cx, cy, gw, gh, yoff, adv))
    with open(os.path.join(OUT_DIR, BASENAME + ".fnt"), "w",
              encoding="utf-8", newline="\n") as handle:
        handle.write("\n".join(fnt) + "\n")

    print("%d glyphes -> %s (%dx%d px)"
          % (len(records), png_name, image.width, image.height))
    print("  latin       : %d" % len(chars))
    if cjk_font is None:
        # Avertir FORT : sans police source, le chinois et le japonais
        # redeviennent des carrés vides, et rien d'autre ne le signalerait.
        print("  idéogrammes : AUCUN — aucune police source trouvée parmi :",
              file=sys.stderr)
        for path in CJK_SOURCES:
            print("      %s" % path, file=sys.stderr)
        print("  Le chinois et le japonais ne s'afficheront PAS.", file=sys.stderr)
    else:
        print("  idéogrammes : %d (source %s)" % (placed, os.path.basename(cjk_path)))
        if skipped:
            print("  ABSENTS de la police source : %s"
                  % " ".join(skipped), file=sys.stderr)


if __name__ == "__main__":
    main()
