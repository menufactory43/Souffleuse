---
status: complete
quick_id: 260608-jux
phase: quick
plan: 260608-jux
subsystem: reverse-engineering-documentation
tags: [cotypist, llama.cpp, ghost-text, branching, mid-word, ghidra]
key_files:
  created:
    - docs/cotypist-ghost-generation-reconstruction.html
decisions:
  - "Le contenu porte exclusivement sur Cotypist."
  - "Les preuves, inférences et inconnues sont visuellement séparées."
  - "Le simulateur mid-word affiche la séquence interne complète mais retire le préfixe déjà tapé du ghost visible."
metrics:
  tasks_completed: 1
  tasks_total: 1
  completed_date: "2026-06-08"
---

# Quick Task 260608-jux Summary

**One-liner:** document HTML autonome et interactif décrivant le pipeline Cotypist, son branching K=9, son pruning déterministe, son cache KV et son chemin mid-word contraint.

## Vérifications

- JavaScript compilé avec `new Function` sans erreur.
- 20 identifiants HTML uniques.
- Aucune dépendance CSS ou JavaScript réseau.
- Aucun contenu Souffleuse dans le document.
- Responsive prévu aux seuils 1040 px et 760 px.
- `git diff --check` sans erreur.

## Limite de vérification

Le navigateur intégré a refusé l'ouverture de l'URL locale `file://` selon sa politique de sécurité.
Le contrôle visuel automatisé n'a donc pas été exécuté; aucun contournement n'a été tenté.

## Fichier livré

- `docs/cotypist-ghost-generation-reconstruction.html`

