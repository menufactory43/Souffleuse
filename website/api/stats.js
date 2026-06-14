// Edge Function — lecture seule des compteurs de téléchargement.
//
//   GET /api/stats            → totaux cumulés (total / site / sparkle)
//   GET /api/stats?day=YYYY-MM-DD → ajoute les compteurs du jour demandé
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

const toInt = (v) => (v == null ? 0 : parseInt(v, 10) || 0)

export default async function handler(request) {
    const { searchParams } = new URL(request.url)
    const day = searchParams.get('day')

    // Validation stricte du paramètre jour (évite d'injecter des clés arbitraires).
    const dayValid = day && /^\d{4}-\d{2}-\d{2}$/.test(day)

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
