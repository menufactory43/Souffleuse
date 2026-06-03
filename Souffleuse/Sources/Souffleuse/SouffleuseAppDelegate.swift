import AppKit
import Foundation
import Observation
import SouffleuseAX
import SouffleuseContext
import SouffleuseCore
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

/// Derives the `midWordContinuation` flag from the stored contextBefore and
/// accepted values at acceptance time. True when the accept glues onto a word
/// in progress (both boundary characters are word-chars as defined by
/// `OutputFilter.isWordChar`), false otherwise.
///
/// Free function (not on AppDelegate) so it is callable from both the
/// @MainActor context and the CGEventTap handler (non-isolated context).
private func deriveMidWordContinuation(contextBefore: String, accepted: String) -> Bool {
    guard let cb = contextBefore.last, let af = accepted.first else { return false }
    return OutputFilter.isWordChar(cb) && OutputFilter.isWordChar(af)
}

@MainActor
final class SouffleuseAppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    /// Carnet d'usage : frappes épargnées, cadence mesurée, actes — affiché au clic
    /// sur l'icône (« mieux qu'un compteur de mots collé à l'icône »).
    private let ledger = UsageLedger()
    private var carnetRepliquesItem: NSMenuItem?
    private var carnetFrappesItem: NSMenuItem?
    private var carnetTempsItem: NSMenuItem?
    private var carnetActesItem: NSMenuItem?
    /// État de la mesure de cadence de frappe (croissance de texte entre deux polls).
    private var cadenceLastLen = 0
    private var cadenceLastBundle: String?
    private var cadenceLastGrowthAt: Date?
    // MARK: - Icône vivante (barre des menus)
    /// En coulisse (endormie) → à l'écoute (champ actif) → elle souffle (ghost) →
    /// (capture, désactivée). Une seule famille de bulle, lecture instantanée.
    private enum IconState: Equatable { case disabled, coulisse, listening, souffle, capturing }
    private var currentIconState: IconState?
    /// Posé dans `tick` : vrai dès qu'un champ texte éligible est focalisé.
    private var iconTextFieldFocused = false
    /// Capture OCR active à l'instant (sondage async de `tick`).
    private var iconCapturingNow = false
    /// « Elle souffle » maintenu un court instant après la dernière apparition du
    /// ghost — anti-strobe pendant la frappe (le ghost cligne à chaque keystroke).
    private var souffleHoldUntil: Date?
    private static let souffleHoldSeconds: Double = 0.45
    private let axClient = AXClient()
    private var overlay: OverlayWindow!
    private var presence: PresenceIndicatorWindow!
    /// Anti-blink de l'indicateur de présence. Le snapshot AX renvoie parfois un
    /// `caretIndex`/`elementRect` transitoirement nil (typiquement aux frontières
    /// de mot dans certaines apps) : sans amortissement, le badge clignote à
    /// 80 ms et donne l'impression que la souffleuse « ne travaille pas ». On
    /// retient le dernier rect valide et on garde le badge ancré pendant une
    /// courte grâce sur ces disparitions transitoires ; au-delà (focus réellement
    /// parti), on cache pour de bon.
    private var lastPresenceFieldRect: CGRect?
    private var presenceMissTicks = 0
    /// ~480 ms à 80 ms de poll — couvre un trou AX de quelques ticks sans laisser
    /// traîner le badge après une vraie perte de focus.
    private static let presenceGraceTicks = 6
    private var interceptor: KeyInterceptor!
    private let predictor = PredictorViewModel()
    /// Mini Phase 4 — moteur instruct paresseux + petit panneau de traduction.
    private let translationRuntime = TranslationRuntime()
    private let translationHUD = TranslationHUDWindow()
    /// Fenêtre DEV d'inspection du ghost (live), créée paresseusement au clic.
    private var ghostInspectorWindow: GhostInspectorWindow?
    /// Item de menu DEV pilotant la fenêtre d'inspection (état coché = visible).
    private var ghostInspectorItem: NSMenuItem?
    /// Cible cyclée à la main (⌘⇧→), tenue VIVANTE pour qu'un choix EXPLICITE
    /// fasse autorité au commit sans dépendre du lookup disque par titre. Le titre
    /// de fenêtre dérive (compteurs de non-lus « (1) », sujet) entre le cycle et le
    /// commit : la clé `bundleID + titre` recalculée au commit rate alors le store
    /// et on retombait silencieusement sur AUTO → EN, perdant la langue choisie.
    /// Ici l'état vivant prime ; le store par conversation reste le repli de
    /// persistance (cross-redémarrage / multi-thread).
    private var liveTargetSelection: (bundleID: String, selection: TargetSelection, at: Date)?
    /// Au-delà de ce délai après le dernier cycle, l'état vivant n'est plus
    /// « courant » et on retombe sur le store par conversation. Couvre le temps de
    /// composer une réponse support ; assez court pour ne pas fuiter sur une autre
    /// conversation de la même app si l'utilisateur n'a pas re-cyclé.
    private static let liveTargetSelectionTTL: TimeInterval = 300
    /// Le Carnet — apparition livret convoquée au clic sur l'icône (sparkline + stats).
    private let carnet = CarnetWindow()
    private var pollTimer: Timer?
    private var onboarding: OnboardingWindow?
    private var customInstructions = CustomInstructionsWindow()
    private var preferences: PreferencesWindow?
    private var historyViewer: HistoryViewerWindow?
    private var hotkeyMonitor: Any?

    private let store = PreferencesStore()
    /// Token returned by `withObservationTracking` so we can keep re-subscribing.
    private var storeObservationTask: Task<Void, Never>?

    /// Per-bundle cache of the last font obtained from a *reliable* source (AX
    /// font attribute or OCR-calibrated metrics). When both sources are nil
    /// (e.g. on an empty line where AX reports no font), we fall back to this
    /// cached value instead of handing a degenerate line-box rect height to
    /// `OverlayWindow.estimatedFont` — which, even with the conservative 20pt
    /// cap, would still be wrong for large-font apps. Only the two reliable
    /// sources (AX font + OCR calibration) populate this cache; the estimate
    /// never does.
    private var lastReliableFontByBundle: [String: NSFont] = [:]
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
    /// Separators (usually "" or a single space) between the misspelled word's end
    /// and the caret, captured when `currentTypo` is set. On accept we delete the
    /// word AND these trailing chars and re-insert `suggestion + trailing`, so a
    /// typo flagged after a trailing space (caret past the word) corrects cleanly
    /// instead of eating the space and corrupting the word into a new "typo" that
    /// then suppresses the ghost until focus changes.
    private var currentTypoTrailing: String = ""
    /// Debounce state for end-of-string typo candidates (caret right after the
    /// word, where the user may still be mid-typing). `typoSettleKey` identifies
    /// the candidate; `typoSettleSince` when it first appeared. We only show the
    /// correction once it has been stable for `typoDebounce`, so an incomplete
    /// word ("messa" on the way to "message") doesn't flash a correction. Words
    /// already followed by a separator are "done" and bypass this entirely.
    private var typoSettleKey: String?
    private var typoSettleSince: Date?
    private static let typoDebounce: TimeInterval = 0.35
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
    // ── ANCRE DE FENÊTRE GLISSANTE BIDIRECTIONNELLE (flag `midWordGhostRollingEnabled`) ──
    // Modélise une fenêtre ghost à BORNE GAUCHE : taper en avant CONSOMME le ghost,
    // effacer en arrière le RE-GÉNÈRE (restaure ce qu'on a effacé) — mais seulement
    // jusqu'au point où le LLM a ancré sa prédiction (la « borne gauche »). Effacer
    // EN-DEÇÀ régénère. Tout est en minuscules pour le matching (la casse tapée gagne
    // dans le texte hôte, comme `isLiveConsumeMatch`). Hors flag : ces trois vars
    // restent vides et n'influencent rien (chemin byte-identique).
    /// Préfixe committé AU MOMENT où le LLM a produit ce ghost. C'est la BORNE GAUCHE :
    /// effacer en-deçà de `count` caractères régénère.
    private var ghostAnchorBase: String = ""
    /// Texte complet prédit = `ghostAnchorBase` + le ghost à l'instant de l'ancrage
    /// (étendu à droite par les refills, et par un accept Tab). La fenêtre vit dans
    /// `[ghostAnchorBase.count, ghostAnchorFull.count)`.
    private var ghostAnchorFull: String = ""
    /// Bundle focus à l'ancrage — l'ancre est réinitialisée au changement de focus.
    private var ghostAnchorBundle: String = ""
    /// Rolling-refill (mode sliding-window, flag `midWordGhostRollingEnabled`) :
    /// vrai tant qu'une passe `extendGhost` est en vol. Empêche le tick à 20 Hz
    /// d'empiler une tempête de refills. Remis à `false` à la fin de la Task.
    private var ghostRefillInFlight = false
    /// Task de refill en vol — trackée pour pouvoir l'annuler sur changement
    /// d'app / divergence / blur (mêmes points que le cancel du predict).
    private var ghostRefillTask: Task<Void, Never>?
    /// Préfixe vu au tick PRÉCÉDENT — sert UNIQUEMENT à détecter un backspace
    /// in-place (le préfixe rétrécit ET reste un préfixe de l'ancien) pour le mode
    /// rolling (flag `midWordGhostRollingEnabled`). Écrit à chaque tick éligible
    /// mais ne change AUCUN comportement hors flag (la branche de suppression qui
    /// le lit est gardée par le flag) ⇒ chemin byte-identique flag-OFF.
    private var lastTickPrefixForDelete: String = ""
    /// Bundle ID we last kicked off enrichment for; used to detect focus changes.
    private var lastEnrichedBundleID: String?
    /// Last window title we kicked off enrichment for; used to detect *intra-app*
    /// context changes (browser tab switches in particular — `bundleID` stays
    /// `com.brave.Browser` across tabs, so without title-tracking the OCR
    /// captures whatever was visible at the first focus and stays cached for
    /// the entire session). Re-firing on title change with a debounce lets the
    /// enricher follow the user across tabs.
    private var lastEnrichedWindowTitle: String?
    /// Timestamp of the last enrichment refire, used to debounce title-driven
    /// re-fires so transient titles during page transitions ("Loading…" →
    /// "Inbox · Intercom") don't cause back-to-back captures.
    private var lastEnrichmentAt: Date = .distantPast
    /// Minimum interval between title-driven refires within the same bundle.
    /// Bundle changes bypass this — focus moves are always honoured.
    private static let titleChangeRefireMinInterval: TimeInterval = 2.0
    /// Last computed enrichment prefix, refreshed asynchronously on focus change.
    /// Read synchronously in tick() so prediction stays on the fast path.
    private var cachedEnrichmentPrefix: String = ""
    /// Last raw *visible* (OCR) text from the enricher, kept so the translation
    /// commit can AUTO-detect the correspondent's language (P5). Only populated
    /// when screen capture is enabled — otherwise nil and AUTO falls back to the
    /// conversation's manual target (or EN). Distinct from `cachedEnrichmentPrefix`
    /// which mixes app/window metadata and would skew language detection.
    private var lastEnrichedVisible: String?
    /// Pending idle-unload of the lazy instruct (translation) engine — cancelled
    /// and rescheduled on each commit so memory is freed only after real idle.
    private var translationIdleUnloadTask: Task<Void, Never>?
    /// Ghost engine lifecycle ("warm while composing"). The GGUF (~0,8 Go) is
    /// unloaded after `ghostIdleUnloadSeconds` without a keystroke, and lazily
    /// reloaded once the user has typed `ghostWarmupMinChars` in a field — so it
    /// is resident only while the user actually writes a sentence.
    private var ghostIdleUnloadTask: Task<Void, Never>?
    private var ghostLoadTask: Task<Void, Never>?
    /// Last prefix seen by the warmth manager — a change between ticks signals a
    /// fresh keystroke (rearms the idle timer); identical means the user paused.
    private var lastGhostActivityPrefix: String = ""
    /// Snapshot of the last applied OCR language list; we reapply when the
    /// user toggles a language in Preferences.
    private var lastOCRLangsApplied: [String] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        installEditMenuShortcuts()

        // Create the overlay/presence windows BEFORE installing the status item:
        // `installStatusItem()` calls `refreshLivingIcon()`, which reads
        // `overlay.isVisible`. `overlay` is an implicitly-unwrapped optional, so
        // it must already exist or the living-icon nil-unwraps and crashes at
        // launch whenever the app starts ENABLED (the `.disabled` icon branch
        // happens to dodge it). Two cheap NSPanel allocations — the status item
        // still appears effectively immediately.
        overlay = OverlayWindow()
        presence = PresenceIndicatorWindow()
        // Inspecteur de ghost (DEV) : moniteur live du chemin de décision —
        // affiché/gaté/dropé + motif. Créé paresseusement et basculé via le menu
        // (item présent uniquement en build Debug, cf. `toggleGhostInspector`).
        // Install the status item early so the user sees the app is alive even
        // if no permissions are granted yet.
        installStatusItem()

        // Prompt for AX once at launch (non-blocking). If denied, the user
        // can toggle the permission in Settings and the app picks it up on
        // the next tick — no relaunch needed.
        _ = AXClient.ensureTrusted(prompt: true)

        // §3b : quand l'utilisateur déplace le panneau de traduction, on mémorise
        // sa position (offset relatif au champ) PAR APP via le HUDAnchorStore.
        translationHUD.onMoved = { [weak self] bundleID, offset in
            guard let self, let bid = bundleID else { return }
            self.store.hudAnchors.upsert(
                HUDAnchor(bundleID: bid, edge: .left,
                          offsetX: Double(offset.width), offsetY: Double(offset.height)))
        }

        interceptor = KeyInterceptor { [weak self] key in
            guard let self else { return false }
            // Called on the tap's DEDICATED thread. Never block on main here —
            // dispatch the accept/dismiss asynchronously and consume at once.
            // The tap is enabled only while a ghost is showing, so a Tab/Esc
            // that reaches us is ours to handle (and to swallow).
            DispatchQueue.main.async { _ = self.handleKey(key) }
            return true
        }
        if !interceptor.install() {
            Log.warn(.input, "key_interceptor_install_failed")
        }
        interceptor.setAcceptAllKey(store.acceptAllKey)
        interceptor.setCommitKey(store.commitKey)
        interceptor.setTargetCycleKey(store.targetCycleKey)
        Task { await self.translationRuntime.setModel(self.store.translationModel) }

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
            // Démarrage à froid : on NE charge PAS le moteur ghost ici. Il se
            // charge paresseusement à la première vraie frappe dans un champ
            // texte (cf. `loadGhostIfNeeded` via `manageGhostWarmth`) — rien en
            // RAM tant que l'utilisateur ne compose pas. On garde quand même le
            // snapshot historique (Layer-1 recall instantané) : `rebuildPersonalization`
            // le pose tout de suite et saute proprement la construction du n-gram
            // tant qu'aucun container n'est chargé (setCorpus no-op sans handles,
            // `guard container` sort) — corpus + n-gram seront bâtis au 1er load.
            guard let self else { return }
            let history = await MainActor.run { self.store.history }
            await history.load()
            // Import any pending messages written by SouffleuseCorpusSeed.
            await history.importPendingIfNeeded()
            // V2 corpus hygiene: one-time retroactive prune of the short
            // single-token word-completer residue ("ton"/"aux"/"cal") that
            // pollutes mid-word recalls. Runs once (UserDefaults flag); the
            // live app holds the working Keychain key so SQLCipher decrypts.
            if !UserDefaults.standard.bool(forKey: "corpusPrunedV2") {
                let deleted = await history.pruneLowQuality()
                UserDefaults.standard.set(true, forKey: "corpusPrunedV2")
                Log.info(.context, "corpus_prune_v2_done", count: deleted)
            }
            // V3 re-prune: the broken-session debugging appended fresh short
            // single-token residue ("fisc"-class) AFTER the one-time V2 sweep —
            // exactly the entries the recall fast-path was slicing into a 1-char
            // ghost ("Rapport fis" → "c"). Re-run the same low-quality prune once
            // so that residue is gone. The recall prior fix already makes any
            // surviving micro-completion beatable by the LLM; this removes the
            // brief instant flash before the LLM overrides.
            if !UserDefaults.standard.bool(forKey: "corpusPrunedV3") {
                let deleted = await history.pruneLowQuality()
                UserDefaults.standard.set(true, forKey: "corpusPrunedV3")
                Log.info(.context, "corpus_prune_v3_done", count: deleted)
            }
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
        observeSuggestionForInstantPaint()
        wireAXPushDetection()

        // 50 ms tick → live-consume + overlay refresh feel near-instant.
        // Lowered from 80 ms (2026-05-26): at 80 ms a keystroke could wait up
        // to 80 ms before the tick even noticed the new text, the dominant
        // remaining chunk of the "slow ghost" feel. 50 ms (20 Hz) halves that
        // worst-case detection lag; the AX snapshot cost stays negligible
        // (<1 ms), so the only cost is a few more idle snapshots per second.
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.tick()
                self?.refreshLivingIcon()
            }
        }

        installGlobalHotkey()
        if shouldShowOnboarding() {
            showOnboarding()
        }
    }

    // MARK: - Onboarding

    private func shouldShowOnboarding() -> Bool {
        let onboarded = UserDefaults.standard.bool(forKey: "onboardingDone")
        // On ré-affiche tant que le souffle ne peut pas générer : permission AX
        // manquante OU GGUF du souffle introuvable (l'utilisateur a pu quitter
        // avant la fin du téléchargement). `isResolvable` couvre aussi le dossier
        // Cotypist legacy → pas de ré-onboarding pour qui a déjà le modèle.
        let ghostReady = GGUFModelOption.option(forID: store.ggufModelID).isResolvable
        if onboarded && AXClient.isTrusted && ghostReady { return false }
        return true
    }

    /// Construit la fenêtre d'onboarding câblée sur le `store` : gestionnaire de
    /// téléchargement partagé, modèle de souffle sélectionné (avec repli sur le
    /// défaut), modèle de traduction courant.
    private func makeOnboardingWindow() -> OnboardingWindow {
        let ghost = GGUFModelOption.option(forID: store.ggufModelID).downloadable
            ?? GGUFModelOption.option(forID: GGUFModelOption.defaultID).downloadable
        return OnboardingWindow(
            modelDownloads: store.modelDownloads,
            ghost: ghost,
            ghostReady: { [store] in GGUFModelOption.option(forID: store.ggufModelID).isResolvable },
            translation: store.translationModel.downloadable,
            onGhostInstalled: { [weak self] in
                // Le GGUF du souffle vient d'arriver sur disque : recharge le
                // moteur pour que le ghost marche sans relancer l'app.
                Task { await self?.predictor.reloadAfterDownload() }
            }
        )
    }

    private func showOnboarding() {
        let win = makeOnboardingWindow()
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
        lastEnrichedVisible = nil
        lastEnrichedBundleID = nil
        Task { await enricher.invalidate() }
        refreshStatusItem()
        NSSound.beep()
    }

    // MARK: - Observation of PreferencesStore

    /// Re-subscribes to @Observable changes after each fire. AppDelegate reacts to
    /// model swap, capture toggle, OCR language changes, and menu mirror updates.
    /// **Instant-paint (flag `SOUFFLEUSE_INSTANT_PAINT`).** Sans ce flag, l'overlay
    /// n'est peint que par le `tick()` du poll (50 ms) : une suggestion résolue
    /// par `predict()` (cache/corpus) ou par la fin d'une génération LLM/refill
    /// DORT jusqu'au prochain tick — jusqu'à +50 ms de latence d'affichage pure,
    /// alors que le ghost est déjà calculé. On observe `predictor.suggestion` et,
    /// dès qu'elle change (depuis N'IMPORTE quelle source : cache, LLM, refill),
    /// on re-déclenche un `tick()` immédiat qui peint via la MÊME freshness-gate.
    /// Pas de double-paint : le tick suivant verra le ghost déjà à l'écran et la
    /// `shouldRenderSuggestion`/`overlay.show` est idempotente. `withObservationTracking`
    /// est one-shot (sémantique willSet) → on re-arme à chaque `onChange`, et on
    /// hop async pour lire la valeur APRÈS commit (même pattern qu'`observePreferences`).
    /// Flag OFF → jamais armé → zéro overhead, comportement byte-identique.
    /// **Détection PUSH (Fix 2, flag `SOUFFLEUSE_AX_PUSH`).** Aujourd'hui la
    /// détection d'un changement de texte/caret passe par le poll 50 ms → jusqu'à
    /// +50 ms de latence avant même de lire l'AX. Cotypist, lui, s'abonne aux
    /// notifications AX (`AXValueChanged`/`AXSelectedTextChanged`) et réagit en
    /// push (~0 ms). Ici on branche le signal `onHostAXChanged` de l'AXClient
    /// (déjà émis sur le main run-loop par l'observer rendu non-muet) sur un
    /// `tickThrottled()` immédiat. Le poll 50 ms reste en FILET pour les apps qui
    /// ne propagent pas de notifs (coller, certaines web-views). Flag OFF → handler
    /// jamais posé + observer no-op ⇒ byte-identique.
    private func wireAXPushDetection() {
        guard ProcessInfo.processInfo.environment["SOUFFLEUSE_AX_PUSH"] != nil else { return }
        axClient.onHostAXChanged = { [weak self] in
            // Invoqué sur le main run-loop (source AX ajoutée à CFRunLoopGetMain),
            // comme le pollTimer → même pattern `MainActor.assumeIsolated`.
            MainActor.assumeIsolated {
                self?.tickThrottled()
            }
        }
    }

    private func observeSuggestionForInstantPaint() {
        guard ProcessInfo.processInfo.environment["SOUFFLEUSE_INSTANT_PAINT"] != nil else { return }
        withObservationTracking {
            _ = predictor.suggestion
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.tickThrottled()                  // peint le ghost frais sans attendre le poll
                    self.observeSuggestionForInstantPaint()  // re-arme (one-shot)
                }
            }
        }
    }

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
            _ = store.acceptAllKey
            _ = store.commitKey
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
        interceptor.setAcceptAllKey(store.acceptAllKey)
        interceptor.setCommitKey(store.commitKey)
        interceptor.setTargetCycleKey(store.targetCycleKey)
        Task { await self.translationRuntime.setModel(self.store.translationModel) }
        if store.captureEnabled != previous.captureEnabled {
            applyCaptureToggle(store.captureEnabled, requestPermissionIfNeeded: true)
        }
        if store.ocrLanguages != previous.ocrLangs {
            applyOCRLangsIfNeeded()
        }
        if !store.enrichmentEnabled && previous.enrichment {
            cachedEnrichmentPrefix = ""
            lastEnrichedVisible = nil
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
        refreshLivingIcon()

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
        menu.addItem(NSMenuItem.separator())
        let carnetHeader = NSMenuItem(title: "Carnet de la souffleuse — aujourd'hui", action: nil, keyEquivalent: "")
        carnetHeader.isEnabled = false
        menu.addItem(carnetHeader)
        let repliques = Self.carnetLine(); menu.addItem(repliques); carnetRepliquesItem = repliques
        let frappes = Self.carnetLine(); menu.addItem(frappes); carnetFrappesItem = frappes
        let temps = Self.carnetLine(); menu.addItem(temps); carnetTempsItem = temps
        let actes = Self.carnetLine(); menu.addItem(actes); carnetActesItem = actes
        let carnetOpen = NSMenuItem(title: "Ouvrir le carnet…", action: #selector(openCarnet), keyEquivalent: "")
        carnetOpen.target = self
        menu.addItem(carnetOpen)
        menu.addItem(NSMenuItem.separator())
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
        #if DEBUG
        menu.addItem(NSMenuItem.separator())
        let inspectorItem = NSMenuItem(
            title: "Inspecteur ghost (DEV)",
            action: #selector(toggleGhostInspector),
            keyEquivalent: ""
        )
        inspectorItem.target = self
        ghostInspectorItem = inspectorItem
        menu.addItem(inspectorItem)
        #endif
        menu.addItem(NSMenuItem.separator())
        let quitItem = NSMenuItem(title: "Quitter", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
        menu.delegate = self   // rafraîchit le carnet à chaque ouverture
        statusItem.menu = menu
    }

    /// Une ligne d'information non cliquable du carnet (grisée, titre posé au refresh).
    private static func carnetLine() -> NSMenuItem {
        let item = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    /// Met à jour les lignes du carnet (frappes, temps, actes) à partir du ledger.
    private func refreshCarnet() {
        let t = ledger.today
        carnetRepliquesItem?.title = "  \(Self.frenchInt(t.ghostsAccepted)) " +
            Self.plural(t.ghostsAccepted, "réplique soufflée", "répliques soufflées")
        carnetFrappesItem?.title = "  \(Self.frenchInt(t.keystrokesSaved)) " +
            Self.plural(t.keystrokesSaved, "frappe épargnée", "frappes épargnées")
        let suffix = ledger.cadenceCalibrated ? " (à ta cadence)" : ""
        carnetTempsItem?.title = "  ≈ \(Self.formatDuration(ledger.estimatedSecondsSavedToday)) gagnées\(suffix)"
        var parts: [String] = []
        if t.translations > 0 { parts.append("\(t.translations) " + Self.plural(t.translations, "traduite", "traduites")) }
        if t.reformulations > 0 { parts.append("\(t.reformulations) " + Self.plural(t.reformulations, "relue", "relues")) }
        if parts.isEmpty {
            carnetActesItem?.isHidden = true
        } else {
            carnetActesItem?.isHidden = false
            carnetActesItem?.title = "  " + parts.joined(separator: " · ")
        }
    }

    private static let frenchNumberFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.groupingSeparator = "\u{202F}"   // espace fine insécable
        f.locale = Locale(identifier: "fr_FR")
        return f
    }()

    private static func frenchInt(_ n: Int) -> String {
        frenchNumberFormatter.string(from: NSNumber(value: n)) ?? "\(n)"
    }

    private static func plural(_ n: Int, _ singular: String, _ plural: String) -> String {
        n <= 1 ? singular : plural
    }

    /// Convoque (ou congédie) le Carnet livret. Active l'app pour que la fenêtre
    /// prenne le focus et capte Échap ; un clic en dehors la referme.
    @objc private func openCarnet() {
        if carnet.isVisible { carnet.hide(); return }
        NSApp.activate(ignoringOtherApps: true)
        carnet.show(currentCarnetData())
    }

    /// Assemble les données du carnet depuis le ledger — toute la copie française
    /// (formats, pluriels) reste ici, source unique ; la fenêtre ne fait que rendre.
    private func currentCarnetData() -> CarnetData {
        let t = ledger.today
        let repliques = "\(Self.frenchInt(t.ghostsAccepted)) "
            + Self.plural(t.ghostsAccepted, "réplique soufflée", "répliques soufflées")
        let frappes = "\(Self.frenchInt(t.keystrokesSaved)) "
            + Self.plural(t.keystrokesSaved, "frappe épargnée", "frappes épargnées")
        let suffix = ledger.cadenceCalibrated ? " · à ta cadence" : ""
        let temps = "≈ \(Self.formatDuration(ledger.estimatedSecondsSavedToday)) gagnées\(suffix)"
        var parts: [String] = []
        if t.translations > 0 { parts.append("\(t.translations) " + Self.plural(t.translations, "traduite", "traduites")) }
        if t.reformulations > 0 { parts.append("\(t.reformulations) " + Self.plural(t.reformulations, "relue", "relues")) }
        let days = 7
        return CarnetData(
            repliquesLine: repliques,
            frappesLine: frappes,
            tempsLine: temps,
            actesLine: parts.isEmpty ? nil : parts.joined(separator: " · "),
            sparkline: ledger.lastDays(days).map(\.keystrokesSaved),
            sparklineCaption: "les \(days) derniers jours")
    }

    /// Durée humaine, arrondie et conservatrice : « moins d'1 min », « 6 min »,
    /// « 1 h 12 ». Jamais de fausse précision à la seconde.
    private static func formatDuration(_ seconds: Double) -> String {
        if seconds < 60 { return "moins d'1 min" }
        let mins = Int((seconds / 60).rounded())
        if mins < 60 { return "\(mins) min" }
        let h = mins / 60, m = mins % 60
        return m == 0 ? "\(h) h" : "\(h) h \(m)"
    }

    /// Recalcule l'état de l'icône vivante et ne touche l'image QUE s'il change.
    /// Appelé après chaque tick + au changement de capture. La priorité va au plus
    /// informatif : désactivée > capture (vie privée) > souffle > écoute > coulisse.
    private func refreshLivingIcon() {
        let state: IconState
        if !store.enabled {
            state = .disabled
        } else if iconTextFieldFocused && iconCapturingNow {
            state = .capturing
        } else if overlay.isVisible {
            souffleHoldUntil = Date().addingTimeInterval(Self.souffleHoldSeconds)
            state = .souffle
        } else if let until = souffleHoldUntil, until > Date() {
            state = .souffle
        } else if iconTextFieldFocused && predictor.isModelReady {
            state = .listening
        } else {
            state = .coulisse
        }
        applyIconState(state)
    }

    /// Applique une silhouette de bulle par état. Souffle = bulle pleine teintée
    /// bordeaux (accent livret, or en barre sombre) ; capture = œil bleu (signal
    /// orthogonal) ; coulisse/désactivée = bulle vide en sourdine.
    private func applyIconState(_ state: IconState) {
        guard let button = statusItem?.button, state != currentIconState else { return }
        currentIconState = state
        let symbol: String, tint: NSColor?, alpha: CGFloat
        var template = true
        switch state {
        case .disabled:  symbol = "bubble";           tint = nil; alpha = 0.35
        case .coulisse:  symbol = "bubble";           tint = nil; alpha = 0.55
        case .listening: symbol = "text.bubble";      tint = nil; alpha = 1.0
        case .souffle:   symbol = "text.bubble.fill"
                         tint = LivretPalette.accent(LivretPalette.isDark(button)); alpha = 1.0
        case .capturing: symbol = "eye.fill"; template = false; tint = .systemBlue; alpha = 1.0
        }
        if let img = NSImage(systemSymbolName: symbol, accessibilityDescription: "Souffleuse") {
            img.isTemplate = template
            button.image = img
            button.contentTintColor = tint
            button.alphaValue = alpha
        } else {
            button.image = nil
            button.title = state == .capturing ? "👁" : "S"
            button.alphaValue = alpha
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
        if onboarding == nil { onboarding = makeOnboardingWindow() }
        onboarding?.show()
    }

    #if DEBUG
    /// Affiche/masque l'inspecteur ghost (DEV). Crée la fenêtre au premier clic,
    /// branche le rafraîchissement live, et n'arme l'enregistrement (`isActive`)
    /// que tant qu'elle est visible — zéro overhead une fois masquée.
    @objc private func toggleGhostInspector() {
        let inspector: GhostInspectorWindow
        if let existing = ghostInspectorWindow {
            inspector = existing
        } else {
            inspector = GhostInspectorWindow()
            ghostInspectorWindow = inspector
            GhostInspector.shared.onChange = { [weak inspector] in
                inspector?.refresh(GhostInspector.shared.entries)
            }
        }
        let visible = inspector.toggle()
        GhostInspector.shared.isActive = visible
        if visible { inspector.refresh(GhostInspector.shared.entries) }
        ghostInspectorItem?.state = visible ? .on : .off
    }
    #endif

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

    /// Mesure la cadence de frappe réelle à partir de la croissance du texte entre
    /// deux polls (~80 ms). N'échantillonne que la frappe humaine continue : ignore
    /// les changements de champ/app, les suppressions, les pauses (> seuil) et les
    /// gros deltas (collage / injection d'un accept). Le résultat calibre « temps
    /// gagné » sur l'utilisateur plutôt que sur une moyenne générique.
    private func observeTypingCadence(text: String, bundleID: String) {
        let len = text.count
        defer { cadenceLastLen = len; cadenceLastBundle = bundleID }
        guard bundleID == cadenceLastBundle else {
            cadenceLastGrowthAt = Date()   // nouveau champ/app : (re)démarre l'horloge
            return
        }
        let now = Date()
        let delta = len - cadenceLastLen
        guard delta > 0 else {
            if delta < 0 { cadenceLastGrowthAt = now }   // suppression : on ne mesure pas
            return
        }
        if let last = cadenceLastGrowthAt {
            let gap = now.timeIntervalSince(last)
            if gap > 0,
               gap < SuggestionPolicy.Tuning.ledgerCadenceMaxGapSeconds,
               delta <= SuggestionPolicy.Tuning.ledgerCadenceMaxCharsPerSample {
                ledger.recordTyping(chars: delta, seconds: gap)
            }
        }
        cadenceLastGrowthAt = now
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
            self.refreshLivingIcon()
        }
    }

    private func tick() {
        guard store.enabled else { return }
        // Icône vivante : par défaut « pas de champ actif » ; repassé à vrai plus
        // bas une fois un champ texte éligible confirmé.
        iconTextFieldFocused = false
        // R1: pause pipeline whenever Souffleuse is the foreground app (Preferences,
        // Onboarding, or CustomInstructions key). Prevents predicting in our own UI
        // and avoids racing AX reads against our own SwiftUI text fields.
        if NSApp.isActive {
            overlay.hide()
            presenceHideNow()
            interceptor.setActive(false)
            return
        }
        // If AX still isn't trusted, hide the overlay and keep idling — the
        // status item stays visible so the user can see we're waiting.
        guard AXClient.isTrusted else {
            overlay.hide()
            presenceHideNow()
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
              !snap.isSearchField,
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
                else if snap.isSearchField { reason = "search_field" }
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
            // Échec AX transitoire (caret/elementRect nil ce tick) : on TIENT le
            // badge ancré pendant la grâce plutôt que de le faire clignoter.
            presenceHoldOrHide()
            interceptor.setActive(false)
            return
        }

        // Mesure passive de la cadence de frappe (croissance de texte entre deux
        // polls) — alimente l'estimation « temps gagné » du carnet. Hors de tout
        // gate de suggestion : on veut mesurer partout où l'utilisateur tape.
        observeTypingCadence(text: text, bundleID: bundleID)

        // Per-app allowlist override (after blocklist, before any prediction work).
        let allowMode = store.allowlist.mode(forBundle: bundleID, windowTitle: snap.windowTitle)
        if allowMode == .disabled {
            overlay.hide()
            presenceHideNow()
            interceptor.setActive(false)
            return
        }
        // Champ texte éligible et actif → « à l'écoute » (sauf si un ghost s'affiche
        // ou si la capture tourne, traité par priorité dans refreshLivingIcon).
        iconTextFieldFocused = true

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
            // Refill rolling en vol → l'annuler : il ciblerait l'ancien champ.
            cancelRollingRefill()
            // Ancre liée au bundle précédent → la jeter (réancrage au prochain ghost).
            clearGhostAnchor()
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
        // else the last reliable font we saw for this bundle (avoids feeding a
        // degenerate empty-line rect to estimatedFont), else nil — letting
        // `OverlayWindow` fall back to its conservative rect-height heuristic.
        // Only AX font + OCR calibration are considered reliable; the estimate
        // is never stored so the cache can never degrade.
        let hostFontForOverlay: NSFont? = {
            if let axFont = snap.caretFont {
                let font = NSFont(name: axFont.familyName, size: CGFloat(axFont.pointSize))
                    ?? .systemFont(ofSize: CGFloat(axFont.pointSize))
                lastReliableFontByBundle[bundleID] = font
                return font
            }
            if let metrics = caretResolver.calibration(for: bundleID) {
                let font = NSFont.systemFont(ofSize: metrics.fontPointSize)
                lastReliableFontByBundle[bundleID] = font
                return font
            }
            // Both reliable sources nil — reuse the last known font for this
            // bundle if available (typical on empty lines in Notes/TextEdit
            // where AX stops reporting the font).
            return lastReliableFontByBundle[bundleID]
        }()

        // We've cleared every gate: focused, AX-trusted, not blocklisted, real
        // text element. Anchor the presence badge to the field's top-left so
        // it stays put as the user types (Cotypist-style), only falling back
        // to the caret rect when the field rect isn't available.
        // Held back until `hasTypedSinceFocus` — keeps the badge from flashing
        // on Cmd+Tab drive-bys.
        if hasTypedSinceFocus {
            if let fieldRect = snap.elementRect {
                presenceShow(at: fieldRect)
            } else if let rect = rectForGhost {
                presenceShow(at: rect)
            } else {
                // Aucun rect ce tick alors qu'on est en train de taper : trou AX
                // transitoire (fin de mot) → on tient le badge au dernier rect.
                presenceHoldOrHide()
            }
        } else {
            presenceHideNow()
        }

        // Dismissed by Esc until text changes.
        if let dismissed = dismissedForText, dismissed == text {
            overlay.hide()
            presenceHideNow()
            interceptor.setActive(false)
            return
        }
        dismissedForText = nil

        // Reflect capture state in the menubar icon (lightweight async poll).
        Task { [weak self] in
            guard let self else { return }
            let cap = await self.enricher.isCapturing()
            await MainActor.run {
                self.iconCapturingNow = cap
                self.refreshLivingIcon()
            }
        }

        // Per-app enrichment policy: suggestionOnly disables enrichment for this
        // bundle without disabling the global toggle.
        let enrichmentAllowed = store.enrichmentEnabled && allowMode != .suggestionOnly
        let captureAllowedHere = store.captureEnabled && allowMode != .clipboardOnly

        // Refresh enrichment when the focused context materially changes:
        //   - bundle changes (focus moved to a different app) — always honoured
        //   - window title changes within the same bundle (typical browser tab
        //     switch) — honoured if at least `titleChangeRefireMinInterval`
        //     elapsed since the last refire, debouncing transient titles
        //     during page loads ("Loading…" → "Inbox · Intercom")
        //
        // First tick after a refire uses the cached prefix (which has been
        // cleared); subsequent ticks pick up the fresh snapshot once it
        // completes.
        let bundleChanged = bundleID != lastEnrichedBundleID
        let titleChanged = snap.windowTitle != lastEnrichedWindowTitle
        let elapsedSinceLast = Date().timeIntervalSince(lastEnrichmentAt)
        let shouldRefire = enrichmentAllowed && (
            bundleChanged ||
            (titleChanged && elapsedSinceLast >= Self.titleChangeRefireMinInterval)
        )
        if shouldRefire {
            lastEnrichedBundleID = bundleID
            lastEnrichedWindowTitle = snap.windowTitle
            lastEnrichmentAt = Date()
            cachedEnrichmentPrefix = ""
            lastEnrichedVisible = nil
            let appliedCapture = captureAllowedHere
            // Within-bundle title changes need an explicit cache invalidate —
            // `visibleCache` in ContextEnricher is keyed on bundleID only and
            // its 5s TTL would otherwise mask the new tab's content.
            let invalidate = titleChanged && !bundleChanged
            Task { [weak self] in
                guard let self else { return }
                if invalidate { await self.enricher.invalidate() }
                // Temporarily toggle capture for this snapshot if the rule says clipboard-only.
                await self.enricher.setCaptureEnabled(appliedCapture)
                let enriched = await self.enricher.snapshot(focusedFieldRect: snap.elementRect)
                // Restore global capture preference after the snapshot.
                await self.enricher.setCaptureEnabled(self.store.captureEnabled)
                await MainActor.run {
                    self.cachedEnrichmentPrefix = enriched.prefix
                    self.lastEnrichedVisible = enriched.visible
                }
            }
        } else if !enrichmentAllowed {
            cachedEnrichmentPrefix = ""
            lastEnrichedVisible = nil
            lastEnrichedBundleID = nil
            lastEnrichedWindowTitle = nil
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

        // Ghost lifecycle ("warm while composing"): a fresh keystroke rearms the
        // idle-unload timer and wakes the model on the FIRST keystroke if it
        // dozed off. Short search boxes never reach here — they fail the text gate
        // above via `isSearchField`, so no per-char warmup threshold is needed.
        manageGhostWarmth(prefix: prefix)

        // Mid-text suppression: when the character immediately after the caret
        // is a non-whitespace glyph, the user is editing INSIDE existing text,
        // not appending — the ghost would land in the wrong position and suggest
        // the wrong continuation. Hide immediately and bail.
        if Self.shouldSuppressForCaretContext(text: text, caretIndex: caretIndex) {
            overlay.hide()
            presenceHideNow()
            interceptor.setActive(false)
            return
        }

        // ── FENÊTRE GLISSANTE BIDIRECTIONNELLE (flag `midWordGhostRollingEnabled`) ──
        // SUPERSÈDE la live-consume forward-only ci-dessous quand une ancre est active
        // (même bundle, `ghostAnchorFull` non vide). Une SEULE règle de slice gère à la
        // fois la consommation avant (le préfixe grandit) ET la restauration arrière sur
        // backspace (le préfixe rétrécit), tant qu'on reste dans `[base, full)` :
        //
        //   • caret DANS la fenêtre  → ghost = suffixe de `ghostAnchorFull` après le
        //     préfixe courant. Rendu via la machinerie partialRemainder. SKIP predict.
        //   • effacé SOUS la borne gauche, fenêtre entièrement consommée, ou divergence
        //     (texte hors-chemin) → on jette l'ancre et on tombe dans le predict normal.
        //
        // Hors flag (default-OFF), ce bloc est entièrement court-circuité : le `guard`
        // sur le flag rend le chemin byte-identique à l'historique.
        if SuggestionPolicy.Tuning.midWordGhostRollingEnabled,
           !ghostAnchorFull.isEmpty,
           ghostAnchorBundle == bundleID {
            let lowerPrefix = prefix.lowercased()
            let lowerFull = ghostAnchorFull.lowercased()
            if lowerFull.hasPrefix(lowerPrefix),
               prefix.count >= ghostAnchorBase.count,
               prefix.count < ghostAnchorFull.count {
                // BACKSPACE / CONSO À L'INTÉRIEUR DE LA FENÊTRE (high-water).
                // `ghostAnchorFull` porte le HIGH-WATER MARK : sa partie GAUCHE jusqu'au
                // caret est le texte que l'UTILISATEUR a réellement tapé (capté en avant,
                // cf. la branche d'extension ci-dessous), sa partie DROITE est le ghost.
                // Reculer dans cette fenêtre restaure donc le texte de l'utilisateur lui-
                // même, pas une prédiction du modèle. On slice le suffixe et l'affiche,
                // SANS rétrécir `ghostAnchorFull` (le high-water tient). On reconstruit
                // l'état partialRemainder pour que refill rolling et accept repartent bon.
                // CE BLOC PASSE AVANT la suppression mid-mot backspace : un restore d'ancre
                // actif gagne toujours (return ici).
                let ghost = String(ghostAnchorFull.dropFirst(prefix.count))
                predictor.cancel()
                partialAcceptedAtPrefix = ghostAnchorBase
                partialAcceptedSoFar = String(ghostAnchorFull.prefix(prefix.count).dropFirst(ghostAnchorBase.count))
                partialAcceptedAtBundleID = bundleID
                partialRemainder = ghost
                if let rect = rectForGhost {
                    overlay.show(text: ghost, at: rect, hostText: text, caretIndex: caretIndex, hostFont: hostFontForOverlay)
                    interceptor.setActive(true)
                    maybeSpawnRollingRefill(committedText: prefix, bundleID: bundleID)
                } else {
                    overlay.hide()
                    interceptor.setActive(false)
                }
                return
            } else if lowerPrefix.hasPrefix(lowerFull),
                      prefix.count >= ghostAnchorBase.count {
                // FRAPPE EN AVANT QUI ÉTEND LE HIGH-WATER. Le préfixe a dépassé (ou égale)
                // `ghostAnchorFull` tout en restant SUR LE CHEMIN (`prefix` commence par
                // `ghostAnchorFull`). C'est exactement le cas où l'utilisateur tape un mot
                // qui DIVERGE de la prédiction du modèle mais constitue son PROPRE texte :
                // on capte ce texte dans le high-water. On met à jour
                // `ghostAnchorFull = prefix + ghost-courant` (gauche = texte tapé réel),
                // on GARDE `ghostAnchorBase` (borne gauche persistante), et on NE return
                // PAS : on laisse le predict gate plus bas générer/peindre un ghost frais
                // pour ce nouveau préfixe (qui ré-étendra le high-water via l'ancrage en
                // bas de tick). Le ghost-courant n'est pris que s'il a été produit POUR ce
                // préfixe exact ; sinon vide (la partie droite est rétablie au render).
                let currentGhost = (predictor.predictedForPrefix == prefix) ? predictor.suggestion : ""
                ghostAnchorFull = prefix + currentGhost
                // pas de return : tombe dans la suppression / predict gate.
            } else {
                // DIVERGENCE (préfixe hors-chemin du high-water) ou SOUS LA BORNE GAUCHE →
                // on jette l'ancre + tout reste de partial, et on tombe dans le predict
                // normal. La prochaine génération fraîche reposera une ancre.
                clearGhostAnchor()
                if !partialRemainder.isEmpty {
                    partialRemainder = ""
                    partialAcceptedSoFar = ""
                    partialAcceptedAtPrefix = ""
                    partialAcceptedAtBundleID = nil
                }
                cancelRollingRefill()
                Log.info(.predictor, "ghost_anchor_cleared")
                // Pas de hide ici (anti-blank-frame) : le predict gate plus bas
                // repeindra, ou un fresh ghost réancrera.
            }
        }

        // ── SUPPRESSION MID-MOT EN BACKSPACE (flag `midWordGhostRollingEnabled`) ──
        // « Compléter ce qu'on TAPE, pas ce qu'on EFFACE. » Quand l'utilisateur
        // recule à travers un mot ("je suis"→"je sui"→"je su"), le fragment de
        // queue est mid-mot : le long-ghost le « guérirait » et re-taperait le mot
        // qu'on est en train de supprimer (perçu comme la fenêtre qui glisse à
        // gauche). On SUPPRIME alors le ghost pour ce tick (hide + interceptor off,
        // pas de predict). Conditions cumulées :
        //   • on RECULE in-place (préfixe rétrécit ET reste préfixe de l'ancien —
        //     exclut un switch d'app/contexte) ;
        //   • le mot de queue est un run de lettres NON VIDE (caret mid-mot, pas à
        //     une frontière) ET n'est PAS un mot complet.
        // On NE supprime PAS à une frontière (espace/ponctuation, ou mot complet) :
        // là un next-word ghost ("je " → autre chose) est légitime. Ce bloc passe
        // APRÈS l'anchor-slice (un restore d'ancre actif gagne donc : effacer
        // "enceinte" dans la fenêtre restaure toujours) et AVANT le predict gate.
        // Hors flag, la garde court-circuite tout ⇒ byte-identique (seule la var
        // `lastTickPrefixForDelete` est écrite, sans effet observable).
        if SuggestionPolicy.Tuning.midWordGhostRollingEnabled {
            let isBackspacing = !lastTickPrefixForDelete.isEmpty
                && prefix.count < lastTickPrefixForDelete.count
                && lastTickPrefixForDelete.hasPrefix(prefix)
            lastTickPrefixForDelete = prefix
            let trailingFragment = OutputFilter.trailingPartialWord(prefix)
            let isIncompleteFragment = !trailingFragment.isEmpty
                && !SuggestionPolicy.defaultPartialWordIsComplete(prefix)
            if isBackspacing, isIncompleteFragment {
                overlay.hide()
                interceptor.setActive(false)
                predictor.cancel()
                lastPredictedPrefix = nil
                Log.info(.predictor, "ghost_backspace_suppress")
                return
            }
        }

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
           predictor.predictedForPrefix == basePrefix,
           prefix.count > basePrefix.count,
           prefix.hasPrefix(basePrefix) {
            let typedSince = String(prefix.dropFirst(basePrefix.count))
            // Case-insensitive match: typing "Bonjour" should still consume
            // a ghost starting with "bonjour" (and vice versa). The user's
            // typed casing wins in the rendered text (AX writes verbatim);
            // only the matching logic ignores case.
            // ANTI-FLICKER (revertable — see note below). We used to also require
            // `!isStaleMidWordCompletion` here, which forced a hide+re-predict on
            // EVERY keystroke into a "word-completion + tail" ghost — now the
            // common case with the corpus (e.g. "achète du Bitcoin."). That blinked
            // the tail on each letter. We now let these enter the smooth
            // partial-remainder consume too: a correctly-guessed word consumes
            // letter-by-letter with no flicker, and a *wrong* guess ("envi" →
            // "es de manger" while the user types "envie ") still self-corrects —
            // the divergence break in the partial-remainder block below re-predicts.
            // Trade-off: on a wrong guess the stale tail shows for ~1 keystroke
            // before the divergence swap, instead of being hidden.
            // TO REVERT: re-add `&& !Self.isStaleMidWordCompletion(basePrefix:
            // basePrefix, ghost: predictor.suggestion)` to the condition below.
            if Self.isLiveConsumeMatch(ghost: predictor.suggestion, typedSince: typedSince) {
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
                    // ── ROLLING REFILL (mode sliding-window, flag OFF par défaut) ──
                    // Si le reste affiché descend SOUS le plancher de mots, on GÉNÈRE
                    // les mots suivants à droite pendant que l'utilisateur consomme à
                    // gauche → fenêtre glissante qui ne se vide jamais. Le reste
                    // courant reste affiché ; les mots générés l'étendront au prochain
                    // tick render. Jamais de hide pendant le refill.
                    maybeSpawnRollingRefill(committedText: expected, bundleID: bundleID)
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
            // Chars between the word's end and the caret (the typo can fire after
            // a trailing space). `prefix` ends at the caret, so this is that gap.
            let trailing = String(prefix[typo.range.upperBound...])
            // A word followed by a separator is "done" → correct immediately. A
            // word at end-of-string may still be in progress → debounce so we
            // don't flash a correction for each incomplete prefix while typing.
            if trailing.isEmpty {
                let settleKey = typo.original + "\u{1}" + String(prefix.count)
                if settleKey != typoSettleKey {
                    typoSettleKey = settleKey
                    typoSettleSince = Date()
                }
                let settled = typoSettleSince.map { Date().timeIntervalSince($0) >= Self.typoDebounce } ?? false
                if !settled {
                    // Still settling: suppress (no flash) and don't predict on a
                    // suspected mid-word typo. Hide any prior typo ghost.
                    if currentTypo != nil {
                        overlay.hide()
                        interceptor.setActive(false)
                        currentTypo = nil
                    }
                    return
                }
            }
            let isNewSuggestion = currentTypo != typo
            currentTypo = typo
            currentTypoTrailing = trailing
            predictor.cancel()
            lastPredictedPrefix = nil
            if let rect = rectForGhost {
                // Render once per new suggestion: the panel persists across the
                // identical re-detections on subsequent ticks (currentTypo stays
                // equal), so re-painting — and re-querying AX bounds — every tick
                // is wasted. Any non-typo branch resets currentTypo, which makes
                // the next typo tick "new" again and re-renders.
                if isNewSuggestion {
                    renderTypoSuggestion(
                        typo,
                        prefix: prefix,
                        caretRect: rect,
                        text: text,
                        caretIndex: caretIndex,
                        font: hostFontForOverlay
                    )
                    Log.info(.input, "typo_suggested")
                }
                interceptor.setActive(true)
            }
            return
        }
        currentTypo = nil
        typoSettleKey = nil

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
        // Freshness gate: only paint a suggestion that was generated for THIS
        // exact prefix. `predictor.suggestion` can outlive the prefix it was made
        // for — kept alive through a gating path while a fresh stream is pending
        // — and without this check it gets painted at the new caret (the
        // "Bonjour" repro: a start-of-message ghost re-shown at "…autre chose
        // pou"). The pending re-prediction repaints once it lands.
        guard Self.shouldRenderSuggestion(suggestion: suggestion,
                                          predictedForPrefix: predictor.predictedForPrefix,
                                          currentPrefix: prefix),
              let rect = rectForGhost else {
            overlay.hide()
            interceptor.setActive(false)
            return
        }

        // Ground-truth render trace (dev only, same env var as PredictDebug):
        // logs the EXACT ghost painted at the caret, distinct from what the LLM
        // merely generated. Lets us see what the user actually saw vs what the
        // gates suppressed.
        if ProcessInfo.processInfo.environment["SOUFFLEUSE_PREDICT_LOG"]?.isEmpty == false {
            let tail = String(prefix.suffix(40))
            let line = "[\(ISO8601DateFormatter().string(from: Date()))] overlay_shown userTail=\(tail.debugDescription) ghost=\(suggestion.debugDescription)\n"
            if let data = line.data(using: .utf8) {
                let path = "/tmp/souffleuse-predict.log"
                if let h = FileHandle(forWritingAtPath: path) {
                    h.seekToEndOfFile(); try? h.write(contentsOf: data); try? h.close()
                } else { FileManager.default.createFile(atPath: path, contents: data) }
            }
        }

        overlay.show(text: suggestion, at: rect, hostText: text, caretIndex: caretIndex, hostFont: hostFontForOverlay)
        interceptor.setActive(true)

        // ── ANCRAGE D'UNE GÉNÉRATION FRAÎCHE (flag `midWordGhostRollingEnabled`) ──
        // On vient de peindre une suggestion produite POUR le préfixe courant
        // (`predictedForPrefix == prefix`, garanti par `shouldRenderSuggestion`). Si le
        // mode rolling est ON et que ce n'est pas déjà l'ancre courante, on pose la
        // borne gauche ici : base = préfixe qui a produit le ghost, full = base + ghost.
        // Tout backspace ultérieur jusqu'à `base` restaurera le ghost via le slice.
        if SuggestionPolicy.Tuning.midWordGhostRollingEnabled {
            let freshBase = predictor.predictedForPrefix
            let freshFull = freshBase + suggestion
            // HIGH-WATER : si une ancre est DÉJÀ active, sur le même bundle, et que la
            // base de cette prédiction est SUR LE CHEMIN du high-water courant (la base
            // étend `ghostAnchorFull` ou reste dans la fenêtre depuis `ghostAnchorBase`),
            // on GARDE la borne gauche persistante `ghostAnchorBase` et on étend seulement
            // `ghostAnchorFull` (la partie gauche jusqu'à `freshBase` reste le texte tapé
            // par l'utilisateur, déjà capté). On ne repose une base NEUVE que si l'ancre
            // est inactive, hors bundle, ou hors-chemin (vraie divergence/reset).
            let lowerFresh = freshBase.lowercased()
            let onPathOfHighWater = !ghostAnchorFull.isEmpty
                && ghostAnchorBundle == bundleID
                && freshBase.count >= ghostAnchorBase.count
                && (ghostAnchorFull.lowercased().hasPrefix(lowerFresh)
                    || lowerFresh.hasPrefix(ghostAnchorFull.lowercased()))
            if onPathOfHighWater {
                if ghostAnchorFull != freshFull {
                    ghostAnchorFull = freshFull
                    Log.info(.predictor, "ghost_anchor_set")
                }
            } else if ghostAnchorFull != freshFull || ghostAnchorBase != freshBase || ghostAnchorBundle != bundleID {
                ghostAnchorBase = freshBase
                ghostAnchorFull = freshFull
                ghostAnchorBundle = bundleID
                Log.info(.predictor, "ghost_anchor_set")
            }
        }
    }

    /// Paint a typo suggestion in place, Cotypist-style: a red strike over the
    /// real misspelled word + the green suggestion after.
    ///
    /// Two ways to locate the word's screen rect:
    /// - **AX `AXBoundsForRange`** — pixel-perfect, native AppKit hosts (Notes,
    ///   TextEdit, Mail). Synchronous on main, consistent with the per-tick
    ///   `axClient.snapshot()`, and fires only on a *new* suggestion.
    /// - **Geometric estimate** — when AX gives no genuine word box (Chromium/
    ///   WebKit refuse range bounds; their marker walk resolves whole-line boxes).
    ///   We derive the word rect from the reliable caret rect minus the measured
    ///   width of the word and the separators between it and the caret.
    private func renderTypoSuggestion(
        _ typo: TypoSuggestion,
        prefix: String,
        caretRect: CGRect,
        text: String,
        caretIndex: Int,
        font: NSFont?
    ) {
        // AX text ranges are UTF-16; convert the word's range (indices into
        // `prefix`, which is a prefix of the element's value) to UTF-16 offsets.
        let utf16Loc = prefix.utf16.distance(from: prefix.utf16.startIndex, to: typo.range.lowerBound)
        let utf16Len = typo.original.utf16.count
        let wordRect = axClient.boundsForFocusedRange(location: utf16Loc, length: utf16Len)

        if let wordRect, OverlayWindow.isUsableWordRect(wordRect) {
            overlay.showCorrection(
                original: typo.original,
                suggestion: typo.suggestion,
                atWordRectQuartz: wordRect,
                font: font
            )
        } else {
            // Separators between the word's end and the caret (usually "" or a
            // single space) — measured so the estimated word rect lands flush.
            let separator = String(prefix[typo.range.upperBound...])
            overlay.showCorrectionEstimated(
                original: typo.original,
                suggestion: typo.suggestion,
                separatorAfterWord: separator,
                caretRectQuartz: caretRect,
                font: font
            )
        }
    }

    // MARK: - Key handling (runs on the CGEventTap thread)

    nonisolated private func handleKey(_ key: KeyInterceptor.Key) -> Bool {
        // Pick up either a pending typo correction, an in-flight partial
        // remainder, or the freshly streamed LLM suggestion (in that order).
        // Typo wins because its ghost overrides the LLM ghost in tick().
        // `partialRemainder` wins over `predictor.suggestion` because we cancel
        // the predictor between chunks — its `suggestion` is empty during a
        // partial run.
        let pending: (typo: TypoSuggestion?, trailing: String, llm: String, isPartial: Bool) = MainActor.assumeIsolated {
            if !partialRemainder.isEmpty {
                return (currentTypo, currentTypoTrailing, partialRemainder, true)
            }
            return (currentTypo, currentTypoTrailing, predictor.suggestion, false)
        }
        if pending.typo == nil, pending.llm.isEmpty { return false }

        switch key {
        case .tab:
            if let typo = pending.typo {
                // Delete the word + any trailing separators between it and the
                // caret, re-inserting `suggestion + trailing` so the fix lands
                // flush even when the typo fired after a space.
                let count = typo.original.count + pending.trailing.count
                let replacement = typo.suggestion + pending.trailing
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
                    // handleKey is dispatched onto the main thread (the tap now
                    // runs on a dedicated thread and hops here via
                    // `DispatchQueue.main.async`), so this whole body runs as
                    // ONE synchronous main-thread unit. Update the partial-accept
                    // state SYNCHRONOUSLY here — a further `DispatchQueue.main.async`
                    // would let the tick fire in between, see `partialRemainder`
                    // still empty, and re-fire a fresh prediction instead of
                    // consuming the remainder. That's how "Tab Tab Tab" was
                    // producing new words each press instead of walking the
                    // cached suggestion.
                    MainActor.assumeIsolated {
                        self.ledger.recordAccepted(charsSaved: chunk.count - 1)
                        if isPartialContinuation {
                            self.partialAcceptedSoFar += chunk
                        } else {
                            self.partialAcceptedAtPrefix = prePrefix
                            self.partialAcceptedAtBundleID = bundleID
                            self.partialAcceptedSoFar = chunk
                        }
                        if isLast {
                            // Dernier chunk = ligne entièrement acceptée. Garde la
                            // borne gauche, étend `ghostAnchorFull` au texte committé
                            // (préfixe d'ancrage + tout l'accepté) pour qu'un
                            // effacement restaure encore la ligne. NE PAS effacer
                            // l'ancre ici.
                            self.extendGhostAnchorOnAccept(
                                committedFullText: self.partialAcceptedAtPrefix + self.partialAcceptedSoFar,
                                bundleID: self.partialAcceptedAtBundleID)
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
                // Corpus hygiene (V2): never record a context-BLIND Layer-0
                // word-completer accept ("Rapport fis"→"ton"/"fiston",
                // "impe"→"impeccable"). These are NSSpellChecker dictionary
                // completions, not the user's own phrasing — recording them
                // pollutes the corpus with short single-word fragments that the
                // unbeatable strongCorpusMatch later recalls as junk. Only the
                // user's real continuations (LLM / history / cache accepts) earn
                // a corpus entry.
                if predictor.suggestionSource == .wordComplete { return false }
                return true
            }
            if recordPersonalization {
                let storedContext = SecretHeuristic.contextTail(prefix: prePrefix)
                let entry = TypingHistoryEntry(
                    timestamp: Date(),
                    contextBefore: storedContext,
                    accepted: suggestion,
                    bundleID: bundleID,
                    midWordContinuation: deriveMidWordContinuation(
                        contextBefore: storedContext,
                        accepted: suggestion
                    )
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
                self.ledger.recordAccepted(charsSaved: suggestion.count - 1)
                // Accept Tab plein : garde la borne gauche, étend `ghostAnchorFull`
                // au texte committé (`prePrefix + suggestion`) pour qu'un effacement
                // restaure encore la ligne. Ne PAS avancer la base sur Tab.
                self.extendGhostAnchorOnAccept(committedFullText: prePrefix + suggestion, bundleID: bundleID)
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
                    // Rejet explicite → jeter l'ancre : on ne veut pas qu'un
                    // backspace restaure le ghost que l'utilisateur vient de refuser.
                    self.clearGhostAnchor()
                    self.cancelRollingRefill()
                    self.lastPredictedPrefix = nil
                    self.overlay.hide()
                    self.interceptor.setActive(false)
                }
            }
            return true

        case .acceptAll:
            // Accept the ENTIRE remaining ghost in one press (vs Tab =
            // word-by-word). Bound to the user-selected key (Preferences →
            // acceptAllKey). `pending.llm` is the partial remainder if a
            // partial accept is in flight, else the full streamed suggestion.
            if let typo = pending.typo {
                let count = typo.original.count + pending.trailing.count
                let replacement = typo.suggestion + pending.trailing
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
            let preSnap = axClient.snapshot()
            let preCaret = preSnap.caretIndex ?? 0
            let prePrefix = preSnap.text.map { String($0.prefix(preCaret)) } ?? ""
            let bundleID = preSnap.bundleID
            // Consuming the whole ghost — clear any in-flight partial state.
            MainActor.assumeIsolated {
                self.partialRemainder = ""
                self.partialAcceptedSoFar = ""
                self.partialAcceptedAtPrefix = ""
                self.partialAcceptedAtBundleID = nil
            }
            Log.info(.input, "ghost_accepted_full")
            return performFullAccept(suggestion: suggestion, prePrefix: prePrefix, bundleID: bundleID)

        case .commit:
            // Vraie traduction visible. On lit le champ, on rend la main au ghost
            // (teardown), puis on stream la traduction FR→cible dans un petit
            // panneau et on remplace le champ. La CIBLE (P5) est résolue ici : une
            // sélection FIXE posée à la touche de cycle l'emporte ; sinon AUTO suit
            // la langue détectée du correspondant (capture ON) ; sinon EN. Le tap
            // n'étant actif que pendant qu'un ghost s'affiche, ⌘↩ n'est intercepté
            // que dans ce cas.
            let snap = axClient.snapshot()
            let current = snap.text ?? ""
            let rect = snap.elementRect
            let bundleID = snap.bundleID
            let windowTitle = snap.windowTitle
            Log.info(.input, "translate_commit_start")
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                let selection = self.currentTargetSelection(
                    forBundle: bundleID, windowTitle: windowTitle)
                let context = self.lastEnrichedVisible ?? ""
                let detected = TranslationTarget.detected(in: context)
                let frCorrespondent = TranslationTarget.correspondentSpeaksFrench(in: context)
                let action = selection.action(detected: detected, correspondentIsFrench: frCorrespondent)
                self.predictor.cancel()
                self.lastPredictedPrefix = nil
                self.overlay.hide()
                self.interceptor.setActive(false)
                // Aiguillage P-relecture : si le correspondant parle français (ou si
                // l'utilisateur a posé FR↺ au cycle) on RELIT le message FR selon le
                // ton de l'app ; sinon on traduit vers la cible. Même panneau, même
                // moteur instruct, même garde-fou.
                switch action {
                case .translate(let target):
                    self.runTranslationCommit(frenchText: current, fieldRect: rect, target: target, bundleID: bundleID)
                case .reformulate:
                    let tone = self.store.tones.tone(forBundle: bundleID)
                    self.runReformulateCommit(frenchText: current, fieldRect: rect, tone: tone, bundleID: bundleID)
                }
            }
            return true

        case .cycleTarget:
            // Fait défiler la langue cible (EN→ES→DE→IT→AUTO) pour la conversation
            // courante et FLASHE la nouvelle cible dans le panneau, SANS traduire :
            // l'utilisateur choisit pendant qu'il compose, puis valide au commit.
            // Persisté par conversation (bundleID + titre de fenêtre).
            let snap = axClient.snapshot()
            let rect = snap.elementRect
            let bundleID = snap.bundleID
            let windowTitle = snap.windowTitle
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                let selection = self.store.conversationTargets.cycle(
                    forBundle: bundleID, windowTitle: windowTitle)
                // Un choix explicite devient la vérité COURANTE : il fera autorité
                // au commit même si le titre de fenêtre a dérivé entre-temps.
                self.liveTargetSelection = (bundleID ?? "?", selection, Date())
                Log.info(.input, "translate_target_cycled")
                self.flashTargetSelection(selection, fieldRect: rect, bundleID: bundleID)
            }
            return true
        }
    }

    /// Décalage de position du HUD mémorisé pour cette app (§3b), `.zero` si jamais
    /// déplacé.
    private func hudSavedOffset(forBundle bundleID: String?) -> CGSize {
        guard let bid = bundleID, let a = store.hudAnchors.anchor(forBundle: bid) else { return .zero }
        return CGSize(width: a.offsetX, height: a.offsetY)
    }

    /// Sélection de traduction COURANTE au commit. Une cible cyclée à la main et
    /// encore fraîche (état vivant, même `bundleID`, < `liveTargetSelectionTTL`)
    /// fait AUTORITÉ — un choix explicite ne doit jamais être perdu parce que le
    /// titre de fenêtre a dérivé entre le cycle et le commit (compteurs de non-lus,
    /// sujet). À défaut, on retombe sur le store par conversation (persistance
    /// cross-session / multi-thread), dont la clé est désormais normalisée.
    private func currentTargetSelection(forBundle bundleID: String?, windowTitle: String?) -> TargetSelection {
        if let live = liveTargetSelection,
           live.bundleID == (bundleID ?? "?"),
           Date().timeIntervalSince(live.at) < Self.liveTargetSelectionTTL {
            return live.selection
        }
        return store.conversationTargets.selection(forBundle: bundleID, windowTitle: windowTitle)
    }

    /// Affiche la cible choisie dans le panneau de traduction, sans lancer de
    /// traduction. Même cycle de vie robuste que le commit (`scheduleAutoHide`) :
    /// reste affiché, ne disparaît pas tant qu'on le survole → on peut le saisir
    /// et le déplacer même en cyclant la langue. Un commit (⌘↩) reprend la main.
    private func flashTargetSelection(_ selection: TargetSelection, fieldRect: CGRect?, bundleID: String?) {
        let anchor = fieldRect ?? .zero
        let header: String
        switch selection {
        case .auto: header = "Cible : AUTO (langue détectée)"
        case .fixed(let t): header = "Cible : FR → \(t.code)"
        case .reformulate: header = "Relecture : FR (réécriture selon le ton de l'app)"
        }
        translationHUD.show(at: anchor, header: header, body: "⌘⇧→ changer · ⌘↩ traduire",
                            savedOffset: hudSavedOffset(forBundle: bundleID), bundleID: bundleID)
        translationHUD.scheduleAutoHide(after: SuggestionPolicy.Tuning.translationHUDVisibleSeconds)
    }

    /// Injects the ENTIRE `suggestion` at once, records it to personalization
    /// (opt-in, gated exactly like the Tab full-accept), and tears down the
    /// ghost. Used by the configurable accept-all key. Returns true (consumed).
    nonisolated private func performFullAccept(suggestion: String, prePrefix: String, bundleID: String?) -> Bool {
        let recordPersonalization: Bool = MainActor.assumeIsolated {
            guard store.personalizationEnabled, let bid = bundleID else { return false }
            if bundleBlocklist.contains(bid) { return false }
            if personalizationBundleBlocklist.contains(where: { bid == $0 || bid.hasPrefix($0) }) { return false }
            if predictor.suggestionSource == .wordComplete { return false }
            return true
        }
        if recordPersonalization {
            let storedContext = SecretHeuristic.contextTail(prefix: prePrefix)
            let entry = TypingHistoryEntry(
                timestamp: Date(),
                contextBefore: storedContext,
                accepted: suggestion,
                bundleID: bundleID,
                midWordContinuation: deriveMidWordContinuation(
                    contextBefore: storedContext,
                    accepted: suggestion
                )
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
            let snap = axClient.snapshot()
            DispatchQueue.main.async { [weak self] in
                self?.dismissedForText = snap.text ?? ""
            }
        }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.ledger.recordAccepted(charsSaved: suggestion.count - 1)
            // acceptAll = ligne entière acceptée. Garde la borne gauche, étend
            // `ghostAnchorFull` au texte committé pour qu'un effacement la restaure.
            self.extendGhostAnchorOnAccept(committedFullText: prePrefix + suggestion, bundleID: bundleID)
            self.predictor.cancel()
            self.lastPredictedPrefix = nil
            self.overlay.hide()
            self.interceptor.setActive(false)
        }
        return true
    }

    /// Vraie traduction visible : affiche un petit panneau, charge le moteur
    /// instruct (paresseux, 1er appel ~1-2 s), stream FR→`target` dedans, puis
    /// remplace le champ via `replaceForCommit` (chemin validé Electron/AZERTY).
    /// La cible est résolue en amont (sélection fixe / AUTO détecté / EN) ; le
    /// panneau drag/persistance reste Phase 3b.
    private func runTranslationCommit(frenchText: String, fieldRect: CGRect?, target: TranslationTarget, bundleID: String?) {
        let text = frenchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        // On va réutiliser le moteur instruct : annule un déchargement-idle en
        // attente pour ne pas le libérer en plein usage (Phase 7).
        translationIdleUnloadTask?.cancel()
        // `show` ci-dessous annule déjà l'auto-masquage d'un flash de cible en
        // attente : le panneau appartient désormais à la traduction.
        let anchor = fieldRect ?? .zero
        translationHUD.show(at: anchor, header: "FR → \(target.code) · traduction…", body: "…",
                            savedOffset: hudSavedOffset(forBundle: bundleID), bundleID: bundleID)
        // Priorité basse : la traduction « a le droit de traîner », elle ne doit
        // pas voler un thread/priorité au ghost FR (§2.9).
        Task(priority: .utility) { @MainActor [weak self] in
            guard let self else { return }
            final class Acc: @unchecked Sendable { var s = "" }
            let acc = Acc()
            let metrics = await self.translationRuntime.translate(text, into: target) { piece in
                acc.s += piece
                let partial = GemmaChatPrompt.cleanCompletion(acc.s)
                Task { @MainActor in self.translationHUD.update(partial) }
                return true
            }
            let output = GemmaChatPrompt.cleanCompletion(acc.s)
            guard metrics != nil, !output.isEmpty else {
                self.translationHUD.update("⚠︎ modèle de traduction indisponible")
                self.translationHUD.scheduleAutoHide(after: 3)
                return
            }
            self.translationHUD.update(output)
            // Garde-fou C : signale les tokens durs (chiffres, montants, termes,
            // noms propres) disparus dans la traduction — zéro appel LLM.
            let missing = TermSurvivalGuard.missingTokens(source: text, translation: output)
            if let summary = TermSurvivalGuard.badgeSummary(for: missing) {
                self.translationHUD.setBadge("⚠︎ à vérifier : \(summary)")
                Log.info(.input, "translate_guard_flagged")
            }
            // Remplace le champ entier par la traduction.
            let axClient = self.axClient
            let deleteCount = frenchText.count
            DispatchQueue.global(qos: .userInitiated).async {
                axClient.replaceForCommit(deleteChars: deleteCount, with: output)
                let s = axClient.snapshot()
                DispatchQueue.main.async { [weak self] in self?.dismissedForText = s.text ?? "" }
            }
            Log.info(.input, "translate_commit_done")
            self.ledger.recordTranslation()
            // Le panneau reste affiché ~6 s (réglable), en fondu — assez pour lire
            // et pour le saisir/déplacer. Le survol souris suspend le compte ; un
            // déplacement l'épingle. Toute la logique vit dans le panneau.
            self.translationHUD.scheduleAutoHide(after: SuggestionPolicy.Tuning.translationHUDVisibleSeconds)
            // Programme le déchargement mémoire du moteur instruct après une
            // période d'inactivité (Phase 7) : en régime « pas de traduction » la
            // RAM du 2e moteur retombe à zéro sur la machine 8 Go.
            self.scheduleTranslationIdleUnload()
        }
    }

    /// Relecture FR→FR visible : même chemin que `runTranslationCommit`, mais le
    /// moteur instruct RÉÉCRIT le message français selon le `tone` de l'app au lieu
    /// de traduire. Panneau, garde-fou, remplacement de champ et déchargement-idle
    /// strictement identiques.
    private func runReformulateCommit(frenchText: String, fieldRect: CGRect?, tone: Tone, bundleID: String?) {
        let text = frenchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        translationIdleUnloadTask?.cancel()
        let anchor = fieldRect ?? .zero
        translationHUD.show(at: anchor, header: "FR ↺ relecture · \(tone.displayName)…", body: "…",
                            savedOffset: hudSavedOffset(forBundle: bundleID), bundleID: bundleID)
        Task(priority: .utility) { @MainActor [weak self] in
            guard let self else { return }
            final class Acc: @unchecked Sendable { var s = "" }
            let acc = Acc()
            let metrics = await self.translationRuntime.reformulate(text, tone: tone) { piece in
                acc.s += piece
                let partial = GemmaChatPrompt.cleanCompletion(acc.s)
                Task { @MainActor in self.translationHUD.update(partial) }
                return true
            }
            let output = GemmaChatPrompt.cleanCompletion(acc.s)
            guard metrics != nil, !output.isEmpty else {
                self.translationHUD.update("⚠︎ modèle de relecture indisponible")
                self.translationHUD.scheduleAutoHide(after: 3)
                return
            }
            self.translationHUD.update(output)
            // Garde-fou C : même réécriture FR→FR ne doit pas perdre un chiffre,
            // un montant ou un nom propre — zéro appel LLM.
            let missing = TermSurvivalGuard.missingTokens(source: text, translation: output)
            if let summary = TermSurvivalGuard.badgeSummary(for: missing) {
                self.translationHUD.setBadge("⚠︎ à vérifier : \(summary)")
                Log.info(.input, "reformulate_guard_flagged")
            }
            let axClient = self.axClient
            let deleteCount = frenchText.count
            DispatchQueue.global(qos: .userInitiated).async {
                axClient.replaceForCommit(deleteChars: deleteCount, with: output)
                let s = axClient.snapshot()
                DispatchQueue.main.async { [weak self] in self?.dismissedForText = s.text ?? "" }
            }
            Log.info(.input, "reformulate_commit_done")
            self.ledger.recordReformulation()
            self.translationHUD.scheduleAutoHide(after: SuggestionPolicy.Tuning.translationHUDVisibleSeconds)
            self.scheduleTranslationIdleUnload()
        }
    }

    /// (Re)programme la libération du moteur instruct après
    /// `translationIdleUnloadSeconds` sans nouvelle traduction. Chaque commit
    /// annule le précédent timer ; le prochain `translate` rechargera
    /// paresseusement (~1-2 s) si besoin.
    @MainActor
    private func scheduleTranslationIdleUnload() {
        translationIdleUnloadTask?.cancel()
        let seconds = SuggestionPolicy.Tuning.translationIdleUnloadSeconds
        translationIdleUnloadTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds) * 1_000_000_000)
            guard !Task.isCancelled, let self else { return }
            await self.translationRuntime.unload()
            Log.info(.predictor, "translate_idle_unload")
        }
    }

    /// Garde le moteur ghost « chaud » uniquement pendant que l'utilisateur
    /// compose. Appelé à chaque tick passé le gate de frappe (donc déjà un champ
    /// texte NON-recherche : les zones de recherche échouent au gate en amont et
    /// n'arrivent jamais ici). Une frappe fraîche (prefix changé depuis le tick
    /// précédent) réarme le timer d'idle-unload et réveille le modèle endormi
    /// **dès la 1ʳᵉ frappe** — la ~1 s de reload recouvre le premier mot.
    @MainActor
    private func manageGhostWarmth(prefix: String) {
        let typingNow = (prefix != lastGhostActivityPrefix)
        lastGhostActivityPrefix = prefix
        guard typingNow else { return }
        scheduleGhostIdleUnload()
        if !predictor.isModelReady {
            loadGhostIfNeeded()
        }
    }

    /// (Re)programme le déchargement du moteur ghost après
    /// `ghostIdleUnloadSeconds` sans frappe. Chaque keystroke annule le timer
    /// précédent, donc on ne décharge qu'après une vraie pause — ce qui survit
    /// aux pauses de réflexion en milieu de phrase mais rend la RAM dès qu'on
    /// passe à autre chose (lecture, app non-texte, idle).
    /// Affiche le badge et réarme l'anti-blink (rect valide ce tick).
    private func presenceShow(at rect: CGRect) {
        lastPresenceFieldRect = rect
        presenceMissTicks = 0
        presence.show(at: rect)
    }

    /// Disparition TRANSITOIRE (snapshot AX vide ce tick) : on garde le badge
    /// ancré au dernier rect connu pendant la fenêtre de grâce, puis on cache.
    private func presenceHoldOrHide() {
        if let last = lastPresenceFieldRect, presenceMissTicks < Self.presenceGraceTicks {
            presenceMissTicks += 1
            presence.show(at: last)
        } else {
            presenceHideNow()
        }
    }

    /// Disparition LÉGITIME (notre UI au premier plan, app désactivée, Esc,
    /// idle-unload) : cache immédiatement et oublie le dernier rect.
    private func presenceHideNow() {
        lastPresenceFieldRect = nil
        presenceMissTicks = 0
        presence.hide()
    }

    @MainActor
    private func scheduleGhostIdleUnload() {
        ghostIdleUnloadTask?.cancel()
        let seconds = SuggestionPolicy.Tuning.ghostIdleUnloadSeconds
        ghostIdleUnloadTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds) * 1_000_000_000)
            guard !Task.isCancelled, let self else { return }
            self.ghostIdleUnloadTask = nil
            guard self.predictor.isModelReady else { return }
            await self.predictor.unloadModel()
            self.overlay.hide()
            self.presenceHideNow()
            self.interceptor.setActive(false)
            Log.info(.predictor, "ghost_idle_unload")
        }
    }

    /// Recharge paresseusement le moteur ghost (~1 s) puis reconstruit le n-gram
    /// perso en tâche de fond (raffinement — le ghost de base fonctionne sans).
    /// Idempotent : un seul rechargement à la fois, et no-op si déjà résident.
    @MainActor
    private func loadGhostIfNeeded() {
        guard ghostLoadTask == nil, !predictor.isModelReady else { return }
        ghostLoadTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.predictor.loadModel()
            Log.info(.predictor, "ghost_warm_reload")
            let entries = await self.store.history.allEntries()
            await self.predictor.rebuildPersonalization(from: entries)
            self.ghostLoadTask = nil
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
        let storedContext = SecretHeuristic.contextTail(prefix: partialAcceptedAtPrefix)
        let entry = TypingHistoryEntry(
            timestamp: Date(),
            contextBefore: storedContext,
            accepted: partialAcceptedSoFar,
            bundleID: bid,
            midWordContinuation: deriveMidWordContinuation(
                contextBefore: storedContext,
                accepted: partialAcceptedSoFar
            )
        )
        let history = self.store.history
        let predictorRef = self.predictor
        Task { [history, predictorRef, entry] in
            await history.append(entry)
            await predictorRef.ingestAccepted(entry)
        }
    }

    /// Records a field's raw text into the corpus as a `.prose` entry. Fires on
    /// focus change with the PREVIOUS field's final text. Gated by the
    /// personalization master toggle + blocklists, a minimum length (a real
    /// sentence, not a stray word), and a consecutive-duplicate dedup. The
    /// `append` call adds the shared secret-heuristic + fragment + FIFO gates.
    private func recordRawInputIfAllowed(text: String, bundleID: String?) {
        guard store.personalizationEnabled else { return }
        // Opt-in gate. The "Retenir aussi ce que vous écrivez sans accepter"
        // toggle (PreferencesStore.storeWithoutAccepted, default false) is meant
        // to govern exactly this prose capture of whole field contents. It was
        // defined + shown in the UI but read NOWHERE, so prose was captured on
        // every focus change regardless of the toggle — the over-recording the
        // user noticed. Honour it now: off ⇒ only accepted suggestions are
        // stored. TO REVERT: delete this guard.
        guard store.storeWithoutAccepted else { return }
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
            bundleID: bid,
            source: .prose
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
        cancelRollingRefill()
        // Divergence du chemin prédit → l'ancre n'est plus valide. La prochaine
        // génération fraîche en reposera une. No-op hors flag (ancre toujours vide).
        clearGhostAnchor()
        // ── ROLLING REFILL (point 4) : pas de blank frame sur divergence ──
        // Quand le mode rolling est ON, on NE cache PAS l'overlay immédiatement :
        // on garde la dernière frame visible et on laisse la fresh prediction la
        // remplacer en place (swap sans trou blanc). On garde le cancel + le reset
        // de `lastPredictedPrefix`. Hors flag, comportement byte-identique (hide).
        if !SuggestionPolicy.Tuning.midWordGhostRollingEnabled {
            overlay.hide()
            interceptor.setActive(false)
        }
        lastPredictedPrefix = nil
    }

    /// Nombre de mots ENTIERS dans `s` (séparateurs = whitespace). Pur, utilisé
    /// par la logique de refill rolling pour décider quand recharger.
    private static func wholeWordCount(_ s: String) -> Int {
        s.split(whereSeparator: { $0.isWhitespace }).count
    }

    /// Réinitialise l'ancre de fenêtre glissante. Appelé quand l'utilisateur efface
    /// EN-DEÇÀ de la borne gauche, diverge du chemin prédit, consomme tout, ou change
    /// de focus. La prochaine génération fraîche reposera une ancre.
    private func clearGhostAnchor() {
        ghostAnchorBase = ""
        ghostAnchorFull = ""
        ghostAnchorBundle = ""
    }

    /// Sur ACCEPT (Tab plein / acceptAll / dernier chunk), on GARDE la borne gauche
    /// `ghostAnchorBase` et on étend `ghostAnchorFull` au texte committé complet, pour
    /// qu'un effacement ultérieur restaure encore la ligne acceptée. No-op hors flag
    /// ou si l'ancre est inactive / le bundle a changé / la borne gauche n'est plus un
    /// préfixe du texte committé. `committedFullText` = `prePrefix + suggestion`.
    @MainActor
    private func extendGhostAnchorOnAccept(committedFullText: String, bundleID: String?) {
        guard SuggestionPolicy.Tuning.midWordGhostRollingEnabled,
              !ghostAnchorFull.isEmpty,
              let bid = bundleID, bid == ghostAnchorBundle,
              committedFullText.lowercased().hasPrefix(ghostAnchorBase.lowercased()),
              committedFullText.count >= ghostAnchorBase.count else { return }
        ghostAnchorFull = committedFullText
    }

    /// Annule la Task de refill rolling en vol (changement d'app / divergence /
    /// blur) et libère le verrou anti-tempête.
    private func cancelRollingRefill() {
        ghostRefillTask?.cancel()
        ghostRefillTask = nil
        ghostRefillInFlight = false
    }

    /// **ROLLING REFILL** — recharge le ghost à droite quand il se vide à gauche
    /// (parité Cotypist). Appelé depuis le bloc de rendu du reste synchronisé,
    /// UNIQUEMENT quand `midWordGhostRollingEnabled`. Spawn une Task trackée qui
    /// génère les mots suivants et les APPEND au `partialRemainder` — mais SEULEMENT
    /// si l'état est resté cohérent (même bundle, `partialAcceptedAtPrefix`/
    /// `partialAcceptedSoFar` inchangés, reste inchangé depuis le départ). Gardé
    /// contre les tempêtes par `ghostRefillInFlight` + une re-vérification de l'état.
    private func maybeSpawnRollingRefill(committedText: String, bundleID: String) {
        guard SuggestionPolicy.Tuning.midWordGhostRollingEnabled else { return }
        guard !ghostRefillInFlight else { return }
        let remainder = partialRemainder
        let remainderWords = Self.wholeWordCount(remainder)
        // Recharge uniquement quand le reste passe SOUS le plancher de mots.
        guard remainderWords < SuggestionPolicy.Tuning.ghostRollingMinWords else { return }
        // Profondeur cible = la préférence « Longueur du souffle » (predictor.maxWords),
        // pour que la fenêtre glissante maintienne la MÊME longueur que le ghost initial —
        // un seul budget global, pas un réglage de refill séparé. Override DEV
        // MW_ROLL_DEPTH optionnel (défaut = la préférence utilisateur).
        let targetWords = ProcessInfo.processInfo.environment["MW_ROLL_DEPTH"]
            .flatMap { Int($0) }.map { max(1, $0) } ?? predictor.maxWords
        let wantWords = targetWords - remainderWords
        guard wantWords >= 1 else { return }

        // Snapshot de l'état pour re-valider à la complétion (anti-stale-append).
        let snapPrefix = partialAcceptedAtPrefix
        let snapSoFar = partialAcceptedSoFar
        let snapBundle = partialAcceptedAtBundleID

        ghostRefillInFlight = true
        ghostRefillTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.ghostRefillInFlight = false
                self.ghostRefillTask = nil
            }
            let extension_ = await self.predictor.extendGhost(
                committedText: committedText,
                currentRemainder: remainder,
                maxWords: wantWords
            )
            if Task.isCancelled { return }
            guard let extension_, !extension_.isEmpty else { return }
            // Re-valide STRICTEMENT l'état : même bundle, mêmes ancres de partial-
            // accept, et reste INCHANGÉ depuis le spawn. Toute divergence → on
            // jette le refill (il s'appliquerait au mauvais endroit).
            guard SuggestionPolicy.Tuning.midWordGhostRollingEnabled,
                  bundleID == self.currentBundleIDForRefillCheck(),
                  snapBundle == self.partialAcceptedAtBundleID,
                  snapPrefix == self.partialAcceptedAtPrefix,
                  snapSoFar == self.partialAcceptedSoFar,
                  self.partialRemainder == remainder else { return }
            // APPEND (le reste reste affiché ; l'extension le prolonge au prochain
            // tick render). On préserve l'espacement : `extension_` porte déjà un
            // espace de tête unique, donc on dé-doublonne une éventuelle jointure.
            let appended: String
            if self.partialRemainder.hasSuffix(" ") && extension_.hasPrefix(" ") {
                appended = String(extension_.dropFirst())
            } else {
                appended = extension_
            }
            self.partialRemainder += appended
            // Fenêtre glissante : le bord DROIT grandit avec le refill. On garde la
            // borne gauche et on prolonge `ghostAnchorFull` du même texte, pour qu'un
            // effacement ultérieur restaure aussi les mots refillés.
            if !self.ghostAnchorFull.isEmpty {
                self.ghostAnchorFull += appended
            }
            // INSTANT-PAINT du bord DROIT (flag `SOUFFLEUSE_INSTANT_PAINT`). Le refill
            // appende à `partialRemainder` (PAS à `predictor.suggestion`), donc
            // l'observation instant-paint ne le couvre pas : sans ce kick, la
            // croissance à droite attend le prochain poll (≤50 ms) — asymétrie vs le
            // bord gauche (backspace) peint dans le tick courant. On repeint tout de
            // suite via le tick (branche partial-remainder synchronisée). Hors flag →
            // comportement d'origine (peint au prochain tick).
            if ProcessInfo.processInfo.environment["SOUFFLEUSE_INSTANT_PAINT"] != nil {
                self.tickThrottled()
            }
        }
    }

    /// Bundle ID focus courant, lu pour re-valider un refill rolling à sa
    /// complétion. Lecture AX légère et synchrone, sur le main (comme le tick).
    private func currentBundleIDForRefillCheck() -> String? {
        axClient.snapshot().bundleID
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

    /// Pure render-gate decision: may the overlay paint `suggestion` right now?
    ///
    /// True only when there IS a suggestion AND it was generated for the LIVE
    /// `currentPrefix` (`predictedForPrefix == currentPrefix`). `suggestion` is
    /// a bare string with no built-in notion of which prefix produced it, and it
    /// can survive in `PredictorViewModel.suggestion` past the keystroke it was
    /// made for (a gating path kept it while a fresh stream is still pending).
    /// Painting such a leftover at the new caret is the "Bonjour" repro — a
    /// start-of-message ghost re-shown far downstream at "…autre chose pou".
    /// Gating on the stamped prefix makes a stale paint impossible regardless of
    /// which path let the suggestion linger.
    static func shouldRenderSuggestion(suggestion: String,
                                       predictedForPrefix: String,
                                       currentPrefix: String) -> Bool {
        !suggestion.isEmpty && predictedForPrefix == currentPrefix
    }

    /// Suppress the ghost when non-whitespace text remains on the CURRENT line
    /// after the caret (before the next newline) — i.e. the user is editing
    /// INSIDE a line, not appending at its end. A caret clicked between two
    /// words lands right before the inter-word space, yet "world" still follows
    /// on the same line, so it is suppressed. But appending at the END of any
    /// line is allowed even when more lines follow below: scanning stops at the
    /// first newline, so a signature/paragraph beneath the caret never blocks
    /// the ghost. Trailing whitespace on the current line and end-of-text are
    /// likewise not suppressed.
    ///
    /// Uses `Character.isNewline` / `isWhitespace` (cover \n, \r, tab, space,
    /// and other Unicode forms). Never logs any user-supplied text. Do not call
    /// this with `text` or `caretIndex` as log arguments anywhere.
    static func shouldSuppressForCaretContext(text: String, caretIndex: Int) -> Bool {
        guard caretIndex >= 0, caretIndex < text.count else { return false }
        let idx = text.index(text.startIndex, offsetBy: caretIndex)
        for ch in text[idx...] {
            if ch.isNewline { break }
            if !ch.isWhitespace { return true }
        }
        return false
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

extension SouffleuseAppDelegate: NSMenuDelegate {
    /// Rafraîchit l'état des bascules ET le carnet juste avant l'ouverture du menu,
    /// pour que les chiffres soient toujours à jour au clic.
    func menuNeedsUpdate(_ menu: NSMenu) {
        refreshStatusItem()
        refreshCarnet()
    }
}
