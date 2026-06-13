#!/usr/bin/env node
// ─────────────────────────────────────────────────────────────────────────────
// publish.mjs — publie les vidéos Souffleuse sur X / TikTok / Instagram / YouTube
// via l'API Blotato (un seul endpoint, plateformes déjà auditées côté Blotato).
//
// Flux Blotato (https://help.blotato.com/api) :
//   1. POST /v2/media {url}      → enregistre un média depuis une URL PUBLIQUE,
//                                   renvoie {url: "https://database.blotato.com/…"}.
//   2. POST /v2/posts {post:{…}} → publie sur une plateforme (accountId + target).
//
// ⚠️ Blotato récupère le média par URL : le .mp4 doit être accessible publiquement
//    (R2/S3 public, asset de release GitHub, Bunny, ou hébergeur temporaire).
//    Voir social/README.md pour les options. On met ces URLs dans assets.*.url.
//
// Pré-requis : social/blotato.config.json (copié depuis .example.json) rempli,
//   et un compte Blotato avec X/TikTok/Instagram(Business)/YouTube connectés.
//
// Usage :
//   node scripts/publish.mjs --accounts          # liste les comptes → accountId
//   node scripts/publish.mjs --dry               # affiche les requêtes sans poster
//   node scripts/publish.mjs                      # publie toutes les cibles activées
//   node scripts/publish.mjs --only=tiktok,twitter
// ─────────────────────────────────────────────────────────────────────────────
import {readFileSync, existsSync} from 'node:fs';
import {dirname, join} from 'node:path';
import {fileURLToPath} from 'node:url';

const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..');
const CFG_PATH = join(ROOT, 'social', 'blotato.config.json');
const API = 'https://backend.blotato.com';

const args = process.argv.slice(2);
const has = (f) => args.includes(f);
const val = (k, d) => {
    const a = args.find((x) => x.startsWith(k + '='));
    return a ? a.split('=')[1] : d;
};
const DRY = has('--dry');
const ONLY = (val('--only', '') || '').split(',').map((s) => s.trim()).filter(Boolean);

if (!existsSync(CFG_PATH)) {
    console.error(
        `Config absente : ${CFG_PATH}\n` +
            `→ copie social/blotato.config.example.json vers social/blotato.config.json puis remplis-la.`,
    );
    process.exit(1);
}
const cfg = JSON.parse(readFileSync(CFG_PATH, 'utf8'));
const KEY = process.env.BLOTATO_API_KEY || cfg.apiKey;
if (!KEY || String(KEY).startsWith('REMPLACE')) {
    console.error('Clé API Blotato manquante (env BLOTATO_API_KEY ou cfg.apiKey).');
    process.exit(1);
}
const headers = {'Content-Type': 'application/json', 'blotato-api-key': KEY};

async function post(path, body) {
    const res = await fetch(API + path, {method: 'POST', headers, body: JSON.stringify(body)});
    const txt = await res.text();
    if (!res.ok) throw new Error(`${path} → HTTP ${res.status} ${txt}`);
    return txt ? JSON.parse(txt) : {};
}

// --accounts : lister les comptes connectés (pour récupérer les accountId)
if (has('--accounts')) {
    const res = await fetch(API + '/v2/users/me/accounts', {headers});
    const txt = await res.text();
    if (!res.ok) {
        console.error(`/v2/users/me/accounts → HTTP ${res.status} ${txt}`);
        process.exit(1);
    }
    console.log(txt);
    process.exit(0);
}

// 1) Upload média par URL publique (mis en cache : un même fichier sert plusieurs plateformes)
const mediaCache = new Map();
async function uploadMedia(url) {
    if (mediaCache.has(url)) return mediaCache.get(url);
    if (DRY) {
        mediaCache.set(url, url);
        return url;
    }
    const {url: hosted} = await post('/v2/media', {url});
    mediaCache.set(url, hosted);
    return hosted;
}

// 2) Cible par plateforme (champs spécifiques)
function buildTarget(platform, t) {
    switch (platform) {
        case 'tiktok':
            return {
                targetType: 'tiktok',
                privacyLevel: t.privacyLevel || 'PUBLIC_TO_EVERYONE',
                disabledComments: false,
                disabledDuet: false,
                disabledStitch: false,
                isBrandedContent: false,
                isYourBrand: false,
                isAiGenerated: t.isAiGenerated ?? false,
            };
        case 'youtube':
            return {
                targetType: 'youtube',
                title: t.title || 'Souffleuse',
                privacyStatus: t.privacyStatus || 'public',
                shouldNotifySubscribers: t.shouldNotifySubscribers ?? false,
            };
        case 'facebook':
            return {targetType: 'facebook', pageId: t.pageId};
        default:
            return {targetType: platform}; // twitter, instagram, threads, bluesky, linkedin…
    }
}

// 3) Publier chaque cible activée
const targets = cfg.targets.filter(
    (t) => t.enabled !== false && (ONLY.length === 0 || ONLY.includes(t.platform)),
);
if (!targets.length) {
    console.error('Aucune cible activée (vérifie cfg.targets / --only).');
    process.exit(1);
}

let ok = 0;
let fail = 0;
for (const t of targets) {
    const asset = cfg.assets?.[t.asset];
    if (!asset?.url || String(asset.url).includes('TON-HOST')) {
        console.error(`✗ ${t.platform}: asset « ${t.asset} » sans URL publique valide — saute.`);
        fail++;
        continue;
    }
    if (!t.accountId || String(t.accountId).startsWith('REMPLACE')) {
        console.error(`✗ ${t.platform}: accountId manquant (lance --accounts) — saute.`);
        fail++;
        continue;
    }
    const text = (cfg.captions?.[t.platform] || cfg.captions?.default || '').replaceAll(
        '{LINK}',
        cfg.link || '',
    );
    try {
        const media = await uploadMedia(asset.url);
        const body = {
            post: {
                accountId: String(t.accountId),
                content: {text, mediaUrls: [media], platform: t.platform},
                target: buildTarget(t.platform, t),
            },
        };
        if (DRY) {
            console.log(`— DRY ${t.platform} (asset ${t.asset}) —\n${JSON.stringify(body, null, 2)}\n`);
            ok++;
            continue;
        }
        const r = await post('/v2/posts', body);
        console.log(`✓ ${t.platform} publié →`, r.id || r);
        ok++;
    } catch (e) {
        console.error(`✗ ${t.platform}:`, e.message);
        fail++;
    }
}
console.log(`\n${DRY ? '[dry] ' : ''}${ok} ok · ${fail} échec(s).`);
process.exit(fail && !ok ? 1 : 0);
