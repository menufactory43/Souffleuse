---
target: préférences
total_score: 30
p0_count: 0
p1_count: 0
timestamp: 2026-06-02T08-16-09Z
slug: sources-souffleuse-preferenceswindow-swift
---
# Re-critique — Préférences (après distill/layout/clarify/polish)

## Design Health Score: 30/40 (Good) — was 26

| # | Heuristique | Avant | Après |
|---|---|---|---|
| 1 | Visibilité état | 3 | 3 |
| 2 | Correspondance monde réel | 2 | 3 |
| 3 | Contrôle & liberté | 3 | 3 |
| 4 | Cohérence | 2 | 3 |
| 5 | Prévention erreur | 3 | 3 |
| 6 | Reconnaissance vs rappel | 2 | 3 |
| 7 | Flexibilité | 3 | 3 |
| 8 | Minimalisme | 2 | 3 |
| 9 | Récupération erreur | 3 | 3 |
| 10 | Aide | 3 | 3 |

## Issues d'origine: toutes closes (2xP1, 2xP2, P3)
Structure 7 onglets (1 fourre-tout) -> 8 onglets mono-thème par fonction.
Modèles près de leur fonction; permissions centralisées; en-têtes littéraux; placeholder implémenté (SMAppService); gouttière d'édition partagée (RuleListEditor); a11y VoiceOver.

## Résiduel (plafonne à 30)
- [P2] 8 onglets > seuil confort (~5). Fusionner Personnalisation dans Souffle, ou ajouter recherche. Prochain levier.
- [P3] Deux rouges d'erreur: "introuvable" .red vs "échec" sang-de-bœuf.
- [P3] Onglets-table (Par app/Ton) en VStack vs Form .grouped ailleurs (Table ne compose pas dans Form).
- [P3] VoiceOver: labels ajoutés, non vérifiés sur appareil.
