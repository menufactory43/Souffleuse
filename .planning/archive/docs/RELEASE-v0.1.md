# Souffleuse (llama.cpp fork) — v0.1.0

Premier jalon du fork llama.cpp de Souffleuse, à parité d'architecture avec Cotypist.

## Ce qui marche
- **Moteur** : llama.cpp + Metal (dylibs réutilisés de Cotypist), modèle **GGUF Gemma 3 1B Q5_K_M** (sélecteur 1B ↔ 4B Q4 dans les Préférences).
- **Prompt** : Fill-in-the-Middle (pré + post-curseur) + steering de langue collant + correction de préfixe silencieuse.
- **Personnalisation** : corpus **SQLite chiffré** (SQLCipher, 50k entrées) → **suffix array** → **biais de logits au décodage** + **fast-path local** 0-inférence.
- **Vitesse** : **KV cache réutilisé** entre frappes (TTFT ~24 ms à chaud vs ~130 ms à froid).
- **Robustesse du ghost** : complétions mid-mot débloquées et cohérentes ; drop des sorties dégénérées (« 1 »), des collages non-mots (« procédblème »), des échos d'instruction ; effacement du ghost périmé sur divergence ; continuations par apostrophe/trait d'union (« S'il vous plaît », « j'ai »).

→ **Le ghost est rapide et suit la frappe.**

## Limitation connue (prochain chantier)
- **Pertinence contextuelle** : le ghost ne trouve pas toujours les *bons mots* en fonction du contexte. C'est le principal écart restant avec Cotypist. Pistes : enrichissement/agencement du prompt FIM, tuning du sampler (temp / `min-p` contre le charabia anglais ponctuel), calibrage du gain de personnalisation et des seuils du fast-path.

## Garde-fous
- macOS 14+ Apple Silicon. Aucune télémétrie, pas de réseau au runtime (modèle chargé depuis le disque).
- Privacy : `audit.sh` vert (pas de log de texte utilisateur, corpus chiffré au repos).
- 336 tests (échecs résiduels = tests de timing flaky sous charge parallèle, verts en isolé).
