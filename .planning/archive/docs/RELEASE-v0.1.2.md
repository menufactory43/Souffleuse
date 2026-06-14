# Souffleuse (llama.cpp fork) — v0.1.2

Jalon « cohérence + réactivité ». Corrige les derniers gros écarts de qualité
ressentie, tous diagnostiqués au probe (pas d'intuition).

## Cohérence du ghost
- **Espace final retiré du prompt** : un modèle SentencePiece émet le mot suivant
  AVEC son espace de tête, donc un espace final dans le prompt faisait boucler /
  dérailler le modèle (« on va y  » → répétition / « arrivait »). Sans l'espace,
  « on va y » → « arriver. » net. Comme on pause presque toujours après un espace,
  c'était la cause principale des « mauvais mots ».
- **Garde-fou spell-check mid-mot retiré** : NSSpellChecker rejette les
  néologismes/termes techniques valides (« gamifier », « procédural »), donc on
  droppait la complétion grammaticalement correcte au profit d'un mot du dico
  (« gamification »). La sortie fraîche du modèle est cohérente (prouvé au probe :
  « gamif » → « gamifier », « dévelo » → « développer »), l'incohérence réelle
  (splicing périmé) est bloquée en amont → on fait confiance au modèle.

## Réactivité
- **Tick 80→50 ms, debounce 30→15 ms** : le ghost apparaît nettement plus tôt.
- **Event tap Tab/Esc sur thread dédié** : il était sur le runloop principal →
  chaque frappe (ghost affiché) attendait derrière le thread principal → lettres
  avalées en frappe rapide + popup d'accent (é/è) qui se réveillait. Le tap a
  maintenant son propre thread → livraison des touches immédiate.

## Garde-fous
- macOS 14+ Apple Silicon. Aucun réseau au runtime, corpus chiffré.
- `audit.sh` vert (6/6). 359 tests (échecs résiduels = timing flaky sous charge,
  verts en isolé).

## Limitations connues
- Choix de mot « signature » : dépend toujours de l'enrichissement de la base
  perso (acceptations + toggle « enregistrer sans acceptation »).
