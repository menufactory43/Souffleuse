// Sert la page anglaise aux robots aspirateurs d'annuaires (node-fetch, python-requests…)
// qui viennent lire souffleuse.app pour pré-remplir une fiche.
// Les humains et les moteurs de recherche (Googlebot, Bingbot…) gardent la page FR.
export const config = { matcher: ['/'] };

const SCRAPERS = /(node-fetch|axios|python-requests|httpx|aiohttp|go-http-client|curl|wget|scrapy|okhttp|java\/|apache-httpclient|headlesschrome|puppeteer|playwright|phantomjs|jsdom|undici|libwww|guzzle)/i;

export default function middleware(request) {
  const ua = request.headers.get('user-agent') || '';
  if (SCRAPERS.test(ua)) {
    const url = new URL(request.url);
    url.pathname = '/en/index.html';
    return Response.redirect(url, 307);
  }
}
