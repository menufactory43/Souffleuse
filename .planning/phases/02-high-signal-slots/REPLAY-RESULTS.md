# Replay Results — Phase 2 Hypothesis Validation

**Generated:** 2026-05-25T09:51:25Z
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

## 1. [slack-empty-channel] Slack: empty message in channel #equipe-produit

- **bundleID:** `com.tinyspeck.slackmacgap`
- **windowTitle:** `Slack — #equipe-produit`
- **userTail:** ``
- **notes:** Cold start — champ vide, contexte de canal visible. Sans contexte: ghost générique "Coucou !". Avec contexte: devrait proposer une réponse liée à la demande Carrefour.

| Variant | Ghost |
|---------|-------|
| **WITHOUT context** | `<input type="text" id="autocomplete"` |
| **WITH context**    | ` Marie: « Ok` |

**Verdict:** [x] ✓ with-context better (marginal)  [ ] = neutral  [ ] ✗ with-context worse

**Human note:** Junk HTML → fragment dialogue. Off-topic mais plus de junk.

---

## 2. [slack-reply-mid] Slack: réponse en cours après salutation

- **bundleID:** `com.tinyspeck.slackmacgap`
- **windowTitle:** `Slack — DM Paul`
- **userTail:** `Hello Paul, je `
- **notes:** Réponse engagée mais incomplète. Doit continuer naturellement ("regarde ça tout de suite" plutôt que "vais bien merci").

| Variant | Ghost |
|---------|-------|
| **WITHOUT context** | `ne ne comprends pas` |
| **WITH context**    | `ne suis pas un` |

**Verdict:** [ ] ✓ with-context better  [ ] = neutral  [x] ✗ with-context worse

**Human note:** "je ne ne" vs "je ne suis pas un" — les deux cassés.

---

## 3. [mail-new-subject] Mail: champ sujet vide, nouveau message

- **bundleID:** `com.apple.mail`
- **windowTitle:** `Nouveau message — Mail`
- **userTail:** ``
- **notes:** Sujet vide. Avec contexte → propose un sujet en lien avec le destinataire.

| Variant | Ghost |
|---------|-------|
| **WITHOUT context** | `<input type="text" id="autocomplete"` |
| **WITH context**    | `I'm trying to create` |

**Verdict:** [ ] ✓ with-context better  [ ] = neutral  [x] ✗ with-context worse

**Human note:** Junk vs anglais dans une app FR.

---

## 4. [mail-reply-body] Mail: corps de réponse, salutation seulement

- **bundleID:** `com.apple.mail`
- **windowTitle:** `Re: Devis Q3 — Mail`
- **userTail:** `Bonjour Sophie,⏎⏎Merci pour `
- **notes:** Devrait enchaîner naturellement ("l'envoi du devis" / "votre retour").

| Variant | Ghost |
|---------|-------|
| **WITHOUT context** | `votre question.` |
| **WITH context**    | `votre demande.` |

**Verdict:** [ ] ✓ with-context better  [x] = neutral  [ ] ✗ with-context worse

**Human note:** Les deux plausibles ("votre question" / "votre demande").

---

## 5. [vscode-comment-fn] VSCode: commentaire au-dessus d'une fonction Swift

- **bundleID:** `com.microsoft.VSCode`
- **windowTitle:** `PredictorViewModel.swift — Souffleuse`
- **userTail:** `/// `
- **notes:** Doc comment au-dessus d'une fonction. Avec contexte → devrait proposer un summary lié au code visible (truncation, language detection).

| Variant | Ghost |
|---------|-------|
| **WITHOUT context** | `<input type="text" id="autocomplete"` |
| **WITH context**    | `------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------` |

**Verdict:** [ ] ✓ with-context better  [ ] = neutral  [x] ✗ with-context worse

**Human note:** Junk vs string de tirets. Pire.

---

## 6. [vscode-impl-line] VSCode: implémentation, milieu de fonction

- **bundleID:** `com.microsoft.VSCode`
- **windowTitle:** `PromptBuilder.swift — Souffleuse`
- **userTail:** `        let total = `
- **notes:** Au milieu d'une expression. Devrait compléter avec un nom de variable plausible.

| Variant | Ghost |
|---------|-------|
| **WITHOUT context** | `0;` |
| **WITH context**    | `0` |

**Verdict:** [x] ✓ with-context better  [ ] = neutral  [ ] ✗ with-context worse

