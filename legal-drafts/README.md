# Pages légales — BROUILLONS (hors site)

Ces pages (CGV/CGU, EULA, mentions légales — FR + EN) sont **volontairement hors
de `website/`** : elles sont **sauvegardées dans le dépôt mais PAS déployées** sur
souffleuse.app tant que l'app est en **bêta gratuite** (aucun paiement encore).

## Pourquoi hors site
- Elles contiennent des **placeholders** (`[SOCIÉTÉ]`, `[ADRESSE DE DOMICILIATION]`,
  `[RCS/SIREN]`, `[REPRÉSENTANT LÉGAL]`, `[DROIT APPLICABLE]`…) qui ne doivent pas
  apparaître en clair en ligne.
- Ce sont des **modèles non juridiques** : à faire relire par un juriste.

## Le jour de l'activation du paiement
1. Remplir les placeholders (société + adresse de **domiciliation**, jamais le domicile).
2. Faire relire.
3. Re-déplacer les fichiers dans `website/` (et `website/en/`).
4. Rétablir les liens de pied de page (Conditions / Licence / Mentions) sur
   `index.html`, `en/index.html`, `confidentialite.html`, `en/privacy.html`.
5. Ré-ajouter les entrées au `website/sitemap.xml`.
6. Déployer : `npx --yes vercel@latest --prod --yes` depuis `website/`.

## Fichiers
- `conditions.html` / `en/terms.html` — CGV/CGU (achat via Lemon Squeezy, Merchant of Record)
- `licence.html` / `en/license.html` — EULA (licence d'usage on-device)
- `mentions-legales.html` / `en/legal-notice.html` — mentions légales (société + domiciliation)
