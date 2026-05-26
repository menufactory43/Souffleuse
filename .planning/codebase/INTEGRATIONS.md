# External Integrations

**Analysis Date:** 2026-05-24

## APIs & External Services

**Model registry / weights download:**
- HuggingFace Hub (`huggingface.co`) — only outbound network call in the app; used implicitly by `LLMModelFactory.shared.loadContainer(configuration:)` in `Souffleuse/Sources/Souffleuse/PredictorViewModel.swift:158` to fetch `mlx-community/*` repos
  - SDK/Client: `swift-transformers` 1.0.0 (transitive via `mlx-swift-examples`)
  - Auth: none — public models only, no API key required
  - Trigger: first time a given model ID is loaded; cached locally afterwards
  - Catalog of model IDs in `Souffleuse/Sources/Souffleuse/PreferencesStore.swift:51-94` (Gemma 3 1B base/Instruct/QAT in 4-bit and 8-bit; Qwen 2.5 0.5B and 1.5B in 4-bit)

**Everything else:** zero external services. No telemetry, no analytics, no crash reporting, no remote config, no auth server, no third-party APIs. The app is offline-first by design (privacy is a hard architectural invariant — see `Souffleuse/audit.sh`).

## Data Storage

**Databases:**
- None. All persistence is flat-file in `~/Library/Application Support/Souffleuse/`.

**File Storage (local only):**
- `~/Library/Application Support/Souffleuse/history.aes` — AES-GCM sealed ring buffer of accepted suggestions (200 entries cap, hard size cap 1 MB). Managed by `TypingHistoryStore` (`Souffleuse/Sources/SouffleusePersonalization/TypingHistoryStore.swift`).
- `~/Library/Application Support/Souffleuse/allowlist.json` — per-app behaviour rules. Managed by `AllowlistStore` (`Souffleuse/Sources/Souffleuse/AllowlistConfig.swift`).
- `~/Library/Application Support/Souffleuse/clipboard-blocklist.txt` — optional user extensions to clipboard blocklist (`Souffleuse/Sources/SouffleuseContext/ClipboardReader.swift:43`).
- `~/Library/Logs/Souffleuse.log[.1|.2|.3]` — JSONL structured logs, rotated at 1 MB with 3 backups (`Souffleuse/Sources/SouffleuseLog/Log.swift`). Privacy invariant: only 5 whitelisted fields (`ts`, `level`, `module`, `event`, `count`) — enforced at compile time by `StaticString` typing.
- HuggingFace model cache — under the default `swift-transformers` Hub directory (managed by the transitive dep).

**Caching:**
- In-memory only: `predictCache` (32-entry FIFO of prefix → suggestion) in `Souffleuse/Sources/Souffleuse/PredictorViewModel.swift:74`. Never persisted.

## Authentication & Identity

**Auth Provider:**
- None — single-user desktop app, no accounts, no login flow.

**Secret management:**
- macOS Keychain (`kSecClassGenericPassword`, `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`) holds the 256-bit AES-GCM key that seals `history.aes`. Service `dev.cocotypist.Souffleuse.history`, account `TypingHistoryStore.aesgcm`. Generated on first run; deleted by user via the "Clear history" action. See `Souffleuse/Sources/SouffleusePersonalization/KeychainKey.swift`.

## Monitoring & Observability

**Error Tracking:**
- None. No Sentry, Crashlytics, Bugsnag, etc.

**Logs:**
- Local JSONL only: `~/Library/Logs/Souffleuse.log` via `Log.info / Log.warn / Log.error` (`Souffleuse/Sources/SouffleuseLog/Log.swift`). Hard-coded event whitelist; no user-text interpolation possible (StaticString call site).
- `audit.sh` enforces six privacy rules at CI/dev time:
  1. No `print(` in shipping targets
  2. No `NSLog(` in shipping targets
  3. No `os_log` with user-text fields
  4. Log file fields restricted to the whitelist
  5. `history.aes` only read from `TypingHistoryStore.swift` / `HistoryViewerWindow.swift`
  6. No interpolation of user-supplied fields in `Log.*` calls
- Dev-only escape hatches gated on env var `SOUFFLEUSE_PREDICT_LOG` write to `/tmp/souffleuse-predict.log` — never enabled in shipping builds, explicitly called out as audit-excluded.