**Human note:** `0;` (faux Swift) vs `0` (correct Swift).

---

## 7. [notes-blank] Notes: nouvelle note vide

- **bundleID:** `com.apple.Notes`
- **windowTitle:** `Nouvelle note — Notes`
- **userTail:** ``
- **notes:** Champ vide, contexte de notes adjacentes. Sans contexte → fortune cookie. Avec → peut-être un titre cohérent.

| Variant | Ghost |
|---------|-------|
| **WITHOUT context** | `<input type="text" id="autocomplete"` |
| **WITH context**    | `The user can select` |

**Verdict:** [ ] ✓ with-context better  [ ] = neutral  [x] ✗ with-context worse

**Human note:** Junk vs anglais générique.

---

## 8. [intercom-cs-reply] Intercom: réponse customer support, milieu de phrase

- **bundleID:** `com.intercom.intercom-inbox`
- **windowTitle:** `Intercom — Conversation #4821`
- **userTail:** `Bonjour, je suis désolé pour ce souci de paiement. Je `
- **notes:** Réponse CS engagée. Devrait continuer en direction "vais vérifier votre transaction" plutôt que générique.

| Variant | Ghost |
|---------|-------|
| **WITHOUT context** | `ne suis pas en` |
| **WITH context**    | `vous invite à contacter` |

**Verdict:** [x] ✓ with-context better  [ ] = neutral  [ ] ✗ with-context worse

**Human note:** "ne suis pas en" vs "vous invite à contacter" — plausible CS.

---

## 9. [browser-form-name] Brave: champ Nom dans un formulaire

- **bundleID:** `com.brave.Browser`
- **windowTitle:** `Inscription — Cocotypist`
- **userTail:** ``
- **notes:** Champ formulaire vide. Difficile sans field metadata (Phase 2). Doit AU MINIMUM ne pas proposer de phrase.

| Variant | Ghost |
|---------|-------|
| **WITHOUT context** | `<input type="text" id="autocomplete"` |
| **WITH context**    | `The autocomplete is a` |

**Verdict:** [ ] ✓ with-context better  [x] = neutral  [ ] ✗ with-context worse

**Human note:** Les deux nuls pour un champ Nom.

---

## 10. [discord-reply] Discord: réply dans un fil

- **bundleID:** `com.hnc.Discord`
- **windowTitle:** `Discord — #dev-souffleuse`
- **userTail:** `yep on devrait pouvoir `
- **notes:** Conversation technique en français mêlé d'anglais. Doit continuer dans le même registre.

| Variant | Ghost |
|---------|-------|
| **WITHOUT context** | `autocomplete="off"` |
| **WITH context**    | `.on('keyup'` |

**Verdict:** [x] ✓ with-context better (marginal)  [ ] = neutral  [ ] ✗ with-context worse

**Human note:** Le with-context capte le registre dev.

---

## 11. [mid-edit-rewrite] Notes: édition au milieu d'un texte existant

- **bundleID:** `com.apple.Notes`
- **windowTitle:** `Compte-rendu réunion — Notes`
- **userTail:** `L'équipe a discuté du planning Q3 et a décidé de prioriser `
- **notes:** Curseur au milieu d'une phrase déjà engagée. Contexte = juste app+window, signal vient surtout du userTail. Test du baseline beforeCursor budget.

| Variant | Ghost |
|---------|-------|
| **WITHOUT context** | `l'amélioration de l'expérience utilisateur.` |
| **WITH context**    | `3 projets.` |

**Verdict:** [ ] ✓ with-context better  [ ] = neutral  [x] ✗ with-context worse

**Human note:** WITHOUT donne mieux ("amélioration de l'expérience" > "3 projets").

---

## 12. [long-tail-truncation] Mail: corps très long approchant la budget cap

