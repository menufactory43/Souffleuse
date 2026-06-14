# Souffleuse — File de posts 𝕏 · J1 → J7

> Voix DA obligatoire : la souffleuse de théâtre (coulisses, à voix basse, le mot juste, lever de rideau, en scène, discrète). Registre éditorial, feutré, chaleureux. Tutoiement, maker indé honnête, zéro hype, aucun claim non prouvé. 0–1 emoji sobre/post. Hybride : la voix encadre, le corps reste concret.
>
> Rappels kit :
> - **Lien en 1er commentaire**, jamais dans le tweet d'ouverture (X défavorise les liens sortants).
> - **Vidéo native** (pas de YouTube) — autoplay muet dans le feed.
> - Créneau idéal : **mardi–jeudi, 9-11h ou 17-19h** (heure audience). Rester 60-90 min après pour répondre.
> - Hashtags sobres : `#macOS #buildinpublic` (1-2 max), seulement quand utile.
> - Crédit musical si un clip avec la BO Bach est posté : *Musique : « Prelude in C » (J.S. Bach, BWV 846) — Kevin MacLeod (incompetech.com), CC-BY 4.0*.
> - J0 = thread de lancement DA déjà posté et épinglé. Référence : `video/social/LAUNCH-KIT.md`.
> - Ordre macro : communautés FR (J0–3) → **Show HN (J5–7)** → Product Hunt après. La traction X sert de preuve sociale pour HN/PH.
> - Métrique nord : **rétention active J7** + taux Tab/Esc + rapports de caret cassé par app. Likes = vanity.

---

## J1 — Le premier lever de rideau (onboarding TCC Accessibilité) · PRIORITÉ

**Objectif** : désamorcer le plus gros trou de funnel — au premier lancement, macOS réclame l'accès Accessibilité et beaucoup décrochent. Transformer ce moment anxiogène en preuve de confiance : on explique POURQUOI la permission est demandée, et la privacy devient l'argument pile au bon instant.

**Format + créneau** : mini-thread (5 tweets). Mardi ou mercredi, 9-11h (les gens installent le matin).

**Asset** : T1 → capture de la fenêtre système Accessibilité de macOS (Réglages › Confidentialité et sécurité › Accessibilité) avec Souffleuse cochée. Optionnel T4 → court clip `souffleuse-cafe-vertical.mp4` recadré, juste pour montrer le ghost en action une fois la permission posée.

**Texte prêt-à-coller :**

> **T1 — le moment**
```
Tu viens d'installer Souffleuse. Premier lever de rideau : macOS te demande l'accès « Accessibilité ».

C'est le seul moment qui peut surprendre. Alors voici, en clair, ce qu'il se passe — et pourquoi. 👇
```

> **T2 — ce que ça permet, concrètement**
```
La souffleuse a besoin de lire la réplique en cours pour souffler la suivante.

Concrètement : l'API Accessibilité lui laisse voir le texte juste avant ton curseur, dans l'app où tu écris. Sans ça, pas de mot juste à te souffler.
```

> **T3 — où ça reste**
```
Ce texte ne sort jamais des coulisses.

Il sert à demander la suite au modèle qui tourne sur ta machine, puis il est oublié. Zéro réseau pendant que tu écris. Un script (audit.sh) le vérifie à chaque build — c'est une contrainte, pas une promesse.
```

> **T4 — les deux autres cases (et pourquoi off)**
```
macOS pourra aussi proposer « Apple Events » et « Enregistrement écran ».

L'enregistrement écran ne sert qu'à un repli OCR pour retrouver ton curseur dans quelques apps récalcitrantes — et il est désactivé par défaut. Tu l'actives seulement si tu veux. La règle : le minimum requis, rien de plus.
```

> **T5 — rassurer + ouvrir la porte**
```
Donc : une case à cocher, une fois, pour que la souffleuse puisse te lire la réplique. Et rien qui quitte ta machine.

Si tu cales à l'installation, dis-le moi ici — je réponds. Le détail est sur le site (lien en commentaire).
```

> **1er commentaire (à poster dans la minute)** : `→ https://souffleuse.app · Et le thread de lancement, si tu l'as raté : [lien vers J0].`

---

## J2 — Elle souffle partout (preuve system-wide)

**Objectif** : prouver le bénéfice différenciant vs une autocomplétion d'app unique — Souffleuse joue dans toutes les salles. Cible les gens qui vivent dans Slack/Mail/navigateur.

**Format + créneau** : single tweet (vidéo porteuse). Mardi–jeudi 17-19h.

**Asset** : recadrer `video/out/screencast-16x9.mp4` (démo ghost + Tab) ; si possible, filmer un nouveau clip court qui enchaîne 3 apps (Mail → Slack → un textarea de navigateur) pour appuyer le « partout ».

