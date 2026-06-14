# Jalon 3 — Polish

> On a un produit qui marche : ghost text local, injection AX, enrichissement contextuel mesurable. Jalon 3 transforme le prototype en logiciel qu'un utilisateur installe et garde. Préférences vraies, ergonomie d'édition (typos + emoji), logs propres, signature + notarisation, landing publique minimale.

## Pré-requis (état au démarrage)

- `git log` : Jalon 2.5 mergé sur `main` au commit `7b8811e`
- `swift run Souffleuse` lance l'app, menubar fonctionnelle, ghost text dans Mail/Notes/Safari
- Onboarding permissions OK, enrichissement contextuel A/B validé
- Aucune signature codée pour l'instant (`spctl` rejette en `Gatekeeper assessment failed`)

Lire avant de commencer :
- `ARCHITECTURE.md` §3 Modules, §7 Distribution, §8 Jalon 3
- `JALON2.5-PLAN.md` §"Hors scope" — ce qui a été reporté ici
- `BENCHMARKS.md` pour comprendre les budgets perf à ne pas régresser

## Définition of done

1. Une vraie fenêtre **Préférences** (pas juste un menu) avec onglets : Général, Modèle, Enrichissement, Allowlist, À propos. Persistance via `UserDefaults` + fichier pour la blocklist.
2. Détection typos basique (Levenshtein ≤2 vs dictionnaire courant FR+EN, suggestion via le pipeline existant).
3. Expansion `:smile:` → 😄 (mappable, source unicode-emoji standard) déclenchée au `space` ou `enter`.
4. Tous les `print` / `NSLog` redirigés vers `~/Library/Logs/Souffleuse.log` avec rotation simple (1 MB / fichier, 3 backups), niveaux `info|warn|error`, jamais de texte utilisateur, jamais de clipboard, jamais d'OCR. Audit grep sur le log produit 0 fuite.
5. `Souffleuse.app` est signé Developer ID, notarisé Apple, stapled, packagé en DMG ouvrable hors quarantaine. `spctl --assess --type execute Souffleuse.app` → `accepted`. Distribué depuis un DMG `souffleuse-0.3.0.dmg` < 200 MB (modèle séparé téléchargé à l'onboarding ? **décision Phase D**).
6. Une landing statique en ligne (un seul HTML + CSS), URL stable, lien direct vers le DMG + hash SHA-256 affiché.

Tous les tests d'acceptance des 5 phases ci-dessous passent **et** un audit `bash audit.sh` (script à écrire Phase A) ne remonte aucune violation privacy.

## Risques connus et contre-mesures

| # | Risque | Contre-mesure |
|---|---|---|
| R1 | Fenêtre Préférences ouverte = focus quitte l'app cible = enrichissement / overlay cassés | Détection `NSApp.isActive` côté FocusObserver, suspension douce du pipeline pendant Préférences ouvertes |
| R2 | Allowlist par bundle ID ne couvre pas les apps Electron (un seul bundle pour 10 fonctions) | Allowlist supporte `bundleID + window title regex` ; UI laisse ajouter une règle composée |
| R3 | Détection typos remplace un mot intentionnel rare (ex: nom propre) | Toujours suggestion via ghost (jamais auto-replace), seuil Levenshtein strict, dictionnaire utilisateur "ignorer ce mot" persistant |
| R4 | Expansion `:smile:` interfère avec markdown / code (`std::vector`) | Désactivée si app frontale ∈ liste IDE (`com.microsoft.VSCode`, `com.apple.dt.Xcode`, JetBrains…) et si le contexte AX précédent contient `:` non isolé |
| R5 | Log fichier grossit silencieusement, finit par exposer du contenu sensible | Rotation 1 MB stricte, format ligne JSONL avec champs whitelist (`ts, level, module, event, count`), **interdit d'y mettre une string utilisateur** — assert en debug |
| R6 | Notarisation Apple échoue pour cause d'entitlement / dépendance MLX | Test sur build "vide" d'abord (Souffleuse stub), puis ajouter MLX, isoler le step qui casse |
| R7 | Le modèle 0.8 GB embarqué fait exploser le DMG > 500 MB | Option : DMG slim (< 30 MB) + téléchargement modèle à l'onboarding depuis manifest signé Ed25519 (cf. décision §10 #16) |
| R8 | Landing publie un binaire signé avec ma clé personnelle = nom dev exposé | Décision consciente, c'est le contrat Developer ID. Documenter dans `README.md` que le nom dans `codesign -dv` est attendu |
| R9 | Logs rotation race-condition multi-process (UI + futures XPC) | Un seul writer process (UI), les autres future-XPC enverront via channel — pas un problème en J3, noter pour J4 |

## Découpage en 5 phases

Séquentiel A → E. A et B peuvent se chevaucher en pratique mais on les commit séparément. D ne démarre **pas** tant que A→C ne sont pas verts (un binaire mal hygiénisé qu'on signe = on signe un problème).

---

### Phase 3.A — Logs propres + audit privacy (1 jour)

**But** : avant tout polish, on ferme la fuite-canal-le-plus-probable (logs stderr qui finissent dans Console.app, screenshots de devs en démo, etc.). Un audit script attrapera toute régression future.

**Livrable**
- `Sources/SouffleuseLog/Log.swift` — module dédié, API minimaliste :
  ```swift
  enum LogLevel: String { case info, warn, error }
  enum LogModule: String { case ax, overlay, input, context, predictor, ui }
  func log(_ level: LogLevel, _ module: LogModule, _ event: String, count: Int? = nil)
  ```
- Fichier JSONL `~/Library/Logs/Souffleuse.log` : une ligne par event, champs **whitelist stricte** : `{ts, level, module, event, count?}`. Aucun autre champ accepté (enforce via struct, pas `[String: Any]`).
- Rotation : à chaque write, si fichier > 1 MB → rename `.log` → `.log.1`, shift `.1` → `.2`, drop `.3`. 3 backups max.
- Script `audit.sh` à la racine du repo :
  ```bash
  #!/usr/bin/env bash
  # Vérifie qu'aucun chemin de code ne sérialise du texte utilisateur dans un log.
  set -e
  echo "=== Recherche print() résiduels ==="
  ! grep -rn "^\s*print(" Sources/ || { echo "FAIL: print() trouvé"; exit 1; }
  echo "=== Recherche NSLog résiduels ==="
  ! grep -rn "NSLog(" Sources/ || { echo "FAIL: NSLog trouvé"; exit 1; }
  echo "=== Recherche os_log avec interpolation %@ string ==="
  ! grep -rn 'os_log.*%@.*\(text\|clipboard\|prompt\|suggestion\)' Sources/ || { echo "FAIL: log de texte utilisateur"; exit 1; }
  echo "=== Audit log file fields ==="
  if [ -f ~/Library/Logs/Souffleuse.log ]; then
    jq -r 'keys[]' ~/Library/Logs/Souffleuse.log | sort -u | tee /tmp/log-keys.txt
    diff <(echo -e "count\nevent\nlevel\nmodule\nts") /tmp/log-keys.txt || { echo "FAIL: champ inattendu dans log"; exit 1; }
  fi
  echo "OK"
  ```
- Migration : remplacer tous les `print` et `NSLog` du codebase. Compteur attendu post-migration : 0 dans `Sources/`.

**Edge cases à valider**
- App lancée pour la première fois (`~/Library/Logs/` n'existe pas) → création silencieuse, pas de crash
- Disque plein → write échoue silencieusement, app continue (log au mieux dans stderr en debug uniquement)
- Multiples threads concurrents → serial queue dédiée pour le writer (1 actor)

**Test acceptance**
```bash
swift build
swift run Souffleuse &
# usage normal 5 min : taper dans Mail, Notes, accepter suggestions, toggle enrichment
kill %1
bash audit.sh
# attendu : OK
wc -l ~/Library/Logs/Souffleuse.log  # quelques dizaines de lignes
grep -i "bonjour\|password\|test123" ~/Library/Logs/Souffleuse.log  # attendu : 0 résultat
```

**Commit attendu** : `Jalon 3.A: logging fichier JSONL + rotation + audit script`

---

### Phase 3.B — Fenêtre Préférences (2 jours)

**But** : remplacer le menu plat par une fenêtre SwiftUI avec onglets, persistance, et **allowlist par app** (vraie fonctionnalité qui change le comportement, pas juste de l'UI).

**Livrable**
- `Sources/Souffleuse/PreferencesWindow.swift` — `NSWindow` borderless-titled, `TabView` SwiftUI à 5 onglets :
  1. **Général** : toggle "Activée" (mirror du global), raccourci ⌃⌥⌘S configurable (lecture seule en v1, juste affiché), lancement au démarrage (LoginItem via `SMAppService`)
  2. **Modèle** : picker entre 2 modèles ; chaque entrée montre nom, taille disque, RAM estimée, langue. Bouton "Télécharger" si manquant (vérif manifest Ed25519). Bouton "Vérifier l'intégrité" → SHA-256 vs manifest.
     - Options v1 : `gemma-3-1b-pt-4bit` (défaut, 0.8 GB), `qwen2.5-0.5b-pt-4bit` (0.4 GB, fallback rapide)
  3. **Enrichissement** : toggle global, sous-toggles clipboard / OCR, langues OCR (FR, EN, ES — multi-select), cap chars par source (slider 100→1000, défaut 500)
  4. **Allowlist** : tableau éditable `[bundleID | windowTitleRegex | mode]` où mode ∈ `{actif, désactivé, clipboard uniquement, suggestion uniquement}`. Boutons +/-/Modifier. Persisté `~/Library/Application Support/Souffleuse/allowlist.json`
  5. **À propos** : version, modèle actif, lien GitHub, lien révoque permissions (ouvre System Settings), bouton "Ouvrir le log" (révèle `~/Library/Logs/Souffleuse.log` dans Finder)
- `Sources/Souffleuse/PreferencesStore.swift` — un seul `@MainActor final class` exposant des `@Published` propriétés, sourcé `UserDefaults` pour les scalaires + fichier JSON pour l'allowlist
- Menu menubar : remplacer "Permissions…" par "Préférences…" (`⌘,`), la fenêtre permissions devient un onglet "Permissions" intégré OU reste à part — **choisir Phase B kick-off** (recommandation : la garder à part car flow d'onboarding distinct)

**Comportement allowlist**
- Au focus change, `FocusObserver` consulte `PreferencesStore.allowlist`
- Lookup ordonné : première règle qui matche bundleID + (regex titre || regex vide) gagne
- Mode `désactivé` → ghost text suspendu, kill switch logique
- Mode `clipboard uniquement` → enrichissement actif sans OCR pour cette app
- Mode `suggestion uniquement` → ghost text actif, enrichissement off
- Mode par défaut (aucune règle match) = `actif`

**Edge cases à valider**
- Allowlist JSON corrompu → reset à `[]`, log warn, ne crash pas
- Regex utilisateur invalide → marquée rouge dans l'UI, ignorée jusqu'à correction
- Préférences ouverte pendant frappe ailleurs → `NSApp.isActive == true` ⇒ pipeline AX se met en pause (FocusObserver vérifie, n'attache pas d'overlay sur les fenêtres de Souffleuse elle-même)
- Modèle sélectionné absent du disque → bouton "Télécharger" obligatoire avant d'activer
- Changement de modèle à chaud : décharger l'ancien container, charger le nouveau, afficher progress overlay (recharge < 5 s)

**Test acceptance**
```bash
swift run Souffleuse
# Cmd+, ouvre fenêtre Préférences, 5 onglets navigables clavier
# Onglet Allowlist : ajouter "com.apple.mail" mode "clipboard uniquement"
#   → focus Mail, capture désactivée mais clipboard préfixe présent (log debug)
# Onglet Allowlist : ajouter "com.apple.TextEdit" mode "désactivé"
#   → focus TextEdit, aucun ghost text, aucun overlay
# Onglet Modèle : changer gemma → qwen, recharge sous 5 s, ghost text retrouve fonctionnel
# Quitter, relancer : tous les choix persistent
```

**Commit attendu** : `Jalon 3.B: fenêtre Préférences SwiftUI + allowlist par app + picker modèle`

---

### Phase 3.C — Typos basique + emoji shortcodes (1-2 jours)

**But** : deux petites valeurs ajoutées indépendantes du modèle LLM, qui marchent même hors-ligne et sans inférence (latence ~0). Démontrent que Souffleuse fait plus que "prédire le mot suivant".

**Livrable**
- `Sources/SouffleuseTyping/TypoDetector.swift` — actor
  - Dictionnaire FR-EN compact embarqué (top 50k mots FR + 50k mots EN, sources `aspell-fr` / `aspell-en`, fichier `Resources/dict-fr.txt` + `dict-en.txt` en plain text une ligne par mot)
  - Au token boundary (espace, ponctuation), prend le dernier mot, calcule Levenshtein ≤ 2 vs dico
  - Si match unique trouvé avec distance == 1 → propose remplacement via overlay (réutilise GhostOverlay avec style "souligné rouge sous le mot, suggestion en gris à côté")
  - Si match ambigu (plusieurs candidats distance ≤ 2) → ne suggère rien
  - Dictionnaire utilisateur `~/Library/Application Support/Souffleuse/user-dict.txt`, mot ajouté via menu contextuel "Ignorer ce mot" sur l'overlay
- `Sources/SouffleuseTyping/EmojiExpander.swift` — actor
  - Table `:shortcode: → emoji` chargée depuis `Resources/emoji-shortcodes.json` (~200 entrées de base, source GitHub `gemoji`)
  - Trigger : `space` ou `enter` après pattern `:[a-z_+-]+:`
  - Réécriture via AX (même mécanisme que Tab inject) : delete N chars + insert emoji
  - Désactivé si :
    - App frontale ∈ `{com.microsoft.VSCode, com.apple.dt.Xcode, com.jetbrains.*, com.googlecode.iterm2, com.apple.Terminal}`
    - Allowlist le désactive
    - Préférences > Général > toggle "Expansion emoji" off (défaut **on**)
- Préférences > Général : 2 toggles supplémentaires : "Correction typos" (défaut **on**), "Expansion emoji" (défaut **on**)

**Edge cases à valider**
- Mot tapé = nom propre absent du dico (ex: "Cocotypist") → user-dict après "Ignorer ce mot", plus jamais re-suggéré
- `:not_a_real_emoji:` → aucune expansion, pas d'erreur visible
- `std::vector` en mode IDE → pas d'expansion (test sur VSCode focus)
- Typo détectée et utilisateur appuie sur space → la suggestion typo doit disparaître proprement, pas être injectée
- Conflit avec ghost text LLM : typo prend priorité visuelle si présente, sinon ghost LLM s'affiche

**Test acceptance**
- Taper "Bonjuor " dans TextEdit → souligné rouge sous "Bonjuor", suggestion "Bonjour" affichée, Tab accepte
- Taper "boursorama " dans Mail → ajouté à user-dict via menu, taper de nouveau → plus de souligné
- Taper `:smile: ` dans Notes → remplacé par 😄
- Taper `:smile:` dans VSCode → aucune expansion
- Toggle "Correction typos" off → plus aucun souligné rouge
- Log JSONL : voir `event="typo_suggested"`, `event="emoji_expanded"`, **jamais** le mot lui-même

**Commit attendu** : `Jalon 3.C: typo detector Levenshtein + emoji shortcodes expansion`

---

### Phase 3.D — Signature Developer ID + notarisation + DMG (2 jours)

**But** : binaire installable par un tiers sans `xattr -d com.apple.quarantine` ni clic-droit-Ouvrir. Sortie Spotlight-friendly.

**Pré-requis hors code**
- Apple Developer Program actif (99 USD/an), Team ID connu
- Certificat "Developer ID Application" généré dans Xcode > Settings > Accounts, présent dans Keychain
- App-specific password généré sur appleid.apple.com pour notarytool
- `xcrun notarytool store-credentials` exécuté une fois pour stocker profil `souffleuse-notary`

**Livrable**
- `make-app.sh` v2 : produit `Souffleuse.app` avec `Info.plist` complet (CFBundleIdentifier `dev.cocotypist.Souffleuse`, CFBundleShortVersionString `0.3.0`, NSHumanReadableCopyright, **LSUIElement true**, **NSAppleEventsUsageDescription**, **NSAccessibilityUsageDescription** déjà présent à vérifier, **NSScreenCaptureUsageDescription**)
- `Souffleuse.entitlements` :
  ```xml
  <dict>
    <key>com.apple.security.cs.allow-jit</key><true/>
    <key>com.apple.security.cs.disable-library-validation</key><true/>
    <key>com.apple.security.cs.allow-unsigned-executable-memory</key><true/>
  </dict>
  ```
  (les 3 requis pour MLX/Metal compilation runtime ; à valider phase D kick-off, peut-être que seul `allow-jit` suffit)
- `scripts/sign.sh` :
  ```bash
  #!/usr/bin/env bash
  set -euo pipefail
  APP="Souffleuse.app"
  IDENTITY="Developer ID Application: <Nom> (<TEAMID>)"
  # Sign nested binaries first (MLX dylibs, helpers)
  find "$APP/Contents" -type f \( -name "*.dylib" -o -name "*.so" \) -print0 \
    | xargs -0 -I {} codesign --force --options runtime --timestamp \
        --entitlements Souffleuse.entitlements --sign "$IDENTITY" {}
  # Sign main binary last
  codesign --force --options runtime --timestamp \
    --entitlements Souffleuse.entitlements --sign "$IDENTITY" "$APP"
  codesign --verify --deep --strict --verbose=2 "$APP"
  spctl --assess --type execute --verbose "$APP"
  ```
- `scripts/notarize.sh` :
  ```bash
  #!/usr/bin/env bash
  set -euo pipefail
  APP="Souffleuse.app"
  ZIP="Souffleuse.zip"
  ditto -c -k --keepParent "$APP" "$ZIP"
  xcrun notarytool submit "$ZIP" --keychain-profile souffleuse-notary --wait
  xcrun stapler staple "$APP"
  xcrun stapler validate "$APP"
  rm "$ZIP"
  ```
- `scripts/dmg.sh` — utilise `create-dmg` (Homebrew) ou `hdiutil` brut. Layout : icône `Souffleuse.app` à gauche, alias `Applications` à droite, fond simple. Output `dist/souffleuse-0.3.0.dmg`. Calcule SHA-256 dans `dist/souffleuse-0.3.0.dmg.sha256`.
- **Décision actée : modèle téléchargé, pas embarqué** (alignée Cotypist, à reporter dans ARCHITECTURE.md §10)
  - DMG slim attendu < 30 MB (binaire + dylibs MLX + ressources, **sans** poids modèle)
  - Au premier lancement, étape onboarding "Télécharger le modèle" :
    1. Lecture du manifest `https://models.cocotypist.dev/manifest.json` signé Ed25519 (clé publique embarquée dans le binaire, cf. §10 #16)
    2. Vérification signature manifest avant toute action
    3. Download `gemma-3-1b-pt-4bit.safetensors` (+ tokenizer + config) vers `~/Library/Application Support/Souffleuse/Models/gemma-3-1b-pt-4bit/`
    4. Vérification SHA-256 par fichier contre le manifest
    5. Échec à toute étape → rollback (suppression du dossier modèle partiel), retry possible, l'app refuse de prédire tant qu'aucun modèle valide n'est dispo
  - Onglet Préférences > Modèle : bouton "Télécharger" actif si manquant, progress bar pendant DL, bouton "Vérifier l'intégrité" relance la vérification SHA-256
  - Modèle alternatif `qwen2.5-0.5b-pt-4bit` listé dans le même manifest, téléchargeable à la demande
  - **Implications dossier** : ajouter logique dans `PredictorViewModel` qui résout le chemin modèle dynamiquement (n'assume plus `Resources/Models/`) et qui no-op tant que le download n'est pas fini
  - Manifest format (à figer en début de Phase D) :
    ```json
    {
      "version": 1,
      "models": [{
        "id": "gemma-3-1b-pt-4bit",
        "files": [
          {"name": "model.safetensors", "url": "...", "sha256": "...", "size": 812345678},
          {"name": "tokenizer.json", "url": "...", "sha256": "...", "size": 1234567},
          {"name": "config.json", "url": "...", "sha256": "...", "size": 1234}
        ]
      }],
      "signature": "<base64 Ed25519 over canonical JSON without this field>"
    }
    ```

**Edge cases à valider**
- Sandbox quarantaine : copier DMG sur une autre machine (ou VM macOS), monter, glisser dans Applications, double-cliquer. Aucune alerte sauf le premier prompt permissions.
- `spctl --assess --type execute Souffleuse.app` → `accepted`
- `codesign -dv --verbose=4 Souffleuse.app` → `Identifier=dev.cocotypist.Souffleuse`, `Authority=Developer ID Application: …`, `TeamIdentifier=<TEAMID>`
- `stapler validate` → `Validation Action: 0`
- Lancer dans une session "Standard User" non-admin macOS → fonctionne (permissions AX demandées normalement)

**Test acceptance**
```bash
bash scripts/sign.sh
bash scripts/notarize.sh   # 5-15 min de wait Apple
bash scripts/dmg.sh
# transférer dist/souffleuse-0.3.0.dmg sur Mac vierge
# monter, drag, lancer → aucun "app endommagée", aucun "développeur non identifié"
shasum -a 256 dist/souffleuse-0.3.0.dmg
# le hash matche dist/souffleuse-0.3.0.dmg.sha256
```

**Commit attendu** : `Jalon 3.D: signature Developer ID + notarisation + DMG release`

> Note : ne commit ni le DMG ni les `.zip` (ajouter `dist/` au `.gitignore`). Le DMG est uploadé séparément à la release GitHub / S3 / page de landing.

---

### Phase 3.E — Landing minimale (0.5 jour)

**But** : URL publique où télécharger Souffleuse + vérifier intégrité. Pas de blog, pas de marketing, juste les faits.

**Livrable**
- `landing/index.html` — un seul fichier, CSS inline (< 200 lignes total). Sections :
  1. Hero : nom Souffleuse, sous-titre "Autocomplete macOS local. Vos mots restent chez vous."
  2. Capture animée (gif ou webm < 2 MB) montrant ghost text en train de prédire
  3. Bouton "Télécharger Souffleuse 0.3.0 (DMG)" → URL stable
  4. Sous le bouton, en monospace : `SHA-256: a1b2…` (le hash réel)
  5. Section "Comment ça marche" : 3 paragraphes courts (modèle local, MLX Apple Silicon, jamais de réseau hors téléchargement modèle)
  6. Section "Permissions" : Accessibility (obligatoire), Screen Recording (optionnel pour enrichissement)
  7. Footer : lien GitHub repo (privé pour l'instant ? **décision E**), email contact, version + date build
- `landing/souffleuse-demo.webm` — capture d'écran QuickTime 10-15s, encodage `ffmpeg -i in.mov -c:v libvpx-vp9 -b:v 800k -an out.webm`
- Hébergement : GitHub Pages depuis branche `gh-pages` du repo `cocotypist/souffleuse-landing` séparé, OU Cloudflare Pages. URL cible : `souffleuse.cocotypist.dev` (DNS à pointer)
- Le DMG est uploadé en GitHub Release, le lien direct du bouton pointe vers `https://github.com/.../releases/download/v0.3.0/souffleuse-0.3.0.dmg`

**À ne PAS faire en Phase E**
- Tracking analytics (Plausible/GA) — phone-home zéro, c'est notre promesse §10 #15
- Newsletter signup
- Comparatif vs Cotypist (peut venir post-v1)
- Blog / changelog détaillé

**Test acceptance**
- `curl -I <URL>` → `200 OK`
- Ouvrir l'URL sur iPhone Safari → lisible, bouton fonctionnel (download s'amorce, l'utilisateur comprend que c'est macOS-only)
- Vérifier que `landing/index.html` ne charge **aucune** ressource externe (fonts Google, analytics, CDN). `grep -E 'https?://' landing/index.html` ne montre que GitHub release et le repo GitHub.
- Hash affiché == `dist/souffleuse-0.3.0.dmg.sha256`

**Commit attendu** : `Jalon 3.E: landing statique + release v0.3.0`

---

## Hors scope Jalon 3 (reportés Jalon 4+)

- Refactor XPC 3-process (UI / AXAgent / InferenceAgent) — décision §10 #14, gros chantier
- Auto-update check (volontairement absent §10 #15)
- LoRA personnalisation depuis phrases acceptées
- KV cache cross-frappe
- Apps Electron via injection JS
- Open source code (décision §10 #18 différée — à reprendre après J3)
- Modes de langue avancés (correction grammaire au-delà de typos mots-uniques)
- Sync préférences iCloud (jamais sans accord explicite ; pas v1)

## Estimation totale

6-7 jours dev solo. Phase la plus risquée : 3.D (chaîne signature/notarisation, premier passage est toujours douloureux, prévoir une demi-journée tampon pour les échecs Apple). Phase la plus stratégique : 3.B (l'allowlist par app est ce qui différencie un jouet d'un outil quotidien).

## Critères pour passer Jalon 3 → v1.0

- DMG installable downloadé et testé sur 2 Macs vierges autres que le dev
- 3 utilisateurs externes (amis FR-natifs) ont utilisé l'app 3+ jours sans crash bloquant
- Aucune entrée dans `~/Library/Logs/Souffleuse.log` ne contient de string utilisateur (audit manuel `bash audit.sh` + spot-check)
- Acceptance rate Tab mesurée >25 % en usage réel (mesure via event `suggestion_accepted` vs `suggestion_shown` dans le log JSONL, agrégat seulement, pas de texte)

## Prochain commit attendu après ce plan

```
git checkout -b jalon-3
# coder Phase 3.A
git add Sources/SouffleuseLog audit.sh Package.swift .gitignore
git commit -m "Jalon 3.A: logging fichier JSONL + rotation + audit script"
```
