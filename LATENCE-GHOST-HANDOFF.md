# Handoff — Latence ghost : enquête bouclée, prochain chantier À ÉVALUER d'abord

> Session 2026-06-10. Pour reprendre après /clear : lis ce fichier en entier,
> puis §6 (reprise). Tout le raisonnement et les chiffres sont ici — ne pas
> re-litiguer, ne pas re-mesurer ce qui l'est déjà.

## 0. TL;DR

La latence perçue du ghost a été **mesurée bout-en-bout, localisée et corrigée** :
p50 frappe→paint (beam) **894 ms → 214 ms**, p95 **2245 → 513 ms**, plus aucune
queue >1 s. Trois causes empilées, toutes trouvées par la mesure, jamais à l'œil.
Le prochain gisement est identifié (réserve périmée pendant la live-consume →
seeds froids post-consommation) mais c'est une **hypothèse à quantifier par éval
AVANT de coder** — c'est exactement la zone qui a déjà cassé une fois (« la
fenêtre fondait », commit `6a3e0e6`).

## 1. Ce qui a été fait (branche `feat/ghost-parity-metrics`, tout mergé sur `feat/beam-llm-core` et poussé)

### Mid-line (la pill vivante) — terminé, validé au clavier par l'utilisateur
- `aa0f085` — anti-recopie beam du texte après-curseur (`BeamGhostShaper.afterCaretEchoCut`
  + `selectGhost` qui itère les K candidats), live-consume + rolling refill de la
  pill, fragment du mot en cours en couleur accent (`PillView` deux runs).
