# 04-02 Baseline Replay Equivalence — Pre-Extraction

**Date :** 2026-05-25
**Commit HEAD :** 3e9a826 (post 04-01)
**MODE :** BUILD-ONLY BASELINE

## Pourquoi BUILD-ONLY

Le binaire `SouffleuseCoherence --replay <scenarios.json>` charge MLX (Gemma 3 1B) et exécute
de la génération live — non-déterministe à 100% en termes de timing TTFT, et lourd (~10s par
scenario × 15 scenarios = ~2.5min). Plus important : le replay ne tourne **pas headless en agent**
parce qu'il télécharge depuis HuggingFace au premier run et requiert un Apple Silicon GPU.

Le plan 04-02 §Task 1 autorise explicitement ce mode :
> **Si `--replay` n'existe pas ou ne tourne pas hors-MLX**, marquer la baseline comme
> TEXTUAL_BUILD_ONLY : capturer juste l'output du `swift build` + un hash sha256 du fichier
> `replay-scenarios.json` comme baseline minimale.

L'equivalence est donc validée à Task 6 par :
1. `swift build --package-path Souffleuse` exits 0
2. `swift test --package-path Souffleuse` — 153+ tests verts (cible : ≥173 après Tasks 4/5)
3. `bash Souffleuse/audit.sh` — 6/6 checks verts
4. Hash sha256 du fichier scenarios inchangé (on ne touche pas au schéma cette phase)

## Inputs versionnés

| Item | Value |
|---|---|
| Commande replay (référence) | `swift run --package-path Souffleuse SouffleuseCoherence --replay .planning/phases/01-foundation-hypothesis-validation/replay-scenarios.json` |
| Path scenarios | `.planning/phases/01-foundation-hypothesis-validation/replay-scenarios.json` |
| Hash sha256 scenarios | `d4fa5820383b51dd9226ac7d905c788396f8f7abbc46b6fe7359c9928d288f23` |
| Schema version | 1 |
| Nombre de scenarios | 15 |

## Liste des scenarios (snapshot)

1. slack-empty-channel
2. slack-reply-mid
3. mail-new-subject
4. mail-reply-body
5. vscode-comment-fn
6. vscode-impl-line
7. notes-blank
8. intercom-cs-reply
9. browser-form-name
10. discord-reply
11. mid-edit-rewrite
12. long-tail-truncation
13. 13-mid-field-mail-subject
14. 14-search-field-empty-with-help
15. 15-mid-code-comment-textarea

## Build pré-extraction

```
swift build --package-path Souffleuse --product SouffleuseCoherence
[0/1] Planning build
Building for debugging...
Build of product 'SouffleuseCoherence' complete! (6.56s)
EXIT=0
```

## Surface that MUST stay equivalent

La refactorisation 04-02 modifie la **structure** de la cascade routing mais ne change PAS
les inputs ni les outputs observables des scenarios :

- `historyExactSubstringMatch` migre verbatim → string-output identique
- `capToWords` migre verbatim → string-output identique
- Cascade L0/L1 priority : history > word-completion > nothing — préservée
- LLM stream chunks : filtre overlap + markup + repeat + maxWords identique
- Decisions de remplacement post-Gate : **PEUVENT différer** quand un ghost low-score
  passait avant et ne passe plus (D-07 intended). Annoté à Task 6.

## Verdict pré-Task 6

✅ Build vert, scenarios versionnés, prêt pour comparaison post-extraction.
