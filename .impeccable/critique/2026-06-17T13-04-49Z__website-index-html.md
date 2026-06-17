---
target: website/index.html
total_score: 32
p0_count: 1
p1_count: 1
timestamp: 2026-06-17T13-04-49Z
slug: website-index-html
---
# Critique — website/index.html (Souffleuse) — round audit+fix

## Design Health Score: 32/40 (Good)
Assessment A (revue design source) : 32/40. Pas de slop — page authored, conceit du souffleur tenu de bout en bout. Détecteur : EXIT 0, 7 advisories (dérive couleur/radius mineure : accent doré egg #c8861d/#a96f12, ombres rgba, #000/#fff, radius 5px). Pas d'inspection navigateur (automation indisponible).

## Issues traitées dans ce round
- [P0] Prix en cul-de-sac après la bêta -> phrase d'intention ajoutée dans la FAQ (achat unique, jamais d'abonnement caché). FIX.
- [P1] CTA sans échafaudage de confiance -> ligne .cta-trust sous les 2 CTA (taille ~6,5 Mo, notarisée Apple, rappel privacy). FIX.
- [P2] Démo au vocabulaire clavier sur tactile -> libellés .verb-key/.verb-touch bascullés en pointer:coarse (boutons déjà cliquables) + hint son + légende. FIX.
- [P2] Ghost sous AA (texte suggéré, ~2,3:1) -> token --ghost #a99a82 -> #786750 (4,56:1 papier / 5,02:1 carte). DESIGN.md + design.json mis à jour. FIX.
- [P3] Tête de section opaque (coulisses) -> didascalie en clair "la confidentialité, par construction". FIX.
- ink-faint #5e5446 : vérifié à 6,21:1, déjà conforme, inchangé.

## Restant (non traité)
- [P2] Fonts Google (gstatic) au runtime : seul appel tiers, contredit la promesse local — envisager self-host.
- [P2] Pas de fallback si souffleuse-demo.mp4 404.
- [P3] role="marquee" non standard ; softwareVersion JSON-LD 0.9.0 vs app 0.3.0 à vérifier.
