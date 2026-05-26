# Jalon 1 — Spike technique MLX + Ghost text

État : code écrit, compile en Swift 6 strict, runtime requiert Xcode.

## Ce qui est en place

- Projet SPM `Souffleuse` (Swift 6, macOS 14+)
- Dépendances : `mlx-swift-examples` 2.29.1 → MLXLLM + MLXLMCommon
- Modèle ciblé pour le spike : `mlx-community/Llama-3.2-1B-Instruct-4bit` (~700 MB téléchargés depuis Hugging Face au premier run)
- 4 fichiers source dans `Sources/Souffleuse/` :
  - `SouffleuseApp.swift` — entry @main, SwiftUI scene, déclenche `loadModel()` au démarrage
  - `ContentView.swift` — UI : status bar + zone de texte + metrics bar (TTFT, tokens/s)
  - `GhostTextEditor.swift` — NSViewRepresentable autour de NSTextView, calcule la position du caret via layout manager, affiche un NSTextField gris en overlay, capte Tab/Esc via NSEvent local monitor
  - `PredictorViewModel.swift` — @Observable, charge le modèle via ModelContainer, debounce + cancel sur chaque frappe, stream les tokens via `MLXLMCommon.generate(...) -> AsyncStream<Generation>`

## Comment tester

SwiftPM CLI (`swift run`) **ne fonctionne pas** : MLX a besoin d'un bundle `.app` pour trouver son metallib Metal. Workflow correct :

```bash
cd ~/cocotypist/Souffleuse
xed Package.swift     # ouvre dans Xcode
```

Dans Xcode :
1. Sélectionner le schéma `Souffleuse`
2. Choisir "My Mac" comme destination
3. Cmd+R

Au premier lancement :
- Téléchargement Llama-3.2-1B-Instruct-4bit depuis Hugging Face (~700 MB, cache local ensuite)
- La barre de progression s'affiche pendant le téléchargement
- "Modèle prêt" quand chargé

Taper du texte dans la zone (au moins 3 caractères non blancs) → ghost text apparaît en gris après ~120 ms de pause → Tab accepte, Esc rejette.

## À mesurer dans ce spike

- TTFT (Time To First Token) — affiché en bas de fenêtre, cible < 100 ms sur M1 base
- Throughput tokens/s — cible 20-40 tok/s
- RAM résident de l'app pendant inférence
- Qualité des suggestions FR (taper du français)
- Qualité des suggestions EN
- Qualité du code-switching (mélange FR/EN dans une même phrase)

## Décisions à prendre après ce spike

- Garder Llama-3.2-1B ou passer à Gemma 3 1B / Qwen 3 1.7B ?
- Le ghost text se positionne correctement dans tous les cas (multi-ligne, fin de ligne, début de paragraphe) ?
- Latence acceptable en l'état ou besoin de tuning (kv cache cross-frappe, batch, etc.) ?

## Limites connues du spike

- App locale uniquement (pas encore d'injection système — Jalon 2)
- Pas de bundle propre, pas de signature, pas de notarization — local dev only
- Pas de gestion de cancellation côté MLX (annule via Task.isCancelled mais le modèle continue de générer le token courant)
- Pas de filtre qualité sur la suggestion (répétition, langue, entropie — Jalon 3)
- Pas de tokenizer-aware truncation à 2048 chars — coupe brutalement le contexte
