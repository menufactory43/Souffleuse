import Testing
import Foundation
import SouffleuseCorpus
import SouffleusePersonalization

/// Phase 3 (KeyType perso mix) — `rankBlended`. La promotion n-gram exige
/// `count ≥ 3` ; la retrieval marche dès count=1. On vérifie que le blend
/// (a) GARDE le filtre de pertinence (pas de bruit), et (b) départage les
/// pertinents par récence × longueur façon KeyType, sans jamais faire remonter
/// un exemple beaucoup moins pertinent.
@Suite("Phase 3 — Blended retrieval (KeyType perso mix)")
struct BlendedRetrievalTests {

    static func entry(_ context: String, _ accepted: String, daysAgo: Double) -> TypingHistoryEntry {
        TypingHistoryEntry(
            timestamp: Date(timeIntervalSinceReferenceDate: 1_000_000 - daysAgo * 86_400),
            contextBefore: context, accepted: accepted, bundleID: nil, source: .prose)
    }
    static let now = Date(timeIntervalSinceReferenceDate: 1_000_000)

    @Test("Filtre de pertinence préservé : aucun exemple non-corrélé injecté")
    func relevanceGateHolds() {
        let entries = [
            Self.entry("", "le chat dort sur le canapé", daysAgo: 0),   // 0 overlap avec la fiscalité
            Self.entry("", "la recette de gâteau au chocolat", daysAgo: 0),
        ]
        let out = SimilarHistoryRetrieval.rankBlended(
            entries: entries, userTail: "le calcul de la plus-value fiscale",
            limit: 3, recencyWeight: 0.3, lengthWeight: 0.2, now: Self.now)
        #expect(out.isEmpty)   // rien de pertinent → rien (comme `rank`)
    }

    @Test("À pertinence ~égale, le plus RÉCENT gagne")
    func recencyBreaksTies() {
        let old = Self.entry("", "votre rapport fiscal annuel", daysAgo: 100)
        let recent = Self.entry("", "votre rapport fiscal annuel", daysAgo: 0)
        let out = SimilarHistoryRetrieval.rankBlended(
            entries: [old, recent], userTail: "je consulte mon rapport fiscal",
            limit: 1, recencyWeight: 0.3, lengthWeight: 0.2, now: Self.now)
        #expect(out.count == 1)
        #expect(out.first?.timestamp == recent.timestamp)
    }

    @Test("La pertinence reste DOMINANTE : un nudge ne renverse pas un gros écart")
    func relevanceStaysDominant() {
        // Très pertinent mais vieux+court vs faiblement pertinent mais récent+long.
        let veryRelevant = Self.entry("", "plus-value imposable cession portefeuille", daysAgo: 200)
        let weaklyRelevant = Self.entry(
            "", "portefeuille " + String(repeating: "mot ", count: 40), daysAgo: 0)
        let out = SimilarHistoryRetrieval.rankBlended(
            entries: [veryRelevant, weaklyRelevant],
            userTail: "calcul de la plus-value imposable sur la cession du portefeuille",
            limit: 1, recencyWeight: 0.3, lengthWeight: 0.2, now: Self.now)
        #expect(out.first?.timestamp == veryRelevant.timestamp)
    }

    @Test("Tail vide / limit 0 → vide")
    func degenerate() {
        let e = [Self.entry("", "rapport fiscal", daysAgo: 0)]
        #expect(SimilarHistoryRetrieval.rankBlended(
            entries: e, userTail: "", limit: 3, recencyWeight: 0.3, lengthWeight: 0.2, now: Self.now).isEmpty)
        #expect(SimilarHistoryRetrieval.rankBlended(
            entries: e, userTail: "rapport fiscal", limit: 0, recencyWeight: 0.3, lengthWeight: 0.2, now: Self.now).isEmpty)
    }
}
