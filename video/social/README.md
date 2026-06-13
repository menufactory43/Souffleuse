# Publication auto — Souffleuse → X / TikTok / Instagram / YouTube (via Blotato)

Un seul `npm run publish` pousse les vidéos sur tes réseaux, via l'API
[Blotato](https://help.blotato.com/api) (plateformes déjà auditées côté Blotato →
pas d'audit TikTok ni de Meta App Review à faire toi-même).

## Mise en place (≈ 15 min, une fois)

1. **Compte Blotato** (plan Starter ~29 $/mo) → récupère ta **clé API**
   (Settings › API). Mets-la dans `social/blotato.config.json` (`apiKey`) ou en
   variable d'env `BLOTATO_API_KEY`.

2. **Connecte tes comptes** dans Blotato : X, TikTok, **Instagram (compte
   Business/Creator obligatoire** — bascule gratuite dans les réglages IG),
   YouTube si voulu.

3. **Config locale** :
   ```bash
   cp social/blotato.config.example.json social/blotato.config.json
   # remplis apiKey + link
   node scripts/publish.mjs --accounts      # liste les accountId connectés
   # recopie chaque accountId dans cfg.targets
   ```

4. **Héberge les .mp4 publiquement** (Blotato les récupère par URL). Options :
   - **Cloudflare R2 / S3** avec accès public (recommandé, stable) ;
   - **Asset de release GitHub** : `gh release create promo-v1 video/out/*.mp4` →
     copie les URLs `…/releases/download/…` ;
   - **Bunny.net / autre CDN** ;
   - test rapide : un hébergeur temporaire (liens éphémères, à éviter en prod).

   Mets les URLs publiques dans `assets.vertical.url` (9:16 → TikTok/Reels/Shorts)
   et `assets.wide.url` (16:9 → X).

## Publier

```bash
cd video
npm run publish -- --dry        # aperçu des requêtes, ne poste RIEN
npm run publish                  # publie toutes les cibles activées
npm run publish -- --only=tiktok,twitter
```

## Notes

- `cfg.targets[].enabled:false` désactive une cible (YouTube off par défaut).
- TikTok : `isAiGenerated:false` (la vidéo est du motion-design fait main, pas une
  vidéo générée par IA). Passe-le à `true` seulement si le contenu devient IA.
- Le ratio est porté par l'asset : `vertical` (1080×1920) pour TikTok/Reels/Shorts,
  `wide` (1920×1080) pour X.
- `social/blotato.config.json` est **gitignoré** (il contient ta clé). Ne le commit pas.
