# Ghost — constats, stratégie & tickets (session 2026-06-05)

> Issu d'une session de debug du « ghost vivant ». La branche `worktree-ghost-living`
> a été abandonnée (bruit : 18 commits d'expériences + patches non prouvés). Tout ce
> qui compte est ici, et s'applique **sur `main`, modèle inchangé**.

## Constats PROUVÉS (probes headless objectives, même modèle que Cotypist)

1. **Modèle = identique à Cotypist.** GGUF `general.name = "Gemma 3 1b Pt"` (base/pt, Q5),
   fichier partagé dans `app.cotypist.Cotypist/Models/`. → **Le modèle n'est PAS le levier.**

2. **L'injection de contexte actuelle est nuisible.** Souffleuse colle les métadonnées
   app/fenêtre en préambule prose (`App Intercom, window "…"`) → le base model les
   **RECOPIE** en sortie (« boîte de réception » parachuté). Inutile + fuite.

3. **Le bon contexte = la CONVERSATION, et ça marche.** Mettre l'entité associée dans le
   texte rend le bon mot **atteignable** : « Elon Musk » plus haut ⇒ logprob de « Tesla »
   passe de **−13.4 à −4.2** (effet positif sur les 6 cas testés).

4. **Le LLM ne peut PAS produire les marques métier.** « Walt » → le modèle lit
   « Walt **Disney** ». « Waltio », « formulaire 2086 » ne sont pas dans son training.

5. **Le biais n-gram perso ne fait atterrir aucun terme métier.** Δlogprob = 0 sur tous
   les cas (mi-mot ET frontière de mot), greedy identique froid/chaud. ⚠️ à re-vérifier
   qu'il marche tout court — mais ce n'est PAS l'outil pour les marques.

6. **L'affichage jette les ghosts.** ~80 % de ghosts cohérents en headless (replay) vs
   ~16 % réellement peints en live (cancel-on-keystroke + streaming de moignons).

## Vérif code (état actuel sur `main`)

- **La conversation n'est PAS captée.** `EnrichedContext` n'a que `app / windowTitle /
  clipboard / visible(OCR)` (`SouffleuseContext/ContextEnricher.swift:6-44`). Le message
  du client ne pourrait venir que de l'OCR `visible`, **OFF par défaut** (`captureEnabled
  = false`). Le titre de fenêtre injecté ≠ contenu du message.

## STRATÉGIE (deux outils, deux jobs)

| Quoi | Outil | Pourquoi |
|---|---|---|
| Marques/jargon (Waltio, 2086, cessions, Binance, Ledger, CSV…) | **Lexique déterministe** (termes de l'user, complétion par préfixe exact) | Le LLM en est incapable (constat #4) |
| Tournure de phrase | **LLM amorcé par la CONVERSATION** (msg du client), en transcript naturel | Prouvé pertinent (constat #3) |
| Métadonnées app/fenêtre | **Supprimer du prompt** | Elles fuient (constat #2) |
| Affichage | Montrer le ghost **complet** et le garder visible pendant la regénération | Sinon moignons (constat #6) |

## TICKETS (sur `main`, par ordre)

### Ticket #0 — KEYSTONE à valider AVANT de coder
Le lexique L0 (`learnedLexicon`, ex. « Bin »→« Binance ») complète-t-il « Walt »→« Waltio »
sur les termes métier de l'user ? Vérifier : (a) les marques entrent-elles dans le lexique
depuis l'historique de frappe ? (b) la porte mi-mot laisse-t-elle L0 tirer ? Si oui, la
stratégie tient. Si non, c'est LÀ qu'est le vrai travail.

### Ticket #1 — Amorcer le LLM par la conversation (double chantier)
1. **Capter** le message du client : AX du fil de discussion (pas seulement l'élément
   focus = champ de réponse), ou OCR **ciblé sur la zone message** (pas tout l'écran).
2. L'injecter en **transcript naturel** (`Client : … ⏎ <ta réponse>`), **PAS** en
   préambule « On screen: … » qui fuit. Couper l'écho de rôle (Souffleuse trim déjà
   single-line + frontière de clause).
3. **Retirer** les métadonnées app/fenêtre du prompt (constat #2).

### Ticket #2 — Affichage : ghost complet & persistant — ❌ REJETÉ (décision produit 12/06)
Montrer le ghost **complet** (pas un moignon de 1 token streamé) et le **garder visible**
pendant qu'on regénère le suivant (au lieu de cacher l'overlay → « rien jusqu'à la pause »).
Cf. analyse cancel-on-keystroke (constat #6).

**REJETÉ le 12/06/2026** : garder l'ancien ghost pendant la régénération =
afficher un ghost calculé pour un AUTRE préfixe, donc potentiellement faux —
contraire au Core Value (justesse > présence). Le « trou visuel » de ~100 ms
pendant le décodage est le prix assumé. La moitié « moignons » du ticket est de
toute façon résolue par le beam one-shot ; la moitié « persistant » ne sera PAS
faite. Ne pas re-litiguer.

## MÉTHODE (comment itérer — ne PAS refaire l'erreur)
Tester **headless + objectif** (probe `SouffleuseLlamaProbe` : `engine.generate` /
`engine.sequenceLogProb`, même modèle), **une variable à la fois**. Le live à l'œil =
piège (on a tourné en rond des heures). La cible idéale : ~8 exemples (préfixe → ghost
Cotypist) comme gold standard.

## Artefacts de la session
- Patch des changements de la branche (renderableGhost, fix persona, MW_STREAM_MIN, knobs
  prompt) : `/tmp/ghost-living-uncommitted.patch` (`git apply` si besoin d'un bout).
- Sorties des probes : `/tmp/ghost-eval/` (reach-probe, strategy-probe, ctx-probe…).
