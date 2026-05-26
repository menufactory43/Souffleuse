# Llama.cpp engine swap — comparateur Cotypist

Objectif: dupliquer l'archi moteur de Cotypist (llama.cpp + GGUF instruct + FIM)
dans ce doublon, en gardant intact overlay / Tab-Esc / AX / input. **Moteur seul**
(pas encore le store SQLite + suffix array de personnalisation).

## Recon Cotypist (faits établis)

- Inférence: **llama.cpp** (pas MLX). Dylibs dans `/Applications/Cotypist.app/Contents/Frameworks/`:
  `libllama.0.dylib`, `libggml.0.dylib`, `libggml-base.0.dylib`, `libggml-cpu.0.dylib`,
  `libggml-blas.0.dylib`, `libggml-metal.0.dylib`. Backend **Metal**. API récente
  (`llama_init_from_model`, `llama_decode`, `llama_memory_seq_*`, `llama_sampler_init*`).
- Modèles **GGUF instruct** déjà sur disque:
  `~/Library/Application Support/app.cotypist.Cotypist/Models/gemma-3-1b.i1-Q5_K_M.gguf` (défaut rapide)
  et `gemma-3-4b.i1-Q4_K_M.gguf` (qualité). Vocab/tokenizer Gemma 262144.
- Personnalisation = `GRDB` SQLite chiffré (`cotypist.db`) + **suffix array** sur le corpus
  de frappe (`groupedByPrefix`). HORS SCOPE de cette v1.
- Intelligence du ghost = (1) **FIM** preContext+postContext, (2) modèle **instruct**,
  (3) préfixe corrigé. Notre `PromptBuilder` a déjà un slot `afterCursor` à exploiter.

## Stratégie d'intégration (décidée)

Réutiliser les dylibs llama.cpp **déjà compilés** de Cotypist (Metal prouvé, ABI
garantie avec le GGUF) + headers C `llama.h`/`ggml*.h`/`gguf.h` de llama.cpp master
(l'API C est stable; symboles vérifiés présents dans le dylib).

### Étapes

1. **Vendoring**
   - Copier les 6 dylibs dans `Souffleuse/vendor/llama/lib/`.
   - Récupérer headers master dans `Souffleuse/vendor/llama/include/`:
     `llama.h ggml.h ggml-cpu.h ggml-backend.h ggml-opt.h gguf.h ggml-alloc.h ggml-metal.h`
     (base: https://raw.githubusercontent.com/ggml-org/llama.cpp/master/{include|ggml/include}/)
   - Écrire `module.modulemap` exposant `llama.h`.

2. **Target SPM `CLlama`** (systemLibrary/C target) avec les headers + modulemap.
   **Target SPM `SouffleuseLlama`** (Swift): `LlamaEngine` (actor) qui charge le modèle,
   tokenize, decode en streaming token-par-token avec cancel coopératif, sampler
   (greedy/temp bas, repeat-penalty). API miroir de l'usage MLX actuel:
   `func generate(prompt:String, maxTokens:Int, onToken:@Sendable (String)->Bool) async`.
   linkerSettings: `-L vendor/llama/lib -lllama -lggml -lggml-base -lggml-cpu -lggml-metal -lggml-blas`
   + rpath. `make-app.sh` doit copier les dylibs dans `Contents/Frameworks/` (cf. pattern mlx Cmlx bundle).

3. **Rebranchage `PredictorViewModel`** (`Sources/Souffleuse/PredictorViewModel.swift`, 670 l.):
   remplacer le chemin de génération MLX (`container.perform` / TokenIterator) par
   `LlamaEngine.generate`. Garder: debounce, generation counter cancel-on-keystroke,
   predictCache FIFO, troncature phrase/mot, chaînage overlay. MLX peut RESTER linké
   en v1 (personalization/prompt l'importent) — on ne rippe pas MLX maintenant, on
   route juste la génération via llama. Tokenizer counting: garder MLXTokenCounter v1.

4. **Prompt FIM**: utiliser le chat template Gemma instruct (`<start_of_turn>`...).
   Brancher `PromptBuilder.afterCursor` comme post-contexte réel. Pour Gemma (pas de
   tokens FIM natifs), encadrer: instruction "complète le texte au curseur" avec
   pré-texte et post-texte fournis. Garder simple en v1.

5. **Build & vérif**: `cd Souffleuse && swift build` puis `./make-app.sh`.
   `./audit.sh` doit passer (no print/os_log user fields). Lancer l'app, vérifier
   ghost intelligent vs MLX. Les 94 tests: cibler vert; si dépendances MLX cassent,
   garder MLX linké (v1) pour ne pas les casser.

## Contraintes
- Ne PAS toucher overlay (`SouffleuseOverlay`), input (`SouffleuseInput`), AX (`SouffleuseAX`).
- `audit.sh` reste vert. Pas de réseau runtime (modèle chargé depuis disque local).
- macOS 14+ Apple Silicon. Swift 6 strict concurrency: `LlamaEngine` = actor, types Sendable.
- Modèle: pointer d'abord sur le GGUF de Cotypist déjà présent (chemin ci-dessus) pour
  comparer à iso-modèle; rendre le chemin configurable ensuite.
