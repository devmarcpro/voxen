class_name WorldNamer
extends RefCounted
## Noms procéduraux DÉTERMINISTES (2026-07-26) : monde, continents, océans.
## Assemblage de syllabes piloté par un hachage de la graine → même graine =
## mêmes noms. Pas de bruit, pas d'état : fonctions pures.

const _PREFIX := ["Val", "Aer", "Mor", "Thal", "Bel", "Dra", "Kor", "Syl",
	"Vor", "Eld", "Nor", "Zan", "Cael", "Fen", "Gor", "Ith", "Lun", "Om",
	"Pyr", "Ryn", "Tor", "Ux", "Wyn", "Xar", "Yll", "Zor"]
const _MID := ["a", "e", "i", "o", "u", "an", "or", "en", "il", "ar", "un",
	"ael", "yr", "os", "am", "eth", "ol", "ir"]
const _SUFFIX := ["ia", "os", "eth", "wyn", "dor", "gard", "mar", "heim",
	"stan", "land", "thys", "ara", "one", "ix", "us", "aria"]
const _OCEAN_SUFFIX := ["thalys", "mare", "abyss", "tide", "vast", "deep",
	"maris", "pelagos", "wynne"]


## Hachage entier déterministe (mêmes constantes que NoiseGenerator.pcg_hash).
static func _h(a: int, b: int) -> int:
	var v := (a * 747796405 + 2891336453) ^ (b * 2654435761)
	v = (v ^ (v >> 15)) * 0x85EBCA6B
	v = (v ^ (v >> 13)) * 0xC2B2AE35
	return (v ^ (v >> 16)) & 0x7FFFFFFF


static func _pick(arr: Array, seed: int, salt: int) -> String:
	return arr[_h(seed, salt) % arr.size()]


## Nom d'un monde / continent (Prefix + éventuel milieu + suffixe).
static func land_name(seed: int, index: int = 0) -> String:
	var s := seed * 131 + index * 977
	var name := _pick(_PREFIX, s, 1)
	if _h(s, 2) % 3 != 0:
		name += _pick(_MID, s, 3)
	name += _pick(_SUFFIX, s, 4)
	return name


## Nom d'océan : « Océan/Mer de <racine> » ou racine + suffixe marin.
static func ocean_name(seed: int, index: int = 0) -> String:
	var s := seed * 977 + index * 131 + 555
	if _h(s, 5) % 2 == 0:
		var kind := "Océan" if _h(s, 6) % 2 == 0 else "Mer"
		return "%s de %s" % [kind, land_name(s, 7)]
	return _pick(_PREFIX, s, 8) + _pick(_OCEAN_SUFFIX, s, 9)
