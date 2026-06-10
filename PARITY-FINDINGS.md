# PARITY-FINDINGS — qualité & latence du ghost, mesurées (branche `feat/ghost-parity-metrics`)

> Rapport de `SouffleuseParityEval`. But : répondre à « comment mesurer la cohérence
> des ghosts » avec LA métrique de parité Cotypist — **le mot juste avec le moins de
> lettres tapées possible** — plus stabilité mid-mot, économies de frappes et latence.

## 1. Méthode

15 phrases FR (email pro, chat, support, technique, narratif) rejouées **caractère
par caractère** ; la phrase complète est la vérité terrain (ce que l'utilisateur
*veut* taper). À chaque frappe, le ghost est généré par le pipeline FIDÈLE de prod
(corpus OFF, perso OFF, contexte vide — couche LLM pure) :

- **cascade** (flag OFF) — miroir verbatim de `ModelRuntime.midWordLongGhost`
  (greedy healed + engagement + plancher dico + garde écho), flags
  `MW_ENGAGEMENT=1 MW_ENG_PRUDENT=0 MW_ENG_PLEIN=0.8`.
- **beam-core** (flag `SOUFFLEUSE_BEAM_CORE` ON) — pipeline exact de
  `ModelRuntime.generateGhostBeam` via `BeamGhostShaper` (G2 → beamConfigChoice →
  buildPrompt → beam.ghost → beamPostFilter), K=3, exp=0.7, maxWords=4.
- **beam-core + routage forcé** (DIAGNOSTIC, `PARITY_BEAM_MIDWORD=force`, éval
  seulement) — idem, mais tout partiel non vide garde `requiredPrefix` + K plein
  (le juge « mot complet » ne peut plus céder la contrainte). Mesure le **plafond
  d'un fix de routage**, sans toucher la prod.

Métriques (juge strict : le ghost doit être insérable VERBATIM au caret) :
- **KTC** (keystrokes-to-correct) : par mot (≥3 lettres, hors 1ᵉʳ mot de phrase —
  G2 silencie <3 lettres), à combien de lettres tapées le ghost donne la suite
  EXACTE du mot.
- **Économies** : utilisateur parfait, Tab = 1 frappe ; full-accept (tout le ghost
  juste) et word-accept (plus long préfixe de mots entiers justes).
- **Stabilité** : un ghost juste à k lettres l'est-il encore à k+1 (anti-flicker) ;
  glissement cohérent quand la lettre tapée == tête du ghost.
- **Latence** : par frappe, mid-mot vs frontière (à froid, sans le reuse HIT).

```bash
cd Souffleuse
MW_ENGAGEMENT=1 MW_ENG_PRUDENT=0 MW_ENG_PLEIN=0.8 swift run -c release SouffleuseParityEval
PARITY_ENGINE=beam PARITY_BEAM_MIDWORD=force swift run -c release SouffleuseParityEval
```

## 2. Scorecard (1087 frappes jugées par moteur, 123 mots KTC)

| métrique | cascade | beam-core (prod) | beam + routage forcé |
|---|---|---|---|
| **KTC — ghost juste à ≤1 lettre** | 4 % | 0 % | **55 %** |
| **KTC — ≤2 lettres** | 18 % | 11 % | **77 %** |
| **KTC — ≤3 lettres** | 41 % | 35 % | **85 %** |
| **KTC — ≤4 lettres** | 64 % | 59 % | **92 %** |
| jamais juste sur le mot | 25 % | 25 % | **7 %** |
| lettres nécessaires (médiane) | 3 | 4 | **1** |
| mot entier deviné à 0 lettre (après-espace) | 32 % | 31 % | 31 % |
| frappes économisées (full-accept) | 23 % | 12 % | 16 % |
| frappes économisées (word-accept) | 42 % | 41 % | **52 %** |
| ghost juste qui le RESTE à k+1 | 70 % | 66 % | **100 %** |
| glissement cohérent | 65 % | 64 % | **86 %** |
| couverture (ghost non vide) | 99 % | 95 % | 95 % |
| latence p50 / p95 (ms) | 204 / 510 | **83 / 292** | 209 / 433 |
| latence mid-mot p50 | 309 | 208 | 225 |
| latence frontière p50 | 201 | 75 | 75 |

## 3. Lecture

1. **Beam-core tel que câblé aujourd'hui** : latence ÷2 vs cascade (p50 83 vs
   204 ms) mais **qualité légèrement DERRIÈRE** la cascade sur le mot juste
   (médiane 4 lettres vs 3). Ça contredit l'IntentionEval du handoff (beam 63-86 %
   hit@1 mid-mot) — voir le défaut ci-dessous.
