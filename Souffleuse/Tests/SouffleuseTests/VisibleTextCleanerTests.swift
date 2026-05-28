import XCTest
@testable import SouffleuseContext

final class VisibleTextCleanerTests: XCTestCase {
    // MARK: - Intercom workflow attribution

    func testStripsWorkflowAttributionFullForm() {
        let input = "nogueira.hugo@gmail.com merci • 17 h Attribution : Workflow : « Assignment Rules (New Conversation Started) > a attribué à Gabriel et 1-France Tu m'as mis en relation avec un humain ?"
        let result = VisibleTextCleaner.clean(input)
        // The Attribution+Workflow chunk vanishes; surrounding customer text
        // remains intact (modulo whitespace collapsing).
        XCTAssertFalse(result.contains("Workflow"))
        XCTAssertFalse(result.contains("Assignment Rules"))
        XCTAssertFalse(result.contains("attribué"))
        XCTAssertTrue(result.contains("nogueira.hugo@gmail.com"))
        XCTAssertTrue(result.contains("merci"))
        XCTAssertTrue(result.contains("Tu m'as mis en relation"))
    }

    func testStripsStandaloneAttribution() {
        let input = "Avant • Attribution : Gabriel et 1-France (par défaut) Après"
        let result = VisibleTextCleaner.clean(input)
        XCTAssertFalse(result.contains("Attribution"))
        XCTAssertTrue(result.contains("Avant"))
        XCTAssertTrue(result.contains("Après"))
    }

    // MARK: - Pause / resume events

    func testStripsPauseEvent() {
        let input = "Bonjour & Vous avez mis la conversation en pause jusqu'à 30 mai, 10:04 Merci pour l'astuce"
        let result = VisibleTextCleaner.clean(input)
        XCTAssertFalse(result.contains("Vous avez mis la conversation en pause"))
        XCTAssertTrue(result.contains("Bonjour"))
        XCTAssertTrue(result.contains("Merci pour l'astuce"))
    }

    func testStripsResumeEvent() {
        let input = "X & Vous avez repris la conversation Y"
        let result = VisibleTextCleaner.clean(input)
        XCTAssertFalse(result.contains("repris la conversation"))
        XCTAssertEqual(result, "X Y")
    }

    func testStripsTicketPauseEvent() {
        let input = "Avant ( Vous avez mis le ticket en pause jusqu'à 27 mai, 15:05) Après"
        let result = VisibleTextCleaner.clean(input)
        XCTAssertFalse(result.contains("mis le ticket en pause"))
        XCTAssertTrue(result.contains("Avant"))
        XCTAssertTrue(result.contains("Après"))
    }

    // MARK: - Fin AI agent automated events

    func testStripsFinResumedConversation() {
        let input = "Avant Fin a automatiquement repris la conversation Bonjour, Oui, mais nous répondons aux horaires d'ouverture."
        let result = VisibleTextCleaner.clean(input)
        XCTAssertFalse(result.contains("Fin a automatiquement repris"))
        XCTAssertTrue(result.contains("Bonjour"))
        XCTAssertTrue(result.contains("Oui, mais nous répondons"))
    }

    func testStripsFinFollowedAdvice() {
        let input = "Q Fin a suivi les conseils ci-dessous Warnings Utilisez un langage simple Oui Je te transfère à quelqu'un"
        let result = VisibleTextCleaner.clean(input)
        XCTAssertFalse(result.contains("Fin a suivi"))
        XCTAssertFalse(result.contains("Warnings Utilisez"))
        XCTAssertTrue(result.contains("Je te transfère à quelqu'un"))
    }

    func testStripsFinReactivatedTicket() {
        let input = "Bonjour Fin a réactivé automatiquement le ticket Avez-vous regardé"
        let result = VisibleTextCleaner.clean(input)
        XCTAssertFalse(result.contains("réactivé automatiquement"))
        XCTAssertTrue(result.contains("Avez-vous regardé"))
    }

    // MARK: - UI buttons / labels

    func testStripsFermerButtonLabel() {
        let input = "nogueira.hugo@gmail.com & Fermer 17 h merci"
        let result = VisibleTextCleaner.clean(input)
        XCTAssertFalse(result.contains("& Fermer"))
        XCTAssertTrue(result.contains("nogueira.hugo@gmail.com"))
        XCTAssertTrue(result.contains("merci"))
    }

    func testStripsConsultationTimer() {
        let input = "X Consultation • 12 min Y"
        let result = VisibleTextCleaner.clean(input)
        XCTAssertFalse(result.contains("Consultation"))
        XCTAssertTrue(result.contains("X"))
        XCTAssertTrue(result.contains("Y"))
    }

    // MARK: - Safety: preserves customer content

    func testPreservesCustomerEmailAndMessage() {
        let input = "celestrix55.lk@gmail.com Merci, le fichier est ajouté. Il faudra probablement supprimé les anciens fichiers manuels."
        let result = VisibleTextCleaner.clean(input)
        XCTAssertEqual(result, input)
    }

    func testPreservesLongCustomerNarrative() {
        let input = "cin32ls@proton.me aussi une explication peut-être la suivante. j'ai reçu un montant et aussitôt je l'ai retiré. le retrait est à 18:36, l'arrivé des fonds en USDC est à 15:09."
        let result = VisibleTextCleaner.clean(input)
        XCTAssertEqual(result, input)
    }

    // MARK: - Whitespace cleanup

    func testCollapsesWhitespaceRunsAfterStripping() {
        let input = "X  & Vous avez mis la conversation en pause  jusqu'à demain  Y"
        let result = VisibleTextCleaner.clean(input)
        // No double spaces, no leading/trailing whitespace.
        XCTAssertFalse(result.contains("  "))
        XCTAssertFalse(result.hasPrefix(" "))
        XCTAssertFalse(result.hasSuffix(" "))
    }

    func testTrimsLeadingSymbolNoise() {
        let input = "• * - X Y"
        let result = VisibleTextCleaner.clean(input)
        XCTAssertEqual(result, "X Y")
    }

    func testEmptyInputReturnsEmpty() {
        XCTAssertEqual(VisibleTextCleaner.clean(""), "")
        XCTAssertEqual(VisibleTextCleaner.clean("   "), "")
    }

    // MARK: - Real-session sample

    func testRealCaptureSample() {
        // From /tmp/souffleuse-ocr.log 2026-05-28 08:46:32 — kevin.benhamou conv.
        // Cleanup should produce text that's predominantly the human message
        // ("Je te transfère à quelqu'un de notre équipe...") rather than
        // workflow metadata.
        let input = "kevin.benhamou@gmail.com * & Fermer 5 min 5 min = Fin a suivi les conseils ci-dessous Warnings Utilisez un langage simple Oui Je te transfère à quelqu'un de notre équipe. Pour que la personne puisse t'aider au mieux, peux-tu lui décrire précisément le problème avec ton fichier et les étapes déjà faites ?"
        let result = VisibleTextCleaner.clean(input)
        XCTAssertFalse(result.contains("& Fermer"))
        XCTAssertFalse(result.contains("Fin a suivi"))
        XCTAssertFalse(result.contains("Warnings Utilisez"))
        XCTAssertTrue(result.contains("Je te transfère à quelqu'un"))
        XCTAssertTrue(result.contains("ton fichier"))
        // The cleaned form should be materially shorter than the noisy input.
        XCTAssertLessThan(result.count, input.count - 60)
    }
}
