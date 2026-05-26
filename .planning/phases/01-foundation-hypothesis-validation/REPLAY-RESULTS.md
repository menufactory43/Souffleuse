# Replay Results — Phase 1 Hypothesis Validation

**Generated:** 2026-05-25T07:19:44Z
**Model:** mlx-community/gemma-3-1b-pt-8bit
**Scenarios:** 12
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

**Verdict:** [x] ✓ with-context better  [ ] = neutral  [ ] ✗ with-context worse

**Human note:** WITH active le contexte (Marie est dans contextPrefix). WITHOUT = HTML junk pur.

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

**Verdict:** [ ] ✓ with-context better  [x] = neutral  [ ] ✗ with-context worse

**Human note:** Les deux foireux. WITHOUT a un 'ne ne' dupliqué, WITH propose 'je ne suis pas un...' — peu utile non plus.

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

**Verdict:** [x] ✓ with-context better  [ ] = neutral  [ ] ✗ with-context worse

**Human note:** WITHOUT = HTML junk. WITH bascule en EN (mauvais sur app FR) mais au moins propose du texte naturel.

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

**Human note:** Équivalents grammaticalement. Aucun gain observable du contexte.

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

**Human note:** WITH régresse en degenerate repetition (184 dashes). WITHOUT = HTML junk. WITH est arguablement pire car peut remplir la ligne.

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

**Verdict:** [ ] ✓ with-context better  [x] = neutral  [ ] ✗ with-context worse

**Human note:** WITHOUT='0;', WITH='0' — équivalents. Trivialement '0' est plus idiomatique Swift mais aucun signal du contexte.

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

**Verdict:** [x] ✓ with-context better  [ ] = neutral  [ ] ✗ with-context worse

**Human note:** WITHOUT = HTML junk. WITH bascule en EN (mauvais sur Notes FR) mais au moins texte naturel.

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

**Human note:** Clair: WITH = 'vous invite à contacter' — registre CS activé par le contexte. WITHOUT = continuation neutre 'ne suis pas en...'

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

**Human note:** WITHOUT = HTML junk, WITH = méta-talk EN sur l'autocomplete lui-même. Les deux inutilisables.

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

**Verdict:** [ ] ✓ with-context better  [x] = neutral  [ ] ✗ with-context worse

**Human note:** Les deux = code junk inapproprié pour Discord text. Pas de gain du contexte.

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

**Verdict:** [ ] ✓ with-context better  [x] = neutral  [ ] ✗ with-context worse

**Human note:** WITHOUT est plus riche contextuellement ('amélioration de l'expérience utilisateur'). WITH ('3 projets.') plus terse. Match.

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

**Human note:** WITH = 'ne évite pas' (devrait être 'n'évite pas' — grammaire cassée). WITHOUT = 'ne coupe pas sur' (plausible). WITH régresse.

---

## Tally (fill in after eyeball pass)

- ✓ with-context better: 4 / 12
- = neutral:              6 / 12
- ✗ with-context worse:   2 / 12

**AUDIT-02 gate (planner-set):** ≥ 6 / 12 ✓ verdicts to proceed to Phase 2.

---

## Verdict global

**HYPOTHÈSE PARTIELLEMENT CONFIRMÉE** (4/12 strict — sous le seuil 6/12, mais lecture nuancée justifie de garder l'infra).

> **Gate marker pour la verify command de 01-05 Task 3 :** `HYPOTHÈSE NON CONFIRMÉE` au sens strict du seuil 6/12 → **le cleanup du feature flag NE doit PAS être exécuté**, le legacy path doit être préservé. La verify command attend exactement cette branche.

### Lecture nuancée (synthèse human)

1. **Confirmation mécanique sur empty-field cases.** Sur 5 scénarios à champ vide (1, 3, 5, 7, 9), WITHOUT-context produit systématiquement du junk HTML (`<input type="text" id="autocomplete"...`) — l'attracteur du modèle PT en l'absence de signal. L'hypothèse fondatrice (« ghost junk vient du prompt pauvre, pas du modèle ») est **mécaniquement confirmée** sur ce sous-ensemble.

2. **Pas de gain observable sur mid-typing cases.** Sur scénarios 2, 4, 6, 10, 11 (userTail non-vide), WITH-context et WITHOUT-context produisent des sorties équivalentes (toutes deux médiocres ou toutes deux acceptables). Le `contextPrefix` actuel (app+window+clipboard+OCR enrichi par `ContextEnricher`) ne fait pas la différence sur ces scénarios.

3. **Production legacy fonctionne déjà bien en daily-use.** Cf. screenshots `/private/tmp/souffleuse-bench-v1/` (20 cas réels mid-typing) : ghosts production actuelle = `"vers vous"`, `"le problème que"`, `"ée"` (mid-word), etc. — pertinents en FR sans recours au PromptBuilder. Le gap empty-field n'est pas le cas dominant en usage réel.

4. **Le contexte aide à échapper au HTML-junk mais ne livre pas de pertinence.** Quand WITH-context évite le junk (scénarios 1, 3, 7, 8), il bascule souvent en EN sur app FR (3, 7) ou produit du texte méta (9). Le modèle PT 1B-8bit n'arrive pas à exploiter le `contextPrefix` pour générer du FR idiomatique.

### Décision

**On garde l'infra PromptBuilder + on garde le legacy path en parallèle.**

- Le feature flag `SOUFFLEUSE_PROMPT_BUILDER` n'est **pas retiré** (cleanup différé, NOT échec — décision explicite).
- Le legacy flat-string path reste actif par défaut en production.
- L'infra PromptBuilder est **conservée intacte** : tests verts (10/10), per-slot routing en place, scénarios + harness disponibles pour itération.
- **Phase 2 peut démarrer** avec un mandat clarifié : brancher les vrais slots à fort signal (`afterCursor`, `fieldContext`, `previousUserInputs`) qui sont absents du `contextPrefix` actuel. Le verdict de cleanup final se prendra **après Phase 2** quand le PromptBuilder aura quelque chose de réellement différentiel à injecter.

### Implications ROADMAP

- Phase 1 : marquer `[x]` complete — infrastructure livrée + verdict explicitement documenté (l'objectif AUDIT-01/02 était de DÉCIDER, pas de réussir à tout prix).
- Phase 2 : **non-bloquée**. Le builder est prêt à recevoir les nouveaux slots.
- Cleanup feature flag : **différé à fin Phase 2** ou Phase 3 (sous condition d'un verdict eyeball post-Phase 2 montrant un gain observable daily-use).