- `f6f4607` + `97a7ea8` — l'accept FUSIONNE avec le texte existant :
  `midLineAcceptPlan` (ops skip/inject alternés ; « m'ai|der  trouver » + ghost
  « der à trouver » n'insère QUE « à »), `AXClient.moveCaretRight`.
- `0ea4f77` — saut de caret CONFIRMÉ par lecture AX avant injection (les flèches
  CGEvent sont asynchrones — sans confirmation l'injection partait de l'ancienne
  position) + drop du séparateur final devant la ponctuation.

### Robustesse
- `339bf8b` — retry du chargement modèle depuis `.failed` avec backoff 10 s
  (avant : un échec ponctuel = ghost mort jusqu'au relaunch, boucle
  `ghost_warm_reload` infinie).

### Enquête latence (l'essentiel de la session)
- `22a1228` + `eec70ef` + `44f7be3` — **trace bout-en-bout** `SOUFFLEUSE_LATENCY_TRACE=1`
  → `/tmp/souffleuse-latency.jsonl`, analysée par `tools/latency_report.py`.
  Étapes : key_down, tick_prefix, predict_begin, gen_begin/end, gen_path
  (1 HIT / 2 REFILL / 3 MISS / 4 seed-réserve / 5 seed), seed_prompt/lcp,
  seed_prefill_ms/seed_decode_ms, refill_*, suggestion_set (i=source), paint
  (hook `OverlayWindow.onPaint`, repaint effectif). AUCUN texte user (hash FNV).
- `c83a930` — **cancel-on-keystroke DANS la boucle de décodage** du beam
  (`Task.isCancelled` → break, + `refillSurvivors`). Avant : un beam périmé
  courait ses 12 pas et l'actor sérialisait tout derrière (p50 713 ms mesuré).
- `3f7ad14` — **tête de prompt du refill alignée sur le predict** (PVM mémorise
  `lastPromptCustomInstr/CtxPrefix`, le refill les reprend, gaté beamCoreEnabled).
  Avant : prompts divergents au token 0 → wipe mutuel du prefix-cache (seed froid
  1288 ms vs chaud 398 ms). Après : prefill = **1-3 ms partout**, bucket froid VIDE.
- **DÉCOUVERTE SANS COMMIT — le build Debug** : les scans scalaires du vocab
  (262k tokens × 2 passes × branche × pas dans `topNextTokens`/`topCompatibleTokens`)
  payaient la pénalité Swift non-optimisée. **Release ÷4 sur le décode**
  (439 → 104 ms p50). ⇒ RÈGLE : toute mesure/usage de latence se fait en
  **Release** (`CONFIGURATION=Release ./make-app.sh`, cert dev habituel, TCC
  conservé ; `RELEASE=1` = signature Developer ID, autre usage).
  Ceci ré-éclaire le « softmax vectorisé REJETÉ » de PARITY-FINDINGS §6 : l'A/B
  neutre tournait optimisé — verdict correct, sujet définitivement clos.

### Chiffres finaux (Release, tous fixes, session réelle 263 générations)
```
frappe→tick 19 ms · tick→predict 32 · predict→gen 28 · GEN 96 · suggestion→paint 8
TOTAL frappe→paint (beam) p50 214 ms · p95 513 · max 807
Chemins : HIT 15× ~1 ms · REFILL 24× p50 2 (p95 355-517) · MISS 23× 169 · seed 49× 131
Seeds : prefill 1 ms · décode 104 ms · reste 3 ms — buckets froids vides partout
Refill vivant : p50 27 ms (chaud 27/103)
```

## 2. Méthode (verrouillée par l'expérience — NE PAS dévier)

1. **Mesurer d'abord** : trace ON, taper en conditions réelles, `python3
   tools/latency_report.py`. Jamais de fix « à l'intuition » — chacune des 3
   causes a contredit une intuition (le poll/debounce étaient innocents ; le
   contexte long décodait PLUS VITE que le court ; le softmax était déjà tranché).
2. **Release obligatoire** pour tout jugement de latence.
3. Une variable à la fois ; A/B offline (`SouffleuseParityEval`) pour tout
   changement qui touche la qualité ; archive de trace avant chaque changement
   (`/tmp/souffleuse-latency-*.jsonl` : -avant, -apres-cancel, -avant/apres-alignement,
   -blocA-debug).
4. Vérifier l'historique avant de proposer un levier (PARITY-FINDINGS §6,
   BEAM-LLM-CORE-HANDOFF, ce fichier).

## 3. État runtime (à reposer après reboot !)

```bash
launchctl setenv SOUFFLEUSE_BEAM_CORE 1
launchctl setenv SOUFFLEUSE_BEAM_RESERVE 1
launchctl setenv SOUFFLEUSE_LATENCY_TRACE 1   # seulement pour mesurer
open Souffleuse/build/Build/Products/Release/Souffleuse.app
```
`launchctl setenv` NE survit PAS au reboot → ghost silencieusement en cascade.
Décision en attente : basculer beam-core/réserve en défaut code (kill-switch
`SOUFFLEUSE_BEAM_CORE_OFF`, pattern `midWordGhostRollingEnabled`).

## 4. Le prochain gisement (ANALYSÉ, PAS CODÉ, PAS QUANTIFIÉ)

**Hypothèse** : la réserve se périme pendant la live-consume. Pendant que
l'utilisateur tape les lettres du ghost affiché, la slice AppDelegate sert tout
(0 ms, aucun predict) → `beamSessionTail` ne suit pas → à la fin de la
consommation, le préfixe a avancé de 10-20 chars d'un coup → la condition de
continuité (`userTail` prolonge l'ancien de ≤ 3 chars,
`ModelRuntime.generateGhostBeam`) casse → **seed froid 131 ms** alors que la
réserve contenait peut-être la suite. Soupçonné responsable d'une grosse part
des 49 seeds / 111 générations.

**Le fix envisagé** (à ne PAS coder avant les évals du §5) : pousser les chars
consommés dans `advance(typedChar:)` pendant la consommation (HIT par avancée de
pointeur) pour garder la réserve alignée. DANGER documenté : c'est la zone du
revert `6a3e0e6` — toute neutralisation du rolling refill vide le living ghost.
Le fix doit être ADDITIF (la slice display reste, on synchronise seulement la
réserve) et flag-gaté.

Note corrigée en session : le « top-up synchrone dans advance » (REFILL p95
355-517 ms) est un gisement MINEUR — il ne touche que les frappes passées par
predict malgré une réserve vivante (divergence vers une branche alternative, ou
affichage gaté), pas la consommation courante.

## 5. ÉVALS À FAIRE D'ABORD (l'étape suivante, avant tout code)

1. **Quantifier le gisement sur les traces existantes** — ✅ FAIT (2026-06-10,
   commit `e2c3a53`, section « Seeds post-consommation » de
   `tools/latency_report.py`). **Verdict : NO-GO.** Sur la session de
   référence (`/tmp/souffleuse-latency.jsonl`, 91 seeds) : 23 % de sauts
   > 3 chars, dont 22 % seulement en consommation probable (saut 4-24) —
   sous le seuil de 30 %. Les autres traces confirment (apres-alignement :
   31 % bruts mais 12 % consommation, le reste = sauts de focus > 24 chars ;
   blocA/blocA-debug : 0 % consommation). En prime, ces seeds ne sont PAS
   plus lents que les autres (p50 115 vs 132 ms) → gain potentiel ≈ 20 seeds
   × ~115 ms par session. **Gisement faible : le fix réserve du §4 est
   abandonné, ne pas re-litiguer.**
2. **Banc de continuité** — SANS OBJET (c'était le go/no-go du fix abandonné
   en 1).
3. **Garde qualité maxTokens** — ✅ FAIT (2026-06-10). **Verdict : REJETÉ.**
   A/B `SOUFFLEUSE_BEAM_MAXTOK=8` vs 12, `PARITY_ENGINE=beam`, 15 phrases :
   scorecards identiques au pour-cent près ET aucun gain de latence — le cap
   ne mord jamais (les candidats finissent avant 8 tokens, `maxWords=3`).
   Sanity check `MAXTOK=2` (p50 47 ms, métriques différentes) : la variable
   est bien effective, le levier est simplement mort. Le « décode 104→70 ms »
   espéré n'existe pas. Documenté dans PARITY-FINDINGS §6. Ne pas re-litiguer.

## 6. Reprise après /clear

Dire : « Lis LATENCE-GHOST-HANDOFF.md et exécute le §5 (évals), dans l'ordre. »
- Garde-fous : Swift 6 strict concurrency · `swift test` vert (749) ·
  `audit.sh` PASSED · benches/évals hors SHIPPING_DIRS (print autorisé) ·
  commits FR style maison · tout changement de comportement flag-gaté.
- Leviers secondaires en attente (après §5) : keyDown→tickThrottled (+10 ms,
  simple, universel — les notifs AX Chromium sont muettes) · top-up de réserve
  asynchrone · anomalie paint p95 238 ms (marque de trace dédiée à ajouter) ·
  bascule beam-core par défaut · documenter l'enquête dans PARITY-FINDINGS.md.
- Worktrees : repo principal = `feat/ghost-parity-metrics` ;
  `/Users/gabrielwaltio/cocotypist-beam-core` = `feat/beam-llm-core` (à jour,
  poussé, `6584d0b`). Merger parity → beam-core après chaque étape validée.
