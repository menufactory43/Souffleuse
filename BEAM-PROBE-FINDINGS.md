# BEAM-PROBE-FINDINGS — cœur beam « génération fraîche glissante »

> Rapport de la probe `SouffleuseBeamGhostProbe`. But : valider la ROBUSTESSE de la
> génération fraîche glissante (ghost multi-mots qui glisse en continu, s'arrête
> proprement aux fins de phrase, ne s'effondre jamais en plein milieu) et laisser à
> l'utilisateur des exemples lisibles pour trancher le ressenti FR.

## 1. Quoi / comment

La logique de mise en forme PURE du cœur beam a été extraite VERBATIM dans
`Souffleuse/Sources/SouffleuseCore/BeamGhostShaper.swift` (importable par une probe ;
le target exécutable `Souffleuse` ne l'est pas). `ModelRuntime.generateGhostBeam`
appelle désormais ce shaper — **comportement byte-identique** (vérifié par lecture +
les 727 tests verts dont 16 nouveaux sur le shaper).

Le shaper expose, en fonctions `nonisolated static` PURES :
- `beamMinSentenceLetters` (=3), `currentSentenceLetterCount`, `sentenceArmed` — **G2**.
- `beamConfigChoice(userTail:beamWidth:)` → `(requiredPrefix, width, isBoundary)` :
  mid-mot → `requiredPrefix=partial`, K plein ; frontière/après-espace → `""`, K=1.
- `promptSlots` / `buildPrompt` — prompt PROSE (`customInstr`+`ctxPrefix`+texte avant
  curseur), **sans** few-shot, **sans** `Champ:`, **sans** FIM.
- `beamPostFilter` — singleLine, dédup mot répété, séparateur d'espace, écho
  positionnel, **coupe-clause INCLUSIVE** (`.!?;:\n`), word-cap.

La probe reproduit EXACTEMENT le pipeline par préfixe :
`G2 → beamConfigChoice → buildPrompt → beam.ghost(maxWidth) → beamPostFilter`.
Elle charge `BeamGhostEngine(config: .ghostCore())` sur le GGUF résolu, **sans réseau,
sans `TypingHistoryStore`, sans Keychain, sans corpus** (perso OFF). À chaque préfixe
croissant elle régénère une fenêtre de quelques mots DEPUIS tout le texte tapé.

## 2. Commande pour lancer la probe

```bash
cd /Users/gabrielwaltio/cocotypist-beam-core/Souffleuse

# Run normal (trace par préfixe + résumé), char-par-char :
swift run -c release SouffleuseBeamGhostProbe

# Résumé seul (rapide à lire), char-par-char :
PROBE_VERBOSE=0 swift run -c release SouffleuseBeamGhostProbe

# Balayage des knobs (exp × maxWords) sur 4 phrases représentatives :
PROBE_SWEEP=1 PROBE_STEP=4 swift run -c release SouffleuseBeamGhostProbe
```

Env (tous optionnels) :
- `SOUFFLEUSE_GGUF` — chemin GGUF (sinon : dossier Souffleuse → dossier Cotypist).
- `SOUFFLEUSE_BEAM_EXP` (Double) / `SOUFFLEUSE_BEAM_K` (Int) — lus par `BeamConfig.ghostCore()`.
- `PROBE_MAXWORDS` (défaut 4), `PROBE_MIN_LETTERS` (G2, défaut 3), `PROBE_STEP` (défaut 1).
- `PROBE_BOUNDARY_WIDTH` (défaut 1) — DIAGNOSTIC : largeur beam aux après-espace.
- `PROBE_SWEEP=1`, `PROBE_VERBOSE=0`.

## 3. Résultat de référence (K=3, exp=0.7, maxWords=4, char-par-char)

6 scénarios FR (email pro, salutation, chat familier, support fiscalité,
multi-phrases), **438 préfixes** :

| métrique | valeur |
|---|---|
| ghost non vide | **395/438 (90 %)** |
| dont silences G2 légitimes (après un point) | 36 |
| longueur moyenne du ghost | **3,25 mots** |
| latence moyenne / max | **177 / 896 ms** |
| régressions « dépasse-fin-phrase » | **0** |
| régressions « vide-mid-phrase » | **7** (≈ 1,6 %) |

→ Le ghost GLISSE bien (reconditionné à chaque frappe sur tout le texte tapé),
s'arrête PROPREMENT aux fins de phrase (0 dépassement de `.!?` au milieu), et G2 fait
correctement silence après un point (36 silences = reprise après le terminateur).

Exemples (phrase #0, registre email pro — le ghost suit la frappe et glisse) :

```
"Je vous confir"   → "me qu'il n'y a"
"Je vous confirme" → " que le problème est"
"Je vous confirme la" → " bonne nouvelle."     ← s'arrête au point (coupe-clause)
```

## 4. Balayage des knobs (exp × maxWords, 4 phrases, pas=4)

| exp | maxWords | non-vide | mots/ghost | lat moy/max (ms) | régressions |
|---|---|---|---|---|---|
| 0.5 | 3 | 97 % | 2,5 | 104 / 427 | 1 |
| 0.5 | 4 | 97 % | 3,2 | 117 / 523 | 1 |
| 0.5 | 5 | 97 % | 3,7 | 145 / 648 | 1 |
| 0.7 | 3 | 97 % | 2,5 | 100 / 432 | 1 |
| **0.7** | **4** | **97 %** | **3,2** | **118 / 538** | **1** |
| 0.7 | 5 | 97 % | 3,7 | 146 / 656 | 1 |
| 1.0 | 3 | 97 % | 2,6 | 100 / 424 | 1 |
| 1.0 | 4 | 97 % | 3,2 | 122 / 549 | 1 |
| 1.0 | 5 | 97 % | 3,9 | 155 / 675 | 1 |

Lecture :
- **`positionExponent` (0.5/0.7/1.0) n'a quasi aucun effet sur couverture/robustesse
  ni latence** — il ne joue que sur le RANKING (donc le « ressenti » du choix de
  continuation), pas sur le taux de ghost ou les régressions. À trancher au ressenti.
- **`maxWords` est un curseur linéaire longueur ↔ latence** : 3 mots = ghost plus
  court, ~100 ms ; 5 mots = plus long, ~150 ms moy. 4 est l'entre-deux (≈3,2 mots
  réels après coupe-clause, 118 ms).

## 5. Reco de réglage par défaut

**Garder le défaut de prod : `positionExponent = 0.7`, `maxWords = 4`, K = 3,
après-espace K = 1, `beamMinSentenceLetters = 3`.** Justification :
- exp n'affecte pas la robustesse → 0.7 (length-norm classique, façon GNMT) reste un
  choix neutre ; le balayage donne à l'utilisateur de quoi préférer 0.5 ou 1.0 **au
  ressenti** sans risque de régression chiffrée.
- maxWords 4 ≈ 3,2 mots affichés, latence moyenne ~118-177 ms (sous le plancher
  cascade) — bon compromis longueur/vitesse.
- K=1 après-espace = fidèle au handoff §e (le beam n'aide pas après-espace, K>1 y PERD
  en cohérence) — confirmé ci-dessous.

## 6. Régressions résiduelles (fragiles, à connaître)

Les **7 `vide-mid-phrase`** (1,6 %) restantes se concentrent toutes près des
**frontières / fragments courts** :

```
"…lité du produit pour la livrai" → ""   (mid-mot court "livrai")
"Bonjour Madame,"                 → ""   (juste après une virgule)
"Bonjour Madame, "                → ""   (après-espace)
"Bonjour Madame, sui"             → ""   (mid-mot court "sui")
"Bonjour Madame, suite à notre"   → ""   (fin de mot "notre")
"Bonjour Madame, suite à notre "  → ""   (après-espace)
"On se voit demain deva"          → ""   (mid-mot court "deva")
```

Diagnostic : ce sont des cas **après-espace K=1** (décode libre qui rend un candidat
vide/blanc filtré) ou des **fragments mid-mot très courts** où le base 1B dérive
(parfois vers une autre langue — cf. « Je vo » → indonésien) et le post-filtre (écho /
dédup) coupe à vide. **C'est le comportement FIDÈLE de prod** (`generateGhostBeam` rend
`best?.ghost ?? ""`), pas un bug introduit par l'extraction.

Levier mesuré (DIAGNOSTIC, **non activé en prod**) : `PROBE_BOUNDARY_WIDTH=3` élargit
le beam aux après-espace →

| boundaryW | non-vide | mots/ghost | lat moy/max | vide-mid-phrase |
|---|---|---|---|---|
| 1 (prod) | 90 % | 3,25 | 177 / 896 | **7** |
| 3 | 91 % | 3,17 | 285 / 786 | **3** |

→ Élargir l'après-espace à K=3 **réduit les empties de 7 à 3** mais **+108 ms de
latence moyenne** ET **contredit la preuve du handoff** (K>1 après-espace perd en
cohérence). **Non recommandé par défaut** : la couche `routeInstant` (rappel /
lexique / perso), DEVANT le beam en prod, est précisément censée couvrir l'après-espace
— elle est OFF dans la probe (LLM pur), donc l'écart réel en usage est plus favorable
que ces 1,6 %. Si l'utilisateur juge au ressenti que les trous après-virgule gênent, le
knob existe (`PROBE_BOUNDARY_WIDTH`) pour rejouer la comparaison ; le câbler en prod
serait un petit changement local dans `beamConfigChoice` (largeur frontière).

## 7. Ce qui marche / ce qui reste fragile

**Marche** :
- Extraction shaper byte-identique (727 tests verts, audit OK, build OK).
- Ghost qui glisse en continu, reconditionné sur tout le texte tapé.
- Arrêt propre aux fins de phrase : **0 dépassement de `.!?`** au milieu.
- G2 : silence après un point, reprise dès 3 lettres (36 silences corrects / 438).
- Latence viable : 177 ms moyenne char-par-char, sous le plancher cascade.

**Fragile (à juger au ressenti, pas une régression d'extraction)** :
- ~1,6 % de ghosts vides en plein milieu, tous aux frontières / fragments courts ;
  inhérent au décode libre K=1 après-espace et à la dérive du base 1B sur 1-3 lettres.
  En prod, `routeInstant` (perso/recall, OFF dans la probe) atténue ces cas.
- Dérive linguistique du base 1B sur fragments très courts (« Je vo » → autre langue) —
  c'est le modèle, pas le pipeline ; mitigé par l'écho-guard et la coupe-clause.

## 8. Pour rejouer / juger (utilisateur)

```bash
cd /Users/gabrielwaltio/cocotypist-beam-core/Souffleuse
# Trace lisible char-par-char (préfixe | ghost | ms) + résumé :
swift run -c release SouffleuseBeamGhostProbe
# Comparer un autre exposant au ressenti :
SOUFFLEUSE_BEAM_EXP=0.5 swift run -c release SouffleuseBeamGhostProbe
# Tester l'effet d'un beam plus large après-espace (latence ↑, empties ↓) :
PROBE_BOUNDARY_WIDTH=3 PROBE_VERBOSE=0 swift run -c release SouffleuseBeamGhostProbe
```

L'app live n'a PAS été touchée (aucun process tué, aucune signature). Tout est
flag-gaté `SOUFFLEUSE_BEAM_CORE` ; sans le flag, le comportement est byte-identique.
