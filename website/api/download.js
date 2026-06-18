// Edge Function — compteur de téléchargements du .dmg.
//
// Branchée sur `/Souffleuse.dmg` via le `rewrites` de vercel.json. Le vrai
// binaire vit en `/dl/Souffleuse.dmg` (fichier statique) : on le sort de la
// racine pour que ce rewrite l'emporte (un fichier statique a priorité sur un
// rewrite sur Vercel).
//
// Chemin d'une requête :
//   GET /Souffleuse.dmg  →  (rewrite)  →  cette fonction
//     → incrémente les compteurs KV (best-effort, jamais bloquant)
//     → 302 vers /dl/Souffleuse.dmg (Vercel sert le fichier, ranges/resume OK)
//
// Sparkle suit le redirect et valide la signature EdDSA sur les octets reçus,
// donc le 302 est transparent pour la mise à jour in-app.
//
// Privacy : on lit le User-Agent uniquement pour classer site vs Sparkle (test
// de sous-chaîne), on ne le stocke pas. Aucune IP, aucun cookie, aucune PII —
// que des compteurs agrégés. Le comptage PAR VERSION lit la version courante
// dans l'appcast (source de vérité du site, pas une donnée utilisateur).

export const config = { runtime: 'edge' }

// Fichier réel servi après comptage (hors racine, cf. en-tête).
const DMG_PATH = '/dl/Souffleuse.dmg'

// Budget max accordé à KV avant de servir quand même : un store lent ou cassé
// ne doit jamais retarder un téléchargement.
const KV_TIMEOUT_MS = 800

// --- Version courante (depuis l'appcast) pour le comptage par release ---------
// L'appcast porte UNE seule <item> = la version courante. On la lit cote serveur
// (best-effort, court timeout) et on la met en cache au niveau du module : un
// instance d'edge function est reutilisee, donc la plupart des hits ne refont pas
// le fetch. Format strict (chiffres + points) -> aucune cle KV arbitraire.
const VERSION_TTL_MS = 5 * 60 * 1000
const VERSION_RE = /^\d+\.\d+(?:\.\d+)?$/
let _verCache = { v: null, at: 0 }

async function currentVersion(baseUrl) {
    const now = Date.now()
    if (_verCache.v && now - _verCache.at < VERSION_TTL_MS) return _verCache.v
    const ctrl = new AbortController()
    const timer = setTimeout(() => ctrl.abort(), 600)
    try {
        const res = await fetch(new URL('/appcast.xml', baseUrl).toString(), { signal: ctrl.signal })
        const xml = await res.text()
        const m = xml.match(/<sparkle:shortVersionString>([^<]+)<\/sparkle:shortVersionString>/)
        const v = m && m[1].trim()
        if (v && VERSION_RE.test(v)) { _verCache = { v, at: now } }
    } catch {
        // Appcast lent/injoignable : on garde l'eventuelle valeur en cache (stale).
    } finally {
        clearTimeout(timer)
    }
    return _verCache.v
}

/// Incrémente les compteurs en un seul aller-retour (pipeline Upstash REST).
/// No-op silencieux si KV n'est pas configuré (env absentes) ou en erreur :
/// le download ne dépend jamais du compteur.
async function bumpCounters(channel, version) {
    // Selon l'intégration, Vercel expose soit KV_REST_API_* (store « KV »), soit
    // UPSTASH_REDIS_REST_* (intégration Upstash directe). On accepte les deux.
    const url = process.env.KV_REST_API_URL || process.env.UPSTASH_REDIS_REST_URL
    const token = process.env.KV_REST_API_TOKEN || process.env.UPSTASH_REDIS_REST_TOKEN
    if (!url || !token) return // KV non activé → on ne compte pas, on sert quand même.

    // Bucket jour en UTC (YYYY-MM-DD) pour une série temporelle simple.
    const day = new Date().toISOString().slice(0, 10)
    const commands = [
        ['INCR', 'dl:total'],
        ['INCR', `dl:${channel}`],
        ['INCR', `dl:${day}:total`],
        ['INCR', `dl:${day}:${channel}`],
    ]
    // Comptage par release (si la version a pu être lue dans l'appcast). `dl:versions`
    // est un SET qui liste les versions vues → /api/stats?versions=1 les énumère.
    if (version) {
        commands.push(
            ['SADD', 'dl:versions', version],
            ['INCR', `dl:ver:${version}`],
            ['INCR', `dl:ver:${version}:${channel}`],
        )
    }

    const ctrl = new AbortController()
    const timer = setTimeout(() => ctrl.abort(), KV_TIMEOUT_MS)
    try {
        await fetch(`${url}/pipeline`, {
            method: 'POST',
            headers: {
                Authorization: `Bearer ${token}`,
                'Content-Type': 'application/json',
            },
            body: JSON.stringify(commands),
            signal: ctrl.signal,
        })
    } catch {
        // Timeout / réseau / store down : on ignore, le download prime.
    } finally {
        clearTimeout(timer)
    }
}

export default async function handler(request) {
    const ua = request.headers.get('user-agent') || ''
    // Sparkle s'annonce dans son UA (ex: "Souffleuse/0.8.1 Sparkle/2.x").
    const channel = ua.includes('Sparkle') ? 'sparkle' : 'site'

    const version = await currentVersion(request.url)
    await bumpCounters(channel, version)

    // Location absolue dérivée de l'origine de la requête (robuste pour Sparkle).
    const target = new URL(DMG_PATH, request.url).toString()
    return new Response(null, {
        status: 302,
        headers: {
            Location: target,
            // Pas de cache sur le 302 : la fonction doit s'exécuter à chaque hit
            // pour que le comptage soit fidèle.
            'Cache-Control': 'no-store',
        },
    })
}