- **bundleID:** `com.apple.mail`
- **windowTitle:** `Re: Spec v2 — Mail`
- **userTail:** `Bonjour Alex,⏎⏎Merci pour ta proposition de spec sur le PromptBuilder. J'ai bien noté les trois points que tu soulèves : l'allocation par slot avec budgets fixes, la policy d'éviction qui préfère couper sur frontière de phrase puis de mot, et les tests snapshot indépendants de MLX. Sur le point 1, je suis aligné — c'est cohérent avec ce que Cotypist fait en interne, et ça correspond à ce qu'on a discuté en standup la semaine dernière avec Marie et Paul. Sur le point 3, les snapshots déterministes via WordCountTokenCounter sont la bonne approche : on évite la dépendance MLX dans la CI, et on garde une assertion exacte sur les frontières de slots. Sur le point 2, j'aimerais juste qu'on s'assure qu'on ne `
- **notes:** Test du head-truncation: userTail ~750 chars, budget beforeCursor=200 tokens (~600 chars). Le builder doit cut head sur frontière phrase, jamais mid-mot. Doit continuer le raisonnement engagé ("coupe pas mid-word" ou similaire). [Rule 1 - Bug] Étendu vs RESEARCH §7 seed (426 chars) pour réellement dépasser le budget beforeCursor et exercer head-truncation.

| Variant | Ghost |
|---------|-------|
| **WITHOUT context** | `ne coupe pas sur` |
| **WITH context**    | `ne évite pas la` |

**Verdict:** [ ] ✓ with-context better  [ ] = neutral  [x] ✗ with-context worse

**Human note:** WITHOUT plus grammatical ("ne évite" vs "n'évite").

---

## 13. [13-mid-field-mail-subject] Mid-field caret in mail subject with placeholder + textAfterCaret

- **bundleID:** `com.apple.mail`
- **windowTitle:** `Nouveau message`
- **userTail:** `Suite à notre échange,`
- **notes:** Placeholder 'Objet' + textAfterCaret continuing the sentence.

| Variant | Ghost |
|---------|-------|
| **WITHOUT context** | `je vous propose un` |
| **WITH context**    | `je vous propose un` |

**Verdict:** [ ] ✓ with-context better  [x] = neutral  [ ] ✗ with-context worse

**Human note:** Identique (replay limitation — slots Phase 2 hors colonne).

---

## 14. [14-search-field-empty-with-help] Empty search field with help text + role

- **bundleID:** `com.tinyspeck.slackmacgap`
- **windowTitle:** `Slack — équipe Cocotypist`
- **userTail:** ``
- **notes:** fieldContext slot must fire on role + placeholder + help; afterCursor skipped (D-14c).

| Variant | Ghost |
|---------|-------|
| **WITHOUT context** | `Aide : « Entrez` |
| **WITH context**    | `Aide : « Entrez` |

**Verdict:** [ ] ✓ with-context better  [x] = neutral  [ ] ✗ with-context worse

**Human note:** Identique (replay limitation — slots Phase 2 hors colonne).

---

## 15. [15-mid-code-comment-textarea] Mid-code TextArea with following code + role

- **bundleID:** `com.microsoft.VSCode`
- **windowTitle:** `main.swift — cocotypist`
- **userTail:** `// TODO: `
- **notes:** afterCursor slot in code context.

| Variant | Ghost |
|---------|-------|
| **WITHOUT context** | `1.` |
| **WITH context**    | `1.` |

**Verdict:** [ ] ✓ with-context better  [x] = neutral  [ ] ✗ with-context worse

**Human note:** Identique (replay limitation — slots Phase 2 hors colonne).

---

## Tally (signed 2026-05-25)

- ✓ with-context better: 4 / 15 (scenarios 1, 6, 8, 10 — dont 2 marginaux: 1, 10)
- = neutral:              5 / 15 (scenarios 4, 9, 13, 14, 15)
- ✗ with-context worse:   6 / 15 (scenarios 2, 3, 5, 7, 11, 12)

**AUDIT-02 gate (planner-set):** ≥ 6 / 15 ✓ verdicts to proceed to Phase 2.

> **AUDIT-02 gate (4/15) : NON ATTEINT en replay-only.** Voir 02-VERIFICATION.md
> pour la lecture étendue (Phase 2 slots non-exercés en replay — les 3 lignes
> identiques 13/14/15 témoignent que la valeur Phase 2 reste à mesurer en
> daily-use, pas en replay). Verdict modèle D-18b et PERF-01 attribution B-3
> restent PENDING jusqu'à la session daily-use avec `SOUFFLEUSE_PROMPT_BUILDER=1`.

## Performance notes

prompt_build_ms statistics: **PENDING (no daily-use session executed yet).**
- samples = 0
- p50 / p95 / max = N/A
- B-3 grep gate (`grep -c "prompt_build_ms" ~/Library/Logs/Souffleuse.log`) = 0
- end-to-end TTFT eyeball verdict = N/A (no daily-use yet)

To capture: see Outstanding section in 02-VERIFICATION.md.
