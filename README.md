<div align="center">

# Souffleuse

**Le mot juste, soufflé à voix basse — dans n'importe quelle app de votre Mac.**

Un assistant de frappe *local-LLM* pour macOS. Il glisse un *ghost text* gris sous
votre curseur à l'instant où vous cherchez vos mots, puis s'efface. **Tab** pour
accepter, **Esc** pour ignorer. Tout reste sur votre machine.

[![Télécharger](https://img.shields.io/badge/Télécharger-souffleuse.app-8c2b21)](https://souffleuse.app)
![Version](https://img.shields.io/badge/version-0.10.0-555)
![Plateforme](https://img.shields.io/badge/macOS-14%2B%20·%20Apple%20Silicon-000)
![On-device](https://img.shields.io/badge/100%25-on--device-346524)

</div>

---

## L'idée

Au théâtre, le **souffleur** est caché dans son trou et glisse la réplique à
l'acteur, pile au moment de l'hésitation — sans jamais monter sur scène. Souffleuse
fait pareil avec vos mots : elle observe le champ où vous écrivez (via l'API
d'accessibilité de macOS), devine la suite, et la propose en gris clair au caret.
Vous l'acceptez d'un Tab ou vous continuez de taper — elle disparaît sans bruit.

100 % **on-device** : le texte est généré localement par [llama.cpp](https://github.com/ggerganov/llama.cpp)
(Metal, modèle GGUF). **Aucun réseau au runtime** — rien ne part en ligne, et tout
s'éteint d'un interrupteur.

## Ce qu'elle fait

- **✍️ Ghost text au caret** — une continuation pertinente de ce que vous écrivez,
  dans Mail, Notes, Slack, le navigateur… partout où il y a un champ de texte.
- **`//` — la barre de commandes au clavier.** Tapez `//` puis choisissez d'un chiffre :
  - **après un texte** : `corriger` · `raccourcir` · `reformuler` · `ton` · `traduire`, ou une **instruction libre** (« rends ça plus poli ») validée par ⏎ ;
  - **en début de champ** : `//` + quelques mots-clés (« rdv Marie mardi 14h ») → Souffleuse **rédige le message complet**, naturel et poli. Langue au choix d'un chiffre (FR · EN · ES · DE · IT).
- **🌍 Traduction** — un HUD discret, langue cible mémorisée *par conversation*.
- **🎭 Relecture par ton** — reformule votre français selon l'app où vous écrivez.
- **📖 Carnet d'usage** — frappes épargnées et temps gagné, en local.

Le résultat s'affiche toujours **en aperçu** d'abord : **Tab** remplace, **Esc** annule.
Rien n'est écrit dans votre champ sans votre geste.

## Confidentialité par construction

- **Pas de réseau** au runtime (seul le téléchargement initial des modèles sort).
  Ni télémétrie, ni ping, ni mouchard — un script d'audit (`audit.sh`) l'impose à chaque build.
- **Historique chiffré** au repos (SQLCipher · AES-256, clé en Keychain).
- **Logs sans texte utilisateur** : invariant garanti par le système de types (seuls
  des champs whitelistés `{ts, level, module, event, count}` peuvent atteindre le writer).
- La **capture d'écran** (contexte enrichi par OCR) est *opt-in* et désactivée par défaut.

## Installation

Téléchargez le DMG signé et notarisé sur **[souffleuse.app](https://souffleuse.app)**,
glissez l'app dans Applications, lancez-la. Les mises à jour se font dans l'app
(Sparkle, signature EdDSA vérifiée).

> macOS Sonoma (14) ou plus récent · Mac à puce Apple Silicon (M1 et suivants).
> Gratuit pendant la bêta.

## Stack technique

| | |
|---|---|
| **Langage** | Swift 6 (strict concurrency), AppKit · SwiftUI · Observation |
| **Inférence** | llama.cpp (GGUF Metal vendoré) — Gemma 3 1B *base* pour le ghost, instruct (Gemma / Qwen 2.5) pour les transformations `//` et la traduction |
| **Accessibilité** | `AXUIElement*` (lecture du champ focus), `CGEventTap` (Tab/Esc) |
| **Contexte** | ScreenCaptureKit + Vision (OCR opt-in), NaturalLanguage (détection de langue) |
| **Chiffrement** | SQLCipher + CommonCrypto (sans OpenSSL), CryptoKit · Keychain |
| **Distribution** | Developer ID notarisé · Sparkle · hébergement Vercel |

L'app est découpée en modules SPM (`SouffleuseCore`, `SouffleuseLlama`, `SouffleuseAX`,
`SouffleuseContext`, `SouffleuseOverlay`, `SouffleusePersonalization`…), chacun avec
sa frontière `Sendable` et ses tests en miroir.

## Construire depuis les sources

```bash
cd Souffleuse

# .app de dev (cert Apple Development, TCC stable entre rebuilds)
./make-app.sh
open build/Build/Products/Debug/Souffleuse.app

# release : .app + DMG signés Developer ID, notarisés + staplés
RELEASE=1 ./make-app.sh

swift test     # ~960 tests (Swift Testing / XCTest)
./audit.sh     # invariants de confidentialité (doit passer avant tout build)
```

> Toolchain Xcode Swift 6.3 · macOS 14+ Apple Silicon. Les modèles GGUF se
> téléchargent dans l'app au premier lancement (ou via `ModelDownloadManager`).

## Statut

Bêta publique — version **0.10.0**. Objectif : la parité subjective avec les
meilleurs assistants de frappe, mais **entièrement local**. Le ghost doit *sembler*
aussi instantané que pertinent ; la qualité contextuelle prime sur la vitesse brute.

---

<div align="center">
<sub>Fait avec soin pour les Mac à puce Apple Silicon · 100 % on-device · <a href="https://souffleuse.app">souffleuse.app</a></sub>
</div>
