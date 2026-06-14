# Souffleuse — Kit de lancement (prêt à copier)

Site : https://souffleuse.app · Asset clé : `video/out/screencast-16x9.mp4`
Règle d'or : **honnête, ton maker indé, zéro hype, pas de claim non prouvé.**

> 🎵 **Crédit musical obligatoire** (la vidéo utilise Bach BWV 846 sous licence CC-BY) — à mettre dans le post X ou sa description :
> *Musique : « Prelude in C » (J.S. Bach, BWV 846) — Kevin MacLeod (incompetech.com), CC-BY 4.0*

---

## ⏱️ Ordre de lancement recommandé
1. **Communautés FR d'abord (J0–J3)** — l'UI parle français nativement : forums/Slack/Discord macOS FR, r/macapps. Objectif : roder, récolter les bugs de détection caret par app, 2-3 retours. Ne pas griller HN/PH avec une v0.8.1 non éprouvée.
2. **Show HN (J~5–7)** — mardi-jeudi, ~14:00–16:00 UTC. Audience technique qui valorise l'on-device/privacy.
3. **Product Hunt (J+2 à +4 après HN)** — démarrage 00:01 PST ; réutilise la traction HN comme preuve sociale.

**✅ UI bilingue FR+EN** : plus de risque de « piège » pour un visiteur EN — l'interface (menu-bar, préférences, onboarding) est dispo en anglais comme en français. HN/PH peuvent partir sans caveat de langue.

**Métrique nord** : **rétention active à J7**. Secondaires : taux d'acceptation (Tab vs Esc), rapports de caret cassé par app. (Upvotes/rang = vanity.)

---

## 𝕏 — Thread de lancement (FR)

> **T1 — hook** · [MÉDIA : screencast 16:9 en **vidéo native**]
```
J'ai construit une app macOS qui prédit ce que je tape, directement au curseur, dans n'importe quelle app.

100% en local. Rien ne part en ligne.

Ça s'appelle Souffleuse. Démo 👇
```

> **T2 — comment ça marche**
```
Le principe est simple :

Tu tapes. Une suggestion apparaît au curseur (le "ghost text").

→ Tab pour accepter, mot à mot
→ Esc pour ignorer

Ça marche partout : Mail, Notes, Messages, Slack, ton navigateur… via l'API d'accessibilité de macOS.
```

> **T3 — la démo décortiquée**
```
Dans la démo, je tape un message.

Le texte en couleur, c'est Souffleuse qui devine la suite — généré en local.

Tab → validé, mot à mot.

Pas de pop-up, pas de menu, pas de copier-coller. Juste le texte qui se complète sous tes doigts.
```

> **T4 — vie privée / on-device**
```
Le truc auquel je tenais le plus : rien ne quitte ta machine.

Le modèle (Gemma 3 1B via llama.cpp, accéléré Metal) tourne en local. Aucun appel réseau pendant que tu écris.

Pas une IA cloud. Pas de la dictée qui envoie ton audio. Ton texte reste chez toi.
```

> **T5 — personnalisation + bonus**
```
Et elle apprend de TA façon d'écrire.

Souffleuse lit ton historique de frappe (chiffré, en local) pour coller à ton style, pas à un style générique.

Bonus : traduction dans un HUD + relecture par ton. Et un carnet qui compte les frappes épargnées.
```

> **T6 — CTA** · ⚠️ lien ici OU en 1er commentaire (voir conseils)
```
C'est gratuit, notarisé Apple (Developer ID), mises à jour Sparkle.

macOS 14+ Apple Silicon. UI en français et en anglais. v0.8.1.

Si tu écris toute la journée sur ton Mac, essaie :
→ https://souffleuse.app

(Codé en solo. Retours bienvenus 🙏)
```