**Texte prêt-à-coller :**
```
Une bonne souffleuse ne connaît pas qu'une seule pièce.

Souffleuse joue dans toutes tes salles : Mail, Notes, Messages, Slack, un champ de ton navigateur. Tu tapes, la suite s'esquisse au curseur. Tab pour la prendre, mot à mot. Esc pour l'ignorer.

Pas un plugin d'une seule app. La même réplique soufflée partout, via l'accessibilité de macOS.
```
> **1er commentaire** : `Démo + téléchargement → https://souffleuse.app`

---

## J3 — Comment elle reste cachée (coulisse technique on-device + caret)

**Objectif** : réchauffer le public technique avant Show HN (J5-7) avec une vraie coulisse d'ingénierie : on-device, détection du caret par app. Crédibilité « solo dev qui sait ce qu'il fait », sans jargon gratuit.

**Format + créneau** : mini-thread (4 tweets). Jeudi 9-11h (proche de HN, public tech matinal). `#macOS #buildinpublic`.

**Asset** : aucun obligatoire. Option : capture du `GhostInspector` (dev) ou une image sobre du logo + une ligne de code. Garder texte-first ici.

**Texte prêt-à-coller :**

> **T1 — la coulisse**
```
Un peu de coulisses, pour les curieux de la mécanique.

Le vrai défi d'une souffleuse, ce n'est pas de parler — c'est de savoir où tu en es dans ta réplique. Trouver ton curseur dans n'importe quelle app, c'est 80% du travail. 👇
```

> **T2 — le caret par app**
```
macOS expose le texte au curseur via l'accessibilité… quand l'app joue le jeu.

Les apps Chromium (Slack, Brave, VS Code) n'exposent pas toujours un curseur propre. Du coup : une calibration par app — position du caret, police — keyée sur le bundle ID. Et un repli OCR (Vision), opt-in, pour les cas tordus.
```

> **T3 — le modèle en local**
```
Une fois la réplique lue, qui souffle la suite ?

Gemma 3 1B, en GGUF, via llama.cpp accéléré Metal. Sur ta machine. Le cache KV reste chaud entre deux frappes (pas de démarrage à froid à chaque lettre) et la génération s'annule dès que tu tapes — les bouts périmés sont jetés.
```

> **T4 — la contrainte privacy**
```
Et tout ça sans réseau. Un script d'audit interdit, sur le code livré, le moindre appel réseau et le moindre log d'un texte que tu as tapé.

C'est codé en solo, Swift 6. Si la détection du curseur casse dans une app chez toi, c'est exactement le retour qui m'aide le plus.
```

> **1er commentaire** : `→ https://souffleuse.app (Show HN bientôt — si la plomberie AX t'intéresse, viens.)`

---

## J4 — Le carnet (chiffres réels, fidélisation)

**Objectif** : montrer la valeur ressentie dans la durée via le carnet d'usage (frappes épargnées · temps gagné) — un argument de rétention, pas d'acquisition. Honnête : chiffres réels, pas inventés.

**Format + créneau** : single tweet. Mardi–mercredi 17-19h.

**Asset** : capture du **carnet d'usage** (frappes épargnées · temps gagné). Utiliser de vrais chiffres ; si encore minces, l'assumer dans le texte plutôt que gonfler.

**Texte prêt-à-coller :**
```
En coulisses, la souffleuse tient aussi un carnet.

Pas pour te noter — pour compter ce qu'elle t'a épargné : les frappes que tu n'as pas eu à taper, le temps regagné. Petit à petit, ça se voit.

Voici le mien après quelques jours. Honnête : les premiers jours sont modestes, ça monte quand elle a appris ta main.
```
> **1er commentaire** : `Le carnet est local, comme le reste → https://souffleuse.app`

---

## J5 — La réplique dans une autre langue (bonus : traduction HUD + relecture par ton)

**Objectif** : élargir l'usage avec les bonus features sans diluer le cœur — montrer la traduction dans un HUD (langue cible par conversation) et la relecture par ton (reformulation selon l'app). Couvre aussi le public EN/bilingue avant HN.

**Format + créneau** : mini-thread (3 tweets). Mercredi 9-11h. (HN possible ce jour côté UTC — garder X léger.)

**Asset** : recadrer `defi-tab-16x9.mp4` (ou vertical) si un passage montre le HUD ; sinon, filmer un court clip de la traduction HUD dans une conversation.

**Texte prêt-à-coller :**

> **T1 — au-delà du souffle**
```
La souffleuse sait souffler la suite. Mais elle a deux autres tours en coulisses. 👇
```

> **T2 — traduction HUD**
```
1/ Traduire sans changer de scène.

Un HUD discret te donne ta phrase dans la langue cible de la conversation — tu fixes une langue par fil, et elle s'y tient. Toujours en local, rien n'est envoyé ailleurs.
```

> **T3 — relecture par ton**
```
2/ Relire selon la salle.

La même phrase ne se dit pas pareil dans Slack et dans un mail. La relecture par ton te la reformule (FR → FR) en s'adaptant à l'app où tu es. Tu gardes ton texte, tu changes juste de registre.

UI en FR et EN. Le tout, sur ta machine.
```