## CI/CD & Deployment

**Hosting:**
- Self-distributed `.app` bundle. No App Store, no auto-update. `make-app.sh` produces a signed bundle locally; `dist/` is gitignored and presumably holds DMG/notarisation artifacts (`Souffleuse/.gitignore` line 17: "J3.D — DMG / notarisation artifacts").

**CI Pipeline:**
- No CI config detected in the repo (no `.github/workflows/`, no `.gitlab-ci.yml`, no `fastlane/`).
- `Souffleuse/audit.sh` is the manual gate before shipping a build.

## Environment Configuration

**Required env vars (production):**
- None. The shipped binary needs no environment configuration.

**Optional env vars (development/benches):**
- `SOUFFLEUSE_PREDICT_LOG` — enable raw-prefix debug trace to `/tmp/souffleuse-predict.log`
- `SOUFFLEUSE_MODEL` — model ID override in `SouffleuseCoherence`
- `SOUFFLEUSE_PENALTY` — repetition-penalty override in `SouffleuseCoherence`
- `SOUFFLEUSE_CONTEXT` — enable upstream context prefix in `SouffleuseCoherence`
- `SIGN_IDENTITY` — code-sign identity for `make-app.sh`

**Secrets location:**
- Keychain only (AES key). No `.env` file in the repo; `.netrc` is gitignored.

## macOS System Integrations (TCC-gated)

These are local-system integrations (not "external" in the network sense) but they require user consent and are the app's critical surface:

**Accessibility (`NSAccessibilityUsageDescription`):**
- Used by `Souffleuse/Sources/SouffleuseAX/AXClient.swift` (`AXUIElement*` calls on the system-wide element) to read the focused text field, caret position, font, and bounds, and to inject the accepted suggestion back via `kAXSelectedTextAttribute`.
- Activation hints set on the focused app: `AXEnhancedUserInterface`, `AXManualAccessibility` (forces Electron / web apps to expose their AX tree).

**Apple Events (`NSAppleEventsUsageDescription`):**
- Declared in `Info.plist` to allow injecting text into the active app. No `osascript` / `NSAppleScript` code path detected in shipping sources.

**Screen Recording (`NSScreenCaptureUsageDescription`):**
- Used by `Souffleuse/Sources/SouffleuseContext/ScreenCapturer.swift` (ScreenCaptureKit `SCShareableContent` + `SCScreenshotManager.captureImage`) to snapshot the frontmost window when OCR enrichment is enabled. **Off by default** (`captureEnabled = false` in `PreferencesStore`). `forcePermissionPrompt()` deliberately triggers the TCC prompt by hitting `SCShareableContent` (CGRequest alone is unreliable on first-launch bundles).
- Captured image is fed to Vision (`VNRecognizeTextRequest`) in `Souffleuse/Sources/SouffleuseContext/VisionOCR.swift` and `OCRCaretLocator.swift` — entirely on-device.

**Input Monitoring (implicit, via CGEventTap):**
- `Souffleuse/Sources/SouffleuseInput/KeyInterceptor.swift` installs a session-level `CGEventTap` (`.cgSessionEventTap`, head-insert, `.defaultTap`) listening only for `keyDown` Tab (keycode 48) and Esc (keycode 53). Tap is created disabled and only enabled while a ghost suggestion is showing.
- macOS auto-disables the tap on timeout / user input → handler re-enables it.

**Pasteboard:**
- `NSPasteboard.general` read by `Souffleuse/Sources/SouffleuseContext/ClipboardReader.swift` when the global Enrichment toggle is on. Hard-coded baseline blocklist of password-manager and banking bundle IDs (1Password, LastPass, Dashlane, Bitwarden, Boursorama, BNP, LCL, SG, Crédit Mutuel, Revolut, Keychain Access). User-extendable via `clipboard-blocklist.txt`. Clipboard text sanitised (whitespace collapsed) and capped at 500 chars before use.

## Webhooks & Callbacks

**Incoming:** None. The app has no HTTP server.
**Outgoing:** None at runtime. The only outbound network call is the one-shot HuggingFace Hub model download on first use of a given model ID.

---

*Integration audit: 2026-05-24*
