---
quick_id: 260608-ksc
type: execute
autonomous: true
files_modified:
  - tools/cotypist-re/lab.entitlements
  - tools/cotypist-re/prepare-lab.sh
  - tools/cotypist-re/llama-kv.lldb
  - tools/cotypist-re/midword-lab.sh
  - tools/cotypist-re/ghidra/DumpTargetFunctions.java
  - tools/cotypist-re/ghidra/DumpStringReferences.java
  - tools/cotypist-re/branch-lab.sh
  - tools/cotypist-re/branch-probe.c
  - tools/cotypist-re/lldb_branch_width.py
  - tools/cotypist-re/swift-field-layout.mjs
  - tools/cotypist-re/README.md
locked_decisions:
  - "Ne jamais modifier /Applications/Cotypist.app."
  - "La copie instrumentée vit dans /tmp/CotypistLab.app."
  - "La première passe trace seulement les fonctions C exportées de libllama."
  - "Aucun texte utilisateur réel n'est collecté."
---

<objective>
Préparer et valider un laboratoire dynamique reproductible pour Cotypist, puis observer les
appels llama.cpp liés au décodage et aux séquences KV sur du texte synthétique.
</objective>

<tasks>
  <task type="auto">
    <name>Préparer la copie resignée et les commandes LLDB</name>
    <files>tools/cotypist-re/lab.entitlements, tools/cotypist-re/prepare-lab.sh, tools/cotypist-re/llama-kv.lldb, tools/cotypist-re/README.md</files>
    <action>Créer une copie jetable, la resigner avec get-task-allow, puis lancer LLDB avec des breakpoints llama ciblés.</action>
    <verify><automated>codesign --verify --deep --strict /tmp/CotypistLab.app puis lancement LLDB en batch.</automated></verify>
    <done>La copie démarre sous LLDB et les breakpoints llama sont résolus. L'observation runtime du chemin ghost reste bloquée: Cotypist désactive les fonctions sous signature ad-hoc, et le binaire officiel signé refuse l'attachement LLDB via hardened runtime.</done>
  </task>
  <task type="auto">
    <name>Corriger le lien modèle et séparer preuves des inférences</name>
    <files>docs/cotypist-ghost-generation-reconstruction.html, tools/cotypist-re/README.md</files>
    <action>Relier le modèle GGUF dans le HOME isolé, confirmer que le binaire officiel le mappe, puis corriger le rapport pour marquer K=9 comme inférence forte plutôt que preuve dynamique.</action>
    <verify><automated>lsof sur le processus officiel signé lancé avec HOME isolé; recherche des affirmations trop fortes dans le HTML.</automated></verify>
    <done>Le modèle 1B est mappé depuis le HOME isolé et le rapport distingue les faits confirmés des inconnues runtime.</done>
  </task>
  <task type="auto">
    <name>Tracer le comportement mid-word du binaire signé</name>
    <files>tools/cotypist-re/midword-lab.sh, tools/cotypist-re/ghidra/DumpTargetFunctions.java, docs/cotypist-ghost-generation-reconstruction.html, tools/cotypist-re/README.md</files>
    <action>Comparer une frappe conforme et divergente sur un ghost synthétique, profiler le processus officiel avec sample, puis décompiler les callers observés avec Ghidra.</action>
    <verify><automated>Le cas conforme ne contient aucun llama_decode; le cas divergent contient llama_vocab::tokenize, llama_decode et un retrait de séquence KV.</automated></verify>
    <done>Le chemin mid-word est hybride: consommation locale du suffixe tant que la frappe correspond, puis invalidation, retokenisation et régénération à la première divergence.</done>
  </task>
  <task type="auto">
    <name>Mesurer la largeur active et reconstruire le pruning</name>
    <files>tools/cotypist-re/branch-lab.sh, tools/cotypist-re/branch-probe.c, tools/cotypist-re/lldb_branch_width.py, tools/cotypist-re/swift-field-layout.mjs, tools/cotypist-re/ghidra/DumpStringReferences.java, docs/cotypist-ghost-generation-reconstruction.html, tools/cotypist-re/README.md</files>
    <action>Relier les métadonnées candidates aux fonctions Swift, extraire les comparaisons de score et profiler plusieurs prompts synthétiques pour distinguer largeur maximale, largeur active et résultats terminés.</action>
    <verify><automated>Exports Ghidra reproductibles, corpus synthétique capturé et assertions du rapport limitées aux éléments statiquement ou dynamiquement observés.</automated></verify>
    <done>Les structures Swift, constantes et comparaisons ARM64 établissent maxSearchWidth=9, maxResultWidth=9, minBranchProbability=0.05, relativeCutoff=1e-10 et le seuil top-K inclusif. La sonde matérielle charge dans le lab, mais la copie resignée ne rejoint pas le chemin ghost faute de conserver l'autorisation Accessibility de l'app officielle; les comptes runtime par ghost restent donc non observés.</done>
  </task>
</tasks>
