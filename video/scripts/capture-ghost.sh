#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# capture-ghost.sh — capture de VRAIES vidéos du ghost de Souffleuse, pour les
# monter dans Remotion via <OffthreadVideo>. Zéro dépendance (osascript +
# screencapture, fournis par macOS).
#
# Cible : TextEdit, document VIERGE à chaque prise. Choix délibéré :
#   - aucune donnée perso à l'écran (contrairement à Notes/Mail qui exposent
#     barres latérales, contacts, signatures) ;
#   - état déterministe (fenêtre dimensionnée, doc vérifié vide avant de filmer) ;
#   - on ne tape JAMAIS de Return et on ne quitte JAMAIS d'app → rien d'irréversible.
#
# PRÉ-REQUIS (une fois) :
#   1. Souffleuse buildée + lancée, ghost vérifié à la main.
#      (build release-like : CONFIGURATION=Release ./Souffleuse/make-app.sh)
#   2. Permissions TCC pour votre terminal : Accessibilité + Enregistrement écran.
#
# Le ghost est généré par un modèle → non déterministe. Si une prise n'a pas de
# ghost, relancez-la : c'est plus rapide que de scénariser.
#
# Usage :
#   ./scripts/capture-ghost.sh                       # joue toutes les prises
#   ./scripts/capture-ghost.sh clavier "Je reviens vers vous"   # une prise ad hoc
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail
cd "$(dirname "$0")/.."
OUT_DIR="public/clips"; mkdir -p "$OUT_DIR"

TAKE_SECONDS="${TAKE_SECONDS:-8}"   # durée d'enregistrement
TYPE_DELAY="${TYPE_DELAY:-0.07}"    # délai entre frappes (humain)
GHOST_WAIT="${GHOST_WAIT:-3.0}"     # attente d'apparition du ghost avant Tab
AFTER_TAB="${AFTER_TAB:-1.6}"       # respiration après acceptation
FONT_SIZE="${FONT_SIZE:-34}"        # taille de police TextEdit (lisible à l'écran)

# Fenêtre TextEdit déterministe {x1,y1,x2,y2} et zone filmée (sous la barre d'outils)
WIN="120, 120, 1320, 640"
RX=130; RY=192; RW=1180; RH=320

# Prises par défaut : "slug|||préfixe tapé". Le ghost complète la suite.
TAKES=(
  "clavier-1|||Je reviens vers vous"
  "clavier-2|||On se retrouve"
  "clavier-3|||Merci beaucoup pour"
)

prep_doc() {  # nouveau doc vierge, dimensionné, police agrandie (hors caméra)
  osascript - "$FONT_SIZE" >/dev/null <<'AS'
on run argv
  set sz to (item 1 of argv) as integer
  tell application "TextEdit"
    activate
    make new document
    delay 0.3
    set d to front document
    -- placeholder pour fixer la taille de frappe, puis on l'efface
    set text of d to "x"
    set font of text of d to "Helvetica Neue"
    set size of text of d to sz
  end tell
end run
AS
  # poser les bornes de fenêtre
  osascript -e "tell application \"TextEdit\" to set bounds of front window to {${WIN}}" >/dev/null
  # effacer le placeholder en gardant l'attribut de taille
  osascript >/dev/null <<'AS'
tell application "TextEdit" to activate
delay 0.2
tell application "System Events"
  keystroke "a" using {command down}
  key code 51
end tell
AS
}

doc_is_empty() {
  local n
  n=$(osascript -e 'tell application "TextEdit" to return (count of characters of text of front document)' 2>/dev/null || echo "-1")
  [ "$n" = "0" ]
}

type_and_accept() {
  osascript - "$1" "$TYPE_DELAY" "$GHOST_WAIT" "$AFTER_TAB" <<'AS'
on run argv
  set t to item 1 of argv
  set dly to (item 2 of argv) as real
  set gw to (item 3 of argv) as real
  set aft to (item 4 of argv) as real
  tell application "TextEdit" to activate
  delay 0.2
  tell application "System Events"
    repeat with i from 1 to (count of characters of t)
      keystroke (character i of t)
      delay dly
    end repeat
    delay gw
    key code 48   -- Tab : accepter le ghost
    delay aft
  end tell
end run
AS
}

capture_one() {
  local slug="$1" prefix="$2"
  local out="$OUT_DIR/${slug}.mov"
  echo "▸ $slug — « $prefix … »  →  $out"
  rm -f "$out"                        # screencapture refuse d'écraser
  prep_doc
  if ! doc_is_empty; then
    echo "  ✗ le document n'est pas vide après préparation — prise sautée."
    return
  fi
  screencapture -v -V"$TAKE_SECONDS" -R"$RX,$RY,$RW,$RH" "$out" &
  local rec=$!
  sleep 1.0
  type_and_accept "$prefix"
  wait "$rec" 2>/dev/null || true
  if [ -f "$out" ]; then echo "  ✓ $(du -h "$out" | cut -f1)"; else echo "  ✗ pas de fichier (TCC ?)"; fi
}

if [[ $# -ge 2 ]]; then
  capture_one "$1" "$2"
else
  echo "Capture de ${#TAKES[@]} prises dans TextEdit — ne touchez pas au clavier."
  echo "(3 s pour annuler…)"; sleep 3
  for t in "${TAKES[@]}"; do capture_one "${t%%|||*}" "${t##*|||}"; sleep 0.6; done
fi

echo; echo "Clips dans $OUT_DIR/ :"; ls -1 "$OUT_DIR"/*.mov 2>/dev/null || echo "  (aucun)"
