---
quick_id: 260613-qlp
slug: repro-midword-nom-propre-perso
date: 2026-06-13
---

# Quick : repro mid-word noms-propres × personnalisation

## Problème
L'utilisateur observe une corruption de nom propre dans le ghost : « Elon Mua » au lieu
de « Elon Musk ». Hypothèse initiale (ton auto / promotion tier) réfutée par les evals
existantes sur le corpus réel :
- Ton : moteur séparé, ne touche pas le ghost inline.
- Promotion tier : s'arme 39/812, 0 ghost changé sur held-out.
- Biais doux : « Musk » présent 8× dominant → favorise « Musk », pas « Mua ».

Aucun eval ne teste **perso ON × milieu de mot × nom propre**. C'est le trou.

## But
Déterminer si la corruption vient du **modèle de base** ou de la **personnalisation**,
en comparant base (strength 0) vs perso-doux vs perso-promo, en next-word ET mid-word,
sur des préfixes finissant en milieu de nom propre.

## Approche
Étendre `SouffleuseRealPersoEval` (dev probe, hors SHIPPING_DIRS) avec un PASS C piloté
par env var `SOUFFLEUSE_MIDWORD_PROBE=1` :
- Préfixes par défaut ciblant des noms propres mid-word (« Elon Mu », « Elon Mus »…)
  + override via `SOUFFLEUSE_MIDWORD_PREFIXES` (séparés par `|`, forme `prefix=attendu`).
- 3 conditions × {next-word, mid-word via OutputFilter.trailingPartialWord}.
- Strength via `SOUFFLEUSE_PERSO_STRENGTH` (défaut 1.0, l'utilisateur réel = 1.58).
- Sortie agrégée : pour chaque condition, le ghost contient-il le mot attendu ou le
  corrompt-il.

## Done quand
- L'eval build et tourne.
- On sait quelle(s) condition(s) corrompt « Musk » → conclusion sur le coupable.