### Variantes du T1 (A/B)
- **B (bénéfice)** : `Autocomplétion façon Gmail… mais dans TOUTES les apps de ton Mac. Et 100% en local. Tu tapes, une suggestion grise apparaît, Tab pour valider. Aucun réseau, aucune IA cloud. Regarde 👇`
- **C (privacy, clivant)** : `Une IA d'écriture qui n'envoie RIEN en ligne. Le modèle tourne sur ton Mac, point. Suggestion grise au curseur dans n'importe quelle app → Tab pour accepter. J'ai construit ça parce que je ne voulais pas filer mon texte à un cloud. 👇`

### Conseils X
- **Vidéo native** (pas de lien YouTube) — autoplay muet dans le feed.
- **Lien en 1er commentaire**, pas dans le T1 (X défavorise les liens sortants). Se répondre à soi-même dans la minute.
- **Mardi-jeudi 9-11h ou 17-19h** (heure audience). Rester actif 60-90 min après. Épingler le T1.
- Hashtags sobres : `#macOS #buildinpublic` (1-2 max).

---

## 𝕏 — Thread condensé (EN, audience tech internationale)

> **T1** · [MEDIA: screencast 16:9]
```
I built a macOS app that predicts what I type, right at the cursor, in any app.

100% on-device. Nothing leaves your Mac.

It's called Souffleuse. Demo 👇
```
> **T2**
```
How it works:

You type → a grey suggestion appears at the cursor (ghost text).
Tab to accept (word by word). Esc to dismiss.

Works everywhere — Mail, Notes, Messages, Slack, your browser — via macOS accessibility.
```
> **T3 — privacy**
```
The part I cared about most: nothing leaves your machine.

Gemma 3 1B runs locally via llama.cpp (Metal). Zero network calls while you write.

Not a cloud AI. Not voice dictation shipping your audio off-device.
```
> **T4 — perso + note FR**
```
It learns from YOUR writing (history stored encrypted, locally) so it matches your style.

The UI ships in both English and French, and it works on your own text in any language you type.

Plus: translation HUD + tone rewriting.
```
> **T5 — CTA**
```
Free. Apple-notarized (Developer ID). Sparkle updates.
macOS 14+ Apple Silicon. v0.8.1.

If you write all day on your Mac, give it a try:
→ https://souffleuse.app

(Built solo. Feedback very welcome 🙏)
```

---

## 🟠 Show HN (en anglais)

**Titre** (72 car.) :
```
Show HN: Souffleuse – On-device autocomplete for any macOS app (llama.cpp, Metal)
```

**Post :**
```
Souffleuse is a macOS menu-bar app that shows inline "ghost text" suggestions
at your cursor in any app — Notes, Mail, a browser textarea, wherever. Tab
accepts word-by-word, Esc rejects. It's free.

The whole thing runs on-device. No network at runtime. The model is Gemma 3 1B
(GGUF) running through llama.cpp on Metal. Your typing never leaves the machine.

Why I built it: I wanted Cotypist-style ghost completions but with the model
running locally and with personalization that learns from my own writing
without anything going to a server. So this is a solo project trying to get to
"feels as good as Cotypist in daily use" while staying 100% local.

How it works:
- It reads the focused text field via the macOS Accessibility API (AX) to get
  the prefix around your caret, then asks the local model for a continuation.
- The KV cache is reused between keystrokes so each new character isn't a cold
  start. Generation is cancelled on every keystroke so stale chunks get dropped.
- Personalization is a local n-gram model built from your own typing history,
  used to bias the model's logits toward words you actually use. History is
  stored encrypted (SQLCipher).
- There's also translation and tone rewriting, plus a small ledger of
  keystrokes saved.

Honest limitations:
- Apple Silicon, macOS 14+ only. No Intel.
- It's a base/continuation model (not FIM), so it only sees text *before* the
  caret, not after.
- The UI ships in English and French. Completions work in any language since
  it's just continuing *your* text, regardless of the UI language.
- Quality vs. a cloud copilot is what you'd expect from a 1B local model —
  good for short, contextual continuations, not for writing paragraphs.
- v0.8.1, solo dev. Rough edges exist.

Developer ID signed + notarized, Sparkle for updates.

https://souffleuse.app

Happy to answer anything about the AX integration, KV-cache reuse, or the
on-device personalization.
```

