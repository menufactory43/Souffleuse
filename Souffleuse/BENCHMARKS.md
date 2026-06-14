# Souffleuse — Benchmarks

Mesures locales du moteur de prédiction. Mises à jour à chaque changement de modèle ou de paramètres.

## Machine de test

- Mac (Apple Silicon, macOS 26.5 / Xcode 26.5)
- Build Debug — Release améliorera notamment le TTFT

## Cibles

| Métrique | Cible | Modèle réf |
|---|---|---|
| TTFT (time-to-first-token) | < 100 ms | M1 base |
| Throughput | > 20 tok/s | M1 base |
| Qualité FR sur prompt mail | continuation naturelle | — |
| Qualité code-switching | garde la langue dominante | — |

## Run 2 — `mlx-community/gemma-3-1b-pt-4bit` (base, RECOMMANDÉ) — référence historique

> **Note (14/06/2026) :** Le moteur de génération est désormais **llama.cpp (GGUF Metal)** exclusivement. MLX (`mlx-swift-examples`) n'est plus une dépendance du package. Les runs ci-dessous sont conservés comme référence historique de comparaison qualité/débit.

Modèle **base pretrained** (pas instruct) — entraîné uniquement à prédire le token suivant, sans biais conversationnel.

| Cas | TTFT | Débit | Suffixe |
|---|---|---|---|
| FR mail pro | 1929 ms (cold) | 37.3 tok/s | « suis désolée de ne pouvoir te donner le numéro de la chambre, mais je te le donnerai à la réservation » |
| EN slack | 82 ms | 38.2 tok/s | « be deploying to a new server soon, so we're going to be using the new server for the next few days » |
| FR/EN code-switching | 111 ms | 34.0 tok/s | « please tell me if it's ok to deploy it on the live server? » |
| FR note numérotée | 89 ms | 23.4 tok/s | « la mise en place de la plateforme de recrutement, (3) la mise en place de la plateforme de gestion des ressources » |

**Analyse qualité** :
- ✅ Toutes les complétions sont des **continuations grammaticales correctes**
- ✅ Bon FR (accord, conjugaison, registre)
- ✅ Code-switching propre : reste en EN après « can you »
- ✅ Continuation de liste numérotée : enchaîne sur « (3) »
- ⚠️ Contenu parfois off-topic (mentionne "chambre" sur un prompt de rdv) — c'est attendu pour un 1B, sera amélioré par contexte enrichi et profil utilisateur

**Performances** :
- TTFT après warmup : 82-111 ms ✅
- Throughput : 23-38 tok/s ✅ (cible >20)
- Premier inférence (cold) : ~1.9 s — attendu, sera mitigé par préchauffage au load

## Run 1 — `mlx-community/Llama-3.2-1B-Instruct-4bit` (REJETÉ) — référence historique

Modèle **instruct** fine-tuné chat. Performances brillantes, qualité catastrophique pour de l'autocomplete.

| Cas | TTFT | Débit | Comportement |
|---|---|---|---|
| FR mail pro | 2596 ms | 80.6 tok/s | ❌ Reset le texte avec « Bonjour! Je suis ravi... » |
| EN slack | 86 ms | 83.3 tok/s | ❌ Commente comme un chatbot « It sounds like you're... » |
| FR/EN code-switching | 78 ms | 81.4 tok/s | ❌ Bascule en français chatbot « Je serais ravi de vous aider! » |
| FR note numérotée | 114 ms | 79.7 tok/s | ❌ Génère un titre markdown « \*\*Réunion du 21 mai :\*\* » |

**Leçon retenue** : ne jamais utiliser un modèle Instruct pour de l'autocomplete inline. Le biais d'entraînement chat domine, même en mode prompt brut.

## Verdict défaut Souffleuse

**Modèle par défaut : `mlx-community/gemma-3-1b-pt-4bit`** (~520 MB).

