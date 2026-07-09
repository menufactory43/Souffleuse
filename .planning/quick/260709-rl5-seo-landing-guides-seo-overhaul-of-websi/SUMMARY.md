---
task: seo-landing-guides
date: 2026-07-09
status: complete
---

# Résumé — SEO overhaul souffleuse.app

## Recherche mots-clés (agent WebSearch, 17 requêtes)
- Wedge n°1 : « cotypist alternative (gratuite) » — Cotypist passé à l'abonnement (~100 complétions/j gratuites puis ~6–9 $/mois).
- SERP FR quasi vide : « autocomplétion IA Mac », « reformuler un mail IA », « traduire en écrivant », « IA locale Mac » sans concurrent produit.
- Petits domaines rankent page 1 avec 1 page exact-match par mot-clé (Grambo, Wysp, WordPolish).
- « souffleuse » seule = souffleuses à neige → toujours marque + descriptif dans les titles.

## Livré (3 commits)
1. `1379957` — accueil FR : title/meta/OG « autocomplétion IA 100 % locale pour Mac », JSON-LD SoftwareApplication à jour (0.12.1, screenshots, featureList) + FAQPage, section galerie (5 cartes promo en 720 px, ~90 Ko vs 450 Ko), section Guides, FAQ +5 questions SEO avec « En savoir plus », footer guides, ~6,5→7,5 Mo.
2. `19e78b0` — 5 guides FR (`website/guides/`) : autocompletion-mac-comme-iphone, reformuler-mail-professionnel-ia (gabarit exemplaire), traduire-en-ecrivant-mac, ia-locale-mac, alternative-cotypist-gratuite.
3. `fdefe69` — 7 guides EN (`website/en/guides/`) + hub `en/compare/cotypist-alternatives.html` (tableau honnête Cotypist/Typeahead/Wysp/Souffleuse), sitemap +13 URLs, footer EN guides.

Toutes les pages : gabarit commun (papier/encre/Bodoni/Spectral, fonts self-hébergées, zéro requête tierce), JSON-LD Article+Breadcrumb+FAQPage, maillage interne, CTA `/Souffleuse.dmg` (jamais `/dl/`), 800–1 250 mots.

## Vérifié
- JSON-LD : 100 % parseable (script python) sur les 14 pages.
- Balisage équilibré, canonicals absolus corrects, aucun lien interne cassé, aucun usage du chemin non compté `/dl/`.
- Cohérence factuelle FR/EN du comparatif (correction : Cotypist bien marqué « local »).

## Reste à faire (hors scope)
- **Déployer** : `cd website && npx --yes vercel@latest --prod --yes` (le push git ne déploie pas), puis vérifier `curl -s "https://souffleuse.app/?cb=$(date +%s)" | rg -c data-version`.
- Soumettre le sitemap dans Google Search Console ; envisager `cleanUrls` Vercel plus tard.
- L'accueil EN `/en/index.html` garde ses meta d'origine (seul le footer a reçu les liens guides) — refonte méta EN possible en tâche suivante.
