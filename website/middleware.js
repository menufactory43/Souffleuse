// Langue servie sur `/`.
//
// Règle : le français est servi à ceux qui le demandent, l'anglais à tous les autres.
// Les annuaires (Uneed, TinyLaunch…) refusent un produit qui « ne charge pas en anglais » :
// leurs relecteurs sont des humains avec un navigateur, pas des robots.
//
// - Navigateur qui annonce `fr` dans Accept-Language  -> page FR (rien à faire)
// - Tout autre navigateur                             -> 307 vers /en/
// - Robots aspirateurs d'annuaires (node-fetch…)      -> 307 vers /en/
// - Moteurs de recherche (Googlebot, Bingbot…)        -> page FR, ils suivent les hreflang
export const config = { matcher: ['/'] };

const SCRAPERS = /(node-fetch|axios|python-requests|httpx|aiohttp|go-http-client|curl|wget|scrapy|okhttp|java\/|apache-httpclient|headlesschrome|puppeteer|playwright|phantomjs|jsdom|undici|libwww|guzzle)/i;
const SEARCH_ENGINES = /(googlebot|bingbot|google-inspectiontool|duckduckbot|applebot|yandexbot|baiduspider|slurp|petalbot|ahrefsbot|semrushbot)/i;

export default function middleware(request) {
  const ua = request.headers.get('user-agent') || '';
  if (SEARCH_ENGINES.test(ua)) return;

  const url = new URL(request.url);

  // Choix explicite depuis le sélecteur FR/EN : il prime, et il colle.
  if (url.searchParams.get('lang') === 'fr') {
    return new Response(null, {
      status: 307,
      headers: {
        location: '/',
        'set-cookie': 'lang=fr; Path=/; Max-Age=31536000; SameSite=Lax',
      },
    });
  }
  if (/(^|;\s*)lang=fr(;|$)/.test(request.headers.get('cookie') || '')) return;

  const accept = request.headers.get('accept-language') || '';
  const wantsFrench = /(^|[,\s])fr\b/i.test(accept);
  if (wantsFrench && !SCRAPERS.test(ua)) return;

  url.pathname = '/en/';
  url.search = '';
  return Response.redirect(url, 307);
}