- Aligné sur le défaut de Cotypist (décision #7 confirmée empiriquement)
- Qualité de continuation propre dans les 3 langues testées
- Performance largement au-dessus des cibles
- À tester prochainement : `mlx-community/Qwen2.5-1.5B-4bit` (base, plus gros) pour voir si on gagne en qualité contenu

## Trade-off Llama-Instruct vs Gemma-base

| Critère | Llama-Instruct | Gemma-base | Winner |
|---|---|---|---|
| Throughput pur | 80 tok/s | 35 tok/s | Llama |
| Continuation correcte | ❌ | ✅ | **Gemma** |
| FR naturel | ❌ | ✅ | **Gemma** |
| Code-switching | ❌ | ✅ | **Gemma** |
| **Verdict autocomplete** | inutilisable | utilisable | **Gemma** |

Le débit Gemma (35 tok/s) reste très confortable. Pour une suggestion « Medium » de 4 mots (~6 tokens) : ~170 ms après TTFT — instantané perçu.

## Prochaines mesures à faire

- Release build (vs Debug actuel) — gain attendu sur TTFT et throughput
- KV cache cross-frappe — réduire le TTFT en réutilisant le contexte
- Mémoire résident sous charge (cible 1.2 GB)
- Comparaison Gemma 3 1B vs Qwen 3 1.7B base sur même set

## Run 3 — A/B Enrichissement contextuel (Jalon 2.5.D) — référence historique

> **Note (14/06/2026) :** Ce bench utilisait `SouffleuseEnrichmentBench` (moteur MLX). Cette cible a été supprimée avec `mlx-swift-examples`. Les données ci-dessous sont conservées à titre de référence historique.

Bench `SouffleuseEnrichmentBench` — 20 cas, chaque prompt généré deux fois :
- (A) prompt utilisateur brut
- (B) `[App: …] [Window: …] [Clipboard: …] [Visible: …]\n[User text]: <prompt>`

Mesurés : sortie tronquée au premier `\n` (comme la prod), TTFT, latence totale, divergence Levenshtein normalisée entre A et B.

| Métrique | Valeur |
|---|---|
| Cas | 20 |
| Divergence moyenne (0=identique, 1=tout différent) | **0.64** |
| Δlatence moyenne (B − A) | **+304 ms** |
| Cas où B est vide | 0 / 20 |

**Détail par cas** (`div / Δlat_ms`) :

| # | Cas | div | Δlat |
|---|---|---|---|
| 1 | mail-reply-fr | — | — |
| 2 | slack-thread-en | 0.79 | +448 |
| 3 | note-meeting-fr | 0.75 | +348 |
| 4 | code-comment-en | 0.68 | +476 |
| 6 | calendar-fr | 0.27 | +436 |
| 7 | safari-article-fr | 0.77 | +384 |
| 8 | terminal-en | **0.00** | +481 |
| 9 | twitter-en | 0.72 | +421 |
| 10 | obsidian-fr | 0.71 | +513 |
| 11 | doc-spec-fr | 0.65 | +373 |
| 12 | reminders-fr | 0.77 | +546 |
| 13 | messages-fr | 0.95 | +415 |
| 14 | github-pr-en | 0.73 | +357 |
| 15 | linkedin-en | 0.62 | +335 |
| 16 | notion-en | 0.59 | +346 |
| 17 | discord-fr | 0.71 | +441 |
| 18 | figma-en | 0.64 | +370 |
| 19 | blank-context-fr | 0.75 | +221 |
| 20 | ambiguous-en | 0.65 | +200 |

**Interprétation**
- ✅ La divergence moyenne (0.64) confirme que l'enrichissement **change réellement la complétion** dans la majorité des cas — il n'est ni transparent ni ignoré par le modèle.
- ⚠️ Coût latence : **+304 ms** moyen (≈ doublement du temps total). Acceptable pour une UX où la suggestion arrive après une pause de frappe, à reconfirmer en session réelle.
- ⚠️ Cas `terminal-en` : div=0.00 — l'enrichissement n'a strictement aucun effet. Cohérent avec l'observation J2.5.B (OCR terminal dégradé) ; on devrait **blocklister les terminaux** côté visible-context.
- ⚠️ Cas `calendar-fr` : div=0.27 faible — possiblement parce que le visible context calendrier ne porte pas beaucoup d'information lexicale réutilisable.
- 📝 **Le bench mesure le mouvement, pas l'amélioration** — la métrique "+5pp acceptation" exige une session humaine de 30 min. À planifier avant de fermer Jalon 2.5.

**Décision provisoire** : enrichissement activé par défaut, capture d'écran opt-in. Réévaluer après une vraie session d'usage. Si la session humaine ne confirme pas le gain, candidat #1 à couper : OCR sur apps terminal/code, candidat #2 : capture sur calendrier/grille.

---

## Personnalisation Jalon 3.X — référence historique

> **Note (14/06/2026) :** Ce bench utilisait `SouffleuseEnrichmentBench` (moteur MLX, supprimé le 14/06/2026). Données conservées à titre de référence historique.

**Date** : 2026-05-22 (Jalon 3.X.D)
**Modèle** : `mlx-community/gemma-3-1b-pt-4bit` (défaut, MLX — historique)
**Bench** : `swift run SouffleuseEnrichmentBench --personalization-ab` (cible supprimée)

### Méthodologie

Le bench compare deux générations sur les mêmes 20 prompts du corpus FR/EN existant :
- **A — sans bias** : chemin stock, identique au shipping product avec `personalizationEnabled = false`.
- **B — avec bias** : n-gram model prépopulé en mémoire avec 12 phrases FR synthétiques recouvrant les tournures du corpus (formules de mail, action items, formules conversationnelles). `NgramLogitBias` strength = 1.5, chaîné avec `RepetitionContext`.

Métrique principale : **% de cas où la sortie biaisée diverge ≥5%** (proxy character-level) du baseline. C'est un substitut au "delta acceptation ≥ 5pp" demandé par le PLAN, qui exige une session humaine de plusieurs jours pour être validé proprement.

### Critère de validation

PLAN.md 3.X.D : **delta acceptation ≥ 5pp** en session utilisateur réelle (3 jours, 20+ mails). Le bench ici sert à valider que la mécanique fonctionne en CI — pas à mesurer l'amélioration UX qui demande de l'humain.

### Comment lancer

```bash
cd Souffleuse
swift run SouffleuseEnrichmentBench --personalization-ab > dist/bench-personalization-AB.jsonl
```

Sortie JSONL : `dist/bench-personalization-AB.jsonl` (une ligne par cas, fields `without_bias` / `with_bias` / `divergence` / `latency_delta_ms`).

### Résultats attendus

- **Divergence moyenne** : devrait être > 0 sur les cas FR alignés (mail-reply-fr, calendar-fr, doc-spec-fr, messages-fr, reminders-fr). Si proche de 0 partout → le bias ne touche pas le modèle, debug avant de valider la phase.
- **Latence delta** : devrait rester modeste (<50ms par cas) puisque le bias ne touche que 5-30 logits par step et n'évalue pas tout le vocab.
- **Critère go/no-go bench** : ≥ 30 % des cas avec divergence > 0.05. En-dessous, repenser la formule de bonus ou la prépopulation de l'historique.

### Verdict réel — 2026-05-22 (M2, Gemma 3 1B 4-bit)

```
cases:                  20
mean divergence:        0.50
cases where bias moved: 17 / 20 (85 %)
latency delta median:   ~50-80 ms / cas
```

Résultats bruts : `benchmarks/bench-personalization-AB-2026-05-22.jsonl` (20 lignes JSON).

**Go/no-go bench : largement validé.** Le seuil documenté était 30 % des cas avec divergence > 0.05 ; on est à 85 %. La mécanique LogitProcessor + chaînage avec repetition penalty fonctionne end-to-end.

**Exemple révélateur** (cas `mail-reply-fr`) :

| | Sans bias | Avec bias |
|---|---|---|
| Output | `remercie pour ton retour !` | `remercie pour ton message.` |
| Latence | 576 ms | 1066 ms |

Le corpus synthétique contenait "Bonjour Marie, je te confirme la réception du document." — le bias pousse vers les n-grammes connus tout en restant cohérent.

**Cas sans mouvement** (3/20) : `clipboard-url-fr`, `terminal-en`, `discord-fr`. Cohérent : aucune phrase du corpus synthétique n'aligne avec ces contextes (URL Apple, ligne de commande git, slang Discord FR/EN mixte), donc le bias n'a rien à voter. Pas un bug.

**Limitations connues** :
- Stdout pollué par des warnings `No chat template` (Gemma 1B base n'en a pas). Filtré via `grep '^{'` avant le commit. À fixer plus tard.
- Latence delta worst case 428 ms (`mail-reply-fr`, qui est aussi le cas avec le plus gros mouvement de bias). À surveiller en session humaine.
- `terminal-en` Δlat=166 ms sans divergence — le bias travaille à vide. Si ça se confirme en prod, ajouter un fast-path "no candidates → skip even the lookup".

**Reste à faire avant Jalon 3.X → 3.D** : session humaine 3 jours (≥ 20 mails) pour mesurer le **delta acceptation ≥ 5pp** demandé par le PLAN. Le bench valide la mécanique, pas le ressenti UX.

