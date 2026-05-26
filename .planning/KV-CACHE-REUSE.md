# KV / prompt cache reuse dans LlamaEngine — instantanéité

Objectif: arrêter de recomputer tout le prompt à chaque frappe. Réutiliser le KV cache
llama pour le plus long préfixe commun entre deux générations consécutives, ne décoder
que le suffixe nouveau. C'est le levier #1 sur le ressenti "ghost instantané".

## Problème actuel

`LlamaEngine.generate` (LlamaEngine.swift ~242) fait `llama_memory_seq_rm(mem, 0, -1, -1)`
à CHAQUE appel → reset complet du KV → re-décodage de tout le prompt (TTFT ~110-380ms).
Or en frappe, le prompt ne diffère qu'à la fin (`beforeCursor` grandit d'un mot/char ;
le bloc système est stable). Le préfixe commun est énorme.

## Conception

Maintenir dans l'actor:
- `kvTokens: [Int32]` = séquence EXACTE de tokens actuellement présents dans le KV
  (seq 0). Inclut le prompt du dernier appel + les tokens qu'on a décodés pendant la
  génération (puisqu'ils ont été `llama_decode`'d dans le contexte).

À chaque `generate(prompt:)`:
1. Tokeniser le nouveau prompt → `newPrompt`.
2. Calculer `lcp` = longueur du plus long préfixe commun `(newPrompt, kvTokens)`.
3. `llama_memory_seq_rm(mem, 0, Int32(lcp), -1)` → drop tout le KV à partir de la
   position `lcp` (garde [0, lcp)).
4. Décoder uniquement `newPrompt[lcp...]` (batch). Si `lcp == newPrompt.count` (prompt
   identique au préfixe en cache), décoder au minimum le dernier token pour avoir des
   logits valides à la position finale (cas limite à gérer).
5. `kvTokens = Array(newPrompt[0..<lcp]) + newPrompt[lcp...]` = newPrompt. Puis pendant
   la boucle de génération, append chaque token décodé à `kvTokens`.
6. Sampler/biais corpus inchangés.

## Pièges à gérer (correctness > perf)

- **Troncature de tête**: le code tronque `promptTokens.suffix(maxPrompt)` si trop long.
  Ça décale les positions → LCP depuis 0 invalide. Si le prompt est tronqué en tête (ou
  si la tête diffère), FALLBACK = reset complet + recompute (rare avec ctx 8192 et
  prompts courts d'autocomplete). Détecter et logguer un event `kv_full_recompute`.
- **Annulation mid-stream** (cancel-on-keystroke): si la génération est cancellée après
  avoir décodé N tokens, ces N tokens sont dans le KV → ils DOIVENT être dans `kvTokens`
  (append au fur et à mesure, pas à la fin). Le prochain LCP les gérera (ils seront
  trimmés car absents du nouveau prompt).
- **Reload modèle / setCorpus**: invalider `kvTokens = []` quand le contexte/modèle
  change (unload/reload). Le corpus n'affecte pas le KV (juste le biais), donc setCorpus
  n'invalide PAS le KV.
- **Multi-appels concurrents**: l'actor sérialise déjà `generate`. OK.
- **EOG / fin de prompt**: après décodage du prompt, `llama_sampler_sample(ctx, -1)` lit
  les logits de la dernière position décodée — s'assurer qu'au moins 1 token a été décodé
  cette passe (sinon les logits de la position finale ne sont pas "frais"). Gérer le cas
  `lcp == newPrompt.count` en re-décodant le dernier token (trim à lcp-1 puis decode 1).

## Vérification

- **Correctness**: pour un même prompt final, la sortie avec cache == sortie sans cache
  (déterminisme greedy). Test: générer prompt A (cache froid), puis prompt B = A (cache
  chaud) → même premier token / même sortie.
- **Perf**: TTFT sur frappe incrémentale (prompt qui grandit d'un token) doit chuter
  drastiquement vs froid. Mesurer via le probe: prompt long, puis prompt+1 token →
  comparer TTFT cache-froid vs cache-chaud (attendu: division significative).
- Tests verts, audit vert, overlay/input/AX intacts.

## Hors scope
- Pas de cache disque/persisté (in-memory, durée de vie du process).
- Pas de context-shifting/rolling (si on dépasse ctx, fallback recompute).
