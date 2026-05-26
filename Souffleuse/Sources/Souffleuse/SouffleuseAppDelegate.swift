import AppKit
import Foundation
import Observation
import SouffleuseAX
import SouffleuseContext
import SouffleuseInput
import SouffleuseLog
import SouffleuseOverlay
import SouffleusePersonalization
import SouffleuseTyping

/// Bundle IDs we never read or inject into. Terminal-class apps expose shell
/// content via AXTextArea (privacy), and password/keychain UIs must be excluded
/// regardless of subrole.
/// Bundle ID prefixes that must never be recorded into the personalization
/// history (sensitive contexts that survive the LLM blocklist too).
/// Mirrors `ClipboardReader.defaultBlocklist` minus the trailing dots so we
/// can `hasPrefix` directly. Banks + password managers go here.
private let personalizationBundleBlocklist: [String] = [
    "com.1password",
    "com.agilebits.onepassword",
    "com.apple.keychainaccess",
    "com.lastpass",
    "com.dashlane",
    "com.bitwarden",
    "com.boursorama",
    "com.bnpparibas",
    "com.lcl",
    "com.sg",
    "com.creditmutuel",
    "com.revolut",
]

private let bundleBlocklist: Set<String> = [
    "com.apple.Terminal",
    "com.googlecode.iterm2",
    "org.alacritty",
    "com.mitchellh.ghostty",
    "net.kovidgoyal.kitty",
    "dev.zed.Zed",
    "com.1password.1password",
    "com.1password.1password7",
    "com.apple.keychainaccess",
]

