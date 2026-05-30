import Testing
import Foundation
@testable import Souffleuse
import SouffleuseCore

/// Couvre le carnet d'usage : arithmétique pure (cadence, temps gagné, fenêtres de
/// jours) et l'aller-retour de persistance. Aucun modèle, aucune UI.
@Suite("UsageLedger — frappes épargnées & temps gagné")
struct UsageLedgerTests {
    typealias T = SuggestionPolicy.Tuning

    // MARK: - Cadence

    @Test("sous le seuil d'échantillons → cadence par défaut")
    func cadenceFallsBackToDefault() {
        #expect(UsageLedger.millisPerChar(typedChars: 50, typedMillis: 9_000) == T.ledgerDefaultMillisPerChar)
        #expect(UsageLedger.millisPerChar(typedChars: 0, typedMillis: 0) == T.ledgerDefaultMillisPerChar)
    }

    @Test("au-dessus du seuil → cadence mesurée (ms/char)")
    func cadenceUsesMeasured() {
        // 400 chars en 40 000 ms = 100 ms/char.
        #expect(UsageLedger.millisPerChar(typedChars: 400, typedMillis: 40_000) == 100)
    }

    // MARK: - Temps gagné

    @Test("temps gagné = frappes × cadence − coût d'acceptation")
    func timeSavedFormula() {
        // 1000 frappes × 200 ms = 200 s ; 10 accepts × 0,4 s = 4 s ; net 196 s.
        let s = UsageLedger.estimatedSecondsSaved(keystrokesSaved: 1000, ghostsAccepted: 10, millisPerChar: 200)
        #expect(abs(s - 196) < 0.001)
    }

    @Test("le temps gagné ne descend jamais sous zéro")
    func timeSavedFlooredAtZero() {
        let s = UsageLedger.estimatedSecondsSaved(keystrokesSaved: 1, ghostsAccepted: 100, millisPerChar: 180)
        #expect(s == 0)
    }

    // MARK: - Fenêtres de jours

    @Test("capped garde les N jours les plus récents")
    func cappedKeepsRecent() {
        let days = (1...5).map { DayStat(date: "2026-05-0\($0)") }
        let kept = UsageLedger.capped(days, maxDays: 3)
        #expect(kept.map(\.date) == ["2026-05-03", "2026-05-04", "2026-05-05"])
    }

    @Test("lastDays complète les trous et finit aujourd'hui")
    func lastDaysFillsGaps() {
        let cal = Calendar(identifier: .gregorian)
        let today = cal.date(from: DateComponents(year: 2026, month: 5, day: 31))!
        // Un seul jour réel, il y a 2 jours ; le reste doit être complété à zéro.
        let real = DayStat(date: "2026-05-29", keystrokesSaved: 42)
        let window = UsageLedger.lastDays([real], count: 3, today: today)
        #expect(window.count == 3)
        #expect(window.map(\.date) == ["2026-05-29", "2026-05-30", "2026-05-31"])
        #expect(window[0].keystrokesSaved == 42)
        #expect(window[1].keystrokesSaved == 0)   // trou comblé
        #expect(window[2].date == UsageLedger.dateKey(today))
    }

    @Test("dateKey produit une clé locale yyyy-MM-dd triable")
    func dateKeyFormat() {
        let cal = Calendar(identifier: .gregorian)
        let d = cal.date(from: DateComponents(year: 2026, month: 1, day: 9))!
        #expect(UsageLedger.dateKey(d) == "2026-01-09")
    }

    // MARK: - Enregistrement & persistance

    @MainActor
    @Test("un accept incrémente frappes épargnées et répliques du jour")
    func recordAcceptedUpdatesToday() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ledger-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        let ledger = UsageLedger(fileURL: url)
        ledger.recordAccepted(charsSaved: 12)
        ledger.recordAccepted(charsSaved: 8)
        #expect(ledger.today.keystrokesSaved == 20)
        #expect(ledger.today.ghostsAccepted == 2)
        // charsSaved <= 0 est ignoré (chunk d'un seul caractère).
        ledger.recordAccepted(charsSaved: 0)
        #expect(ledger.today.ghostsAccepted == 2)
    }

    @MainActor
    @Test("frappes, cadence et actes survivent à un rechargement")
    func persistenceRoundTrip() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ledger-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        let ledger = UsageLedger(fileURL: url)
        ledger.recordTyping(chars: 300, seconds: 30)   // 1re écriture (throttle initial)
        ledger.recordTranslation()
        ledger.recordReformulation()
        ledger.recordAccepted(charsSaved: 50)           // écriture immédiate

        let reloaded = UsageLedger(fileURL: url)
        #expect(reloaded.today.keystrokesSaved == 50)
        #expect(reloaded.today.translations == 1)
        #expect(reloaded.today.reformulations == 1)
        #expect(reloaded.cadenceTypedChars == 300)
        // Calibrée ssi l'accumulateur dépasse le seuil d'échantillons.
        #expect(reloaded.cadenceCalibrated == (300 >= T.ledgerCadenceMinSampleChars))
    }
}
