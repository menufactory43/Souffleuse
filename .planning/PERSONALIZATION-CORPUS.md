# Personnalisation type Cotypist — corpus SQLite chiffré + suffix array + biais de logits

Objectif: répliquer la couche perso de Cotypist sur le moteur llama.cpp.
Décisions utilisateur: **le plus proche de Cotypist** (fast-path local + biais de
logits) et **migration vers SQLite chiffré**. Le few-shot dans le prompt est EXCLU
(déjà prouvé nuisible — in-context learning pollue le ghost, cf. PVM:484-498).

## État actuel (recon établie)

- `TypingHistoryStore` VIVANT: enregistre chaque Tab `(timestamp, contextBefore,
  accepted, bundleID)` dans `~/Library/Application Support/Souffleuse/history.aes`
  (AES-GCM, ring buffer **200 entrées**, cap 1 Mo). Recording: SouffleuseAppDelegate
  ~1114-1127 (full) + ~1186-1208 (partial).
- `NgramModel` (bi/trigram) reconstruit au lancement + ingéré à chaque accept, mais
  **plus jamais lu** depuis le swap llama.
- `NgramLogitBias`/`ChainLogitProcessor`/`SimilarHistoryRetrieval` = morts (MLX only
  ou abandonnés).
- `LlamaEngine.generate` = sampler greedy/temp + repeat-penalty, **zéro biais corpus**.
- Layer 1 instant-ghost: scan exact-substring linéaire sur les 200 entrées
  (SuggestionPolicyEngine.routeInstant). Déjà là, mais pauvre.
- `audit.sh` whiteliste les accès à `history.aes` aux seuls `TypingHistoryStore.swift`
  + `HistoryViewerWindow.swift`. Toute migration de stockage doit mettre l'audit à jour.

## Seam technique du biais de logits (confirmé)

Dans `LlamaEngine.generate` (LlamaEngine.swift:289-309), avant
`llama_sampler_sample(sampler, ctx, -1)`: récupérer `llama_get_logits_ith(ctx, -1)`
(`UnsafeMutablePointer<Float>` de taille `n_vocab`), ajouter un boost aux token ids
prédits par le corpus selon la fenêtre de tokens déjà générés, puis sampler (la chaîne
lit les logits modifiés). Maintenir une fenêtre glissante des derniers tokens générés
(+ queue du prompt) pour calculer le contexte n-gram / suffix-array.

---

## Phase 1 — Reconnecter le corpus au décodage (biais de logits, n-gram existant)

But: prouver le seam `llama_get_logits_ith` + restaurer l'influence du corpus le plus
vite, SANS nouvelle dépendance. On réutilise `NgramSnapshot` déjà produit.

- Étendre `LlamaSampling` (ou ajouter un param) pour passer une source de biais
  Sendable: une closure `(_ contextTokens: [Int32]) -> [(token: Int32, boost: Float)]`
  OU directement le `NgramSnapshot` + un mapping token→id. Attention: le NgramModel
  tokenise en *mots* (tokenizer MLX), pas en *tokens llama*. Pont nécessaire:
  recalculer le n-gram sur des **token ids llama** (re-tokeniser le corpus avec
  `LlamaEngine.tokenize`) OU mapper. Choix v1: construire un petit n-gram **en token
  ids llama** dans LlamaEngine à partir du corpus (passé au load), indépendant du
  NgramModel MLX. Garder simple: bigram/trigram sur ids llama.
- Dans la boucle: maintenir `recentIds` (prompt tail + générés), à chaque step booster
  `logits[id] += strength * log(1+count)` pour les ids candidats du n-gram.
- Brancher `personalizationStrength` (préf existante) comme gain.
- Vérif: build + tests verts + probe montrant qu'une continuation déjà tapée ressort
  plus volontiers. audit.sh vert.

## Phase 2 — Stockage SQLite chiffré (parité Cotypist)

But: remplacer le blob AES 200-entrées par une base SQLite chiffrée, gros corpus.

- Dépendance: SQLCipher (via GRDB.swift SPM `.product("GRDB", ...)` avec SQLCipher, OU
  SQLite3 C + SQLCipher). Cotypist utilise GRDB.framework → GRDB est le choix fidèle.
- Schéma: table `entries(id, ts, context_before, accepted, bundle_id)` + index sur un
  préfixe normalisé. Clé de chiffrement: réutiliser `KeychainKey` (AES-256 → passphrase
  SQLCipher dérivée).
- Migration: au premier lancement, si `history.aes` existe, déchiffrer (via
  TypingHistoryStore actuel) → insérer dans SQLite → archiver l'ancien fichier.
- Lever le cap 200 (ex. 50k entrées, purge par âge/taille).
- Garder l'API actor (`append`, `allEntries`, `clear`) pour ne pas casser les appelants.
- Mettre à jour `audit.sh`: le nouveau store chiffré devient la source whitelistée;
  garder l'invariant "lecture du corpus seulement depuis le store + viewer".
- Vérif: migration testée (entrées préservées), tests verts, audit vert.

## Phase 3 — Suffix array + fast-path local

But: indexation puissante du corpus pour (a) biais plus riche (contexte variable) et
(b) chemin de complétion locale instantané (mode "short" de Cotypist).

- Construire un suffix array en mémoire au lancement sur le corpus concaténé (token ids
  llama ou chars). Mise à jour incrémentale à l'accept (ou rebuild paresseux).
- (a) Biais: au lieu du bigram/trigram fixe, requête longest-match du contexte courant
  dans le suffix array → distribution des tokens suivants observés → boost logits.
- (b) Fast-path: étendre `SuggestionPolicyEngine.routeInstant` pour interroger le suffix
  array; si match fort (longueur de contexte ≥ seuil), afficher la continuation
  DIRECTEMENT sans appeler le LLM (ghost 0-inférence). Garder le LLM en repli.
- Vérif: latence fast-path < quelques ms; pas de régression LLM; tests + audit verts.

## Contraintes transverses
- Ne pas toucher overlay/input/AX. Swift 6 strict concurrency (stores = actors, types
  Sendable). Pas de réseau. macOS 14+ Apple Silicon.
- `audit.sh` reste vert (pas de print/os_log de champs user; corpus chiffré au repos;
  accès au corpus whitelisté).
- MLX peut rester linké (n-gram MLX tokenizer) tant que ça ne gêne pas; viser à ne plus
  en dépendre côté perso.
