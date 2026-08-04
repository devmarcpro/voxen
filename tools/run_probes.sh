#!/usr/bin/env sh
# Lance les sondes ASSERTIVES l'une apres l'autre et agrege leur code de sortie.
#
# POURQUOI. Le projet compte une quarantaine de sondes, mais une seule sur six
# se termine par `finish(ok, tag)` — les autres impriment un rapport qu'un
# humain doit lire et interpreter. Il n'existait donc aucune commande capable
# de repondre a « est-ce que quelque chose est casse ? », et rien a brancher
# sur une CI. Ce script est cette commande.
#
# Chaque sonde demande son propre lancement de Godot (elle appelle quit()),
# d'ou une boucle de processus plutot qu'un drapeau --probe-all interne.
#
# Usage :
#   tools/run_probes.sh                  # sondes assertives, headless
#   tools/run_probes.sh --godot /chemin  # binaire Godot explicite
#   tools/run_probes.sh --timeout 600    # secondes par sonde (defaut 420)
#   tools/run_probes.sh --list           # affiche la liste et sort
#
# Code de sortie : 0 si toutes passent, 1 sinon.

set -u

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TIMEOUT=420
GODOT="${GODOT:-}"
LIST_ONLY=0

# Sondes qui rendent un VERDICT (appellent finish()) et n'ont pas besoin d'une
# fenetre pour le rendre. Les sondes de capture (--test-ui, --test-corps,
# --test-triche, --test-carte) sont exclues : en headless leurs captures sont
# sautees, donc leur verdict ne vaut plus grand-chose. Elles se lancent a la
# main, avec fenetre.
# Sondes lancees AVANT la suite, dont le code de sortie est ignore : elles
# preparent un etat que d'autres verifient. `--probe-save` ecrit la sauvegarde
# de test que `--probe-save-verify` relit — sans elle, la verification echoue
# sur « sauvegarde de la phase 1 absente », ce qui n'apprend rien sur le code.
SETUP="--probe-save"

PROBES="--probe-touches
--probe-police
--probe-noms
--probe-heure
--probe-tour
--probe-etages
--probe-dungeon
--probe-interieur
--probe-gemme
--probe-collection
--probe-potentiel
--probe-modificateurs
--probe-corps
--probe-rigs-animaux
--probe-save-verify
--probe-villages
--probe-pnj
--probe-royaumes
--probe-combat
--probe-assemblage
--probe-mains
--probe-arbres
--probe-pousses
--probe-foreuse
--probe-dimensions
--probe-triche
--probe-village-vie
--probe-royaumes-perf"

while [ $# -gt 0 ]; do
	case "$1" in
		--godot)   GODOT="$2"; shift 2 ;;
		--timeout) TIMEOUT="$2"; shift 2 ;;
		--list)    LIST_ONLY=1; shift ;;
		*) echo "Option inconnue : $1" >&2; exit 2 ;;
	esac
done

if [ "$LIST_ONLY" -eq 1 ]; then
	echo "$PROBES"
	exit 0
fi

# Recherche du binaire : $GODOT, puis le PATH, puis les emplacements usuels
# sous Windows. Echouer ICI avec un message clair vaut mieux que laisser
# chaque sonde echouer pour une raison sans rapport avec le code teste.
if [ -z "$GODOT" ]; then
	for candidate in godot godot4 \
		"$LOCALAPPDATA/Programs/Godot/Godot_v4.7-stable_win64_console.exe" \
		"$HOME/AppData/Local/Programs/Godot/Godot_v4.7-stable_win64_console.exe"; do
		if command -v "$candidate" >/dev/null 2>&1; then GODOT="$candidate"; break; fi
		if [ -x "$candidate" ]; then GODOT="$candidate"; break; fi
	done
fi
if [ -z "$GODOT" ]; then
	echo "Godot introuvable. Passer --godot /chemin/vers/godot ou definir \$GODOT." >&2
	exit 2
fi

printf 'Godot   : %s\n' "$GODOT"
printf 'Projet  : %s\n' "$PROJECT_DIR"
printf 'Timeout : %ss par sonde\n\n' "$TIMEOUT"

for flag in $SETUP; do
	printf '%-24s ' "$flag"
	if timeout "$TIMEOUT" "$GODOT" --headless --path "$PROJECT_DIR" -- "$flag" \
			>/dev/null 2>&1; then
		printf 'preparee\n'
	else
		printf 'preparation ratee (la suite peut echouer en cascade)\n'
	fi
done
printf '\n'

failed=""
timed_out=""
passed=0
total=0

for flag in $PROBES; do
	total=$((total + 1))
	printf '%-24s ' "$flag"
	log="$(mktemp)"
	# `timeout` est indispensable : une sonde qui attend une capture d'ecran
	# impossible en headless se bloque INDEFINIMENT, et c'est le pire mode
	# d'echec pour de l'automatisation (deux lots perdus le 2026-07-28).
	timeout "$TIMEOUT" "$GODOT" --headless --path "$PROJECT_DIR" -- "$flag" \
		>"$log" 2>&1
	code=$?
	if [ "$code" -eq 0 ]; then
		printf 'OK\n'
		passed=$((passed + 1))
	elif [ "$code" -eq 124 ]; then
		printf 'TIMEOUT (%ss)\n' "$TIMEOUT"
		timed_out="$timed_out $flag"
	else
		printf 'ECHEC (code %s)\n' "$code"
		failed="$failed $flag"
		# Le verdict de la sonde, pas les 2 000 lignes de journal du moteur.
		grep -E 'ÉCHEC|ECHEC|RÉSULTAT|SCRIPT ERROR' "$log" | head -15 | sed 's/^/    /'
	fi
	rm -f "$log"
done

printf '\n%s/%s sonde(s) passee(s).\n' "$passed" "$total"
[ -n "$failed" ]    && printf 'Echecs  :%s\n' "$failed"
[ -n "$timed_out" ] && printf 'Timeouts:%s\n' "$timed_out"
[ -z "$failed" ] && [ -z "$timed_out" ] && exit 0
exit 1
