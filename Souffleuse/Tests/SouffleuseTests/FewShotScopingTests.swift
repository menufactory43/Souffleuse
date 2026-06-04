import Testing
import Foundation
import SouffleuseCore
import SouffleusePersonalization

/// Couvre le scoping few-shot par registre (P1.2 / P1.3) : la prose injectée
/// comme exemples de style ne vient QUE du même cluster que l'app focus ; les
/// fragments `.accept` et les salutations sont écartés ; `.other` ⇒ pas de scope.
/// C'est le point partagé par `predict()` (long-ghost) et `extendGhost` (refill).
@Suite("FewShotScoping — sélection few-shot scopée par registre")
struct FewShotScopingTests {

    private func prose(_ text: String, _ bundle: String?) -> TypingHistoryEntry {
        TypingHistoryEntry(timestamp: Date(), contextBefore: "", accepted: text,
                           bundleID: bundle, source: .prose)
    }
    private func accept(_ text: String, _ bundle: String?) -> TypingHistoryEntry {
        TypingHistoryEntry(timestamp: Date(), contextBefore: "", accepted: text,
                           bundleID: bundle, source: .accept)
    }

    @Test("même cluster inclus : prose .web éligible en contexte .web")
    func sameClusterIncluded() {
        let pool = [prose("Puis-je avoir votre fichier des dernières années ?", "com.brave.Browser")]
        let out = FewShotScoping.scopedExamplesPool(pool, activeDomain: .web)
        #expect(out.count == 1)
    }

    @Test("autre cluster exclu : la prose privée .chat ne fuit pas en .web")
    func otherClusterExcluded() {
        let pool = [prose("on se voit demain soir au resto", "org.whispersystems.signal-desktop")]
        let out = FewShotScoping.scopedExamplesPool(pool, activeDomain: .web)
        #expect(out.isEmpty)   // .chat (Signal) jamais injecté comme style en .web
    }

    @Test("activeDomain .other ⇒ aucun scope : toute la prose reste éligible")
    func otherDomainNoScope() {
        let pool = [prose("votre solde s'affiche dans le dashboard", "com.brave.Browser"),
                    prose("on se voit demain soir", "org.whispersystems.signal-desktop")]
        let out = FewShotScoping.scopedExamplesPool(pool, activeDomain: .other)
        #expect(out.count == 2)   // pas de scope quand l'app focus est inconnue
    }

    @Test("salutations et fragments .accept écartés")
    func greetingsAndAcceptsExcluded() {
        let pool = [prose("Bonjour", "com.brave.Browser"),     // salutation nue
                    accept("ation", "com.brave.Browser")]      // fragment .accept (jamais démo de style)
        let out = FewShotScoping.scopedExamplesPool(pool, activeDomain: .web)
        #expect(out.isEmpty)
    }

    @Test("URLs / chemins / hashes exclus du pool de style (bruit navigateur)")
    func urlsAndPathsExcluded() {
        let pool = [
            prose("Puis-je avoir votre relevé Binance ?", "com.brave.Browser"),                 // prose ✓
            prose("https://intel.arkm.com/explorer/address/bc1qxuyrnxjw", "com.brave.Browser"), // URL ✗
            prose("/Users/gabriel/cocotypist/website/index.html", "com.brave.Browser"),         // chemin ✗
            prose("app.zerion.io/0xbcf763f3f85f5f57202f13d1866b6e32fc7d2704", "com.brave.Browser"), // token long ✗
        ]
        let out = FewShotScoping.scopedExamplesPool(pool, activeDomain: .web)
        #expect(out.count == 1)
        #expect(out.first?.accepted == "Puis-je avoir votre relevé Binance ?")
    }

    @Test("mix réaliste : seule la prose .web non-salutation passe en .web")
    func mixedPoolScopedCorrectly() {
        let pool = [
            prose("Puis-je avoir votre relevé Binance ?", "com.brave.Browser"),   // .web ✓
            prose("Bonjour", "com.brave.Browser"),                                 // greeting ✗
            prose("let x = compute()", "com.openai.codex"),                        // .code ✗
            prose("à ce soir", "org.whispersystems.signal-desktop"),               // .chat ✗
            accept("nance", "com.brave.Browser"),                                  // .accept ✗
        ]
        let out = FewShotScoping.scopedExamplesPool(pool, activeDomain: .web)
        #expect(out.count == 1)
        #expect(out.first?.accepted == "Puis-je avoir votre relevé Binance ?")
    }
}
