import Foundation
import Testing
@testable import Souffleuse

// MARK: - CrashReportDetectorTests

/// Verrouille la logique pure de détection d'un plantage récent : reconnaissance
/// du nom de rapport (notre process, pas un autre) et choix du plus récent non
/// encore proposé. Aucun accès disque — tout est dérivé d'entrées explicites.
@Suite("Crash report detector")
struct CrashReportDetectorTests {

    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)
    private func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }
    private func u(_ name: String) -> URL { URL(fileURLWithPath: "/tmp/\(name)") }

    // MARK: isOurReport

    @Test("reconnaît nos rapports .ips / .crash, rejette le reste")
    func recognizesOurReports() {
        #expect(CrashReportDetector.isOurReport(filename: "Souffleuse-2026-06-18-114523.ips"))
        #expect(CrashReportDetector.isOurReport(filename: "Souffleuse_2026-06-18-114523.crash"))
        // Pas notre process / pas un crash
        #expect(!CrashReportDetector.isOurReport(filename: "Safari-2026-06-18.ips"))
        #expect(!CrashReportDetector.isOurReport(filename: "Souffleuse-2026-06-18.diag"))
        #expect(!CrashReportDetector.isOurReport(filename: "Souffleuse.log"))
        // Un helper hypothétique ne doit PAS matcher (tiret juste après le nom)
        #expect(!CrashReportDetector.isOurReport(filename: "SouffleuseHelper-2026-06-18.ips"))
    }

    // MARK: newestUnseen

    @Test("aucun rapport → nil")
    func noReports() {
        #expect(CrashReportDetector.newestUnseen(reports: [], since: at(0), now: at(100)) == nil)
    }

    @Test("renvoie le plus récent strictement postérieur au repère")
    func newestAfterSince() {
        let reports = [
            (url: u("a.ips"), date: at(10)),
            (url: u("b.ips"), date: at(50)),
            (url: u("c.ips"), date: at(30)),
        ]
        let found = CrashReportDetector.newestUnseen(reports: reports, since: at(20), now: at(100))
        #expect(found?.url == u("b.ips"))
        #expect(found?.date == at(50))
    }

    @Test("tout antérieur ou égal au repère → nil (déjà proposé)")
    func nothingNewerThanSince() {
        let reports = [(url: u("a.ips"), date: at(10)), (url: u("b.ips"), date: at(20))]
        #expect(CrashReportDetector.newestUnseen(reports: reports, since: at(20), now: at(100)) == nil)
    }

    @Test("premier lancement (since nil) : fenêtre récente, ignore les anciens")
    func firstRunWindow() {
        let now = at(100_000)
        let reports = [
            (url: u("vieux.ips"), date: now.addingTimeInterval(-48 * 3600)),  // hors fenêtre 24 h
            (url: u("recent.ips"), date: now.addingTimeInterval(-3600)),       // dans la fenêtre
        ]
        let found = CrashReportDetector.newestUnseen(reports: reports, since: nil, now: now)
        #expect(found?.url == u("recent.ips"))
    }

    @Test("premier lancement, aucun crash récent → nil")
    func firstRunNoRecent() {
        let now = at(100_000)
        let reports = [(url: u("vieux.ips"), date: now.addingTimeInterval(-48 * 3600))]
        #expect(CrashReportDetector.newestUnseen(reports: reports, since: nil, now: now) == nil)
    }
}
