#!/usr/bin/env node
// ─────────────────────────────────────────────────────────────────────────────
// publish.mjs — publie les vidéos Souffleuse sur X / YouTube / Instagram / TikTok
// via l'API GraphQL de Buffer (https://developers.buffer.com).
//
// Pourquoi Buffer : API « fully scripted » avec clé perso (Bearer), vidéo + threads,
// plateformes déjà auditées côté Buffer (pas de TikTok API approval ni Meta App
// Review à faire soi-même), et dispo dès le plan gratuit (1 clé, 3 canaux).
//
// Flux GraphQL :
//   - query channels(organizationId)        → récupère les channelId par réseau.
//   - mutation createPost(input)             → publie/met en file un post.
//     assets = [{ video: { url } }]  ⚠️ la vidéo est fournie par URL PUBLIQUE
//     (R2/S3 public, asset de release GitHub, Bunny…). Buffer la récupère.
//
// Pré-requis : social/buffer.config.json (copié depuis .example.json) rempli,
//   clé API (publish.buffer.com/settings/api), canaux X/YouTube/IG/TikTok connectés.
//
// Usage :
//   node scripts/publish.mjs --orgs              # tente de lister tes organizationId
//   node scripts/publish.mjs --channels          # liste les canaux → channelId
//   node scripts/publish.mjs --dry               # affiche les requêtes sans poster
//   node scripts/publish.mjs                      # publie toutes les cibles activées
//   node scripts/publish.mjs --only=tiktok,twitter
// ─────────────────────────────────────────────────────────────────────────────
import {readFileSync, existsSync} from 'node:fs';
import {dirname, join} from 'node:path';
import {fileURLToPath} from 'node:url';

const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..');
const CFG_PATH = join(ROOT, 'social', 'buffer.config.json');
const ENDPOINT = 'https://api.buffer.com'; // POST GraphQL

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
            `→ copie social/buffer.config.example.json vers social/buffer.config.json puis remplis-la.`,
    );
    process.exit(1);
}
const cfg = JSON.parse(readFileSync(CFG_PATH, 'utf8'));
const KEY = process.env.BUFFER_API_KEY || cfg.apiKey;
if (!KEY || String(KEY).startsWith('REMPLACE')) {
    console.error('Clé API Buffer manquante (env BUFFER_API_KEY ou cfg.apiKey). → publish.buffer.com/settings/api');
    process.exit(1);
}
const headers = {'Content-Type': 'application/json', Authorization: `Bearer ${KEY}`};

/** Exécute une requête GraphQL ; lève sur erreur réseau ou erreurs GraphQL. */
async function gql(query, variables = {}) {
    const res = await fetch(ENDPOINT, {
        method: 'POST',
        headers,
        body: JSON.stringify({query, variables}),
    });
    const txt = await res.text();
    let json;
    try {
        json = txt ? JSON.parse(txt) : {};
    } catch {
        throw new Error(`HTTP ${res.status} (réponse non-JSON) : ${txt.slice(0, 300)}`);
    }
    if (!res.ok || json.errors) {
        throw new Error(`GraphQL ${res.status} : ${JSON.stringify(json.errors || json).slice(0, 500)}`);
    }
    return json.data;
}

// --orgs : tente de lister tes organisations (pour récupérer organizationId).
// Schéma « account » non garanti côté doc → best-effort, on imprime le brut.
if (has('--orgs')) {
    try {
        const data = await gql(`query { account { id organizations { id name } } }`);
        console.log(JSON.stringify(data, null, 2));
    } catch (e) {
        console.error(
            `Échec de la découverte auto : ${e.message}\n` +
                `→ Récupère ton organizationId depuis l'URL du dashboard Buffer, ou la doc, et mets-le dans cfg.organizationId.`,
        );
        process.exit(1);
    }
    process.exit(0);
}

// --channels : liste les canaux connectés (id, nom, service) pour cette organisation.
if (has('--channels')) {
    if (!cfg.organizationId || String(cfg.organizationId).startsWith('REMPLACE')) {
        console.error('cfg.organizationId manquant — lance d\'abord `--orgs`.');
        process.exit(1);
    }
    const data = await gql(
        `query Channels($input: ChannelsInput!) {
            channels(input: $input) { id name service }
        }`,
        {input: {organizationId: cfg.organizationId}},
    );
    for (const c of data.channels || []) {
        console.log(`${c.service.padEnd(12)} ${c.id}   ${c.name}`);
    }
    process.exit(0);
}

// Métadonnées spécifiques par réseau (best-effort ; ajuste si le schéma diffère).
function buildMetadata(t) {
    if (t.platform === 'tiktok') return {tiktok: {isAiGenerated: t.isAiGenerated ?? false}};
    if (t.platform === 'instagram') return {instagram: {postType: t.postType || 'reel'}};
    if (t.platform === 'youtube') return {youtube: {title: t.title || 'Souffleuse'}};
    return undefined;
}

// Publier chaque cible activée.
const targets = (cfg.targets || []).filter(
    (t) => t.enabled !== false && (ONLY.length === 0 || ONLY.includes(t.platform)),
);
if (!targets.length) {
    console.error('Aucune cible activée (vérifie cfg.targets / --only).');
    process.exit(1);
}

const MUTATION = `mutation CreatePost($input: CreatePostInput!) {
    createPost(input: $input) { id }
}`;

let ok = 0;
let fail = 0;
for (const t of targets) {
    const asset = cfg.assets?.[t.asset];
    if (!asset?.url || String(asset.url).includes('TON-HOST')) {
        console.error(`✗ ${t.platform}: asset « ${t.asset} » sans URL publique valide — saute.`);
        fail++;
        continue;
    }
    if (!t.channelId || String(t.channelId).startsWith('REMPLACE')) {
        console.error(`✗ ${t.platform}: channelId manquant (lance --channels) — saute.`);
        fail++;
        continue;
    }
    const text = (cfg.captions?.[t.platform] || cfg.captions?.default || '').replaceAll('{LINK}', cfg.link || '');
    const metadata = buildMetadata(t);
    const input = {
        channelId: String(t.channelId),
        text,
        assets: [{video: {url: asset.url, ...(asset.thumbnailUrl ? {thumbnailUrl: asset.thumbnailUrl} : {})}}],
        // addToQueue = prochain créneau de ta file Buffer (tu peux relire avant qu'il parte).
        // « shareNow » pour publier tout de suite ; ou mets t.dueAt (ISO) pour programmer.
        mode: t.mode || 'addToQueue',
        schedulingType: 'automatic',
        ...(t.dueAt ? {dueAt: t.dueAt} : {}),
        ...(metadata ? {metadata} : {}),
        aiAssisted: false,
        source: 'souffleuse-publish',
    };
    try {
        if (DRY) {
            console.log(`— DRY ${t.platform} (asset ${t.asset}) —\n${JSON.stringify({input}, null, 2)}\n`);
            ok++;
            continue;
        }
        const data = await gql(MUTATION, {input});
        console.log(`✓ ${t.platform} →`, data.createPost?.id || data);
        ok++;
    } catch (e) {
        console.error(`✗ ${t.platform}:`, e.message);
        fail++;
    }
}
console.log(`\n${DRY ? '[dry] ' : ''}${ok} ok · ${fail} échec(s).`);
process.exit(fail && !ok ? 1 : 0);
