// swift-tools-version: 6.3
import PackageDescription

let package = Package(
    name: "Souffleuse",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "Souffleuse", targets: ["Souffleuse"]),
        .executable(name: "SouffleuseBench", targets: ["SouffleuseBench"]),
        .executable(name: "SouffleuseCoherence", targets: ["SouffleuseCoherence"]),
        .executable(name: "SouffleuseEnrichmentBench", targets: ["SouffleuseEnrichmentBench"]),
        .executable(name: "SouffleuseOCRAblation", targets: ["SouffleuseOCRAblation"]),
        .executable(name: "SouffleuseMidwordEval", targets: ["SouffleuseMidwordEval"]),
        .executable(name: "SouffleuseRecallEval", targets: ["SouffleuseRecallEval"]),
        .executable(name: "SouffleuseInjectionEval", targets: ["SouffleuseInjectionEval"]),
        .executable(name: "SouffleuseAXProbe", targets: ["SouffleuseAXProbe"]),
        .executable(name: "SouffleuseContextProbe", targets: ["SouffleuseContextProbe"]),
        .executable(name: "SouffleuseReplay", targets: ["SouffleuseReplay"]),
        .executable(name: "SouffleuseBoundaryAblation", targets: ["SouffleuseBoundaryAblation"]),
        .executable(name: "SouffleuseCorpusSeed", targets: ["SouffleuseCorpusSeed"]),
        .executable(name: "SouffleuseTranslateBench", targets: ["SouffleuseTranslateBench"]),
        .library(name: "SouffleuseAX", targets: ["SouffleuseAX"]),
        .library(name: "SouffleuseCore", targets: ["SouffleuseCore"]),
        .library(name: "SouffleuseOverlay", targets: ["SouffleuseOverlay"]),
        .library(name: "SouffleuseInput", targets: ["SouffleuseInput"]),
        .library(name: "SouffleuseContext", targets: ["SouffleuseContext"]),
        .library(name: "SouffleuseLog", targets: ["SouffleuseLog"]),
        .library(name: "SouffleuseTyping", targets: ["SouffleuseTyping"]),
        .library(name: "SouffleuseCorpus", targets: ["SouffleuseCorpus"]),
        .library(name: "SouffleusePersonalization", targets: ["SouffleusePersonalization"]),
        .library(name: "SouffleusePrompt", targets: ["SouffleusePrompt"]),
        .library(name: "SouffleuseLlama", targets: ["SouffleuseLlama"]),
    ],
    dependencies: [
        .package(url: "https://github.com/ml-explore/mlx-swift-examples", from: "2.0.0"),
    ],
    targets: [
        .target(
            name: "SouffleuseLog"
        ),
        .target(
            name: "CSQLCipher",
            cSettings: [
                // SQLCipher encryption-at-rest, backed by Apple CommonCrypto
                // (no OpenSSL dependency → self-contained, distributable).
                .define("SQLITE_HAS_CODEC"),
                .define("SQLCIPHER_CRYPTO_CC"),
                .define("SQLITE_TEMP_STORE", to: "2"),
                .define("SQLITE_THREADSAFE", to: "1"),
                .define("NDEBUG"),
                .unsafeFlags(["-Wno-ambiguous-macro", "-Wno-unused-function", "-Wno-unused-but-set-variable"]),
            ],
            linkerSettings: [
                .linkedFramework("Security"),
                .linkedFramework("Foundation"),
            ]
        ),
        .systemLibrary(
            name: "CLlama",
            path: "vendor/llama/include"
        ),
        .target(
            name: "SouffleuseLlama",
            dependencies: ["CLlama", "SouffleuseLog"],
            linkerSettings: [
                .unsafeFlags([
                    "-L", "vendor/llama/lib",
                    "-lllama", "-lggml", "-lggml-base",
                    "-lggml-cpu", "-lggml-metal", "-lggml-blas",
                    "-Xlinker", "-rpath", "-Xlinker", "@loader_path/../Frameworks",
                    "-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks",
                    // Absolute rpath to the vendored dylibs so `swift build`
                    // outputs (CLI probes + the xctest bundle) resolve
                    // @rpath/libllama.0.dylib without env vars (SIP strips
                    // DYLD_* from the spawned test helper). The make-app.sh
                    // bundle uses the @loader_path/@executable_path rpaths
                    // above to find the copies in Contents/Frameworks.
                    "-Xlinker", "-rpath", "-Xlinker",
                    "/Users/gabrielwaltio/cocotypist-llama/Souffleuse/vendor/llama/lib",
                ]),
            ]
        ),
        .target(
            name: "SouffleuseTyping"
        ),
        // Feuille PURE (Foundation only) : la *forme* des données du corpus
        // (TypingHistoryEntry, EntrySource, SecretHeuristic, LearnedLexicon),
        // séparée de la *persistance* (SouffleusePersonalization : SQLCipher,
        // Keychain). Permet à SouffleuseCore de dépendre des types du corpus sans
        // lier SQLCipher/Keychain — débloque l'InferenceAgent du split 3-process.
        .target(
            name: "SouffleuseCorpus"
        ),
        .target(
            name: "SouffleuseCore",
            dependencies: [
                "SouffleuseLog",
                "SouffleuseTyping",
                "SouffleuseCorpus",
            ]
        ),
        .target(
            name: "SouffleuseAX"
        ),
        .target(
            name: "SouffleuseOverlay",
            resources: [.process("Resources")]
        ),
        .target(
            name: "SouffleuseInput"
        ),
        .target(
            name: "SouffleuseContext",
            dependencies: ["SouffleuseAX", "SouffleuseLog", "SouffleuseOverlay"]
        ),
        .target(
            name: "SouffleusePersonalization",
            dependencies: [
                "SouffleuseLog",
                "CSQLCipher",
                "SouffleuseTyping",
                "SouffleuseCorpus",
                // MLXLMCommon retiré : dépendance MORTE depuis la suppression du
                // chemin n-gram MLX (aucun `import MLX*` dans ce module).
            ]
        ),
        .target(
            name: "SouffleusePrompt",
            dependencies: [
                "SouffleuseLog",
                .product(name: "MLXLMCommon", package: "mlx-swift-examples"),
            ]
        ),
        .executableTarget(
            name: "SouffleuseLlamaProbe",
            dependencies: ["SouffleuseLlama", "SouffleuseTyping"]
        ),
        .executableTarget(
            name: "SouffleuseTypoQualityProbe",
            dependencies: ["SouffleuseLlama"]
        ),
        .executableTarget(
            name: "SouffleuseTTFTBench",
            dependencies: ["SouffleuseLlama"]
        ),
        .executableTarget(
            name: "SouffleuseBoundaryAblation",
            dependencies: [
                "SouffleuseLlama",
                "SouffleuseCore",
                "SouffleusePersonalization",
                "SouffleuseCorpus",
                "SouffleuseTyping",
            ]
        ),
        .executableTarget(
            name: "SouffleuseAXProbe",
            dependencies: ["SouffleuseAX", "SouffleuseOverlay", "SouffleuseInput"]
        ),
        .executableTarget(
            name: "SouffleuseContextProbe",
            dependencies: ["SouffleuseAX", "SouffleuseContext"]
        ),
        .executableTarget(
            name: "SouffleuseReplay",
            dependencies: [
                "SouffleuseCore",
                "SouffleuseLlama",
                "SouffleusePersonalization",
                "SouffleuseCorpus",
                "SouffleuseTyping",
                "SouffleuseLog",
            ]
        ),
        .executableTarget(
            name: "Souffleuse",
            dependencies: [
                "SouffleuseAX",
                "SouffleuseContext",
                "SouffleuseCore",
                "SouffleuseInput",
                "SouffleuseLog",
                "SouffleuseOverlay",
                "SouffleuseTyping",
                "SouffleusePersonalization",
                "SouffleuseCorpus",
                "SouffleusePrompt",
                "SouffleuseLlama",
                .product(name: "MLXLLM", package: "mlx-swift-examples"),
                .product(name: "MLXLMCommon", package: "mlx-swift-examples"),
            ]
        ),
        .executableTarget(
            name: "SouffleuseBench",
            dependencies: [
                .product(name: "MLXLLM", package: "mlx-swift-examples"),
                .product(name: "MLXLMCommon", package: "mlx-swift-examples"),
            ]
        ),
        .executableTarget(
            name: "SouffleuseCoherence",
            dependencies: [
                "SouffleusePrompt",
                .product(name: "MLXLLM", package: "mlx-swift-examples"),
                .product(name: "MLXLMCommon", package: "mlx-swift-examples"),
            ]
        ),
        .executableTarget(
            name: "SouffleuseEnrichmentBench",
            dependencies: [
                .product(name: "MLXLLM", package: "mlx-swift-examples"),
                .product(name: "MLXLMCommon", package: "mlx-swift-examples"),
            ]
        ),
        .executableTarget(
            name: "SouffleuseOCRAblation",
            dependencies: [
                "SouffleuseCore",
                "SouffleuseContext",
                "SouffleuseLlama",
                "SouffleuseLog",
                "SouffleusePersonalization",
                "SouffleuseCorpus",
            ]
        ),
        .executableTarget(
            name: "SouffleuseMidwordEval",
            dependencies: [
                "SouffleuseCore",
                "SouffleuseLlama",
                "SouffleuseLog",
                "SouffleusePersonalization",
                "SouffleuseCorpus",
                "SouffleuseTyping",
            ]
        ),
        .executableTarget(
            name: "SouffleuseRecallEval",
            dependencies: [
                "SouffleuseCore",
                "SouffleusePersonalization",
                "SouffleuseCorpus",
                "SouffleuseTyping",
            ]
        ),
        // JETABLE (dev-only) — harnais d'eval perso consolidé, à supprimer après usage.
        .executableTarget(
            name: "SouffleuseCorpusEval",
            dependencies: [
                "SouffleuseCore",
                "SouffleusePersonalization",
                "SouffleuseCorpus",
                "SouffleuseTyping",
            ]
        ),
        .executableTarget(
            name: "SouffleusePersonalizationEval",
            dependencies: [
                "SouffleuseCore",
                "SouffleuseLlama",
                "SouffleuseLog",
                "SouffleusePersonalization",
                "SouffleuseCorpus",
                "SouffleuseTyping",
            ]
        ),
        .executableTarget(
            name: "SouffleuseRealPersoEval",
            dependencies: [
                "SouffleuseCore",
                "SouffleuseLlama",
                "SouffleuseLog",
                "SouffleusePersonalization",
                "SouffleuseCorpus",
                "SouffleuseTyping",
            ]
        ),
        .executableTarget(
            name: "SouffleuseFewShotAB",
            dependencies: [
                "SouffleuseCore",
                "SouffleuseLlama",
                "SouffleuseLog",
                "SouffleusePersonalization",
                "SouffleuseCorpus",
                "SouffleuseTyping",
            ]
        ),
        .executableTarget(
            name: "SouffleuseVocabCompleteEval",
            dependencies: [
                "SouffleusePersonalization",
                "SouffleuseCorpus",
            ]
        ),
        .executableTarget(
            name: "SouffleuseContextCopyEval",
            dependencies: [
                "SouffleuseCore",
                "SouffleuseLlama",
                "SouffleuseLog",
            ]
        ),
        .executableTarget(
            name: "SouffleuseLexiconRouteEval",
            dependencies: [
                "SouffleuseCore",
                "SouffleusePersonalization",
                "SouffleuseCorpus",
                "SouffleuseTyping",
            ]
        ),
        .executableTarget(
            name: "SouffleuseInjectionEval",
            dependencies: [
                "SouffleuseCore",
                "SouffleuseLlama",
                "SouffleuseLog",
                "SouffleusePersonalization",
                "SouffleuseCorpus",
            ]
        ),
        .executableTarget(
            name: "SouffleuseCorpusSeed",
            dependencies: [
                "SouffleusePersonalization",
                "SouffleuseCorpus",
                "SouffleuseLog",
            ]
        ),
        // Phase-0 gate bench for the translation HUD feature. Dev-only,
        // print()-heavy, NOT in audit.sh SHIPPING_DIRS. Measures gemma-3-1b-it
        // translation quality + the memory cost of running base + instruct
        // engines side by side on this 8 GB machine.
        .executableTarget(
            name: "SouffleuseTranslateBench",
            dependencies: ["SouffleuseLlama", "SouffleuseCore"]
        ),
        .testTarget(
            name: "SouffleuseTests",
            dependencies: [
                "Souffleuse",
                "SouffleuseAX",
                "SouffleuseContext",
                "SouffleuseCore",
                "SouffleuseInput",
                "SouffleuseLog",
                "SouffleuseOverlay",
                "SouffleuseTyping",
                "SouffleusePersonalization",
                "SouffleuseCorpus",
                "SouffleusePrompt",
                "SouffleuseLlama",
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
