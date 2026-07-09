---
task: seo-landing-guides
date: 2026-07-09
status: in-progress
---

# Quick task — SEO overhaul du site souffleuse.app

## Contexte (recherche mots-clés, 2026-07-09)
- Niche « system-wide local AI autocomplete for Mac » : Cotypist domine, mais passage en abonnement ($6–9/mo) → wedge « alternative gratuite / sans abonnement » = intention max.
- SERP FR quasi vide : aucun produit ne possède « autocomplétion IA Mac », « reformuler un mail IA », « traduire en écrivant », « IA locale Mac ».
- Petits domaines rankent page 1 avec 1 landing exact-match par mot-clé (Grambo, Refine, Wysp, WordPolish).
- « souffleuse » seule = souffleuses à neige → toujours titrer marque + descriptif.

## Livrables
1. `website/index.html` (FR) — title/description/JSON-LD SEO (SoftwareApplication enrichi + FAQPage), section screenshots (cartes promo), section guides, FAQ étendue (questions SEO + « En savoir plus » vers guides), footer enrichi. Conserver design + démo interactive + badge version + modale don.
2. Images screenshots optimisées pour le web (720 px) sous `website/promo/souffleuse-en-action/web/`.
3. Guides FR sous `website/guides/` : reformuler-mail-professionnel-ia, traduire-en-ecrivant-mac, ia-locale-mac, autocompletion-mac-comme-iphone, alternative-cotypist-gratuite.
4. Guides EN sous `website/en/guides/` : autocomplete-every-mac-app, mac-predictive-text-like-iphone, copilot-for-writing, offline-ai-writing-mac, translate-while-typing-mac, professional-email-tone-mac, local-llm-writing-assistant + hub `website/en/compare/cotypist-alternatives.html`.
5. `website/sitemap.xml` mis à jour (toutes les nouvelles URLs).
6. Section guides ajoutée aussi au footer de `website/en/index.html` (liens de découverte).

## Contraintes
- Pages autonomes, fonts self-hébergées (`/assets/fonts.css`), palette papier/encre/sang-de-bœuf, aucune requête tierce.
- Bouton téléchargement public = `/Souffleuse.dmg` (compteur) ; jamais `/dl/` sur les pages publiques.
- Ton FR-first « souffleuse de théâtre », pas de jargon marketing creux.
- Aucun code app touché ; audit.sh non concerné (website/ hors SHIPPING_DIRS).

## Commits prévus
1. assets screenshots web + index.html
2. guides FR
3. guides EN + compare + sitemap + en/index footer
