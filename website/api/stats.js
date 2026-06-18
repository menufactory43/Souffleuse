// Edge Function — lecture seule des compteurs de téléchargement.
//
//   GET /api/stats            → totaux cumulés (total / site / sparkle)
//   GET /api/stats?day=YYYY-MM-DD → ajoute les compteurs du jour demandé
//   GET /api/stats?versions=1 → ajoute la ventilation par release (adoption)
//
// Utilise le token read-only de KV si disponible (sinon le token standard).
// Aucune écriture. Réponse JSON, non mise en cache.

export const config = { runtime: 'edge' }

const KV_TIMEOUT_MS = 1500

/// MGET via l'API REST Upstash. Retourne un tableau de valeurs (null si clé
/// absente). Lève si KV n'est pas joignable — géré par l'appelant.
async function mget(keys) {
    // Accepte les deux conventions de nommage Vercel (KV_* ou UPSTASH_REDIS_*).
    const url = process.env.KV_REST_API_URL || process.env.UPSTASH_REDIS_REST_URL
    // Token read-only de préférence (principe du moindre privilège), avec repli.
    const token =
        process.env.KV_REST_API_READ_ONLY_TOKEN ||
        process.env.KV_REST_API_TOKEN ||
        process.env.UPSTASH_REDIS_REST_READ_ONLY_TOKEN ||
        process.env.UPSTASH_REDIS_REST_TOKEN
    if (!url || !token) throw new Error('KV non configuré')

    const ctrl = new AbortController()
    const timer = setTimeout(() => ctrl.abort(), KV_TIMEOUT_MS)
    try {
        const res = await fetch(`${url}/mget/${keys.map(encodeURIComponent).join('/')}`, {
            headers: { Authorization: `Bearer ${token}` },
            signal: ctrl.signal,
        })
        const body = await res.json()
        return body.result ?? []
    } finally {
        clearTimeout(timer)
    }
}

/// SMEMBERS via l'API REST Upstash : liste les membres d'un SET (les versions
/// vues). Retourne [] si vide/absent. Lève si KV injoignable.
async function smembers(key) {
    const url = process.env.KV_REST_API_URL || process.env.UPSTASH_REDIS_REST_URL
    const token =
        process.env.KV_REST_API_READ_ONLY_TOKEN ||
        process.env.KV_REST_API_TOKEN ||
        process.env.UPSTASH_REDIS_REST_READ_ONLY_TOKEN ||
        process.env.UPSTASH_REDIS_REST_TOKEN
    if (!url || !token) throw new Error('KV non configuré')

    const ctrl = new AbortController()
    const timer = setTimeout(() => ctrl.abort(), KV_TIMEOUT_MS)
    try {
        const res = await fetch(`${url}/smembers/${encodeURIComponent(key)}`, {
            headers: { Authorization: `Bearer ${token}` },
            signal: ctrl.signal,
        })
        const body = await res.json()
        return body.result ?? []
    } finally {
        clearTimeout(timer)
    }
}

const toInt = (v) => (v == null ? 0 : parseInt(v, 10) || 0)

// Tri sémantique des versions (0.9.0 < 0.10.0), récent d'abord.
const cmpVerDesc = (a, b) => {
    const pa = a.split('.').map(Number), pb = b.split('.').map(Number)
    for (let i = 0; i < 3; i++) {
        const d = (pb[i] || 0) - (pa[i] || 0)
        if (d) return d
    }
    return 0
}

export default async function handler(request) {
    const { searchParams } = new URL(request.url)
    const day = searchParams.get('day')

    // Validation stricte du paramètre jour (évite d'injecter des clés arbitraires).
    const dayValid = day && /^\d{4}-\d{2}-\d{2}$/.test(day)
    const wantVersions = searchParams.get('versions') === '1'

    const keys = ['dl:total', 'dl:site', 'dl:sparkle']
    if (dayValid) keys.push(`dl:${day}:total`, `dl:${day}:site`, `dl:${day}:sparkle`)

    try {
        const vals = await mget(keys)
        const payload = {
            total: toInt(vals[0]),
            site: toInt(vals[1]),
            sparkle: toInt(vals[2]),
        }
        if (dayValid) {
            payload.day = {
                date: day,
                total: toInt(vals[3]),
                site: toInt(vals[4]),
                sparkle: toInt(vals[5]),
            }
        }
        if (wantVersions) {
            // Liste des releases vues, puis leurs compteurs (total/site/sparkle).
            const versions = (await smembers('dl:versions')).filter((v) => /^\d+\.\d+(?:\.\d+)?$/.test(v))
            if (versions.length) {
                const vkeys = versions.flatMap((v) => [`dl:ver:${v}`, `dl:ver:${v}:site`, `dl:ver:${v}:sparkle`])
                const vvals = await mget(vkeys)
                payload.versions = versions
                    .map((v, i) => ({
                        version: v,
                        total: toInt(vvals[i * 3]),
                        site: toInt(vvals[i * 3 + 1]),
                        sparkle: toInt(vvals[i * 3 + 2]),
                    }))
                    .sort((a, b) => cmpVerDesc(a.version, b.version))
            } else {
                payload.versions = []
            }
        }
        return Response.json(payload, {
            headers: { 'Cache-Control': 'no-store' },
        })
    } catch {
        // KV non activé ou injoignable : on le dit clairement plutôt que de
        // renvoyer des zéros trompeurs.
        return Response.json(
            { error: 'kv_unavailable', hint: 'Activer Vercel KV sur le projet et lier KV_REST_API_URL / KV_REST_API_TOKEN.' },
            { status: 503, headers: { 'Cache-Control': 'no-store' } },
        )
    }
}