**1er commentaire (à poster soi-même, juste après) :**
```
A few more technical details for those interested:

Accessibility plumbing: getting the caret prefix reliably across apps is the
hard part. Chromium apps (Brave, Slack, VS Code's Electron, etc.) don't always
expose a clean AXSelectedText/AXValue, so there's per-bundle calibration: caret
rect, font info, and an OCR fallback (Vision) keyed on the app's bundle ID.

Inference: a single llama.cpp engine (Metal GGUF), loaded while you're actively
typing and unloaded at idle. Every prefix increments a generation counter; the
in-flight Task is cancelled when you type, so chunks from a stale prefix are
dropped. The KV cache is kept warm between keystrokes rather than re-prefilling.

Personalization: an n-gram model built locally from your accepted-text history
(encrypted ring buffer, SQLCipher, AES-256 key in Keychain), applied as a logit
bias toward your own vocabulary. Nothing touches the network — there's an audit
script that enforces no-network on shipping code paths and forbids logging any
user string.

Trade-offs I'm still wrestling with: continuation model (no fill-in-the-middle,
ignores text after the caret), and the tension between TTFT and relevance — a
fast but generic ghost is useless, so I'd rather be slightly slower and relevant.

Stack: Swift 6 (strict concurrency), AppKit/SwiftUI, llama.cpp vendored for
Metal. Solo project — feedback (especially apps where caret detection breaks)
very welcome.
```

**Pièges à éviter :** pas de comparaison vitesse/qualité non prouvée ; répondre techniquement sans se justifier ; dire « I » (pas de « we »/« revolutionary »/waitlist). **Créneau :** mar-jeu ~14:00-16:00 UTC, rester dispo 2-3 h.

---

## 🟣 Product Hunt (en anglais)

**Name :** `Souffleuse`

**Tagline (≤60) :** `On-device text autocomplete for any macOS app`
Variantes : `Local, private ghost-text autocomplete for macOS` · `Private AI typing assistant — no cloud, no network`

**Description (≤260) :**
```
Souffleuse shows inline ghost-text completions at your cursor in any macOS app.
Tab accepts, Esc rejects. A local LLM (llama.cpp, Metal) runs 100% on-device —
no network. Learns from your own typing, stored encrypted. Free, Apple Silicon.
```

**1er commentaire du maker :**
```
Hi Product Hunt 👋

I'm a solo developer and I built Souffleuse because I wanted Cotypist-style
inline suggestions, but with everything running locally on my own machine.

Most AI writing tools send your text to a server. Souffleuse doesn't — there's
no network at runtime. A small language model (Gemma 3 1B via llama.cpp on
Metal) runs entirely on your Mac and suggests a continuation at your cursor in
any app, through the macOS Accessibility API. Tab accepts word-by-word, Esc
rejects.

What makes it different:
- 100% on-device. Your writing never leaves your Mac.
- Personalizes locally — learns your vocabulary/phrasing from your own typing
  history, stored encrypted (SQLCipher), never uploaded.
- Works system-wide, not just in one editor.
- Also includes translation and tone rewriting.

Free, Developer ID notarized, macOS 14+ Apple Silicon. v0.8.1, built by one
person — the UI is available in English and French (completions work in any
language since it's continuing your own text). Honest heads-up: it's a 1B local
model, so it shines at short contextual completions rather than full paragraphs.

Would love your feedback, especially on apps where caret detection misbehaves.
```

**Topics :** Productivity · Mac · Artificial Intelligence · Writing · Privacy / Developer Tools · (Open Source uniquement si le repo est public).

---

À vérifier avant de poster : ne fabriquer aucun visuel qu'on n'a pas (le carnet d'usage / GIF du T3 sont optionnels — la vidéo du T1 suffit).
