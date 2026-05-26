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
        .executable(name: "SouffleuseAXProbe", targets: ["SouffleuseAXProbe"]),
        .executable(name: "SouffleuseContextProbe", targets: ["SouffleuseContextProbe"]),
        .library(name: "SouffleuseAX", targets: ["SouffleuseAX"]),
        .library(name: "SouffleuseOverlay", targets: ["SouffleuseOverlay"]),
        .library(name: "SouffleuseInput", targets: ["SouffleuseInput"]),
        .library(name: "SouffleuseContext", targets: ["SouffleuseContext"]),
        .library(name: "SouffleuseLog", targets: ["SouffleuseLog"]),
        .library(name: "SouffleuseTyping", targets: ["SouffleuseTyping"]),
        .library(name: "SouffleusePersonalization", targets: ["SouffleusePersonalization"]),
        .library(name: "SouffleusePrompt", targets: ["SouffleusePrompt"]),
    ],
    dependencies: [
        .package(url: "https://github.com/ml-explore/mlx-swift-examples", from: "2.0.0"),
    ],
    targets: [
        .target(
            name: "SouffleuseLog"
        ),
        .target(
            name: "SouffleuseTyping"
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
                .product(name: "MLXLMCommon", package: "mlx-swift-examples"),
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
            name: "SouffleuseAXProbe",
            dependencies: ["SouffleuseAX", "SouffleuseOverlay", "SouffleuseInput"]
        ),
        .executableTarget(
            name: "SouffleuseContextProbe",
            dependencies: ["SouffleuseAX", "SouffleuseContext"]
        ),
        .executableTarget(
            name: "Souffleuse",
            dependencies: [
                "SouffleuseAX",
                "SouffleuseContext",
                "SouffleuseInput",
                "SouffleuseLog",
                "SouffleuseOverlay",
                "SouffleuseTyping",
                "SouffleusePersonalization",
                "SouffleusePrompt",
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
                "SouffleusePersonalization",
                .product(name: "MLXLLM", package: "mlx-swift-examples"),
                .product(name: "MLXLMCommon", package: "mlx-swift-examples"),
            ]
        ),
        .testTarget(
            name: "SouffleuseTests",
            dependencies: [
                "Souffleuse",
                "SouffleuseAX",
                "SouffleuseContext",
                "SouffleuseLog",
                "SouffleuseOverlay",
                "SouffleuseTyping",
                "SouffleusePersonalization",
                "SouffleusePrompt",
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
