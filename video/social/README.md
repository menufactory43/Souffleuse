# Publication auto — Souffleuse → X / YouTube / Instagram / TikTok (via Buffer)

Un seul `npm run publish` pousse les vidéos sur tes réseaux, via l'API GraphQL de
[Buffer](https://developers.buffer.com) (plateformes déjà auditées côté Buffer →
pas d'audit TikTok ni de Meta App Review à faire toi-même). API « fully scripted »
avec clé perso, dispo **dès le plan gratuit** (1 clé, 3 canaux).

## Mise en place (≈ 15 min, une fois)

1. **Compte Buffer** → récupère ta **clé API** (`publish.buffer.com/settings/api`).
   Mets-la dans `social/buffer.config.json` (`apiKey`) ou en variable d'env
   `BUFFER_API_KEY`. (Gratuit = 3 canaux ; +Instagram = Essentials ~5 $/canal/mo.)

2. **Connecte tes comptes** dans Buffer : X, YouTube, TikTok, **Instagram (compte
   Business/Creator obligatoire** — bascule gratuite dans les réglages IG).

3. **Config locale** :
   ```bash
   cp social/buffer.config.example.json social/buffer.config.json
   # colle apiKey
   node scripts/publish.mjs --orgs        # → ton organizationId (mets-le dans cfg)
   node scripts/publish.mjs --channels    # → les channelId par réseau
   # recopie chaque channelId dans cfg.targets
   ```

4. **Héberge les .mp4 publiquement** (Buffer les récupère par URL, une seule fois).
   → **Déjà fait sur Vercel** : les vidéos sont servies depuis `souffleuse.app/promo/`
   (`website/promo/*.mp4` + headers dans `website/vercel.json`). Les URLs sont
   pré-remplies dans la config (`assets.vertical.url` / `assets.wide.url`).
   Alternative si tu scales : Cloudflare R2 / Bunny (bucket public).

## Publier

```bash
cd video
npm run publish -- --dry        # aperçu des requêtes GraphQL, ne poste RIEN
npm run publish                  # publie toutes les cibles activées
npm run publish -- --only=tiktok,twitter
```

## Notes

- `cfg.targets[].enabled:false` désactive une cible (IG/TikTok off par défaut).
- `mode` : `addToQueue` (prochain créneau de ta file Buffer, relisible avant départ),
  `shareNow` (publie tout de suite), ou ajoute `dueAt` (ISO) pour programmer.
- TikTok : `isAiGenerated:false` (motion-design fait main). Passe à `true` si IA.
- Le ratio est porté par l'asset : `vertical` (1080×1920) pour TikTok/Reels/Shorts,
  `wide` (1920×1080) pour X.
- `social/buffer.config.json` est **gitignoré** (il contient ta clé). Ne le commit pas.
- ⚠️ Endpoint/mutation/enums viennent de la doc Buffer : au 1er appel **live**, 1-2
  champs GraphQL peuvent devoir être ajustés (sélection de retour de `createPost`,
  forme de `metadata` IG/TikTok, `mode`). Le `--dry` aide à vérifier avant.
