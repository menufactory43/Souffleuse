# Souffleuse — Architecture

> Autocomplétion intelligente système pour macOS. LLM local, suggestions inline dans n'importe quel champ texte, Tab pour accepter. Inspiré de Cotypist.

**Nom** : Souffleuse — la femme du théâtre qui chuchote les répliques aux acteurs. Métaphore exacte de ce que fait l'app : elle souffle le mot suivant.

---

## 0. Positionnement

> **« Le souffleur français pour ton Mac. Bilingue FR/EN natif, achat unique, vie privée vérifiable. »**

### Stratégie : clone fidèle + 3 wedges

Souffleuse vise feature parity avec Cotypist (référence du marché en 2026), mais se différencie sur trois axes que ni Cotypist ni Caret n'occupent :

| Axe | Cotypist | Caret | Apple Intelligence | **Souffleuse** |
|---|---|---|---|---|
| Multilingue FR-first | Anglo-centrique | Anglo-centrique | Multi mais générique | **FR + EN natifs, code-switching, accords, registre tu/vous** |
| Pricing | Abonnement (critiqué Reddit) | TBD | Gratuit | **One-time purchase** + mises à jour modèle optionnelles |
| Privacy | Closed-source, on parole | Closed-source | Black box Apple | **Open weights vérifiables, checksums publics, no telemetry** |

### Pourquoi ce wedge

- **Marché** : quadrant local + system-wide a seulement 3 acteurs (Cotypist, Caret avril 2026, Apple). Fenêtre 12-18 mois avant qu'Apple Intelligence ne ferme l'opportunité côté grand public.
- **Validation paiement** : Wispr Flow ($30M levés) prouve qu'on paie pour améliorer la saisie. Cursor/Copilot prouvent le willingness-to-pay sur autocomplete. WunderType prouve qu'un one-time fonctionne au Mac App Store.
- **Marché FR sous-servi** : francophonie (FR + QC + BE + CH) ignorée par les indés US. Premier acteur sérieux sur ce créneau gagne la mindshare.

### Risques identifiés

1. **Apple Intelligence rattrape** → contre-mesure : profondeur features (apprentissage style, profils par app, snippets) qu'Apple ne fera pas à court terme.
2. **Caret prend les early adopters** → contre-mesure : exécution rapide Jalon 1+2, lancement beta sous 3 mois.
3. **Multilingue FR demande modèle plus gros** → contre-mesure : benchmarks comparatifs Gemma 3 vs Qwen 3 sur corpus français dès Jalon 1.

---

## 1. Vision et périmètre

### Promesse utilisateur
- Pendant que je tape, un texte gris apparaît en ligne avec la suite probable.
- Tab → j'accepte le mot suivant (ou la suggestion complète).
- Esc ou continuer à taper → je rejette.
- Tout est local, rien ne quitte la machine.

### Hors scope (v1)
- Apprentissage personnalisé (LoRA, fine-tuning) → v2
- Synchronisation cross-device → jamais
- Apps Electron problématiques (Slack desktop, Discord) → best effort, fallback graceful
- Code editors / terminals → désactivé par défaut

### Cibles techniques
- **Time-to-first-token** : < 100 ms (M1 base)
- **RAM résident actif** : 1 – 2 GB
- **CPU idle** : < 2 %
- **macOS** : 14+ (Sonoma), Apple Silicon uniquement

---

## 2. Vue d'ensemble

```
┌──────────────────────────────────────────────────────────┐
│                    macOS user session                    │
│                                                          │
│  ┌──────────┐   AX events    ┌──────────────────────┐    │
│  │ Mail.app │ ─────────────► │   FocusObserver      │    │
│  │ Safari   │ ◄───── inject  │   (AXObserver)       │    │
│  │ Notes…   │                └──────────┬───────────┘    │
│  └──────────┘                           │ context        │
│                                         ▼                │
│                                ┌─────────────────────┐   │
│                                │   Predictor         │   │
│                                │   (MLX, async)      │   │
│                                └─────────┬───────────┘   │
│                                          │ tokens stream │
│                                          ▼               │
│                                ┌─────────────────────┐   │
│                                │   GhostOverlay      │   │
│                                │   (NSWindow + Text) │   │
│                                └─────────────────────┘   │
│                                          ▲               │
│                              CGEventTap  │ Tab/Esc       │
└──────────────────────────────────────────┴───────────────┘
```

