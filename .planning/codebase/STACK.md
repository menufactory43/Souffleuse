# Technology Stack

**Analysis Date:** 2026-05-24

## Languages

**Primary:**
- Swift 6 (tools-version `6.3`, `swiftLanguageModes: [.v6]`) — entire application, libraries, and benches

**Secondary:**
- Bash — build/audit scripts (`Souffleuse/make-app.sh`, `Souffleuse/audit.sh`)

## Runtime

**Environment:**
- macOS 14+ (`platforms: [.macOS(.v14)]` in `Souffleuse/Package.swift`; `LSMinimumSystemVersion = 14.0` in `Souffleuse/Resources/Info.plist`)
- Apple Silicon required (MLX uses Metal kernels; `mlx-swift_Cmlx.bundle` shipped as metallib in `make-app.sh`)

**Package Manager:**
- Swift Package Manager (SPM) — `Souffleuse/Package.swift`
- Lockfile: present (`Souffleuse/Package.resolved`)

## Frameworks

**Core (Apple SDKs in use):**
- AppKit — app lifecycle, windows, pasteboard
- SwiftUI — preferences and onboarding windows
- Observation (`@Observable`) — view-model reactivity (e.g. `Souffleuse/Sources/Souffleuse/PredictorViewModel.swift`)
- CoreGraphics — `CGEventTap` for Tab/Esc interception (`Souffleuse/Sources/SouffleuseInput/KeyInterceptor.swift`)
- ApplicationServices — Accessibility API (`AXUIElement*`) in `Souffleuse/Sources/SouffleuseAX/AXClient.swift`
- ScreenCaptureKit — frontmost window capture in `Souffleuse/Sources/SouffleuseContext/ScreenCapturer.swift`
- Vision — OCR (`VNRecognizeTextRequest`) in `Souffleuse/Sources/SouffleuseContext/VisionOCR.swift` and `OCRCaretLocator.swift`
- NaturalLanguage — language detection (`NLLanguageRecognizer`) in `Souffleuse/Sources/Souffleuse/PredictorViewModel.swift`
- CryptoKit — AES-GCM sealing of typing history (`Souffleuse/Sources/SouffleusePersonalization/TypingHistoryStore.swift`)
- Security — Keychain Services for AES key storage (`Souffleuse/Sources/SouffleusePersonalization/KeychainKey.swift`)
- IOKit.hid — used in `Souffleuse/Sources/Souffleuse/OnboardingWindow.swift`
- Foundation — pervasive

**Local LLM Inference:**
- MLX (`MLX`, `MLXLLM`, `MLXLMCommon`) — Apple-silicon-native LLM runtime; loaded via `LLMModelFactory.shared.loadContainer` in `Souffleuse/Sources/Souffleuse/PredictorViewModel.swift:158`

**Testing:**
- Swift Testing / XCTest target `SouffleuseTests` (`Souffleuse/Tests/SouffleuseTests/`)

**Build/Dev:**
- `xcodebuild` (invoked by `Souffleuse/make-app.sh`) — produces `.app` bundle for code-signing
- `codesign` with Apple Developer cert (overridable via `SIGN_IDENTITY` env var) — required for stable TCC entries across rebuilds

## Key Dependencies

**Critical (from `Souffleuse/Package.resolved`):**
- `mlx-swift-examples` 2.29.1 (`https://github.com/ml-explore/mlx-swift-examples`) — provides `MLXLLM`, `MLXLMCommon` (the library Souffleuse links). Only direct package dependency.
- `mlx-swift` 0.29.1 (transitive) — provides `MLX` array/runtime primitives
- `swift-transformers` 1.0.0 (HuggingFace, transitive) — tokenizers + Hub model download
- `swift-jinja` 2.3.6 (HuggingFace, transitive) — chat-template rendering
- `swift-collections` 1.5.1 (Apple, transitive)
- `swift-numerics` 1.1.1 (Apple, transitive)
- `GzipSwift` 6.0.1 (transitive)

**Infrastructure:**
- None beyond the above — no networking SDKs, no analytics, no crash reporting

## Configuration

**Build/Bundle:**
- `Souffleuse/Package.swift` — SPM package manifest (8 executables, 7 libraries, 1 test target)
- `Souffleuse/Resources/Info.plist` — bundle identifier `app.cocotypist.Souffleuse`, version `0.2.0`, `LSUIElement = true` (menu-bar app, no Dock icon), TCC usage descriptions for Accessibility / AppleEvents / ScreenCapture
- `Souffleuse/Resources/AppIcon.icns` — app icon
- Code-signing identity hard-coded in `make-app.sh`: `A798891AB1B0A8C0B46AFADBD95094BABF680037` (Apple Development), overridable via `SIGN_IDENTITY` env var. Stable cert intentional so TCC permissions persist across rebuilds.

**Runtime user prefs:**
- `UserDefaults.standard` — typed keys in `Souffleuse/Sources/Souffleuse/PreferencesStore.swift` (model ID, OCR languages, completion length, personalization strength, partial-accept toggles, etc.)
- `~/Library/Application Support/Souffleuse/allowlist.json` — per-app behaviour overrides
- `~/Library/Application Support/Souffleuse/history.aes` — AES-GCM-sealed typing history (ring buffer, 200 entries, capped at 1 MB)
- `~/Library/Application Support/Souffleuse/clipboard-blocklist.txt` — user-supplied clipboard blocklist additions
- `~/Library/Logs/Souffleuse.log` — JSONL structured log, rotated at 1 MB with 3 backups (`Souffleuse/Sources/SouffleuseLog/Log.swift`)
- Keychain (`kSecClassGenericPassword`, service `dev.cocotypist.Souffleuse.history`, account `TypingHistoryStore.aesgcm`) — 256-bit AES key for history file

**Environment variables (development-only flags):**
- `SOUFFLEUSE_PREDICT_LOG` — when non-empty, writes user-text debug trace to `/tmp/souffleuse-predict.log` (dev only; explicitly excluded from production audit)
- `SOUFFLEUSE_MODEL` — overrides default model in `SouffleuseCoherence` bench
- `SOUFFLEUSE_PENALTY` — repetition penalty in coherence bench
- `SOUFFLEUSE_CONTEXT` — enables realistic upstream context in coherence bench
- `SIGN_IDENTITY` — overrides code-sign identity in `make-app.sh`

## Platform Requirements

**Development:**
- macOS 14+ with Xcode toolchain providing Swift 6.3
- Apple Development signing certificate (or override `SIGN_IDENTITY=-` for ad-hoc)
- `jq` (optional) for `audit.sh` log-field check
- Granted TCC permissions for the dev bundle: Accessibility, Apple Events, Screen Recording (Screen Recording is opt-in; OCR capture is disabled by default)

**Production:**
- macOS 14+ on Apple Silicon (MLX inference runs on the GPU/ANE via Metal kernels shipped in `mlx-swift_Cmlx.bundle`)
- ~0.4 GB to ~1.3 GB free disk per LLM (model catalog: Gemma 3 1B variants, Qwen 2.5 0.5B/1.5B; downloaded from `mlx-community/*` HF repos on first use via `LLMModelFactory`)
- Network access on first model download only; no runtime network calls

---

*Stack analysis: 2026-05-24*