2. **Le défaut (trouvé et quantifié)** : `beamConfigChoice` cède la contrainte
   `requiredPrefix` dès que `defaultPartialWordIsComplete` (= `isValidWord`,
   permissif FR+EN) juge le fragment « mot complet ». Or il accepte « d », « l »,
   « v », « vo », « co », « dispo »… → **451/1087 frappes (~41 %) réellement
   mid-mot partent en décode libre K=1**, et `beamPostFilter` y force un espace
   de tête qui casse les recollages (`"…mardi proc" → " édure de…"`,
   `"Je vo" → dérive néerlandaise`). La cascade a le même routage mais s'en sort
   mieux : son splice `modelGlued` recolle le mot quand le greedy le complète.
   L'IntentionEval ne l'a jamais vu parce qu'il appliquait TOUJOURS
   `requiredPrefix` — le défaut est dans le câblage prod, pas dans le moteur.
3. **Avec le routage forcé, le beam ÉCRASE tout** : mot juste dès **1 lettre dans
   55 % des cas**, 85 % à 3 lettres, **médiane 1 lettre** (vs 3 cascade), seulement
   7 % de mots jamais trouvés, et **stabilité 100 %** (un ghost juste ne flicke
   plus jamais). C'est le profil Cotypist : trouver le mot juste avec le moins de
   lettres possible et s'y tenir.
4. **Latence du fix** : mid-mot repasse en beam K=3 partout → p50 209 ms à froid,
   ≈ la cascade actuelle, p95 433 < cascade 510. Et ce chiffre est **pessimiste** :
   l'éval régénère à chaque frappe, alors que la prod a la réserve/`advance`
   (88 % de HIT à ~0 ms, cf. SouffleuseBeamAmortizedEval) — en frappe réelle la
   majorité des frappes sont des avancées de pointeur.
5. Le full-accept (12-23 %) est bas pour tous : le ghost multi-mots dévie souvent
   après le mot courant — c'est le word-accept (41-52 %) qui reflète l'usage réel
   (partial-accept / accept-puis-continue).

## 4. Fix appliqué et VÉRIFIÉ (commit `1020f92`)

`BeamGhostShaper.beamConfigChoice` ne cède plus la contrainte au juge « mot
complet » : tout partiel non vide → `requiredPrefix=partial`, K plein ; K=1
réservé au VRAI après-espace (partiel vide). Corollaire automatique : l'espace
forcé de `beamPostFilter` (`isBoundary && !caretAfterSpace`) ne s'applique plus
à ces cas. Chemin actif uniquement sous `SOUFFLEUSE_BEAM_CORE` — sans flag,
comportement byte-identique.

**Vérification** :
- Re-run de l'éval sur le pipeline PROD corrigé (`/tmp/parity-eval-fixed.txt`) :
  chiffres IDENTIQUES au diagnostic forcé — mot juste à ≤1 lettre **55 %**,
  ≤3 lettres **85 %**, médiane **1 lettre**, jamais juste **7 %**, stabilité
  k→k+1 **100 %**, glissement cohérent **86 %**, word-accept **52 %**, latence
  p50/p95 **209/440 ms** à froid.
- **729 tests verts** (727 + 2 nouveaux verrouillant le routage :
  `config_dicoValidFragmentStaysConstrained`, `config_completeWordKeepsConstraintToo`).
- **`audit.sh` PASSED**.

Risque résiduel surveillé : les fins de mot réelles (« la », « de » tapés en
entier, mot suivant à deviner) restent bien servies — le beam contraint peut
terminer le mot par un espace (couverture 95 %, après-espace inchangé 31 %).
À confirmer au ressenti en frappe réelle (`SOUFFLEUSE_BEAM_CORE=1`).

## 5. Optimisation latence −42 % (workflow `ghost-latency-minus-30`, commit suivant)

Objectif : latence −30 % minimum en perdant ≤5 % de validité. Deux configs de
knobs testées séquentiellement (GPU exclusif), mêmes 1087 frappes :

| config | lat moy/p50/p95 | KTC ≤1/≤3 | jamais | word-accept | couverture |
|---|---|---|---|---|---|
| K=3 · tok14 · mots4 (baseline) | 216 / 209 / 440 | 55 / 85 % | 7 % | 52 % | 95 % |
| C1 : K=2 · tok11 · mots4 | 156 / 149 / 283 | 56 / 82 % | 7 % | 53 % | 95 % |
| **C2 : K=2 · tok12 · mots3 (retenue)** | **125 / 114 / 229** | **58 / 82 %** | 8 % | 51 % | 95 % |