Trois modules indépendants reliés par un `Coordinator` :

| Module | Responsabilité | Tech |
|---|---|---|
| **FocusObserver** | Détecter le champ texte actif, lire le contexte avant le caret, calculer la position du caret à l'écran | `AXObserver`, `AXUIElement` |
| **ContextEnricher** | Enrichir le contexte avec signaux optionnels (screenshot de l'app frontale, presse-papier, nom app, titre fenêtre) | `ScreenCaptureKit`, `NSPasteboard`, `NSWorkspace` |
| **Predictor** | Générer la suite probable du texte, streaming | `mlx-swift`, modèle quantisé 4-bit |
| **GhostOverlay** | Afficher le texte fantôme par-dessus l'app cible, capter Tab/Esc, injecter le texte accepté | `NSPanel` transparent, `CGEventTap`, `AXUIElementSetAttributeValue` |
| **SettingsStore** | Préférences utilisateur, profils par app, raccourcis, modèle actif | `UserDefaults` + JSON profils |
| **ModelManager** | Téléchargement, vérification d'intégrité, switch entre modèles | `URLSession`, MLX loader |

---

## 3. Modules en détail

### 3.1 FocusObserver

**Rôle** : savoir où l'utilisateur tape, quoi, et où afficher la suggestion.

**APIs** :
- `AXObserverCreate` + `kAXFocusedUIElementChangedNotification` sur l'app frontale
- `NSWorkspace.didActivateApplicationNotification` pour repivoter l'observer
- `kAXValueAttribute` (texte complet), `kAXSelectedTextRangeAttribute` (position caret)
- `kAXBoundsForRangeParameterizedAttribute` pour la rect écran du caret
- `kAXRoleAttribute` filter : `AXTextField`, `AXTextArea`, `AXComboBox`

**Stratégie polling/event** : préférer notifications AX, mais débounce frappe via timer 80 ms (les events `AXValueChanged` arrivent par burst).

**Contexte transmis au Predictor** : 2048 derniers caractères avant le caret, plus métadonnées (nom de l'app, langue détectée via `NSLinguisticTagger`). Enrichi par `ContextEnricher` (voir 3.2).

**Edge cases connus** :
- Apps Electron : AX expose un seul nœud opaque → fallback désactivé pour ces apps en v1, allowlist progressive en v2.
- Champs sécurisés (mot de passe) : `kAXSubroleAttribute == AXSecureTextField` → ignorer absolument.
- Apps sans AX (terminaux, code editors) : ignorer par défaut, liste configurable.

### 3.2 ContextEnricher

**Rôle** : ajouter des signaux contextuels au-delà du texte brut. Tout est opt-in, tout est local, rien n'est stocké.

**Sources** (chacune désactivable indépendamment) :

| Source | Permission | Apport | Coût |
|---|---|---|---|
| Nom app + titre fenêtre | aucune | "Je tape dans Mail à propos de X" | nul |
| **Screen Recording** | `ScreenCaptureKit` | Vision du contexte visuel (formulaire web, document en lecture) | ~50 ms par capture, on-demand |
| **Clipboard** | aucune (mais opt-in) | Le presse-papier indique souvent ce sur quoi l'utilisateur travaille | nul |
| Selection courante | AX déjà acquis | Texte sélectionné = sujet probable | nul |

**Stratégie d'enrichissement** :
- Screenshot pris seulement au changement de focus app, pas à chaque frappe. Cache 5 s.
- OCR du screenshot via `VNRecognizeTextRequest` (Vision framework) — top 500 chars insérés en préfixe contextuel
- Clipboard lu une fois par focus change, tronqué à 500 chars
- Tout est concaténé dans un préfixe système court avant le contexte texte :
  ```
  [App: Mail | Window: "Re: Invoice Q2"]
  [Clipboard excerpt: …]
  [Visible context: …]
  [User text]: …
  ```

**Privacy hard rules** :
- Screenshots jamais persistés sur disque, jamais loggés
- Clipboard non lu si l'app frontale est dans une blocklist (1Password, Keychain Access, banking apps)
- Toggle global "désactiver tout enrichissement" en un raccourci

### 3.3 Predictor

**Rôle** : produire un suffixe probable, en streaming.

**Modèle candidat principal** : **Gemma 3 1B** quantisé 4-bit (~0.8 GB sur disque, ~1.2 GB RAM).
- Choix par défaut de Cotypist pour M1 base — bon compromis qualité/latence
- Multilingue, bonne base instruct, support officiel MLX
- TTFT estimé ~60-100 ms sur M1, ~25-35 tokens/s

**Catalogue de modèles proposés à l'utilisateur** (alignés sur Cotypist) :

| Modèle | Taille | RAM | Cible |
|---|---|---|---|
| Gemma 3 1B | 0.8 GB | ~1.2 GB | **Défaut** M1 base / 8 GB RAM |
| Qwen 3 1.7B | 1.2 GB | ~1.8 GB | M1 base, qualité supérieure |
| Gemma 3 4B | 2.3 GB | ~3 GB | M1 Pro / 16 GB |
| Qwen 3 4B | 2.3 GB | ~3 GB | M1 Pro / 16 GB |
| Gemma 4 E2B | 3.2 GB | ~4 GB | M2 Pro+ |
| Qwen 3 8B | 4.7 GB | ~6 GB | M2 Max / 32 GB |
| Gemma 4 E4B | 6.2 GB | ~8 GB | M2 Max+ |
| Qwen 3 30B A3B (MoE) | 13.7 GB | ~16 GB | M3 Max / 64 GB |
| Gemma 4 26B A4B (MoE) | 15.7 GB | ~18 GB | Power users |

Auto-recommandation basée sur RAM système + chip detection au premier lancement.

**Framework** : `mlx-swift` + `mlx-swift-examples` (paquet `MLXLLM`).
- Modèle chargé une fois au lancement, gardé en mémoire
- Génération sur un `Task` détaché, annulable via `Task.cancel()` à chaque nouvelle frappe

**Prompt** : *completion brute, pas de chat template*. Le modèle reçoit directement le texte de l'utilisateur et continue. On utilise la version base si disponible, sinon on bypasse le chat template.

**Critères d'arrêt** (configurables — préf "Maximum Completion Length") :
- **Short** : ~1 mot (8 tokens max)
- **Medium** : ~2-4 mots (16 tokens max) — **défaut**
- **Long** : phrase complète (32 tokens max)
- Stop tokens : `\n\n`, `. ` après début de phrase, fin de phrase contextuelle
- Annulation immédiate si nouvelle frappe entre-temps

> Note UX (alignée Cotypist) : on recommande Medium par défaut. Les longues complétions sont plus lentes à générer, perturbent le flux, et dévient plus souvent de l'intention. Raccourci "accept-next-word-only" pour récupérer la partie utile d'une suggestion trop longue.

**Filtre qualité** :
- Reject si la suggestion répète les 8 derniers chars du contexte
- Reject si entropie très basse (modèle qui boucle)
- Reject si langue détectée ≠ langue du contexte

### 3.4 GhostOverlay

**Rôle** : afficher le texte fantôme et gérer l'acceptation.

**Implémentation** :
- `NSPanel` `.borderless`, `.nonactivating`, `.transparent`, level `.statusBar`
- Positionné via les rect retournés par `kAXBoundsForRangeParameterizedAttribute`
- Texte rendu en `NSAttributedString` gris 40 % opacité, même police que le champ cible (best effort : sinon SF Mono / SF Pro)

**Acceptation** :
- `CGEventTap` sur `kCGEventKeyDown` au niveau session (nécessite Accessibility permission)
- Si suggestion active + Tab : consommer l'event, injecter le texte, masquer overlay
- Word-by-word : Option+Tab accepte un mot, Tab accepte tout

**Injection** :
- Voie 1 (préférée) : `AXUIElementSetAttributeValue(kAXSelectedTextAttribute)` — propre, undoable
- Voie 2 (fallback) : `CGEventCreateKeyboardEvent` simulant la frappe — fonctionne partout mais perd l'undo natif

**Position du caret introuvable** : si AX ne renvoie pas de bounds (apps web rendues en canvas), désactiver overlay pour cette session/app.

---

## 4. Modèle de threading

| Thread | Rôle |
|---|---|
| Main | UI, NSWindow, CGEventTap callback |
| `focusQueue` (serial) | Lecture AX, calcul contexte |
| `inferenceQueue` (serial, QoS userInitiated) | Génération MLX |

**Annulation** : chaque frappe annule la `Task` MLX courante avant d'en lancer une nouvelle. Le debounce de 80 ms évite de lancer/tuer en boucle.

**Pas de réutilisation de KV cache cross-frappe en v1** : trop complexe, gain ~30 % de TTFT. Réservé v1.1.

---

## 5. Sécurité, vie privée, permissions

- **Aucun réseau** : entitlement `com.apple.security.network.client` absent. Vérifié au build.
- **Sandbox** : impossible (Accessibility API requiert sortie de sandbox) → distribution hors Mac App Store, signé Developer ID + notarisé.
- **Permissions** :
  1. **Accessibility** (requis) — lecture/écriture champs texte + `CGEventTap`
  2. **Screen Recording** (recommandé, optionnel) — capture contextuelle visuelle
  3. **Input Monitoring** (selon macOS) — souvent inclus dans Accessibility, à confirmer

- **Coexistence avec macOS** :
  - Inviter l'utilisateur à désactiver les suggestions natives de macOS (System Settings → Keyboard → Text Input → Show inline predictive text) pour éviter conflit visuel et concurrence sur Tab
- **Données utilisateur** : tout reste en RAM. Aucun log de texte. Crash reports anonymisés (sans contenu).
- **Champs sensibles** : password fields exclus. Liste d'apps blocked-by-default (1Password, Keychain Access, Banking, etc.).

---

## 5.bis Threat model et privacy profonde

### Persistance de texte utilisateur — Personnalisation Jalon 3.X

**Pourquoi ce changement de posture ?** Avant Jalon 3.X, l'invariant était "aucun texte utilisateur n'est persisté sur disque". Avec la personnalisation par historique de frappe (toggle opt-in, défaut OFF), on déroge consciemment à cet invariant : les suggestions acceptées via Tab sont écrites sur disque pour entraîner un modèle n-gram local qui biaise les suggestions du LLM vers les tournures habituelles de l'utilisateur. Cette dérogation est strictement encadrée :

| Vecteur | Mitigation |
|---|---|
| Fichier `~/Library/Application Support/Souffleuse/history.aes` lu par une app malveillante voisine | Chiffrement AES-GCM 256-bit. La clé est dans le **Keychain login** (`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`). Sans la clé, le fichier est inutilisable. |
| Attaquant avec accès Keychain (root / utilisateur logué) | **Hors scope** — c'est le contrat macOS standard. Documenté. |
| Backup Time Machine ou sauvegarde tierce | Le fichier chiffré est sauvegardé tel quel. La clé Keychain est incluse dans le backup login. Sur le **même Mac restauré** : lisible. Sur **un autre Mac** : illisible. Conforme à l'attente Apple. |
| iCloud Keychain sync entre Macs de l'utilisateur | Possible si l'utilisateur a activé iCloud Keychain. **Accepté** : c'est sa propre cuisine, jamais hors de ses devices. |
| Mot de passe collé puis tapé dans un champ "normal" | (1) Blocklist apps (1Password, Bitwarden, banks, terminaux) — réutilise `ClipboardReader.defaultBlocklist`. (2) Heuristique entropie : refuse toute suggestion qui contient un token alphanumérique ≥16 chars sans espace. |
| Screenshot ou screen-share de la fenêtre "Voir mes données" | `NSWindow.sharingType = .none` désactive la capture système et le partage d'écran sur cette fenêtre. |
| Bug qui logge le contenu d'une entry | `audit.sh` check #5 interdit toute lecture de `history.aes` hors `TypingHistoryStore` et `HistoryViewerWindow`. Check #6 interdit toute interpolation de `accepted` / `contextBefore` dans un `Log.*` call. |
| Utilisateur veut tout effacer | Bouton "Tout supprimer" dans Préférences > Personnalisation : `history.clear()` zéroise le fichier ET supprime la clé Keychain. Le rebuild n-gram retombe à vide. |

**Contraintes invariantes** :
- Le toggle est **OFF par défaut**. Aucune collecte sans opt-in explicite + modal d'onboarding consenti au premier ON.
- Aucun appel réseau pour cette feature, jamais. La doc Préférences l'affiche.
- Le ring buffer cape à 200 entrées (~50 KB) — pas de croissance illimitée.
- Le fichier ne stocke que les Tab acceptations LLM, **jamais** les acceptations typo (corrections, pas style).

### Adversaires considérés

| Adversaire | Capacité | Ce qu'on protège |
|---|---|---|
| **Apps malveillantes voisines** sur le Mac | Lecture process memory si pas hardened, lecture caches disk | Buffer prompt en mémoire, modèle chargé, contexte enrichi |
| **Accès physique temporaire** (laptop volé/laissé) | Lecture FileVault si déverrouillé, paging, hibernation, swap | Aucune trace persistante des prompts |
| **Apple via crash reports** | Tout ce qui finit dans `DiagnosticReports` | Pas de texte utilisateur dans les crash dumps |
| **Réseau passif** (FAI, captive portal, employeur) | Voir nos requêtes sortantes et leur fréquence | Métadonnées d'usage (fréquence, IP), update checks |
| **Compromission de notre propre code** (bug, malicious dep) | Comportement keylogger involontaire | Capacité à auditer ce que notre process a réellement fait |
| **Compromission supply chain** (modèle modifié, build modifié) | Faux modèle distribué, binaire altéré | Intégrité vérifiable hors-bande |

### Hors scope (assumé non protégé)

- Adversaire avec **root** sur la machine → game over, on ne prétend pas le contraire
- Side-channels matériels (Spectre-like, power analysis)
- Keyloggers OS-level installés indépendamment
- Utilisateur qui prend une photo de l'écran

### Contre-mesures (mappées sur les 4 piliers)

#### Pilier 1 — Isolation process (XPC)

Trois processes séparés au lieu d'un monolithe :

```
┌──────────────────┐     XPC      ┌──────────────────┐
│  SouffleuseUI    │ ───────────► │  AXAgent         │
│  (Settings, MIB) │              │  (AX + caret)    │
│                  │              │  Sandbox: NONE   │
│  Sandbox: YES    │              │  Entitlements:   │
└─────────┬────────┘              │   AX, Input Mon  │
          │ XPC                   └────────┬─────────┘
          ▼                                │ contexte
┌──────────────────┐                       │
│  InferenceAgent  │ ◄─────────────────────┘
│  (MLX, modèles)  │
│  Sandbox: YES    │
│  Pas de réseau   │
│  Pas d'AX        │
└──────────────────┘
```

**Bénéfices** :
- **AXAgent** a Accessibility (clé maîtresse) mais zéro accès réseau (`com.apple.security.network.client` absent), zéro accès disque hors `~/Library/Application Support/Souffleuse/`
- **InferenceAgent** n'a aucune permission système, ne voit que les buffers texte passés via XPC
- **SouffleuseUI** est sandboxé strict, ne touche pas l'AX
- Si l'un est compromis, les deux autres restent intègres

#### Pilier 2 — Hygiène mémoire

- **`mlock`** sur le buffer prompt et le buffer de génération → bloque le paging vers swap chiffré (mais persistant en hibernation)
- **Zeroing explicite** (`memset_s`) après chaque dismissal de suggestion, après chaque change de focus app, à l'extinction de l'agent
- **Crash dumps désactivés** sur l'AXAgent et l'InferenceAgent : `setrlimit(RLIMIT_CORE, 0)` + `os_log` configuré sans contenu utilisateur
- **Pas de logs verbeux** en build release. Le seul log autorisé : compteurs (nb suggestions générées, latence p50/p99) sans texte
- **`DisableFreezeReport`** dans Info.plist pour bloquer les sysdiagnose hangs

#### Pilier 3 — Stratégie réseau zero-leak

**Règle d'or** : la seule action réseau du process AXAgent ou InferenceAgent est `0`. Aucune. Vérifiable par `nettop -p souffleuse-ax-agent`.

Seules sorties réseau acceptées, depuis SouffleuseUI uniquement, sur action utilisateur explicite :

| Endpoint | Quand | Données envoyées |
|---|---|---|
| Téléchargement modèle | Clic "Download" sur modèle | Nom du modèle + HEAD request |
| Vérification update | Clic "Check for updates" | Version actuelle |
| Aucun "phone home" automatique | jamais | rien |

**Update checks** : **pas de Sparkle auto-check** en v1. L'utilisateur clique pour vérifier. Trade-off accepté : moins d'updates rapides, mais zéro leak passif d'IP/fréquence.

**Intégrité du modèle** :
- Chaque modèle distribué via Hugging Face mirror + notre CDN
- Manifest `models.json` signé **Ed25519**, clé publique embarquée dans le binaire
- Chaque modèle : SHA-256 dans le manifest, vérifié post-download avant chargement
- Refus de charger si signature ou hash invalide

**Hosting** : modèles sur Hugging Face (canal officiel, pérenne) + miroir Cloudflare R2 (notre infra). Pas de tracking côté HF (téléchargement anonyme).

#### Pilier 4 — Auditabilité

- **Audit log local** dans `~/Library/Application Support/Souffleuse/audit.log` (lisible uniquement par l'utilisateur, JSONL) : `{timestamp, event, bytes_in, bytes_out, app_bundle_id}`. Aucun contenu texte, juste des métadonnées. Permet à l'utilisateur paranoïaque de vérifier ce que l'agent a fait.
- **Build reproductible** : recette `make reproducible-build` documentée. Hash binaire publié sur le site, comparable au build local.
- **Audit externe** payé une fois par release majeure (cabinet sec indépendant, type Trail of Bits / Cure53 si budget).
- **Open weights** dès le départ. Open source du code → décision différée.

### Stockage local

| Donnée | Emplacement | Chiffrement |
|---|---|---|
| Settings UI (toggles, raccourcis) | `~/Library/Preferences/...plist` | Compte sur FileVault |
| Profils par app, allowlist | `~/Library/Application Support/Souffleuse/profiles.json` | FileVault |
| Snippets perso | `~/Library/Application Support/Souffleuse/snippets.enc` | **AES-256-GCM**, clé dans **Keychain** |
| Compteurs statistics | `stats.sqlite` | FileVault — **intégers uniquement, jamais de texte** |
| Modèles téléchargés | `~/Library/Application Support/Souffleuse/models/` | FileVault |
| Audit log | `audit.log` | FileVault — pas de texte utilisateur |

**Garantie textuelle** : aucun fichier ne contient jamais de texte saisi par l'utilisateur. La personnalisation v2 (LoRA) devra trouver une solution dédiée (training in-memory ou chiffrement séparé).

### Coexistence multi-utilisateur Mac

Toute la config est par-utilisateur (`~/Library/...`). Pas de partage. Chaque session macOS recharge son modèle.

### Communication transparente au premier lancement

Écran d'onboarding "Ce que Souffleuse voit, ce qu'elle ne voit pas" :
- ✅ Lit le texte des champs où vous tapez (nécessaire)
- ✅ Lit le presse-papier si activé
- ✅ Capture l'écran si activé
- ❌ N'envoie rien sur le réseau sans votre clic
- ❌ Ne stocke aucun texte sur disque
- ❌ Ne se met pas à jour sans votre demande
- 🔍 Vous pouvez auditer son activité : `~/Library/Application Support/Souffleuse/audit.log`

---

## 6. UX critique

- **Panneau de préférences** (sections, alignées sur Cotypist) :
  - **Setup** — checklist permissions, téléchargement modèle, désactivation suggestions macOS, contexte presse-papier
  - **General** — launch at login, status menu item, accessory button
  - **AI Model** — choix du modèle, recommandation auto, dossier des modèles
  - **Context** — toggles screen recording, clipboard, selection
  - **Personalization** — vocabulaire, expressions favorites (v2 : LoRA)
  - **Emoji** — `:smile:` → 😄 dictionnaire
  - **Shortcuts** — Tab, accept-word, suspend, toggle
  - **App Settings** — allowlist / blocklist par app
  - **Souffleuse Labs** — features expérimentales opt-in
  - **Statistics** — mots acceptés, temps gagné, modèles utilisés (local only)
  - **About / Contact Support**

- **Deux modes d'affichage des suggestions** (l'utilisateur choisit) :
  1. **Ghost text inline** — par-dessus le champ texte (mode par défaut)
  2. **Accessory button** — petit bouton flottant près du caret qui ouvre un menu de la suggestion (fallback pour apps où l'overlay inline ne s'aligne pas, ex. Electron)
- **Onboarding** : guide pas-à-pas pour donner les permissions (System Settings ne peut pas être ouvert programmatiquement de manière fiable depuis Sonoma → instructions + deep link `x-apple.systempreferences:com.apple.preference.security`).
- **Indicateur d'activité** : icône menubar discrète, état "thinking" pendant génération.
- **Toggle global** : raccourci ⌃⌥⌘S pour suspendre.
- **Per-app config** : allowlist / blocklist visible dans préférences.
- **Premier usage par app** : la première fois qu'on s'active dans une app, petit toast non intrusif "Souffleuse active dans Mail — ⌃⌥⌘S pour désactiver".

---

## 7. Distribution

- **Format** : `.app` signé + notarisé, livré en `.dmg` ou via Homebrew Cask.
- **Mises à jour** : Sparkle 2.
- **Crash reporting** : Sentry self-hosted ou rien en v1 (privacy first).

---

## 8. Roadmap

### Jalon 1 — Cœur prédictif (2 sem)
- [ ] Projet Xcode SwiftUI macOS
- [ ] Intégration `mlx-swift` + `MLXLLM`
- [ ] Chargement Qwen2.5-0.5B-4bit
- [ ] Démo : NSTextView local avec ghost text + Tab à accepter
- [ ] Mesure TTFT, throughput, RAM

### Jalon 2 — Injection système (3 sem)
- [ ] FocusObserver bout-en-bout sur TextEdit
- [ ] GhostOverlay positionné correctement
- [ ] CGEventTap Tab/Esc
- [ ] Injection via AX
- [ ] Test sur Notes, Safari, Mail
- [ ] Permissions onboarding (Accessibility + Screen Recording optionnel)

### Jalon 2.5 — ContextEnricher (1 sem)
- [ ] Capture ScreenCaptureKit + OCR Vision
- [ ] Lecture presse-papier opt-in
- [ ] Préfixe contextuel formaté
- [ ] Mesure impact qualité (avec / sans enrichissement)

### Jalon 3 — Polish (2 sem)
- [ ] Préférences (allowlist, raccourci, modèle)
- [ ] Icône menubar
- [ ] Détection typos basique
- [ ] Emoji `:smile:` → 😄
- [ ] Build signé + notarisé + DMG
- [ ] Site landing minimal

### Plus tard (post-v1)
- Personnalisation LoRA depuis phrases acceptées
- KV cache cross-frappe
- Apps Electron via injection JS (Slack, Discord)
- Vision Pro / iPad ?

---

## 9. Questions ouvertes

1. **Modèle par défaut** : Gemma 3 1B confirmé après benchmark, ou Qwen 3 1.7B si la qualité justifie le surcoût RAM ? Décision Jalon 1.
2. **Acceptation Tab** : conflit avec Tab natif dans formulaires web. Solution : suggestion masquée si dernier event est focus change.
3. **Multi-écrans / Spaces** : overlay doit suivre. À tester.
4. **VoiceOver** : l'overlay ne doit pas être annoncé. `accessibilityElement = false`.
5. **Curseur clignotant** : risque de race entre nos read AX et l'app source. Snapshot avant inject.

---

## 10. Décisions prises

| # | Décision | Raison | Date |
|---|---|---|---|
| 1 | Swift + SwiftUI natif | Accès direct AX, MLX, perf | 2026-05-21 |
| 2 | MLX (vs llama.cpp) | First-party Apple Silicon, intégration Swift propre | 2026-05-21 |
| 3 | Approche progressive 3 jalons | Valider risque modèle avant risque AX | 2026-05-21 |
| 4 | Hors Mac App Store | AX impose sortie sandbox | 2026-05-21 |
| 5 | Nom : Souffleuse | Métaphore parfaite, français, féminin | 2026-05-21 |
| 6 | Famille de modèles : Gemma 3/4 + Qwen 3 | Aligné Cotypist, support MLX, multilingue | 2026-05-21 |
| 7 | Défaut : Gemma 3 1B 4-bit | 0.8 GB, tourne sur M1 base, recommandé par Cotypist | 2026-05-21 |
| 8 | Deux modes d'affichage : inline + accessory button | Fallback pour apps où inline échoue (Electron) | 2026-05-21 |
| 9 | Swift natif (pas Tauri/Rust) | 95 % surface API Apple, MLX-swift first-party, pas de pont FFI multiple | 2026-05-21 |
| 10 | Screen Recording + Clipboard en enrichissement opt-in | Aligné Cotypist, gain qualité significatif, privacy préservée | 2026-05-21 |
| 11 | Positionnement : clone fidèle + FR-first + one-time + privacy vérifiable | Wedge unique vs Cotypist/Caret, marché FR sous-servi | 2026-05-21 |
| 12 | One-time purchase (pas d'abonnement v1) | Différenciation vs Cotypist, validé par WunderType | 2026-05-21 |
| 13 | Open weights + checksums publics | Différenciation privacy vérifiable vs closed-source concurrents | 2026-05-21 |
| 14 | Architecture XPC 3-process (UI/AXAgent/InferenceAgent) | Isolation blast radius, AX et inférence séparées | 2026-05-21 |
| 15 | Pas d'auto-update check en v1 | Zero phone-home, update vérification manuelle uniquement | 2026-05-21 |
| 16 | Manifest modèles signé Ed25519, clé embarquée | Intégrité vérifiable des poids téléchargés | 2026-05-21 |
| 17 | Audit log local JSONL sans texte | Utilisateur paranoïaque peut vérifier l'activité de l'agent | 2026-05-21 |
| 18 | Open source : décision différée | Choix structurant à prendre après spike technique | 2026-05-21 |
| 19 | macOS only, pas de roadmap iOS/iPadOS | Focus, iOS bloqué par keyboard extension memory cap Apple | 2026-05-21 |
| 20 | ~~Modèle Instruct interdit pour autocomplete~~ → **Modèle Instruct AVEC system message contraignant est strictement meilleur** | Décision initiale basée sur un bench Llama-Instruct sans system message → mode chatbot. Re-bench Jalon 3 : Instruct + system "tu es un autocomplete, sors uniquement la continuation, dans la langue de l'utilisateur, sois bref" → suit les Custom Instructions, reste dans la langue, ne dérive pas. Hypothèse Cotypist confirmée par comportement observé sur le même hardware. | 2026-05-21 / révisé 2026-05-22 |
| 21 | **Défaut : `gemma-3-1b-pt-4bit`** (footprint léger 1.5 GB RAM). Qwen 2.5 1.5B Instruct disponible dans le picker pour meilleur suivi d'instructions (RAM 2 GB). | Garder un défaut petit pour ne pas pénaliser les Macs 8 GB ; les utilisateurs qui veulent la qualité Cotypist switchent vers Qwen Instruct via Préférences. | 2026-05-21 / révisé 2026-05-22 |
