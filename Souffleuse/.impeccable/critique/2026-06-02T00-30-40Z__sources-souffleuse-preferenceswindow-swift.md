---
target: préférences
total_score: 26
p0_count: 0
p1_count: 2
timestamp: 2026-06-02T00-30-40Z
slug: sources-souffleuse-preferenceswindow-swift
---
# Critique — Préférences (Souffleuse)

## Design Health Score: 26/40 (Acceptable)

| # | Heuristique | Score | Problème |
|---|---|---|---|
| 1 | Visibilité état | 3 | Badges permission, download progress — solide |
| 2 | Correspondance monde réel | 2 | En-têtes poétiques nuisent trouvabilité |
| 3 | Contrôle & liberté | 3 | Confirmations, annulations, Esc |
| 4 | Cohérence | 2 | Modèle ghost vs traduction séparés; permissions 3 endroits |
| 5 | Prévention erreur | 3 | confirmationDialog, regex, disabled |
| 6 | Reconnaissance vs rappel | 2 | Traduction éclatée force le rappel |
| 7 | Flexibilité | 3 | Raccourcis documentés, pas de recherche |
| 8 | Minimalisme | 2 | Général surchargé + placeholder mort |
| 9 | Récupération erreur | 3 | introuvable/échec + Réessayer |
| 10 | Aide | 3 | Footers explicatifs partout |

## Priority Issues
- [P1] "Général" fourre-tout (6 sections/15 contrôles); Traduction sans onglet dédié, noyée dans "Accepter le souffle". Asymétrie vs "Ton" qui a son onglet. Fix: extraire onglet Traduction, dégraisser Général.
- [P1] Deux sélecteurs de modèle dans deux onglets (ghost->Modèle, traduction->Général). Fix: une règle unique (par fonction OU hub Modèles).
- [P2] Permissions éparpillées sur 3 onglets (Accessibilité/Général, Écran/Contexte, À propos). Fix: centraliser.
- [P2] En-têtes poétiques opaques au scan ("Coups de pouce"=coquilles/emoji). Fix: littéral + 1-2 signatures.
- [P3] Placeholder mort "Au démarrage du Mac: bientôt". Fix: retirer ou implémenter.

## Personas
- Alex: 7 onglets sans recherche, raccourcis non remappables.
- Jordan: en-têtes non littéraux, densité de Général intimidante.
- Sam: Form natif OK; permission par couleur+icône (vérifier annonce VoiceOver).

## Opportunité majeure
Redécouper selon les 4 piliers (Souffle/Traduction/Ton/Carnet) + Réglages/À-propos, au lieu de l'accumulation historique. Réduirait le compte d'onglets ET clarifierait.