**C2 = nouveau `ghostCoreDefault`** : latence **−42 %** (216→125 ms moy,
p95 440→229), KTC≤3 −3,5 % relatif (85→82), word-accept −1,9 % (52→51) — dans
le budget de 5 % — et le hit à 1 lettre MONTE de 3 pts (58 %) : moins de
branches = moins de candidats exotiques en tête du ranking. Overrides env
toujours disponibles (`SOUFFLEUSE_BEAM_K/MAXTOK/MAXWORDS/EXP`).

**Diagnostic moteur** (agent d'analyse, BeamGhostEngine lu en entier) : le
decode par étape EST bien batché en un seul `llama_decode` ; le ×3 de K=3 vs
K=1 vient de (1) plus d'étapes (les K branches ne s'arrêtent pas ensemble),
(2) softmax CPU scalaire O(262k) PAR branche et PAR étape, (3) lm_head ×K
lignes, (4) overhead batch/étape.

## 6. Les trois leviers suivants — implémentés, mesurés, tranchés

| levier | verdict | mesure |
|---|---|---|
| Softmax vectorisé Accelerate | **REJETÉ** | A/B neutre : 134/127 vs 133/125 ms — l'expf est déjà masqué par le GPU. Pas de complexité sans gain. |
| **Prefix-caching KV du prompt** (commit `4d15e6e`) | **ADOPTÉ** (toujours actif) | ctx long (~210 tok, `PARITY_LONGCTX=1`) : 242→97 ms (−60 %) ; ctx court : −13/−18 %. Ghosts **byte-identiques** (289 frappes, 0 diff). |
| **Réserve advance** (commit `049c1fe`, flag `SOUFFLEUSE_BEAM_RESERVE`) | **ADOPTÉ** (flag-gaté) | voir tableau ci-dessous. |
| maxTokens 12→8 (`SOUFFLEUSE_BEAM_MAXTOK=8`, éval 3 du handoff latence) | **REJETÉ** | A/B 2026-06-10 (15 phrases, 1087 frappes) : scorecards **identiques au pour-cent près** (KTC ≤1 58 %, ≤3 82 %, accepts 23/94, stabilité 100 %) et AUCUN gain de latence (p50 92 vs 104 ms, bruit d'ordre de passage). Les candidats terminent naturellement avant 8 tokens (`maxWords=3` + branches finies) : le cap ne mord jamais. Sanity check `MAXTOK=2` : p50 47 ms et métriques différentes — la variable est bien lue, le levier est juste mort. Le « seed décode 104→70 ms » espéré n'existe pas. |

**Réserve — frais vs réserve (15 phrases, 1087 frappes)** :

| métrique | frais (prefix-cache) | réserve |
|---|---|---|
| latence moy / p50 / p95 | 106 / 91 / 218 | **44 / 0 / 164** |
| ventilation | — | HIT 54 % à 0 ms · refill 18 % à 87 ms · miss 19 % à 101 ms · seed 2 % |
| KTC ≤1 / ≤3 lettres | 58 / 82 % | **59 / 84 %** |
| jamais juste | 8 % | 7 % |
| stabilité k→k+1 | 100 % | 100 % |
| word-accept | 51 % | 49 % (−3,9 % rel) |
| mot entier deviné à 0 lettre (après-espace) | 31 % | **14 %** ← seul recul |
| couverture | 95 % | 94 % |

Le « 13 % de HIT » historique (cause de l'abandon en `0dd276b`) était un
artefact du routage cassé : post-fix, le taux vérité-terrain est 76 % (43 %
avant fix) et la machinerie en délivre 54 % de HIT purs + 18 % de refills.
Le seul recul réel est le mot-suivant après-espace (la branche survivante
traverse l'espace au lieu d'un re-décode frais) — si le ressenti le confirme,
un re-seed forcé à la frappe d'espace est un petit changement local (coût :
l'espace repasse à ~100 ms, les lettres restent à 0).

**Trajectoire latence complète** (1087 frappes, vérité terrain) :
216 ms (K=3, avant) → 125 (K=2·tok12·mots3) → 106 (prefix-cache KV) →
**44 ms moyenne, p50 0 ms** (réserve). p95 : 440 → 164 ms.

**Pour tester au clavier** :
```bash
launchctl setenv SOUFFLEUSE_BEAM_CORE 1
launchctl setenv SOUFFLEUSE_BEAM_RESERVE 1
open Souffleuse/build/Build/Products/Release/Souffleuse.app   # rebuild requis
```

## 7. Artefacts

- Rapport prod : `/tmp/parity-eval-report.txt` · JSONL par frappe : `/tmp/parity-eval.jsonl`
- Rapport diag : `/tmp/parity-eval-beamfix.txt` · JSONL : `/tmp/parity-eval-beamfix.jsonl`
- Eval : `Souffleuse/Sources/SouffleuseParityEval/main.swift` (cette branche)
