# Replay Results — Phase 1 Hypothesis Validation

**Generated:** 2026-05-26T07:18:34Z
**Model:** mlx-community/gemma-3-1b-pt-8bit
**Scenarios:** 15
**Founding hypothesis under test:** « le ghost junk vient du prompt pauvre, pas du modèle ».

Pour chaque scénario : le ghost produit SANS contexte (`contextPrefix=""`)
vs AVEC contexte (`contextPrefix` du scénario). Eyeball verdict : ✓ si
avec-contexte est plus pertinent, = si neutre, ✗ si moins pertinent.

> **Caveat — système prompt** (W5) : le system prompt utilisé en replay
> est une version simplifiée (`"You are an inline autocomplete. Continue
> the user's text naturally."`) — la version production passe par
> `PredictorViewModel.buildSystemPrompt(detectedLanguage:)` qui injecte
> la langue détectée et un framing plus riche. Le verdict porte donc sur
> l'EFFET DU `contextPrefix` (with vs without), pas sur la parité prompt
> complète production.

> **Caveat — paramètres génération** (W6) : `temperature=0`, `topP=0.9`,
> `repetitionPenalty=1.0`, `maxTokens=12`. Peuvent différer des prefs
> runtime utilisateur (qui modulent `maxTokens` via la pref "Court /
> Moyen / Long").

---
## Confusion Matrix (D-12)

Rows: human-annotated `expectedCategory`. Columns: `classifyReplayGhost` actual.
Scenarios with no `expectedCategory` (or `skip`) are excluded from the rows but
still contribute to the per-scenario detail table below.

| expected \ actual | correct | acceptable | useless | bad | total |
|--------------------|---------|------------|---------|-----|-------|
| **expected: correct** | 0 | 0 | 0 | 0 | 0 |
| **expected: acceptable** | 0 | 0 | 6 | 0 | 6 |
| **expected: useless** | 0 | 0 | 0 | 0 | 0 |
| **expected: bad** | 0 | 0 | 0 | 0 | 0 |
| **total**          | 0 | 0 | 6 | 0 | 15 |

### Release gate D-11 (simulated on replay — parasite untestable in single-pass)

- ✗ correct/total ≥ 30% → 0/15 = 0.0%
- ✗ (useless+bad)/total ≤ 35% → 6/15 = 40.0%
- parasite/total ≤ 5% — untestable in single-pass replay (live production only)

---


## 1. [slack-empty-channel] Slack: empty message in channel #equipe-produit

- **bundleID:** `com.tinyspeck.slackmacgap`
- **windowTitle:** `Slack — #equipe-produit`
- **userTail:** ``
- **notes:** Cold start — champ vide, contexte de canal visible. Sans contexte: ghost générique "Coucou !". Avec contexte: devrait proposer une réponse liée à la demande Carrefour.
- **expectedCategory:** —
- **expectedGhostPrefix:** —
- **actual category (D-12):** skip

| Variant | Ghost | Actual category |
|---------|-------|-----------------|
| **WITHOUT context** | `` | — |
| **WITH context**    | `` | skip |

**Verdict:** [ ] ✓ with-context better  [ ] = neutral  [ ] ✗ with-context worse

**Human note:** _(fill in)_

---

## 2. [slack-reply-mid] Slack: réponse en cours après salutation

- **bundleID:** `com.tinyspeck.slackmacgap`
- **windowTitle:** `Slack — DM Paul`
- **userTail:** `Hello Paul, je `
- **notes:** Réponse engagée mais incomplète. Doit continuer naturellement ("regarde ça tout de suite" plutôt que "vais bien merci").
- **expectedCategory:** acceptable
- **expectedGhostPrefix:** `regarde`
- **actual category (D-12):** useless

| Variant | Ghost | Actual category |
|---------|-------|-----------------|
| **WITHOUT context** | `` | — |
| **WITH context**    | `` | useless |

**Verdict:** [ ] ✓ with-context better  [ ] = neutral  [ ] ✗ with-context worse

**Human note:** _(fill in)_

---

## 3. [mail-new-subject] Mail: champ sujet vide, nouveau message

- **bundleID:** `com.apple.mail`
- **windowTitle:** `Nouveau message — Mail`
- **userTail:** ``
- **notes:** Sujet vide. Avec contexte → propose un sujet en lien avec le destinataire.
- **expectedCategory:** —
- **expectedGhostPrefix:** —
- **actual category (D-12):** skip

| Variant | Ghost | Actual category |
|---------|-------|-----------------|
| **WITHOUT context** | `` | — |
| **WITH context**    | `` | skip |

**Verdict:** [ ] ✓ with-context better  [ ] = neutral  [ ] ✗ with-context worse

**Human note:** _(fill in)_

---

## 4. [mail-reply-body] Mail: corps de réponse, salutation seulement

- **bundleID:** `com.apple.mail`
- **windowTitle:** `Re: Devis Q3 — Mail`
- **userTail:** `Bonjour Sophie,⏎⏎Merci pour `
- **notes:** Devrait enchaîner naturellement ("l'envoi du devis" / "votre retour").
- **expectedCategory:** acceptable
- **expectedGhostPrefix:** `votre`
- **actual category (D-12):** useless

| Variant | Ghost | Actual category |
|---------|-------|-----------------|
| **WITHOUT context** | `` | — |
| **WITH context**    | `` | useless |

**Verdict:** [ ] ✓ with-context better  [ ] = neutral  [ ] ✗ with-context worse

**Human note:** _(fill in)_

---

## 5. [vscode-comment-fn] VSCode: commentaire au-dessus d'une fonction Swift

- **bundleID:** `com.microsoft.VSCode`
- **windowTitle:** `PredictorViewModel.swift — Souffleuse`
- **userTail:** `/// `
- **notes:** Doc comment au-dessus d'une fonction. Avec contexte → devrait proposer un summary lié au code visible (truncation, language detection).
- **expectedCategory:** —
- **expectedGhostPrefix:** —
- **actual category (D-12):** skip

| Variant | Ghost | Actual category |
|---------|-------|-----------------|
| **WITHOUT context** | `` | — |
| **WITH context**    | `` | skip |

**Verdict:** [ ] ✓ with-context better  [ ] = neutral  [ ] ✗ with-context worse

**Human note:** _(fill in)_

---

## 6. [vscode-impl-line] VSCode: implémentation, milieu de fonction

- **bundleID:** `com.microsoft.VSCode`
- **windowTitle:** `PromptBuilder.swift — Souffleuse`
- **userTail:** `        let total = `
- **notes:** Au milieu d'une expression. Devrait compléter avec un nom de variable plausible.
- **expectedCategory:** —
- **expectedGhostPrefix:** —
- **actual category (D-12):** skip

| Variant | Ghost | Actual category |
|---------|-------|-----------------|
| **WITHOUT context** | `` | — |
| **WITH context**    | `` | skip |

**Verdict:** [ ] ✓ with-context better  [ ] = neutral  [ ] ✗ with-context worse

**Human note:** _(fill in)_

---

## 7. [notes-blank] Notes: nouvelle note vide

- **bundleID:** `com.apple.Notes`
- **windowTitle:** `Nouvelle note — Notes`
- **userTail:** ``
- **notes:** Champ vide, contexte de notes adjacentes. Sans contexte → fortune cookie. Avec → peut-être un titre cohérent.
- **expectedCategory:** —
- **expectedGhostPrefix:** —
- **actual category (D-12):** skip

| Variant | Ghost | Actual category |
|---------|-------|-----------------|
| **WITHOUT context** | `` | — |
| **WITH context**    | `` | skip |

**Verdict:** [ ] ✓ with-context better  [ ] = neutral  [ ] ✗ with-context worse

**Human note:** _(fill in)_

---

## 8. [intercom-cs-reply] Intercom: réponse customer support, milieu de phrase

- **bundleID:** `com.intercom.intercom-inbox`
- **windowTitle:** `Intercom — Conversation #4821`
- **userTail:** `Bonjour, je suis désolé pour ce souci de paiement. Je `
- **notes:** Réponse CS engagée. Devrait continuer en direction "vais vérifier votre transaction" plutôt que générique.
- **expectedCategory:** acceptable
- **expectedGhostPrefix:** `vais`
- **actual category (D-12):** useless

| Variant | Ghost | Actual category |
|---------|-------|-----------------|
| **WITHOUT context** | `` | — |
| **WITH context**    | `` | useless |

**Verdict:** [ ] ✓ with-context better  [ ] = neutral  [ ] ✗ with-context worse

**Human note:** _(fill in)_

---

## 9. [browser-form-name] Brave: champ Nom dans un formulaire

- **bundleID:** `com.brave.Browser`
- **windowTitle:** `Inscription — Cocotypist`
- **userTail:** ``
- **notes:** Champ formulaire vide. Difficile sans field metadata (Phase 2). Doit AU MINIMUM ne pas proposer de phrase.
- **expectedCategory:** —
- **expectedGhostPrefix:** —
- **actual category (D-12):** skip

| Variant | Ghost | Actual category |
|---------|-------|-----------------|
| **WITHOUT context** | `` | — |
| **WITH context**    | `` | skip |

**Verdict:** [ ] ✓ with-context better  [ ] = neutral  [ ] ✗ with-context worse

**Human note:** _(fill in)_

---

## 10. [discord-reply] Discord: réply dans un fil

- **bundleID:** `com.hnc.Discord`
- **windowTitle:** `Discord — #dev-souffleuse`
- **userTail:** `yep on devrait pouvoir `
- **notes:** Conversation technique en français mêlé d'anglais. Doit continuer dans le même registre.
- **expectedCategory:** acceptable
- **expectedGhostPrefix:** `le`
- **actual category (D-12):** useless

| Variant | Ghost | Actual category |
|---------|-------|-----------------|
| **WITHOUT context** | `` | — |
| **WITH context**    | `` | useless |

**Verdict:** [ ] ✓ with-context better  [ ] = neutral  [ ] ✗ with-context worse

**Human note:** _(fill in)_

---

## 11. [mid-edit-rewrite] Notes: édition au milieu d'un texte existant

- **bundleID:** `com.apple.Notes`
- **windowTitle:** `Compte-rendu réunion — Notes`
- **userTail:** `L'équipe a discuté du planning Q3 et a décidé de prioriser `
- **notes:** Curseur au milieu d'une phrase déjà engagée. Contexte = juste app+window, signal vient surtout du userTail. Test du baseline beforeCursor budget.
- **expectedCategory:** acceptable
- **expectedGhostPrefix:** `les`
- **actual category (D-12):** useless

| Variant | Ghost | Actual category |
|---------|-------|-----------------|
| **WITHOUT context** | `` | — |
| **WITH context**    | `` | useless |

**Verdict:** [ ] ✓ with-context better  [ ] = neutral  [ ] ✗ with-context worse

**Human note:** _(fill in)_

---

## 12. [long-tail-truncation] Mail: corps très long approchant la budget cap

- **bundleID:** `com.apple.mail`
- **windowTitle:** `Re: Spec v2 — Mail`
- **userTail:** `Bonjour Alex,⏎⏎Merci pour ta proposition de spec sur le PromptBuilder. J'ai bien noté les trois points que tu soulèves : l'allocation par slot avec budgets fixes, la policy d'éviction qui préfère couper sur frontière de phrase puis de mot, et les tests snapshot indépendants de MLX. Sur le point 1, je suis aligné — c'est cohérent avec ce que Cotypist fait en interne, et ça correspond à ce qu'on a discuté en standup la semaine dernière avec Marie et Paul. Sur le point 3, les snapshots déterministes via WordCountTokenCounter sont la bonne approche : on évite la dépendance MLX dans la CI, et on garde une assertion exacte sur les frontières de slots. Sur le point 2, j'aimerais juste qu'on s'assure qu'on ne `
- **notes:** Test du head-truncation: userTail ~750 chars, budget beforeCursor=200 tokens (~600 chars). Le builder doit cut head sur frontière phrase, jamais mid-mot. Doit continuer le raisonnement engagé ("coupe pas mid-word" ou similaire). [Rule 1 - Bug] Étendu vs RESEARCH §7 seed (426 chars) pour réellement dépasser le budget beforeCursor et exercer head-truncation.
- **expectedCategory:** —
- **expectedGhostPrefix:** —
- **actual category (D-12):** skip

| Variant | Ghost | Actual category |
|---------|-------|-----------------|
| **WITHOUT context** | `` | — |
| **WITH context**    | `` | skip |

**Verdict:** [ ] ✓ with-context better  [ ] = neutral  [ ] ✗ with-context worse

**Human note:** _(fill in)_

---

## 13. [13-mid-field-mail-subject] Mid-field caret in mail subject with placeholder + textAfterCaret

- **bundleID:** `com.apple.mail`
- **windowTitle:** `Nouveau message`
- **userTail:** `Suite à notre échange,`
- **notes:** Placeholder 'Objet' + textAfterCaret continuing the sentence.
- **expectedCategory:** acceptable
- **expectedGhostPrefix:** `déjeuner`
- **actual category (D-12):** useless

| Variant | Ghost | Actual category |
|---------|-------|-----------------|
| **WITHOUT context** | `` | — |
| **WITH context**    | `` | useless |

**Verdict:** [ ] ✓ with-context better  [ ] = neutral  [ ] ✗ with-context worse

**Human note:** _(fill in)_

---

## 14. [14-search-field-empty-with-help] Empty search field with help text + role

- **bundleID:** `com.tinyspeck.slackmacgap`
- **windowTitle:** `Slack — équipe Cocotypist`
- **userTail:** ``
- **notes:** fieldContext slot must fire on role + placeholder + help; afterCursor skipped (D-14c).
- **expectedCategory:** useless
- **expectedGhostPrefix:** —
- **actual category (D-12):** skip

| Variant | Ghost | Actual category |
|---------|-------|-----------------|
| **WITHOUT context** | `` | — |
| **WITH context**    | `` | skip |

**Verdict:** [ ] ✓ with-context better  [ ] = neutral  [ ] ✗ with-context worse

**Human note:** _(fill in)_

---

## 15. [15-mid-code-comment-textarea] Mid-code TextArea with following code + role

- **bundleID:** `com.microsoft.VSCode`
- **windowTitle:** `main.swift — cocotypist`
- **userTail:** `// TODO: `
- **notes:** afterCursor slot in code context.
- **expectedCategory:** —
- **expectedGhostPrefix:** —
- **actual category (D-12):** skip

| Variant | Ghost | Actual category |
|---------|-------|-----------------|
| **WITHOUT context** | `` | — |
| **WITH context**    | `` | skip |

**Verdict:** [ ] ✓ with-context better  [ ] = neutral  [ ] ✗ with-context worse

**Human note:** _(fill in)_

---

## Tally (fill in after eyeball pass)

- ✓ with-context better: ___ / 15
- = neutral:              ___ / 15
- ✗ with-context worse:   ___ / 15

**AUDIT-02 gate (planner-set):** ≥ 6 / 15 ✓ verdicts to proceed to Phase 2.