@MainActor
final class SouffleuseAppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let axClient = AXClient()
    private var overlay: OverlayWindow!
    private var presence: PresenceIndicatorWindow!
    private var interceptor: KeyInterceptor!
    private let predictor = PredictorViewModel()
    private var pollTimer: Timer?
    private var onboarding: OnboardingWindow?
    private var customInstructions = CustomInstructionsWindow()
    private var preferences: PreferencesWindow?
    private var historyViewer: HistoryViewerWindow?
    private var hotkeyMonitor: Any?

    private let store = PreferencesStore()
    /// Token returned by `withObservationTracking` so we can keep re-subscribing.
    private var storeObservationTask: Task<Void, Never>?

    /// Per-app cache so the ghost stays anchored across frames where AX briefly
    /// returns nil for the bounds query (Notes does this).
    private var lastCaretRectByApp: [String: CGRect] = [:]
    /// Timestamp of the last fresh AX caretRect we stored per bundle. Used to
    /// age out the cache after `caretRectTTL` — when the host stops emitting
    /// rects (zoom in Brave/Intercom, scroll, reflow) the ghost would otherwise
    /// keep painting at the stale coordinates. Cotypist disappears in that
    /// state because it'd rather show nothing than the wrong position.
    private var lastCaretRectTimestampByApp: [String: Date] = [:]
    /// How long a cached caretRect is considered usable after the last fresh
    /// AX read. Past this, we drop back to "no rect" → ghost hides until the
    /// next valid AX bounds query (typically the user typing a character
    /// re-syncs AX state).
    private static let caretRectTTL: TimeInterval = 1.2
    /// Per-bundle snapshot of the host text at the moment focus landed on it.
    /// We hold the ghost (and the badge) until the user actually types at
    /// least one character — focus alone isn't a strong enough intent signal,
    /// and re-rendering on every drive-by Cmd+Tab makes the UI feel noisy.
    /// Clears on text divergence; rewrites only on a fresh focus.
    private var textAtFocusByBundle: [String: String] = [:]
    /// Tracks which bundle the previous tick saw, so we can detect "focus
    /// landed on a new bundle" and re-snapshot `textAtFocusByBundle`. We can't
    /// use `lastEnrichedBundleID` for this because it's also gated by the
    /// enrichment toggle.
    private var lastFocusedBundleID: String? = nil
    /// Running latest text + bundle of the focused field, for the "store inputs
    /// without accepted completions" mode. Updated each tick; the previous
    /// field's final text is recorded on focus change. `lastRecordedRawInput`
    /// dedups so the same draft isn't appended twice.
    private var rawInputText: String = ""
    private var rawInputBundleID: String? = nil
    private var lastRecordedRawInput: String = ""
    /// Owns the OCR fallback + per-bundle layout calibration cache. Used when
    /// AX hides per-character bounds (Brave/Chrome/Edge web fields).
    private let caretResolver = CaretResolver()
    /// Set when an async OCR refinement has completed but the next tick has
    /// not yet run — lets us redraw immediately instead of waiting up to
    /// 200 ms for the next timer fire.
    private var caretRefinementPending: Bool = false
    /// Set by Esc; cleared the next time the host text changes. Suppresses the
    /// ghost so a single Esc dismissal isn't immediately undone by the next tick.
    private var dismissedForText: String? = nil
    /// Last prefix we asked the predictor to generate from; used to skip redundant
    /// requests while the user isn't typing.
    private var lastPredictedPrefix: String? = nil
    /// Pending debounced predict launch. Cancelled and replaced whenever the
    /// prefix mutates again before the debounce window elapses, so the LLM
    /// only fires once the user has paused ~80 ms.
    private var predictDebounceTask: Task<Void, Never>? = nil
    /// How long we wait after the last prefix mutation before firing the LLM.
    ///
    /// **Calibrated 2026-05-25**: 50 ms → 150 ms. The 50 ms value assumed
    /// model TTFT ~80 ms (so the stream could complete between keystrokes
    /// for a typist hitting ~10 kps). Measured reality on Gemma 3 1B PT 6-bit
    /// MLX: TTFT 544-1056 ms steady state. With 50 ms debounce, 94% of
    /// streams were cancelled before producing a token (5.8% completion rate
    /// observed in /tmp/souffleuse-predict.log). Bumping the debounce
    /// reduces wasted generations and gives each one a longer time-budget
    /// to fire before the next keystroke hits — net effect: more visible
    /// ghosts at the cost of a perceptual ~100 ms delay during a typing
    /// pause. Will revert to ~80 ms once KV cache lands and TTFT drops
    /// below the typing inter-keystroke interval.
    ///
    /// Cancels in flight are cheap because we abort the Task before the
    /// first token is generated.
    ///
    /// 2026-05-25: lowered from 150ms to 30ms. With the Instant Ghost Path
    /// cascade (Layer 0 WordCompleter, Layer 1 history match, both sub-ms),
    /// 150ms debounce was the dominant chunk of perceived ghost latency.
    /// 2026-05-26: 30ms → 15ms. Warm KV TTFT is ~24ms and cancellations are
    /// cheap, so a tighter debounce makes the ghost appear noticeably sooner
    /// without flooding the engine — burst keystrokes still cancel the prior
    /// in-flight Task before its first token.
    private static let predictDebounceNanos: UInt64 = 15 * 1_000_000

    private let enricher = ContextEnricher()
    private let typoDetector = TypoDetector()
    /// Set when a typo suggestion is currently shown — Tab will replace the
    /// misspelled word with `suggestion.suggestion` instead of appending an
    /// LLM continuation.
    private var currentTypo: TypoSuggestion? = nil
    /// What's left of the LLM suggestion after one or more partial (Tab-by-Tab)
    /// acceptances. Non-empty value takes precedence over `predictor.suggestion`
    /// for both the overlay and `handleKey(.tab)`. Tick() bails before
    /// `predictor.predict()` while this is non-empty so streaming MLX chunks
    /// can't race against the in-flight remainder.
    private var partialRemainder: String = ""
    /// Cumulative chunks injected since the user started accepting the current
    /// LLM suggestion partially. Used to (a) record the full accepted span in
    /// the personalization history at the end of the run, and (b) verify the
    /// AX text still matches what we injected — divergence triggers a reset.
    private var partialAcceptedSoFar: String = ""
    /// The text-before-caret captured at the FIRST partial accept. Combined
    /// with `partialAcceptedSoFar` gives the expected current prefix.
    private var partialAcceptedAtPrefix: String = ""
    /// Bundle ID at the first partial accept — gates personalization recording
    /// at end-of-run with the same blocklist as the full-accept branch.
    private var partialAcceptedAtBundleID: String? = nil
    /// Bundle ID we last kicked off enrichment for; used to detect focus changes.
    private var lastEnrichedBundleID: String?
    /// Last computed enrichment prefix, refreshed asynchronously on focus change.
    /// Read synchronously in tick() so prediction stays on the fast path.
    private var cachedEnrichmentPrefix: String = ""
    /// Snapshot of the last applied OCR language list; we reapply when the
    /// user toggles a language in Preferences.
    private var lastOCRLangsApplied: [String] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        installEditMenuShortcuts()

        // Always install the status item first so the user can see the app is
        // alive even if no permissions are granted yet.
        installStatusItem()
        overlay = OverlayWindow()
        presence = PresenceIndicatorWindow()

        // Prompt for AX once at launch (non-blocking). If denied, the user
        // can toggle the permission in Settings and the app picks it up on
        // the next tick — no relaunch needed.
        _ = AXClient.ensureTrusted(prompt: true)

        interceptor = KeyInterceptor { [weak self] key in
            self?.handleKey(key) ?? false
        }
        if !interceptor.install() {
            Log.warn(.input, "key_interceptor_install_failed")
        }

        predictor.maxTokens = store.completionLength.maxTokens
        predictor.maxWords = store.completionLength.maxWords
        predictor.personalizationStrength = store.personalizationEnabled
            ? Float(store.personalizationStrength)
            : 0
        predictor.prefixCorrectionEnabled = store.prefixCorrectionEnabled
        // Few-shot dynamique : le predictor lit ce store à chaque appel à
        // `predict()` pour retrouver des entrées similaires au userTail.
        // Gated par `personalizationStrength > 0` côté predictor.
        predictor.history = store.history
        // Load the persisted GGUF selection on launch (the real ghost engine).
        predictor.configureInitialGGUF(store.ggufModelID)
        Task { [weak self] in
            await self?.predictor.loadModel()
            // Rebuild the n-gram model from history once the tokenizer is ready.
            guard let self else { return }
            let history = await MainActor.run { self.store.history }
            await history.load()
            let entries = await history.allEntries()
            await self.predictor.rebuildPersonalization(from: entries)
        }
        Task { await enricher.setCaptureEnabled(store.captureEnabled) }
        applyOCRLangsIfNeeded()
        // Critical: if captureEnabled was persisted ON across launches but
        // macOS Screen Recording permission is missing, the OCR pipeline
        // dies silently and the LLM sees no visible context. Trigger the
        // system prompt at startup so Souffleuse appears in System Settings
        // → Privacy → Screen Recording and the user can grant access.
        // (Each rebuild's cdhash changes, so TCC may re-prompt anyway.)
        if store.captureEnabled, !ScreenCapturer.hasPermission() {
            Log.warn(.input, "screen_recording_permission_missing")
            // forcePermissionPrompt hits ScreenCaptureKit directly. This is
            // the only reliable way to make TCC register the bundle when
            // CGRequestScreenCaptureAccess no-ops silently (typical when
            // the bundle has never been TCC-registered before).
            Task { await ScreenCapturer.forcePermissionPrompt() }
        }
        observePreferences()

        // 50 ms tick → live-consume + overlay refresh feel near-instant.
        // Lowered from 80 ms (2026-05-26): at 80 ms a keystroke could wait up
        // to 80 ms before the tick even noticed the new text, the dominant
        // remaining chunk of the "slow ghost" feel. 50 ms (20 Hz) halves that
        // worst-case detection lag; the AX snapshot cost stays negligible
        // (<1 ms), so the only cost is a few more idle snapshots per second.
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }

        installGlobalHotkey()
        if shouldShowOnboarding() {
            showOnboarding()
        }
    }

    // MARK: - Onboarding

    private func shouldShowOnboarding() -> Bool {
        let onboarded = UserDefaults.standard.bool(forKey: "onboardingDone")
        if onboarded && AXClient.isTrusted { return false }
        return true
    }

    private func showOnboarding() {
        let win = OnboardingWindow()
        self.onboarding = win
        win.show()
        UserDefaults.standard.set(true, forKey: "onboardingDone")
    }

    // MARK: - Global hotkey ⌃⌥⌘S / ⌃⌥⌘E

    private func installGlobalHotkey() {
        let mask: NSEvent.ModifierFlags = [.control, .option, .command]
        hotkeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard flags == mask else { return }
            switch event.keyCode {
            case 1:  // S — master on/off
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { self?.toggleEnabled() }
                }
            case 14:  // E — enrichment kill-switch (forces off, never toggles back on)
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { self?.disableEnrichmentNow() }
                }
            default:
                break
            }
        }
    }

    private func disableEnrichmentNow() {
        guard store.enrichmentEnabled else { return }
        store.enrichmentEnabled = false
        cachedEnrichmentPrefix = ""
        lastEnrichedBundleID = nil
        Task { await enricher.invalidate() }
        refreshStatusItem()
        NSSound.beep()
    }

    // MARK: - Observation of PreferencesStore

    /// Re-subscribes to @Observable changes after each fire. AppDelegate reacts to
    /// model swap, capture toggle, OCR language changes, and menu mirror updates.
    private func observePreferences() {
        storeObservationTask?.cancel()
        let snapshot = (
            modelID: store.modelID,
            ggufModelID: store.ggufModelID,
            captureEnabled: store.captureEnabled,
            ocrLangs: store.ocrLanguages,
            enrichment: store.enrichmentEnabled,
            enabled: store.enabled,
            completionLength: store.completionLength
        )
        withObservationTracking {
            _ = store.modelID
            _ = store.ggufModelID
            _ = store.captureEnabled
            _ = store.ocrLangFR
            _ = store.ocrLangEN
            _ = store.ocrLangES
            _ = store.enrichmentEnabled
            _ = store.enabled
            _ = store.completionLength
            _ = store.personalizationEnabled
            _ = store.personalizationStrength
            _ = store.prefixCorrectionEnabled
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.handlePreferenceChange(previous: snapshot)
                    self?.observePreferences()  // resubscribe; @Observable is one-shot
                }
            }
        }
    }

    private func handlePreferenceChange(previous: (modelID: String, ggufModelID: String, captureEnabled: Bool, ocrLangs: [String], enrichment: Bool, enabled: Bool, completionLength: CompletionLength)) {
        if store.modelID != previous.modelID {
            Task { await predictor.swapModel(to: store.modelID) }
        }
        if store.ggufModelID != previous.ggufModelID {
            Task { await predictor.swapGGUF(to: store.ggufModelID) }
        }
        if store.completionLength != previous.completionLength {
            predictor.maxTokens = store.completionLength.maxTokens
        predictor.maxWords = store.completionLength.maxWords
        }
        // Propagate personalization knob. Strength = 0 when the toggle is off
        // — the predictor fast-paths and skips the n-gram bias entirely.
        let effectiveStrength: Float = store.personalizationEnabled
            ? Float(store.personalizationStrength)
            : 0
        if predictor.personalizationStrength != effectiveStrength {
            predictor.personalizationStrength = effectiveStrength
        }
        if predictor.prefixCorrectionEnabled != store.prefixCorrectionEnabled {
            predictor.prefixCorrectionEnabled = store.prefixCorrectionEnabled
        }
        if store.captureEnabled != previous.captureEnabled {
            applyCaptureToggle(store.captureEnabled, requestPermissionIfNeeded: true)
        }
        if store.ocrLanguages != previous.ocrLangs {
            applyOCRLangsIfNeeded()
        }
        if !store.enrichmentEnabled && previous.enrichment {
            cachedEnrichmentPrefix = ""
            lastEnrichedBundleID = nil
            Task { await enricher.invalidate() }
        }
        if !store.enabled && previous.enabled {
            overlay.hide()
            interceptor.setActive(false)
            predictor.cancel()
            // Master toggle off → context break. Cache wouldn't survive a
            // disable+reenable cycle anyway (user expectation: starting fresh).
            predictor.clearPredictCache()
        }
        refreshStatusItem()
    }

    private func applyOCRLangsIfNeeded() {
        let langs = store.ocrLanguages
        guard langs != lastOCRLangsApplied else { return }
        lastOCRLangsApplied = langs
        Task { await enricher.setOCRLanguages(langs) }
    }

    private func applyCaptureToggle(_ enabled: Bool, requestPermissionIfNeeded: Bool) {
        if enabled, requestPermissionIfNeeded, !ScreenCapturer.hasPermission() {
            Task { await ScreenCapturer.forcePermissionPrompt() }
        }
        Task { await enricher.setCaptureEnabled(enabled) }
    }

    // MARK: - Status item

    private func installStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        applyStatusItemIcon(capturing: false)

        let menu = NSMenu()
        let toggleItem = NSMenuItem(title: store.enabled ? "Activée ✓" : "Désactivée", action: #selector(toggleEnabled), keyEquivalent: "s")
        toggleItem.keyEquivalentModifierMask = [.control, .option, .command]
        toggleItem.target = self
        menu.addItem(toggleItem)
        menu.addItem(NSMenuItem.separator())
        let enrichItem = NSMenuItem(
            title: store.enrichmentEnabled ? "Enrichissement contextuel ✓" : "Enrichissement contextuel",
            action: #selector(toggleEnrichment),
            keyEquivalent: ""
        )
        enrichItem.target = self
        menu.addItem(enrichItem)
        let captureItem = NSMenuItem(
            title: store.captureEnabled ? "  ↳ Inclure capture d'écran ✓" : "  ↳ Inclure capture d'écran",
            action: #selector(toggleCapture),
            keyEquivalent: ""
        )
        captureItem.target = self
        menu.addItem(captureItem)
        let instructionsItem = NSMenuItem(
            title: "Instructions personnalisées…",
            action: #selector(openCustomInstructions),
            keyEquivalent: ""
        )
        instructionsItem.target = self
        menu.addItem(instructionsItem)
        menu.addItem(NSMenuItem.separator())
        let prefsItem = NSMenuItem(title: "Préférences…", action: #selector(openPreferences), keyEquivalent: ",")
        prefsItem.keyEquivalentModifierMask = [.command]
        prefsItem.target = self
        menu.addItem(prefsItem)
        let onboardingItem = NSMenuItem(title: "Permissions…", action: #selector(openOnboarding), keyEquivalent: "")
        onboardingItem.target = self
        menu.addItem(onboardingItem)
        menu.addItem(NSMenuItem.separator())
        let quitItem = NSMenuItem(title: "Quitter", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
        statusItem.menu = menu
    }

    private func applyStatusItemIcon(capturing: Bool) {
        guard let button = statusItem?.button else { return }
        let symbol = capturing ? "eye.fill" : "text.bubble"
        if let img = NSImage(systemSymbolName: symbol, accessibilityDescription: "Souffleuse") {
            img.isTemplate = !capturing  // tinted (blue) when capturing
            button.image = img
            button.contentTintColor = capturing ? NSColor.systemBlue : nil
        } else {
            button.title = capturing ? "👁" : "S"
        }
    }

    /// LSUIElement apps have no menu bar, so Cmd+C/V/X/A/Z don't reach text views
    /// by default. Installing a hidden main menu with the standard Edit items
    /// wires the shortcuts via responder chain — the menu itself never renders.
    private func installEditMenuShortcuts() {
        let mainMenu = NSMenu()

        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)
        appItem.submenu = NSMenu()  // empty; we never show it

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(NSMenuItem.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)

        NSApp.mainMenu = mainMenu
    }

    @objc private func openCustomInstructions() {
        customInstructions.show()
    }

    @objc private func openOnboarding() {
        if onboarding == nil { onboarding = OnboardingWindow() }
        onboarding?.show()
    }

    @objc private func openPreferences() {
        if preferences == nil {
            preferences = PreferencesWindow(
                store: store,
                onModelChange: { [weak self] id in
                    Task { await self?.predictor.swapModel(to: id) }
                },
                onCaptureToggle: { [weak self] on in
                    self?.store.captureEnabled = on
                    self?.applyCaptureToggle(on, requestPermissionIfNeeded: true)
                },
                onOpenOnboarding: { [weak self] in self?.openOnboarding() },
                onOpenHistoryViewer: { [weak self] in self?.openHistoryViewer() },
                onClearPersonalization: { [weak self] in self?.clearPersonalization() }
            )
        }
        preferences?.show()
    }

    private func openHistoryViewer() {
        if historyViewer == nil {
            historyViewer = HistoryViewerWindow(history: store.history)
        }
        historyViewer?.show()
    }

    private func clearPersonalization() {
        let history = store.history
        let predictor = self.predictor
        Task {
            await history.clear()
            await predictor.rebuildPersonalization(from: [])
        }
    }

    private func refreshStatusItem() {
        guard let menu = statusItem.menu else { return }
        if let toggle = menu.items.first {
            toggle.title = store.enabled ? "Activée ✓" : "Désactivée"
        }
        // Order matches installStatusItem: [toggle, sep, enrich, capture, ...]
        if menu.items.count > 2 {
            menu.items[2].title = store.enrichmentEnabled ? "Enrichissement contextuel ✓" : "Enrichissement contextuel"
        }
        if menu.items.count > 3 {
            menu.items[3].title = store.captureEnabled ? "  ↳ Inclure capture d'écran ✓" : "  ↳ Inclure capture d'écran"
        }
    }

    @objc private func toggleEnrichment() {
        store.enrichmentEnabled.toggle()
    }

    @objc private func toggleCapture() {
        store.captureEnabled.toggle()
        applyCaptureToggle(store.captureEnabled, requestPermissionIfNeeded: true)
    }

    @objc private func toggleEnabled() {
        store.enabled.toggle()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    // MARK: - Poll loop

    /// Coalesces multiple "I want to re-tick now" requests within a single
    /// runloop pass. The 200 ms poll timer already runs `tick()`, so worst
    /// case we'd repaint twice; the boolean avoids stacking N OCR-completion
    /// closures into N consecutive tick calls.
    private func tickThrottled() {
        guard !caretRefinementPending else { return }
        caretRefinementPending = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.caretRefinementPending = false
            self.tick()
        }
    }

    private func tick() {
        guard store.enabled else { return }
        // R1: pause pipeline whenever Souffleuse is the foreground app (Preferences,
        // Onboarding, or CustomInstructions key). Prevents predicting in our own UI
        // and avoids racing AX reads against our own SwiftUI text fields.
        if NSApp.isActive {
            overlay.hide()
            presence.hide()
            interceptor.setActive(false)
            return
        }
        // If AX still isn't trusted, hide the overlay and keep idling — the
        // status item stays visible so the user can see we're waiting.
        guard AXClient.isTrusted else {
            overlay.hide()
            presence.hide()
            interceptor.setActive(false)
            return
        }
        let snap = axClient.snapshot()

        // Verbose tick observability — every snapshot result, gated by env var.
        if ProcessInfo.processInfo.environment["SOUFFLEUSE_PREDICT_LOG"]?.isEmpty == false,
           let bid = snap.bundleID, !bid.contains("ghostty"), !bid.contains("Terminal") {
            let txtLen = snap.text?.count ?? -1
            let caret = snap.caretIndex.map(String.init) ?? "nil"
            let rect = snap.caretRect.map { "\($0.origin.x.rounded()),\($0.origin.y.rounded())" } ?? "nil"
            let elem = snap.elementRect.map { "\($0.size.width.rounded())x\($0.size.height.rounded())" } ?? "nil"
            let line = "[\(ISO8601DateFormatter().string(from: Date()))] tick_snap bundle=\(bid) textLen=\(txtLen) caretIdx=\(caret) isText=\(snap.isTextElement) secure=\(snap.isSecureField) caretRect=\(rect) elemRect=\(elem)\n"
            if let data = line.data(using: .utf8) {
                let path = "/tmp/souffleuse-tick.log"
                if let h = FileHandle(forWritingAtPath: path) {
                    h.seekToEndOfFile(); try? h.write(contentsOf: data); try? h.close()
                } else { FileManager.default.createFile(atPath: path, contents: data) }
            }
        }

        // Gate: must be a non-blocklisted, non-secure text element.
        guard let bundleID = snap.bundleID,
              !bundleBlocklist.contains(bundleID),
              !snap.isSecureField,
              let text = snap.text,
              let caretIndex = snap.caretIndex,
              snap.isTextElement else {
            // Temporary diagnostic for "Signal stops working" investigation.
            // Logs which AX gate fails per-bundle so we can see why we bail.
            // Same env var as the predictor debug log.
            if ProcessInfo.processInfo.environment["SOUFFLEUSE_PREDICT_LOG"]?.isEmpty == false {
                let reason: String
                if snap.bundleID == nil { reason = "no_bundleID" }
                else if let b = snap.bundleID, bundleBlocklist.contains(b) { reason = "blocklisted=\(b)" }
                else if snap.isSecureField { reason = "secure_field" }
                else if snap.text == nil { reason = "no_text" }
                else if snap.caretIndex == nil { reason = "no_caret" }
                else if !snap.isTextElement { reason = "not_text_element" }
                else { reason = "unknown" }
                let line = "[\(ISO8601DateFormatter().string(from: Date()))] tick_gate_fail bundle=\(snap.bundleID ?? "nil") reason=\(reason)\n"
                if let data = line.data(using: .utf8) {
                    let path = "/tmp/souffleuse-tick.log"
                    if let h = FileHandle(forWritingAtPath: path) {
                        h.seekToEndOfFile(); try? h.write(contentsOf: data); try? h.close()
                    } else {
                        FileManager.default.createFile(atPath: path, contents: data)
                    }
                }
            }
            overlay.hide()
            presence.hide()
            interceptor.setActive(false)
            return
        }

        // Per-app allowlist override (after blocklist, before any prediction work).
        let allowMode = store.allowlist.mode(forBundle: bundleID, windowTitle: snap.windowTitle)
        if allowMode == .disabled {
            overlay.hide()
            presence.hide()
            interceptor.setActive(false)
            return
        }

        // Fresh-focus snapshot: when the user lands on a new bundle, capture
        // the host text as our "intent baseline". The ghost stays hidden until
        // `text` diverges (= the user typed at least one character). Avoids
        // the cmd-Tab flash, gives AX time to settle on the actual focused
        // element, and ensures the FIRST ghost paints on a freshly-resolved
        // caretRect — Cotypist-style "appear discreetly on the first keystroke".
        if lastFocusedBundleID != bundleID {
            // Focus is leaving the previous field → if "store without accepted"
            // is on, record what the user wrote there (even with no acceptance).
            recordRawInputIfAllowed(text: rawInputText, bundleID: rawInputBundleID)
            textAtFocusByBundle[bundleID] = text
            lastFocusedBundleID = bundleID
            // Focus left mid-partial: record what the user did take in the
            // previous bundle (with that bundle's ID, captured at first chunk)
            // and clear so the remainder doesn't bleed into the new app.
            if !partialRemainder.isEmpty {
                recordPartialAcceptanceToHistoryIfAllowed()
                partialRemainder = ""
                partialAcceptedSoFar = ""
                partialAcceptedAtPrefix = ""
                partialAcceptedAtBundleID = nil
            }
        } else if textAtFocusByBundle[bundleID] == nil {
            // Defensive: same bundle but state missing (first run, prefs reset).
            textAtFocusByBundle[bundleID] = text
        }
        let hasTypedSinceFocus = (textAtFocusByBundle[bundleID] != text)
        // Track the focused field's running text so a focus change can record
        // it under the "store without accepted" mode.
        rawInputText = text
        rawInputBundleID = bundleID

        // Cache fresh AX caretRect WITH a timestamp so we can expire stale
        // anchors. When the host stops emitting bounds (zoom, scroll, reflow
        // in Brave/Intercom/Notion), the previous rect would otherwise survive
        // forever and our ghost would paint at the wrong screen coordinates.
        if let rect = snap.caretRect {
            lastCaretRectByApp[bundleID] = rect
            lastCaretRectTimestampByApp[bundleID] = Date()
        }
        let cachedRect: CGRect? = {
            guard let rect = lastCaretRectByApp[bundleID],
                  let ts = lastCaretRectTimestampByApp[bundleID],
                  Date().timeIntervalSince(ts) < Self.caretRectTTL
            else { return nil }
            return rect
        }()
        // Hosts that refuse `kAXBoundsForRangeParameterizedAttribute` for web
        // content (Chromium-based browsers, contenteditable, some Electron
        // apps) leave us with no real caret rect — but we still have
        // `elementRect`, `text`, and `caretIndex`. The resolver picks the
        // best available strategy (instant estimate now, OCR refinement
        // async) without blocking the tick loop.
        let resolvedRect: CGRect? = {
            guard snap.caretRect == nil, cachedRect == nil else {
                return nil
            }
            return caretResolver.resolve(snapshot: snap) { [weak self] in
                // Async OCR completed: redraw on the next runloop turn.
                self?.tickThrottled()
            }
        }()
        let rectForGhost = snap.caretRect ?? cachedRect ?? resolvedRect

        // Pick the font we'll hand to the overlay: AX's report wins (rare in
        // web hosts), else the OCR-calibrated point size from the resolver,
        // else nil — letting `OverlayWindow` fall back to its rect-height
        // heuristic. Without this hand-off the overlay derives the size from
        // the calibrated rect's height, which is line-height, not font size,
        // and produces a ghost ~1.4× too big.
        let hostFontForOverlay: NSFont? = {
            if let axFont = snap.caretFont {
                return NSFont(name: axFont.familyName, size: CGFloat(axFont.pointSize))
                    ?? .systemFont(ofSize: CGFloat(axFont.pointSize))
            }
            if let metrics = caretResolver.calibration(for: bundleID) {
                return .systemFont(ofSize: metrics.fontPointSize)
            }
            return nil
        }()

        // We've cleared every gate: focused, AX-trusted, not blocklisted, real
        // text element. Anchor the presence badge to the field's top-left so
        // it stays put as the user types (Cotypist-style), only falling back
        // to the caret rect when the field rect isn't available.
        // Held back until `hasTypedSinceFocus` — keeps the badge from flashing
        // on Cmd+Tab drive-bys.
        if hasTypedSinceFocus {
            if let fieldRect = snap.elementRect {
                presence.show(at: fieldRect)
            } else if let rect = rectForGhost {
                presence.show(at: rect)
            } else {
                presence.hide()
            }
        } else {
            presence.hide()
        }

        // Dismissed by Esc until text changes.
        if let dismissed = dismissedForText, dismissed == text {
            overlay.hide()
            presence.hide()
            interceptor.setActive(false)
            return
        }
        dismissedForText = nil

        // Reflect capture state in the menubar icon (lightweight async poll).
        Task { [weak self] in
            guard let self else { return }
            let cap = await self.enricher.isCapturing()
            await MainActor.run { self.applyStatusItemIcon(capturing: cap) }
        }

        // Per-app enrichment policy: suggestionOnly disables enrichment for this
        // bundle without disabling the global toggle.
        let enrichmentAllowed = store.enrichmentEnabled && allowMode != .suggestionOnly
        let captureAllowedHere = store.captureEnabled && allowMode != .clipboardOnly

        // On focus change, refresh enrichment asynchronously. The prediction below
        // uses whatever prefix is cached — first tick after focus change runs
        // without enrichment, subsequent ticks use it once snapshot completes.
        if enrichmentAllowed, bundleID != lastEnrichedBundleID {
            lastEnrichedBundleID = bundleID
            cachedEnrichmentPrefix = ""
            let appliedCapture = captureAllowedHere
            Task { [weak self] in
                guard let self else { return }
                // Temporarily toggle capture for this snapshot if the rule says clipboard-only.
                await self.enricher.setCaptureEnabled(appliedCapture)
                let enriched = await self.enricher.snapshot(focusedFieldRect: snap.elementRect)
                // Restore global capture preference after the snapshot.
                await self.enricher.setCaptureEnabled(self.store.captureEnabled)
                await MainActor.run {
                    self.cachedEnrichmentPrefix = enriched.prefix
                }
            }
        } else if !enrichmentAllowed {
            cachedEnrichmentPrefix = ""
            lastEnrichedBundleID = nil
        }

        // First-keystroke gate: enrichment has been kicked off (pre-warming
        // for when the user actually types) but the UI stays silent — no
        // ghost, no typo flag, no predict, no interceptor. Pre-warming the
        // predictor here would be wasted: the first typed character mutates
        // `prefix`, invalidating any in-flight stream. Only enrichment
        // benefits from the head start.
        if !hasTypedSinceFocus {
            overlay.hide()
            interceptor.setActive(false)
            predictor.cancel()
            lastPredictedPrefix = nil
            currentTypo = nil
            return
        }

        // Only predict from text up to caret; cap to 2048 chars (matches predictor).
        let prefix = String(text.prefix(caretIndex))

        // Live-consume promotion: if there's an active LLM suggestion and the
        // user just typed characters that match its beginning (INCLUDING
        // spaces and punctuation), promote it into the partial-remainder
        // state. We deliberately do NOT break on word boundaries — Cotypist's
        // observed behaviour keeps the same ghost while the user types
        // straight through "ça va ?" letter by letter, space included.
        // Regeneration happens only on divergence (typed char ≠ next ghost
        // char) or when the entire ghost has been consumed.
        if partialRemainder.isEmpty,
           !predictor.suggestion.isEmpty,
           let basePrefix = lastPredictedPrefix,
           prefix.count > basePrefix.count,
           prefix.hasPrefix(basePrefix) {
            let typedSince = String(prefix.dropFirst(basePrefix.count))
            // Case-insensitive match: typing "Bonjour" should still consume
            // a ghost starting with "bonjour" (and vice versa). The user's
            // typed casing wins in the rendered text (AX writes verbatim);
            // only the matching logic ignores case.
            if Self.isLiveConsumeMatch(ghost: predictor.suggestion, typedSince: typedSince)
                && !Self.isStaleMidWordCompletion(basePrefix: basePrefix, ghost: predictor.suggestion) {
                // User is consuming the ghost letter-by-letter — set up
                // partial state so the existing block below renders the
                // remainder and skips re-prediction.
                partialAcceptedAtPrefix = basePrefix
                partialAcceptedSoFar = typedSince
                partialAcceptedAtBundleID = bundleID
                partialRemainder = String(predictor.suggestion.dropFirst(typedSince.count))
                predictor.cancel()
            } else {
                // Either the typed char(s) do NOT match the start of the ghost
                // (true divergence — the "applielle" bug), OR the ghost was a
                // stale mid-word completion guess that the user is now typing
                // past (the "envies de" bug). Both cases: hide the stale ghost
                // NOW, then fall through. The predict gate at the bottom fires a
                // fresh prediction because `lastPredictedPrefix` is reset to nil
                // here (and was stale anyway). Without this clear, the old ghost
                // stayed rendered.
                clearStaleGhostOnDivergence()
            }
        }

        // Partial-accept guard: while we still owe the user a remainder, the
        // overlay shows that remainder verbatim. The remainder may originate
        // from a Tab partial accept OR from live typing consumption (above).
        // If the AX text still matches what we injected/consumed, do not
        // request a new prediction. If it doesn't match, we either keep
        // consuming (user typing more matching letters) or treat it as
        // divergence and re-predict.
        if !partialRemainder.isEmpty {
            let expected = partialAcceptedAtPrefix + partialAcceptedSoFar
            if prefix == expected {
                // Synced — render remainder and skip predict.
                if let rect = rectForGhost {
                    overlay.show(text: partialRemainder, at: rect, hostText: text, caretIndex: caretIndex, hostFont: hostFontForOverlay)
                    interceptor.setActive(true)
                } else {
                    overlay.hide()
                    interceptor.setActive(false)
                }
                return
            }
            if expected.hasPrefix(prefix) {
                // AX hasn't caught up to our latest inject yet. Keep showing
                // the remainder, do not re-predict, wait for the next tick.
                if let rect = rectForGhost {
                    overlay.show(text: partialRemainder, at: rect, hostText: text, caretIndex: caretIndex, hostFont: hostFontForOverlay)
                    interceptor.setActive(true)
                }
                return
            }
            // Prefix has grown past expected — the user typed more. Could be
            // (a) live consumption of the next letters of the remainder, or
            // (b) divergence / word boundary requesting a regen.
            if prefix.hasPrefix(expected), prefix.count > expected.count {
                let typedSince = String(prefix.dropFirst(expected.count))
                // Case-insensitive match: a typo correction or auto-capitalize
                // shouldn't break the consume chain mid-suggestion.
                if Self.isLiveConsumeMatch(ghost: partialRemainder, typedSince: typedSince) {
                    // Continue consuming — match keeps going regardless of
                    // whether the typed char is a space, punctuation, or
                    // letter. Only divergence breaks the consume.
                    partialAcceptedSoFar += typedSince
                    partialRemainder = String(partialRemainder.dropFirst(typedSince.count))
                    if partialRemainder.isEmpty {
                        // Whole suggestion consumed by typing — record + reset,
                        // let the next tick re-predict on the new prefix.
                        recordPartialAcceptanceToHistoryIfAllowed()
                        partialAcceptedSoFar = ""
                        partialAcceptedAtPrefix = ""
                        partialAcceptedAtBundleID = nil
                        overlay.hide()
                        interceptor.setActive(false)
                        // Don't return — fall through so predict fires.
                    } else {
                        if let rect = rectForGhost {
                            overlay.show(text: partialRemainder, at: rect, hostText: text, caretIndex: caretIndex, hostFont: hostFontForOverlay)
                            interceptor.setActive(true)
                        }
                        return
                    }
                } else {
                    // Divergence — record what was consumed, reset, fall
                    // through to the predict gate below. Hide the stale ghost
                    // (the remainder rendered last tick) so it can't linger if
                    // the re-prediction is gated/empty.
                    recordPartialAcceptanceToHistoryIfAllowed()
                    partialRemainder = ""
                    partialAcceptedSoFar = ""
                    partialAcceptedAtPrefix = ""
                    partialAcceptedAtBundleID = nil
                    clearStaleGhostOnDivergence()
                }
            } else {
                // Divergence (user deleted, moved caret, etc.) — record + reset.
                // Hide the stale remainder ghost; re-prediction repaints later.
                recordPartialAcceptanceToHistoryIfAllowed()
                partialRemainder = ""
                partialAcceptedSoFar = ""
                partialAcceptedAtPrefix = ""
                partialAcceptedAtBundleID = nil
                clearStaleGhostOnDivergence()
            }
        }

        // Emoji shortcode expansion — fires when text ends with `:code:<space>`.
        // No ghost UI: we just do the AX replace and let the user see the result.
        // Disabled in IDE/terminal bundles where `:tags:` are real syntax.
        if store.emojiEnabled,
           !EmojiExpander.disabledBundles.contains(bundleID),
           let expansion = EmojiExpander.detect(textBeforeCaret: prefix)
        {
            DispatchQueue.global(qos: .userInitiated).async { [axClient] in
                axClient.replaceTrailing(deleteChars: expansion.deleteChars, with: expansion.insert)
            }
            Log.info(.input, "emoji_expanded")
            // Clear any pending suggestion so the LLM ghost doesn't blink.
            predictor.cancel()
            lastPredictedPrefix = nil
            overlay.hide()
            interceptor.setActive(false)
            currentTypo = nil
            return
        }

        // Typo correction — preempts LLM ghost. Triggered only on word boundary
        // (caret right after a non-word char like space/punct), so we don't
        // flag the word the user is still typing.
        let typoCandidate: TypoSuggestion? = {
            guard store.typoEnabled,
                  !EmojiExpander.disabledBundles.contains(bundleID),
                  allowMode != .suggestionOnly  // honor per-app modes
            else { return nil }
            return typoDetector.checkLastWord(in: prefix, caretIndex: caretIndex)
        }()

        // Mid-word case: caret is INSIDE a misspelled word. We can't suggest a
        // correction (no clear word boundary yet), but we should also stop the
        // LLM from extending the typo with more wrong text. Bail before predict.
        if store.hideOnTypo,
           store.typoEnabled,
           !EmojiExpander.disabledBundles.contains(bundleID),
           typoCandidate == nil,
           typoDetector.currentWordLooksSuspect(in: prefix, caretIndex: caretIndex)
        {
            currentTypo = nil
            overlay.hide()
            interceptor.setActive(false)
            predictor.cancel()
            lastPredictedPrefix = nil
            return
        }

        if let typo = typoCandidate {
            let isNewSuggestion = currentTypo != typo
            currentTypo = typo
            predictor.cancel()
            lastPredictedPrefix = nil
            if let rect = rectForGhost {
                overlay.show(text: " → " + typo.suggestion, at: rect, hostText: text, caretIndex: caretIndex, hostFont: hostFontForOverlay)
                interceptor.setActive(true)
            }
            if isNewSuggestion { Log.info(.input, "typo_suggested") }
            return
        }
        currentTypo = nil

        if prefix != lastPredictedPrefix {
            // Debounce: every prefix change cancels the pending task and
            // schedules a new one. The LLM only fires once the user has
            // paused for at least `predictDebounceNanos`. This avoids
            // bursts of cancel-and-restart cycles when the user types
            // multiple characters between two poll ticks.
            predictDebounceTask?.cancel()
            let capturedPrefix = prefix
            let capturedContext = cachedEnrichmentPrefix
            let capturedCustom = CustomInstructionsWindow.current()
            let capturedSnap = snap                                    // Phase 2: forward live AX snapshot
            predictDebounceTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: Self.predictDebounceNanos)
                guard !Task.isCancelled, let self else { return }
                // Re-check freshness — another tick may have advanced
                // lastPredictedPrefix already.
                guard self.lastPredictedPrefix != capturedPrefix else { return }
                self.lastPredictedPrefix = capturedPrefix
                self.predictor.predict(
                    prefix: capturedPrefix,
                    contextPrefix: capturedContext,
                    customInstructions: capturedCustom,
                    axSnapshot: capturedSnap                           // Phase 2: feeds fieldContext + afterCursor slots
                )
            }
        }

        let suggestion = predictor.suggestion
        guard !suggestion.isEmpty, let rect = rectForGhost else {
            overlay.hide()
            interceptor.setActive(false)
            return
        }

        overlay.show(text: suggestion, at: rect, hostText: text, caretIndex: caretIndex, hostFont: hostFontForOverlay)
        interceptor.setActive(true)
    }

    // MARK: - Key handling (runs on the CGEventTap thread)

    nonisolated private func handleKey(_ key: KeyInterceptor.Key) -> Bool {
        // Pick up either a pending typo correction, an in-flight partial
        // remainder, or the freshly streamed LLM suggestion (in that order).
        // Typo wins because its ghost overrides the LLM ghost in tick().
        // `partialRemainder` wins over `predictor.suggestion` because we cancel
        // the predictor between chunks — its `suggestion` is empty during a
        // partial run.
        let pending: (typo: TypoSuggestion?, llm: String, isPartial: Bool) = MainActor.assumeIsolated {
            if !partialRemainder.isEmpty {
                return (currentTypo, partialRemainder, true)
            }
            return (currentTypo, predictor.suggestion, false)
        }
        if pending.typo == nil, pending.llm.isEmpty { return false }

        switch key {
        case .tab:
            if let typo = pending.typo {
                let count = typo.original.count
                let replacement = typo.suggestion
                DispatchQueue.global(qos: .userInitiated).async { [axClient] in
                    axClient.replaceTrailing(deleteChars: count, with: replacement)
                }
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.currentTypo = nil
                    self.predictor.cancel()
                    self.lastPredictedPrefix = nil
                    self.overlay.hide()
                    self.interceptor.setActive(false)
                }
                Log.info(.input, "typo_accepted")
                return true
            }
            let suggestion = pending.llm
            let isPartialContinuation = pending.isPartial
            // Pre-inject snapshot captures the prefix and bundle that preceded
            // the acceptance — used by the personalization store (opt-in).
            let preSnap = axClient.snapshot()
            let preCaret = preSnap.caretIndex ?? 0
            let prePrefix = preSnap.text.map { String($0.prefix(preCaret)) } ?? ""
            let bundleID = preSnap.bundleID

            // Partial accept enabled → split the suggestion, inject just the
            // next chunk, and keep the rest as a ghost remainder.
            let partialConfig: (enabled: Bool, trailingSpace: Bool) = MainActor.assumeIsolated {
                (store.partialAcceptEnabled, store.trailingSpaceOnPartial)
            }
            if partialConfig.enabled {
                let chunk = ChunkSplitter.nextChunk(suggestion, trailingSpace: partialConfig.trailingSpace)
                if chunk.isEmpty {
                    // Defensive: ChunkSplitter returned nothing (only whitespace
                    // with trailingSpace=false, etc.). Fall through to the
                    // legacy full-accept path so Tab still does something useful.
                } else {
                    let rest = String(suggestion.dropFirst(chunk.count))
                    let isLast = rest.isEmpty
                    // CGEventTap is wired to the main runloop (KeyInterceptor
                    // calls `CFRunLoopAddSource(CFRunLoopGetMain(), ...)`), so
                    // handleKey ALREADY runs on the main thread. Update the
                    // partial-accept state SYNCHRONOUSLY here — if we deferred
                    // via `DispatchQueue.main.async`, the 200 ms tick could
                    // fire between handleKey returning and the async block
                    // running, see `partialRemainder` still empty, and re-fire
                    // a fresh prediction instead of consuming the remainder.
                    // That's how "Tab Tab Tab" was producing new words each
                    // press instead of walking through the cached suggestion.
                    MainActor.assumeIsolated {
                        if isPartialContinuation {
                            self.partialAcceptedSoFar += chunk
                        } else {
                            self.partialAcceptedAtPrefix = prePrefix
                            self.partialAcceptedAtBundleID = bundleID
                            self.partialAcceptedSoFar = chunk
                        }
                        if isLast {
                            self.recordPartialAcceptanceToHistoryIfAllowed()
                            self.partialRemainder = ""
                            self.partialAcceptedSoFar = ""
                            self.partialAcceptedAtPrefix = ""
                            self.partialAcceptedAtBundleID = nil
                            self.predictor.cancel()
                            self.lastPredictedPrefix = nil
                            self.overlay.hide()
                            self.interceptor.setActive(false)
                        } else {
                            self.partialRemainder = rest
                            // Stop the streaming task so it can't overwrite
                            // the remainder mid-flight.
                            self.predictor.cancel()
                            // Pre-arm `lastPredictedPrefix` to the post-inject
                            // prefix so even if AX races and `partialRemainder`
                            // somehow gets cleared before tick sees it, the
                            // predict gate still won't fire on the same input.
                            self.lastPredictedPrefix = prePrefix + chunk
                        }
                    }
                    DispatchQueue.global(qos: .userInitiated).async { [axClient] in
                        axClient.inject(chunk)
                        if isLast {
                            let snap = axClient.snapshot()
                            DispatchQueue.main.async { [weak self] in
                                self?.dismissedForText = snap.text ?? ""
                            }
                        }
                    }
                    Log.info(.input, "partial_accept")
                    return true
                }
            }

            // Full-accept (legacy / partialAcceptEnabled=false) path.
            let recordPersonalization: Bool = MainActor.assumeIsolated {
                guard store.personalizationEnabled, let bid = bundleID else { return false }
                if bundleBlocklist.contains(bid) { return false }
                if personalizationBundleBlocklist.contains(where: { bid == $0 || bid.hasPrefix($0) }) { return false }
                return true
            }
            if recordPersonalization {
                let entry = TypingHistoryEntry(
                    timestamp: Date(),
                    contextBefore: SecretHeuristic.contextTail(prefix: prePrefix),
                    accepted: suggestion,
                    bundleID: bundleID
                )
                let history = MainActor.assumeIsolated { self.store.history }
                let predictorRef = MainActor.assumeIsolated { self.predictor }
                Task { [history, predictorRef, entry] in
                    await history.append(entry)
                    await predictorRef.ingestAccepted(entry)
                }
            }
            DispatchQueue.global(qos: .userInitiated).async { [axClient] in
                axClient.inject(suggestion)
                // Re-read AX state after the host applies the inject, then
                // mark that text as "dismissed" so we don't immediately re-suggest
                // off the freshly-extended text — that's the double-Tab bug
                // (user taps Tab twice and the same prediction lands twice).
                let snap = axClient.snapshot()
                DispatchQueue.main.async { [weak self] in
                    self?.dismissedForText = snap.text ?? ""
                }
            }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.predictor.cancel()
                self.lastPredictedPrefix = nil
                self.overlay.hide()
                self.interceptor.setActive(false)
            }
            return true

        case .esc:
            // If a typo ghost is up, teach NSSpellChecker to ignore this word
            // for the rest of the process — "Esc on typo = not a typo".
            if let typo = pending.typo {
                let word = typo.original
                MainActor.assumeIsolated { typoDetector.ignore(word: word) }
                Log.info(.input, "typo_ignored")
            }
            DispatchQueue.global(qos: .userInitiated).async { [axClient] in
                let snap = axClient.snapshot()
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.currentTypo = nil
                    self.dismissedForText = snap.text ?? ""
                    // If a partial-accept remainder was visible, record the
                    // span the user did take (so personalization captures
                    // what they actually used) and reset partial state.
                    if !self.partialRemainder.isEmpty {
                        self.recordPartialAcceptanceToHistoryIfAllowed()
                        self.partialRemainder = ""
                        self.partialAcceptedSoFar = ""
                        self.partialAcceptedAtPrefix = ""
                        self.partialAcceptedAtBundleID = nil
                    }
                    self.predictor.cancel()
                    // Esc = explicit user dismissal: blow the cache so a
                    // re-type of the same prefix doesn't restore the ghost
                    // they just refused.
                    self.predictor.clearPredictCache()
                    self.lastPredictedPrefix = nil
                    self.overlay.hide()
                    self.interceptor.setActive(false)
                }
            }
            return true
        }
    }

    /// Records the cumulative span the user accepted partially into the
    /// personalization history, gated by the same toggles + bundle blocklists
    /// as the full-accept branch. No-op when nothing was accepted, when
    /// personalization is disabled, or when the bundle is blocklisted.
    @MainActor
    private func recordPartialAcceptanceToHistoryIfAllowed() {
        guard !partialAcceptedSoFar.isEmpty else { return }
        guard store.personalizationEnabled, let bid = partialAcceptedAtBundleID else { return }
        if bundleBlocklist.contains(bid) { return }
        if personalizationBundleBlocklist.contains(where: { bid == $0 || bid.hasPrefix($0) }) { return }
        let entry = TypingHistoryEntry(
            timestamp: Date(),
            contextBefore: SecretHeuristic.contextTail(prefix: partialAcceptedAtPrefix),
            accepted: partialAcceptedSoFar,
            bundleID: bid
        )
        let history = self.store.history
        let predictorRef = self.predictor
        Task { [history, predictorRef, entry] in
            await history.append(entry)
            await predictorRef.ingestAccepted(entry)
        }
    }

    /// Records a field's raw text into the corpus when "store without accepted"
    /// is on — Cotypist's "Store Inputs Without Accepted Completions". Fires on
    /// focus change with the PREVIOUS field's final text. Gated exactly like
    /// acceptance recording (personalization master toggle + blocklists), plus
    /// the store-without-accepted toggle, a minimum length (a real sentence, not
    /// a stray word), and a consecutive-duplicate dedup. The `append` call adds
    /// the shared secret-heuristic + fragment + FIFO gates.
    private func recordRawInputIfAllowed(text: String, bundleID: String?) {
        guard store.personalizationEnabled, store.storeWithoutAccepted else { return }
        guard let bid = bundleID else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 8 else { return }
        guard trimmed != lastRecordedRawInput else { return }
        if bundleBlocklist.contains(bid) { return }
        if personalizationBundleBlocklist.contains(where: { bid == $0 || bid.hasPrefix($0) }) { return }
        lastRecordedRawInput = trimmed
        let entry = TypingHistoryEntry(
            timestamp: Date(),
            contextBefore: "",
            accepted: String(trimmed.suffix(200)),
            bundleID: bid
        )
        let history = self.store.history
        let predictorRef = self.predictor
        Task { [history, predictorRef, entry] in
            await history.append(entry)
            await predictorRef.ingestAccepted(entry)
        }
        Log.info(.context, "raw_input_recorded")
    }

    /// Clear the on-screen ghost when the user typed a character that DIVERGES
    /// from the currently displayed suggestion. Without this, the old ghost
    /// stays rendered while the (debounced, async) re-prediction runs — and if
    /// that re-prediction is gated or empty, the stale ghost lingers forever
    /// (e.g. "applielle"). Callers MUST NOT `return` after this: control falls
    /// through to the predict gate so a fresh prediction fires on the new
    /// prefix. `predictor.cancel()` also empties `predictor.suggestion`, so the
    /// final tick guard won't re-show the stale text.
    private func clearStaleGhostOnDivergence() {
        predictor.cancel()
        overlay.hide()
        interceptor.setActive(false)
        lastPredictedPrefix = nil
    }

    /// Pure decision: do the characters the user just typed (`typedSince`)
    /// CONSUME the start of the displayed ghost (`ghost`), or DIVERGE from it?
    ///
    /// Returns `true` when `typedSince` is a case-insensitive prefix of `ghost`
    /// (smooth live-consume — keep shrinking the ghost). Returns `false` on
    /// divergence — the caller must hide the stale ghost and re-predict. Empty
    /// `typedSince` is treated as a (degenerate) consume so an unchanged prefix
    /// never triggers a spurious divergence clear.
    static func isLiveConsumeMatch(ghost: String, typedSince: String) -> Bool {
        ghost.lowercased().hasPrefix(typedSince.lowercased())
    }

    /// True when `ghost` was generated while the caret sat MID-WORD (its
    /// `basePrefix` ends in a word character) AND the ghost completes that very
    /// word and then keeps going (its leading word-run is followed by more
    /// text). Such a ghost committed to a GUESSED word completion the model can
    /// no longer revise: "J'ai envi" → ghost "es de manger" splices to
    /// "envies de manger". Once the user reveals the next letter the guess can
    /// be wrong ("J'ai envie de manger") — yet plain live-consume would happily
    /// shave the matching head ("e") and keep showing the stale tail ("s de"),
    /// rendering "envies de". So when this holds the caller must NOT promote the
    /// ghost via live-consume; it re-predicts on the now-longer word instead
    /// (the base model, fed "J'ai envie", returns " de manger").
    ///
    /// A *pure* word completion with nothing after it ("Bonj" → "our") is NOT
    /// stale — it merely finishes the obvious word — so live-consume keeps it
    /// and the ghost stays instant. The space/punctuation-led next-word ghost
    /// ("J'ai envie" → " de manger") is likewise unaffected: its first char is
    /// not a word char.
    static func isStaleMidWordCompletion(basePrefix: String, ghost: String) -> Bool {
        guard let lastTyped = basePrefix.last,
              ModelRuntime.OutputFilter.isWordChar(lastTyped),
              let firstGhost = ghost.first,
              ModelRuntime.OutputFilter.isWordChar(firstGhost) else {
            return false
        }
        // The ghost finishes the in-progress word (leading word-run) AND
        // continues past it. A word-run that IS the whole ghost ("our") just
        // completes the word and is safe to consume.
        return ModelRuntime.OutputFilter.leadingWordRun(ghost).count < ghost.count
    }
}
