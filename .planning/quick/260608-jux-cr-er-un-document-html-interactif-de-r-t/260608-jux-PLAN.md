---
quick_id: 260608-jux
type: execute
autonomous: true
files_modified:
  - docs/cotypist-ghost-generation-reconstruction.html
  - .planning/quick/260608-jux-cr-er-un-document-html-interactif-de-r-t/260608-jux-PLAN.md
  - .planning/quick/260608-jux-cr-er-un-document-html-interactif-de-r-t/260608-jux-SUMMARY.md
locked_decisions:
  - "Le document décrit Cotypist uniquement; Souffleuse n'est pas utilisée comme preuve."
  - "Chaque affirmation est classée: prouvé dans le binaire, inférence solide, ou inconnu."
  - "Le cas mid-word est présenté comme un décodage contraint par requiredPrefix, distinct du chemin après espace."
---

<objective>
Créer une page HTML autonome et interactive qui restitue la reconstruction du pipeline de
génération des ghosts de Cotypist, depuis la collecte de contexte jusqu'à l'overlay.

La page doit rendre visibles les paramètres confirmés du moteur llama.cpp, le branching K=9,
le scoring cumulatif, le pruning, la réutilisation du KV cache et le comportement mid-word.
</objective>

<tasks>

<task type="auto">
  <name>Construire le document interactif Cotypist</name>
  <files>docs/cotypist-ghost-generation-reconstruction.html</files>
  <action>
    Créer un fichier HTML/CSS/JS sans dépendance réseau. Inclure une vue synthétique du pipeline,
    une simulation des branches et du pruning, les scénarios après espace/mid-word/mid-line,
    un inventaire des faits confirmés et des inconnues, et les sources de preuve.
  </action>
  <verify>
    <automated>Vérifier la syntaxe HTML/JS, ouvrir le fichier dans le navigateur intégré, tester les contrôles et inspecter le rendu desktop/mobile.</automated>
  </verify>
  <done>La page est lisible, responsive, interactive, et ne présente aucune inférence comme un fait.</done>
</task>

</tasks>