> **1er commentaire** : `→ https://souffleuse.app`

---

## J6 — « Tu m'as signalé un caret cassé → corrigé » (build-in-public, fidélisation)

**Objectif** : montrer la réactivité du maker et boucler avec les retours reçus en J1-J5 (apps où le curseur cassait). Fidélise les early users, prouve que les rapports comptent, et nourrit la métrique nord (caret par app). À adapter au vrai bug remonté.

**Format + créneau** : single tweet (ou T1+T2 si tu veux remercier nommément). Jeudi 17-19h. `#buildinpublic`.

**Asset** : aucun, ou un court clip avant/après dans l'app concernée (à filmer si le bug était visuel).

**Texte prêt-à-coller :** *(remplace [App] et le détail par le vrai cas)*
```
Petit mot des coulisses.

Cette semaine, plusieurs d'entre vous m'ont signalé que la souffleuse perdait votre curseur dans [App]. Repéré, corrigé, dans la prochaine mise à jour (Sparkle s'en occupe).

C'est exactement pour ça que je lance d'abord ici, en petit comité : chaque app où le caret casse, dites-le-moi. Merci à ceux qui l'ont fait. 🙏
```
> **1er commentaire** : `Si ça coince encore dans une app chez toi → réponds ici ou https://souffleuse.app`

---

## J7 — Baisser de rideau sur la semaine (récap + merci, recentré rétention)

**Objectif** : clore la semaine FR, remercier, et recentrer sur ce qui compte vraiment (rétention, pas les likes) — tout en posant la passerelle vers Show HN. Ton chaleureux, bilan honnête.

**Format + créneau** : mini-thread (3 tweets). Vendredi matin ou lundi 9-11h (selon le calage HN).

**Asset** : aucun, ou l'`og.png`/logo pour clore proprement.

**Texte prêt-à-coller :**

> **T1 — bilan honnête**
```
Une semaine que Souffleuse est en scène. Un mot de bilan, à voix basse. 👇
```

> **T2 — ce qui compte (et ce qui ne compte pas)**
```
Ce qui me rend heureux, ce n'est pas le compteur de likes — c'est vous qui l'avez toujours en menu-bar au bout de 7 jours. Que la souffleuse soit devenue un geste, pas une nouveauté.

Les vrais signaux que je regarde : combien de répliques vous prenez (Tab) vs ignorez (Esc), et les apps où elle vous perd encore.
```

> **T3 — merci + suite**
```
Merci à la communauté macOS FR d'avoir essuyé les plâtres d'une v0.8.1. Vos retours sur le curseur ont déjà nourri une mise à jour.

La suite : je vais la présenter à un public plus technique. Si elle vous souffle le mot juste au quotidien, gardez-la — et continuez à me dire ce qui casse.
```

> **1er commentaire** : `Gratuite, locale, FR & EN → https://souffleuse.app · Merci 🙏`

---

## Checklist — assets à préparer

- [ ] **J1** : capture de la fenêtre macOS *Accessibilité* (Réglages › Confidentialité et sécurité › Accessibilité) avec Souffleuse cochée. (Bonus : recadrage `souffleuse-cafe-vertical.mp4`.)
- [ ] **J2** : recadrage `screencast-16x9.mp4` ; idéalement un **nouveau clip 3-apps** (Mail → Slack → navigateur).
- [ ] **J3** : aucun obligatoire (option capture `GhostInspector` dev / visuel logo sobre).
- [ ] **J4** : capture du **carnet d'usage** avec de **vrais chiffres** (ne pas gonfler).
- [ ] **J5** : clip **traduction HUD** (recadrage `defi-tab-16x9.mp4` si le HUD y figure, sinon nouveau clip).
- [ ] **J6** : optionnel — clip **avant/après** du caret corrigé dans l'app concernée. **Remplacer `[App]`** par le vrai cas remonté.
- [ ] **J7** : aucun obligatoire (option `og.png`/logo).
- [ ] **Transverse** : récupérer le **lien du thread J0** (à coller en commentaire J1). Préparer le crédit musical Bach si un clip avec BO est posté.

## Rappel — les 2 trous de funnel

1. **Friction TCC Accessibilité** (le plus gros) : les gens téléchargent, macOS réclame l'accès Accessibilité au 1er lancement, beaucoup décrochent. → **Traité en J1** (thread d'onboarding qui retourne la permission en preuve de confiance/privacy). À garder épinglé en complément du J0 pendant la semaine.
2. **Mismatch ghost rouge ↔ gris** : la DA et le LAUNCH-KIT décrivent le ghost « gris/grisé » (variante T1-B « suggestion grise »), mais l'asset démo principal (`screencast-16x9.mp4`) montre un **ghost rouge** + Tab. **À trancher avant de pousser les clips** : soit aligner la couleur de l'app sur les visuels, soit ajuster le discours (« texte en couleur »). En attendant, T3 du J0 dit prudemment « le texte en couleur » — rester cohérent dans tous les posts qui montrent un clip.
