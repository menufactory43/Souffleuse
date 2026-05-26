# Correction de préfixe + raffinage prompt FIM — pertinence du ghost

Objectif: améliorer à quel point le ghost "tombe juste", sans toucher au moteur.
Deux volets — (1) correction de préfixe (must-have, impact net), (2) raffinage léger
de l'assemblage du prompt FIM (secondaire, ne pas régresser).

## Volet 1 — Correction de préfixe (correctedPrefix de Cotypist)

Idée: corriger SILENCIEUSEMENT les fautes du texte envoyé au modèle, pour qu'il
complète à partir d'un préfixe propre. L'utilisateur voit toujours son texte d'origine ;
seule l'ENTRÉE du modèle (le `beforeCursor` du prompt) est corrigée. Le ghost (la
continuation) s'en trouve plus pertinent.

Exemple: "Je vous écirs pour vou" → modèle reçoit "Je vous écris pour vous" → ghost
"informer que…" au lieu d'un truc incohérent bâti sur "écirs/vou".

### Règles de conservatisme (CRITIQUE — une correction trop agressive nuit)
- N'utiliser que le `TypoDetector` existant (NSSpellChecker, SouffleuseTyping) — pas de
  nouvelle dépendance.
- **Respecter la langue détectée** (on a déjà `detectLanguage` + sticky). Corriger dans
  la bonne langue, jamais forcer une correction cross-langue.
- **Ne JAMAIS toucher le dernier token (mot en cours de frappe au caret).** La complétion
  du mot en cours, c'est le job de `WordCompleter`. On ne corrige que les mots COMPLÉTÉS
  en amont (suivis d'un espace/ponctuation).
- Ne corriger qu'au-dessus du seuil de confiance du TypoDetector (Levenshtein ≤ max,
  longueur ≥ min). En cas de doute, laisser tel quel.
- Ne pas corriger dans des contextes non-prose: champs secure, code, URLs, identifiants
  (réutiliser les gates existants: secure field, bundle/allowlist, SecretHeuristic).
- **Invisible**: ne modifie QUE le `beforeCursor` passé à `buildLlamaPrompt`. `userTail`
  (utilisé pour `stripPrefixOverlap`/anti-repeat/affichage) reste le texte RÉEL tapé.
- Derrière un toggle Préférences (réutiliser le pattern PreferencesStore.K), activé par
  défaut, désactivable.

### Pièges
- Le pipeline de filtres (`OutputFilter.stripPrefixOverlap(generated, prefix: userTail)`)
  compare le ghost au texte réel. Comme la correction ne change que l'orthographe de mots
  en amont (pas le dernier token, pas la longueur globale de façon notable), la
  continuation reste alignée. Vérifier qu'on ne casse pas l'anti-repeat.
- Coût: la correction doit être cheap (quelques mots de la fin du préfixe, pas tout le
  contexte). Borner à la dernière phrase / ~N derniers mots.
- KV cache: corriger le préfixe change les tokens → le LCP avec le KV précédent reste
  valide tant que la correction est stable entre frappes (un mot corrigé reste corrigé).
  OK, pas d'action spéciale.

## Volet 2 — Raffinage assemblage prompt FIM (léger, ne pas régresser)

État: `ModelRuntime.buildLlamaPrompt` assemble system + customInstr + ctxPrefix +
fieldContext + afterCursor + beforeCursor (v1 "simple"). Améliorations mesurées:
- Clarifier l'ordre/formulation pour que le 1B distingue bien CONTEXTE (à ne pas répéter)
  de TEXTE-À-CONTINUER. Éviter toute fuite de label dans le ghost (déjà un risque traité).
- S'assurer que le steering de langue (déjà dans `system`) est bien en tête.
- Garder `afterCursor` comme contexte FIM non répété.
- NE PAS réintroduire d'exemples few-shot (prouvé nuisible).
Tout changement ici doit être validé par éval avant/après — si pas d'amélioration nette,
on garde la v1.

## Vérification
- Build + tests verts, audit vert, overlay/input/AX intacts.
- Tests unitaires correction: "écirs"→"écris" corrigé dans beforeCursor; dernier token en
  cours JAMAIS corrigé; langue respectée; toggle off = identité.
- Probe avant/après sur 2-3 phrases avec fautes: montrer ghost incohérent (préfixe brut)
  vs ghost pertinent (préfixe corrigé), sortie réelle pastée.
- Confirmer userTail (affichage/anti-repeat) inchangé.
