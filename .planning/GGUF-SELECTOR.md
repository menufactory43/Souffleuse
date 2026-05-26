# Sélecteur de modèle GGUF (remplace le picker MLX vestige)

Décision: Option B — rebrancher le sélecteur de modèle pour qu'il choisisse RÉELLEMENT
le GGUF du ghost (1B Q5 ↔ 4B Q4, **un seul à la fois**, comme Cotypist), et indiquer
clairement que ce sont des modèles **GGUF (llama.cpp)**, pas MLX.

## État actuel (le problème)

- Le picker (`PreferencesWindow.swift` ~324, `ModelOption.catalogue` dans
  `PreferencesStore.swift`) liste d'anciens modèles **MLX** et pilote `modelId` →
  `PVM.swapModel` → `ModelRuntime.swap` (charge un container MLX).
- MAIS le ghost vient de `llamaEngine` sur un GGUF à **chemin fixe**
  (`ModelRuntime.resolveGGUFPath`, indépendant de `modelId`). Le container MLX ne sert
  plus qu'au n-gram tokenizer legacy (`ModelRuntime.swift:158-159`). Donc le picker ne
  change RIEN au ghost → trompeur.

## Cible

Un sélecteur qui liste les GGUF disponibles et, au changement, recharge le moteur llama.

### Catalogue GGUF
Nouveau type (ex. `GGUFModelOption`) avec id, label affiché, sous-titre quant, et
résolution de chemin. Deux entrées v1:
- "Gemma 3 1B · Q5_K_M (GGUF)" → `gemma-3-1b.i1-Q5_K_M.gguf`  (rapide, défaut)
- "Gemma 3 4B · Q4_K_M (GGUF)" → `gemma-3-4b.i1-Q4_K_M.gguf`  (qualité, plus lent/RAM)

Résolution de chemin par entrée (même logique que `resolveGGUFPath`):
1. `SOUFFLEUSE_GGUF` env (si présent, override global — garder pour debug),
2. `~/Library/Application Support/Souffleuse/Models/<fichier>` si présent,
3. fallback `~/Library/Application Support/app.cotypist.Cotypist/Models/<fichier>`.
N'afficher/activer une entrée que si son fichier est résolvable (sinon grisée + hint
"fichier introuvable"). Les deux GGUF sont déjà sur disque via Cotypist.

### Persistance
Stocker l'id GGUF choisi dans `PreferencesStore` (UserDefaults, clé dans `K`). Défaut =
1B Q5. Survit au redémarrage. `resolveGGUFPath()` lit ce choix.

### Switch = recharger le moteur llama (PAS MLX)
Au changement de sélection:
1. `llamaEngine.load(modelPath: <nouveau GGUF>, contextTokens: …)` — `load()` réinitialise
   déjà l'état (kvTokens=[]). 
2. **Re-set le corpus** après le load (`runtime.setCorpus(...)` / `rebuildPersonalization`)
   car le moteur a été rechargé → le n-gram/suffix-array token-ids doivent être reconstruits.
   (Tokenizer Gemma identique 1B/4B, mais on rebuild par sûreté.)
3. Surfacer un `loadState` "loading" pendant le chargement (le 4B = ~2.5 Go, plus long).
4. Le container MLX n'est plus piloté par ce sélecteur. Laisser le chargement MLX legacy
   tel quel (best-effort, n'impacte pas le ghost) OU le rendre inerte — NE PAS ripper MLX
   dans ce chantier (hors scope), juste ne plus le lier au choix utilisateur.

### UI / étiquetage (exigence explicite)
- Renommer la section et ajouter un libellé clair: ce sont des modèles **GGUF (llama.cpp)**,
  le moteur réel du ghost. Ex. titre "Modèle du ghost (GGUF · llama.cpp)" + note:
  "Ces modèles tournent via llama.cpp. (Les anciens modèles MLX ne sont plus utilisés.)"
- Chaque ligne montre le quant (Q5_K_M / Q4_K_M) et un indice rapide/qualité.
- Retirer de l'UI le catalogue MLX (`ModelOption.catalogue`) du picker visible (le type
  peut rester en code si d'autres chemins le référencent, mais l'utilisateur ne le voit
  plus).

## Vérification
- Build + tests verts, audit vert, overlay/input/AX intacts.
- Sélectionner 4B → log `llama_loaded` du nouveau modèle + ghost produit par le 4B
  (TTFT plus élevé attendu). Re-sélectionner 1B → recharge 1B. Choix persistant après
  redémarrage (relire la pref).
- Corpus toujours actif après switch (suffix array reconstruit).
- Entrée grisée si le GGUF est absent.
- Pas de régression: le ghost 1B reste l'expérience par défaut.

## Hors scope
- Téléchargement de modèles (on référence les GGUF déjà sur disque).
- Suppression de la dépendance MLX (cleanup séparé).
