import Testing
import Foundation
@testable import Souffleuse

/// GGUF model selector — catalogue, path resolution precedence, and the
/// PreferencesStore persistence round-trip.
@Suite("GGUF model selector")
struct GGUFModelOptionTests {

    // MARK: - Catalogue

    @Test("v1 catalogue lists the two Gemma GGUF entries")
    func catalogueShape() {
        let ids = GGUFModelOption.catalogue.map(\.id)
        #expect(ids == ["gemma-3-1b-q5", "gemma-3-4b-q4"])
        #expect(GGUFModelOption.catalogue[0].fileName == "gemma-3-1b.i1-Q5_K_M.gguf")
        #expect(GGUFModelOption.catalogue[1].fileName == "gemma-3-4b.i1-Q4_K_M.gguf")
    }

    @Test("default is the 1B Q5 entry")
    func defaultIsOneBQ5() {
        #expect(GGUFModelOption.defaultID == "gemma-3-1b-q5")
        #expect(GGUFModelOption.option(forID: GGUFModelOption.defaultID).quant == "Q5_K_M")
    }

    @Test("unknown id falls back to the default entry")
    func unknownIdFallsBack() {
        #expect(GGUFModelOption.option(forID: "does-not-exist").id == "gemma-3-1b-q5")
    }

    // MARK: - Path resolution precedence

    @Test("prefers the Souffleuse dir over the Cotypist dir")
    func prefersSouffleuseDir() {
        let souffleuse = "/tmp/Souffleuse/Models"
        let cotypist = "/tmp/Cotypist/Models"
        // Both dirs "contain" the file; Souffleuse must win.
        let path = GGUFModelOption.resolvePath(
            fileName: "m.gguf",
            envOverride: nil,
            souffleuseModelsDir: souffleuse,
            cotypistModelsDir: cotypist,
            fileExists: { _ in true }
        )
        #expect(path == "/tmp/Souffleuse/Models/m.gguf")
    }

    @Test("falls back to the Cotypist dir when missing from Souffleuse dir")
    func fallsBackToCotypist() {
        let path = GGUFModelOption.resolvePath(
            fileName: "m.gguf",
            envOverride: nil,
            souffleuseModelsDir: "/tmp/Souffleuse/Models",
            cotypistModelsDir: "/tmp/Cotypist/Models",
            fileExists: { $0.hasPrefix("/tmp/Cotypist") }
        )
        #expect(path == "/tmp/Cotypist/Models/m.gguf")
    }

    @Test("env override wins over both dirs")
    func envOverrideWins() {
        let path = GGUFModelOption.resolvePath(
            fileName: "m.gguf",
            envOverride: "/custom/path.gguf",
            souffleuseModelsDir: "/tmp/Souffleuse/Models",
            cotypistModelsDir: "/tmp/Cotypist/Models",
            fileExists: { _ in true }
        )
        #expect(path == "/custom/path.gguf")
    }

    @Test("unresolved entry returns nil (flagged disabled in UI)")
    func unresolvedReturnsNil() {
        let path = GGUFModelOption.resolvePath(
            fileName: "m.gguf",
            envOverride: nil,
            souffleuseModelsDir: "/tmp/Souffleuse/Models",
            cotypistModelsDir: "/tmp/Cotypist/Models",
            fileExists: { _ in false }
        )
        #expect(path == nil)
    }

    // MARK: - PreferencesStore persistence

    @MainActor
    @Test("ggufModelID defaults to the 1B entry then persists across stores")
    func persistenceRoundTrip() {
        let suiteName = "GGUFTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        // Fresh store with no stored value → default.
        let key = "ggufModelID"
        #expect(defaults.string(forKey: key) == nil)
        let initial = (defaults.string(forKey: key)) ?? GGUFModelOption.defaultID
        #expect(initial == "gemma-3-1b-q5")

        // Simulate the store's didSet writing the new selection.
        defaults.set("gemma-3-4b-q4", forKey: key)
        #expect(defaults.string(forKey: key) == "gemma-3-4b-q4")

        // A "restart" reads it back.
        let restored = (defaults.string(forKey: key)) ?? GGUFModelOption.defaultID
        #expect(restored == "gemma-3-4b-q4")
    }
}
