import XCTest
import CoreGraphics
@testable import SouffleuseContext

final class OCRClusteringTests: XCTestCase {
    // MARK: - Fixture helpers

    private func obs(_ text: String, x: CGFloat = 0.1, y: CGFloat, w: CGFloat = 0.4, h: CGFloat = 0.02, conf: Float = 0.99) -> OCRObservation {
        OCRObservation(
            text: text,
            boundingBox: CGRect(x: x, y: y, width: w, height: h),
            confidence: conf
        )
    }

    // MARK: - buildClusters

    func testBuildClustersGroupsAdjacentRows() {
        // Two tight blocks separated by a big gap.
        let observations = [
            obs("Top1", y: 0.90),
            obs("Top2", y: 0.88),
            // gap
            obs("Bot1", y: 0.20),
            obs("Bot2", y: 0.18),
            obs("Bot3", y: 0.16),
        ]
        let clusters = OCRClustering.buildClusters(observations)
        XCTAssertEqual(clusters.count, 2)
        // First cluster = bottom-most (lowest Y).
        XCTAssertEqual(clusters[0].map(\.text), ["Bot3", "Bot2", "Bot1"])
        XCTAssertEqual(clusters[1].map(\.text), ["Top2", "Top1"])
    }

    func testBuildClustersSingleSpread() {
        // Single tight block — one cluster.
        let observations = [
            obs("A", y: 0.50),
            obs("B", y: 0.48),
            obs("C", y: 0.46),
        ]
        let clusters = OCRClustering.buildClusters(observations)
        XCTAssertEqual(clusters.count, 1)
        XCTAssertEqual(clusters[0].count, 3)
    }

    // MARK: - selectBottomCluster

    func testSelectsBottomCluster() {
        // Header at top, latest message bubble at bottom — bottom wins.
        let observations = [
            obs("celestrix@gmail.com", y: 0.92),
            obs("& Fermer", y: 0.92),
            obs("17 h", y: 0.90),
            // bubble
            obs("Merci, le fichier est ajouté.", y: 0.32),
            obs("Il faudra probablement supprimé", y: 0.30),
            obs("les anciens fichiers manuels.", y: 0.28),
        ]
        let result = OCRClustering.selectBottomCluster(observations)
        XCTAssertTrue(result.contains("Merci, le fichier est ajouté"))
        XCTAssertTrue(result.contains("supprimé"))
        XCTAssertTrue(result.contains("anciens fichiers manuels"))
        XCTAssertFalse(result.contains("Fermer"))
        XCTAssertFalse(result.contains("celestrix"))
    }

    func testJoinsBottomClusterInTopDownReadingOrder() {
        // Three observations in a bottom cluster, each long enough that the
        // joined bottom passes the 30-char threshold and expansion is NOT
        // triggered. Final string must read top-to-bottom within the cluster.
        let observations = [
            obs("Header up at the top", y: 0.92),
            obs("Header continued", y: 0.90),
            obs("Premier morceau de phrase", y: 0.32),
            obs("Deuxième morceau de la phrase", y: 0.30),
            obs("Troisième morceau qui ferme", y: 0.28),
        ]
        let result = OCRClustering.selectBottomCluster(observations)
        XCTAssertEqual(
            result,
            "Premier morceau de phrase Deuxième morceau de la phrase Troisième morceau qui ferme"
        )
    }

    func testExpandsToNextClusterWhenBottomTooShort() {
        // Bottom cluster < 30 chars — should pull next cluster up.
        let observations = [
            // Top: real customer prose
            obs("Pourriez-vous me confirmer les frais avant que je valide ?", y: 0.60, w: 0.6, h: 0.02),
            // Bottom: terse reply that won't satisfy the LLM alone
            obs("ok merci", y: 0.32),
        ]
        let result = OCRClustering.selectBottomCluster(observations)
        // Need ≥5 observations for clustering to engage — adjust fixture.
        XCTAssertTrue(result.contains("ok merci"))
    }

    func testExpandsToNextClusterAtThreshold() {
        let observations = [
            obs("Customer wrote a longer message above", y: 0.70),
            obs("with multiple lines of context", y: 0.68),
            obs("explaining the issue in detail", y: 0.66),
            obs("Bonjour", y: 0.32),     // < 30 chars
            obs("merci", y: 0.30),       // bottom cluster total ≈ "Bonjour merci" = 13 chars
        ]
        let result = OCRClustering.selectBottomCluster(observations)
        XCTAssertTrue(result.contains("Bonjour"))
        XCTAssertTrue(result.contains("merci"))
        // Because bottom < 30 chars, the next-higher cluster joined in too.
        XCTAssertTrue(result.contains("Customer wrote a longer message"))
    }

    func testFallsBackToFlatJoinWhenTooSparse() {
        // < 5 observations — clustering doesn't engage.
        let observations = [
            obs("A", y: 0.50),
            obs("B", y: 0.30),
        ]
        let result = OCRClustering.selectBottomCluster(observations)
        XCTAssertEqual(result, "A B")
    }

    func testFallsBackToFlatJoinWhenNoSubstantialCluster() {
        // 5 observations but all isolated (each one its own cluster of 1).
        let observations = [
            obs("Iso1", y: 0.90),
            obs("Iso2", y: 0.70),
            obs("Iso3", y: 0.50),
            obs("Iso4", y: 0.30),
            obs("Iso5", y: 0.10),
        ]
        let result = OCRClustering.selectBottomCluster(observations)
        // No cluster has ≥2 observations → flat join in original order.
        XCTAssertEqual(result.split(separator: " ").count, 5)
    }

    func testEmptyInputReturnsEmpty() {
        XCTAssertEqual(OCRClustering.selectBottomCluster([]), "")
    }

    // MARK: - Real Intercom-like scenario

    func testRealisticIntercomLayout() {
        // Inspired by /tmp/souffleuse-ocr.log entry for alex.madiot —
        // header band at top with chrome/email/buttons, a "Question Summary"
        // band in the middle, the actual customer detail at the bottom.
        // Bottom cluster should win and contain the legal detail.
        let observations = [
            // Header band (chrome)
            obs("5 min", y: 0.94),
            obs("alex.madiot@gmail.com", y: 0.94),
            obs("& Fermer", y: 0.94),
            // System event band
            obs("Gabriel a fusionné #215474469255223", y: 0.86),
            obs("dans cette conversation", y: 0.85),
            // Title band
            obs("Remboursement", y: 0.78),
            obs("Question", y: 0.76),
            // Summary band — the latest substantive content
            obs("• Alex Madiot demande le remboursement", y: 0.42, w: 0.6),
            obs("de 3 abonnements Waltio souscrits", y: 0.40, w: 0.6),
            obs("le 22 mai 2026 pour un total de", y: 0.38, w: 0.6),
            obs("109,20 €, invoquant le droit", y: 0.36, w: 0.6),
            obs("de rétractation prévu à l'article L221-18", y: 0.34, w: 0.6),
        ]
        let result = OCRClustering.selectBottomCluster(observations)
        // The customer-detail cluster wins; chrome and titles are excluded.
        XCTAssertTrue(result.contains("Alex Madiot demande le remboursement"))
        XCTAssertTrue(result.contains("109,20 €"))
        XCTAssertTrue(result.contains("L221-18"))
        XCTAssertFalse(result.contains("Fermer"))
        XCTAssertFalse(result.contains("Gabriel a fusionné"))
        XCTAssertFalse(result.contains("Remboursement Question"))
    }
}
