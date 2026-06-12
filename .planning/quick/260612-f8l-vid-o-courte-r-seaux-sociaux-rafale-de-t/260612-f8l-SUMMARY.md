---
quick_id: 260612-f8l
description: Vidéo courte réseaux sociaux « rafale de Tab » (Remotion 9:16)
date: 2026-06-12
status: complete
---

# Quick Task 260612-f8l — Vidéo sociale « rafale de Tab »

## Livrables

- `video/out/souffleuse-rafale.mp4` — 1080×1920 (9:16), 15,03 s, 30 fps, ~1,8 Mo, h264 + AAC.
- `video/src/scenes/Rafale.tsx` — composition `SouffleuseRafale` (3 scènes + chute + boucle).
- `video/src/scenes/rafale-ui.tsx` — `VSheet` (feuille 940 px verticale, montée paramétrable), `TabStamp` (tampon letterpress rouge, scale 1.35→1, ink-splat), `Tally` (compteur roulant façon compteur de taxi). Réutilise `Kbd`/`Caret`/`clamp` d'acte-ui.
- `video/scripts/make-bande-son-rafale.mjs` — bande-son 15 s dédiée (valse-minute Chopin, 3 arpèges I→IV→V en Ré bémol, souffle par ghost) → `public/bande-son-rafale.wav`. Ne touche pas `bande-son.wav` (16:9).
- `video/src/Root.tsx` — 2e `<Composition id="SouffleuseRafale">` ; la compo `Souffleuse` 16:9 est intacte.
- `video/package.json` — scripts `render:rafale` et `son:rafale`.

## Structure (450 frames)

| Scène | Frames | Contenu |
|-------|--------|---------|
| 1 — Mail formel | 0–115 | frappe dès frame 0 (hook), ghost 56, Tab 88 |
| 2 — Signal décontracté | 116–231 | ghost 176, Tab 208 |
| 3 — Insertion en plein milieu | 232–359 | caret remonte, insertion tapée, pastille ghost 306, Tab 334 |
| Chute | 360–449 | marque + tagline + souffleuse.app, fondu papier 443→449 (boucle avec frame 0) |

Compteur « frappes épargnées » persistant, cumulatif (0 → 63 → 91 → 111).

## Corrections après vérification visuelle (frames extraites)

1. **Trous morts aux cuts** : frontières resserrées (116/232 au lieu de 120/240) + montée des feuilles accélérée (`rise={14}`) — plus de papier nu entre scènes.
2. **Scène 3 recomposée** : insertion raccourcie (« disons jeudi ») et ghost (« en fin de journée — ») pour que la frappe finisse avant le Tab et que la phrase acceptée se lise d'une traite. Bande-son recalée (souffle 306, arpège 334).
3. **Pastille** : ancrée à droite du caret (plus de débordement hors feuille) ; disparition pile au Tab (le fondu de sortie traînait un fragment rogné après le saut du caret en ligne 2).
4. **Sons retravaillés (itération user)** : le souffle devient une vraie expiration (bande résonante état-variable, centre glissant 1800→450 Hz) et le Tab un coup de tampon (choc mat 170→70 Hz + clic d'encre + accord plaqué) au lieu de l'arpège de harpe. Gains calibrés par analyse RMS (impacts ≈ 2–2,5× l'ambiance, zéro clipping).

## Notes

- `video/` est volontairement non tracké dans git (statu quo du repo) : les sources vivent sur le disque, pas de commit de code. Les commits de l'exécuteur en worktree (e8287e6, 2287c00) ont servi de véhicule puis ont été remplacés par les fichiers synchronisés + correctifs.
- Vérification : sondage ffmpeg (durée/format) + 17 frames extraites et inspectées visuellement (hook, cuts, tampon, compteur, pastille, chute, raccord de boucle).
