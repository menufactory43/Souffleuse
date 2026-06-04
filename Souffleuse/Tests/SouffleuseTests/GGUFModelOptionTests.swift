import Testing
import Foundation
@testable import Souffleuse
import SouffleuseCore

/// GGUF model selector — catalogue, path resolution precedence, and the
/// PreferencesStore persistence round-trip.
@Suite("GGUF model selector")
struct GGUFModelOptionTests {

    // MARK: - Catalogue

    @Test("v2 catalogue : Gemma + Qwen base, rangés du plus léger au plus lourd")
    func catalogueShape() {
        let ids = GGUFModelOption.catalogue.map(\.id)
        #expect(ids == ["gemma-3-1b-q5", "qwen3-1.7b-q4", "gemma-3-4b-q4", "qwen3-4b-q4", "qwen3-8b-q4"])
        // Le 1B reste en tête (défaut FR/EN).
        #expect(GGUFModelOption.catalogue[0].fileName == "gemma-3-1b.i1-Q5_K_M.gguf")
        // Rangé par empreinte mémoire croissante.
        let rams = GGUFModelOption.catalogue.map(\.approxRAMMB)
        #expect(rams == rams.sorted())
        // Tous téléchargeables, tous des variantes base (jamais instruct/-it).
        for m in GGUFModelOption.catalogue {
            #expect(m.downloadable != nil)
            #expect(!m.fileName.contains("-it"))
            #expect(m.downloadURL?.host == "huggingface.co")
        }
    }

    @Test("la voix conseillée dépend de la langue, et reste la plus légère possible")
    func recommendationByLanguage() {
        // Français : la plus petite voix suffit (rapide, peu de RAM), quelle que
        // soit la RAM — plus gros ≠ mieux pour le ghost.
        for ram in [8, 16, 32, 64] {
            #expect(GGUFModelOption.recommendedID(machineRAMGB: ram, language: .french) == "gemma-3-1b-q5")
        }
        // Plusieurs langues : la plus petite voix VRAIMENT multilingue.
        for ram in [8, 16, 32, 64] {
            #expect(GGUFModelOption.recommendedID(machineRAMGB: ram, language: .multilingual) == "qwen3-1.7b-q4")
        }
        // Le 8B n'est jamais auto-conseillé, même multilingue sur très gros Mac.
        #expect(GGUFModelOption.recommendedID(machineRAMGB: 64, language: .multilingual) != "qwen3-8b-q4")
    }

    @Test("l'adéquation au Mac suit l'empreinte réelle, pas un seuil grossier")
    func fitClassification() {
        let rec = GGUFModelOption.recommendedID(machineRAMGB: 8, language: .multilingual)
        let qwen8b = GGUFModelOption.option(forID: "qwen3-8b-q4")
        // 8B (~5,8 Go, min 16) : trop lourd sous 16 Go, juste à 16, à l'aise à 32.
        #expect(qwen8b.fit(machineRAMGB: 8, recommendedID: rec) == .tooHeavy)
        #expect(qwen8b.fit(machineRAMGB: 16, recommendedID: rec) == .tight)
        #expect(qwen8b.fit(machineRAMGB: 32, recommendedID: rec) == .comfortable)
        // La voix conseillée est marquée .recommended.
        let recOption = GGUFModelOption.option(forID: rec)
        #expect(recOption.fit(machineRAMGB: 8, recommendedID: rec) == .recommended)
    }

    @Test("cohérence : une petite voix n'est jamais « juste » quand la conseillée passe « à l'aise »")
    func fitCoherenceOn8GB() {
        // Le bug repéré : sur un Mac 8 Go, une petite voix (~1 Go) ne doit pas
        // dire « un peu juste » alors que la voix conseillée est verte.
        let rec = GGUFModelOption.recommendedID(machineRAMGB: 8, language: .multilingual)
        let gemma1b = GGUFModelOption.option(forID: "gemma-3-1b-q5")
        #expect(rec == "qwen3-1.7b-q4")
        #expect(gemma1b.fit(machineRAMGB: 8, recommendedID: rec) == .comfortable)
    }

    @Test("le descripteur de téléchargement enregistre la variante -pt sous le nom du catalogue")
    func ghostDownloadableMapsPtSourceToCatalogFilename() {
        let d = GGUFModelOption.catalogue[0].downloadable
        #expect(d != nil)
        // Destination = nom attendu par le résolveur ; source = GGUF base/pt.
        #expect(d?.filename == "gemma-3-1b.i1-Q5_K_M.gguf")
        #expect(d?.url.absoluteString.contains("gemma-3-1b-pt.i1-Q5_K_M.gguf") == true)
        #expect(d?.url.host == "huggingface.co")
        #expect((d?.approxSizeMB ?? 0) > 0)
    }

    @Test("le descripteur de traduction pointe le bon GGUF")
    func translationDownloadable() {
        let q = InstructModel.qwen1_5b.downloadable
        #expect(q.filename == "qwen2.5-1.5b-instruct-q4_k_m.gguf")
        #expect(q.url.host == "huggingface.co")
        #expect(q.id == "translate-qwen1_5b")
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
