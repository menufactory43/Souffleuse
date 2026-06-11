import ApplicationServices
import AppKit
import Foundation

public struct AXFontInfo: Sendable, Equatable {
    public let familyName: String
    public let pointSize: Double
}

public struct AXSnapshot: Sendable, Equatable {
    public let bundleID: String?
    public let role: String?
    public let subrole: String?
    public let text: String?
    public let caretIndex: Int?
    public let caretRect: CGRect?
    public let caretFont: AXFontInfo?
    public let windowTitle: String?
    /// Frame of the focused text element itself (Quartz coordinates). Used by
    /// the presence indicator so the badge sticks to the field instead of
    /// chasing the caret as the user types.
    public let elementRect: CGRect?
    /// AX `kAXPlaceholderValueAttribute` of the focused element when present.
    /// High-signal for empty-field cases per Phase 1 verdict — surfaces the
    /// app's intent for the field beyond what `AppContextProbe` exposes.
    /// Nil if the attribute is unsupported, empty, or the field is secure.
    public let placeholder: String?

    /// AX `kAXHelpAttribute` of the focused element when present. Often a
    /// human-readable tooltip the app exposes for accessibility users —
    /// usable as additional structural framing for the LLM. Nil if the
    /// attribute is unsupported or the field is secure.
    public let help: String?

    /// Text after the caret captured via `kAXStringForRangeParameterizedAttribute`
    /// at snapshot time. Capped at 500 chars upstream to keep the AX read
    /// bounded (well above the 120-token afterCursor slot budget). Nil if
    /// the caret is at end-of-text, the host refuses the read, or the result
    /// is empty (D-14c).
    public let textAfterCaret: String?

    /// AX `kAXIdentifierAttribute` du champ focalisé. Lu seulement pour les
    /// champs single-line (`AXTextField`/`AXComboBox`) — sert à reconnaître
    /// les champs utilitaires (Safari annonce son omnibox via
    /// "WEB_BROWSER_ADDRESS_AND_SEARCH_FIELD", sondé le 11/06/2026).
    public let identifier: String?

    /// `AXDOMIdentifier` (attribut non-standard exposé par Gecko et Chromium).
    /// Firefox identifie sa barre d'adresse par "urlbar-input" — indépendant
    /// de la locale, contrairement à AXDescription.
    public let domIdentifier: String?

    /// `AXDOMClassList` (attribut non-standard Chromium). Pour les vues natives
    /// du navigateur (hors page web), contient le nom de la classe Views —
    /// l'omnibox expose "OmniboxViewViews" (Chrome) / "BraveOmniboxViewViews"
    /// (Brave) ; le suffixe couvre toute la famille Chromium (Edge, Vivaldi…).
    public let domClassList: [String]?

    /// `AXHasPopup` — mapping Chromium/Gecko de `aria-haspopup`. Vrai pour les
    /// champs qui ouvrent une liste de choix (combobox ARIA, chip-input
    /// Angular Material…). Faux si l'attribut est absent ou false.
    public let hasPopup: Bool

    /// `AXAutocompleteValue` — mapping de `aria-autocomplete` ("list",
    /// "inline", "both", "none"). "list"/"both" ⇒ le champ propose ses propres
    /// suggestions dans un popup ; notre ghost ne ferait que rivaliser avec.
    public let autocompleteKind: String?

    public init(
        bundleID: String?,
        role: String?,
        subrole: String?,
        text: String?,
        caretIndex: Int?,
        caretRect: CGRect?,
        caretFont: AXFontInfo?,
        windowTitle: String? = nil,
        elementRect: CGRect? = nil,
        placeholder: String? = nil,
        help: String? = nil,
        textAfterCaret: String? = nil,
        identifier: String? = nil,
        domIdentifier: String? = nil,
        domClassList: [String]? = nil,
        hasPopup: Bool = false,
        autocompleteKind: String? = nil
    ) {
        self.bundleID = bundleID
        self.role = role
        self.subrole = subrole
        self.text = text
        self.caretIndex = caretIndex
        self.caretRect = caretRect
        self.caretFont = caretFont
        self.windowTitle = windowTitle
        self.elementRect = elementRect
        self.placeholder = placeholder
        self.help = help
        self.textAfterCaret = textAfterCaret
        self.identifier = identifier
        self.domIdentifier = domIdentifier
        self.domClassList = domClassList
        self.hasPopup = hasPopup
        self.autocompleteKind = autocompleteKind
    }

    public var isTextElement: Bool {
        guard let role else { return false }
        return AXClient.textRoles.contains(role)
    }

    public var isSecureField: Bool {
        subrole == "AXSecureTextField"
    }

    /// Vrai quand le champ focalisé est une ZONE DE RECHERCHE : subrole AX
    /// `AXSearchField` — natif macOS (Finder/Mail/réglages…) et exposé aussi par
    /// Chromium pour `input[type=search]` / ARIA `role=searchbox`. On ne propose
    /// pas de ghost dans une recherche (et on ne réveille pas le modèle pour ça).
    public var isSearchField: Bool {
        subrole == "AXSearchField"
    }

    /// Vrai quand le champ focalisé est la BARRE D'ADRESSE d'un navigateur.
    /// Les omniboxes sont des `AXTextField` ordinaires (PAS `AXSearchField`),
    /// donc elles passaient le gate texte et allumaient badge + génération pour
    /// des URLs. Signatures sondées le 11/06/2026 (axdump), toutes indépendantes
    /// de la locale :
    ///   - Safari   : AXIdentifier "WEB_BROWSER_ADDRESS_AND_SEARCH_FIELD"
    ///   - Chromium : AXDOMClassList contient *"OmniboxViewViews" (Chrome nu,
    ///                "BraveOmniboxViewViews" — le suffixe couvre les forks)
    ///   - Firefox  : AXDOMIdentifier "urlbar-input"
    /// Match exact/suffixe uniquement : Notes expose aussi un AXIdentifier
    /// ("Note Body Text View") et ne doit jamais matcher.
    public var isAddressBar: Bool {
        if identifier == "WEB_BROWSER_ADDRESS_AND_SEARCH_FIELD" { return true }
        if domIdentifier == "urlbar-input" { return true }
        if let domClassList, domClassList.contains(where: { $0.hasSuffix("OmniboxViewViews") }) {
            return true
        }
        return false
    }

    /// Vrai quand le champ focalisé est un SÉLECTEUR : un champ texte dont le
    /// rôle est de filtrer une liste de choix (combobox ARIA, autocomplete
    /// Angular Material/React Select, chip-input…). L'utilisateur y choisit
    /// une valeur dans un popup — un ghost LLM y est du bruit qui rivalise
    /// avec les suggestions du champ lui-même. Sondé le 11/06/2026 sur un
    /// chip-input Angular Material (Brave) : AXHasPopup=1,
    /// AXAutocompleteValue="list". "inline" n'est PAS un sélecteur (simple
    /// complétion dans le champ, pas de liste).
    public var isPickerField: Bool {
        if hasPopup { return true }
        if let autocompleteKind, autocompleteKind == "list" || autocompleteKind == "both" {
            return true
        }
        return false
    }
}

public final class AXClient: @unchecked Sendable {
    static let textRoles: Set<String> = [
        "AXTextField",
        "AXTextArea",
        "AXComboBox",
    ]

    private let queue = DispatchQueue(label: "cocotypist.ax.client", qos: .userInitiated)
    private let systemWide: AXUIElement
    /// PIDs whose AX tree currently reads as LIVE (the last focused-element
    /// read succeeded). While a PID is live we skip activation entirely — no
    /// redundant attribute writes. Keyed by PID, not bundle id.
    private var treeLiveNowPIDs: Set<pid_t> = []
    /// PIDs whose AX tree has been live AT LEAST ONCE — i.e. confirmed
    /// Electron/Chromium hosts worth re-waking WITHOUT bound if they go dormant
    /// again. Chromium's `AutoDisableAccessibility` turns the tree back OFF
    /// mid-session after the user types without an AT reading (observed live:
    /// Signal flipped `textLen=21` → `textLen=-1` in one tick), so a one-shot
    /// "confirmed forever" model never recovers. A never-live PID's initial
    /// wake is bounded (`maxInitialActivationAttempts`); a known-live PID that
    /// went dormant is retried every tick until it wakes.
    private var treeEverLivePIDs: Set<pid_t> = []
    /// Activation attempts for a PID that has NEVER been live, bounding the
    /// initial wake so a Cocoa app with no AX tree (Finder, etc.) is not
    /// re-written at the poll rate forever. Reset once the PID first goes live.
    private var initialActivationAttempts: [pid_t: Int] = [:]
    /// Live no-op AX observers, keyed by PID. Strongly retained so Chromium
    /// keeps the tree alive for the host process's lifetime. Created AT MOST
    /// once per PID (guarded) so a retry never overwrites — and leaks the
    /// run-loop source of — a prior observer (there is no CFRunLoopRemoveSource
    /// in this class). The observer is NOT itself the activation trigger (a
    /// long-standing misconception in this file): it only pumps extra run-loop
    /// turns while the tree builds and keeps a live AT signature.
    private var observersByPID: [pid_t: AXObserver] = [:]
    /// **Détection PUSH (Fix 2, flag `SOUFFLEUSE_AX_PUSH`).** Signal émis sur le
    /// MAIN run-loop quand le host notifie un changement de valeur / sélection /
    /// focus via AX. Branché par l'AppDelegate sur `tickThrottled()` → détection
    /// instantanée (parité Cotypist) au lieu d'attendre le poll 50 ms. Hors flag :
    /// jamais appelé (le callback C retourne tôt) et jamais abonné aux notifs
    /// valeur/sélection → comportement byte-identique (observer no-op d'origine).
    /// Lu/écrit sur le main uniquement (set au démarrage, appelé depuis le callback
    /// AX qui fire sur le main run-loop). `@unchecked Sendable` de la classe couvre.
    public var onHostAXChanged: (@Sendable () -> Void)?
    /// Flag maître du push AX, lu une fois. OFF → observer reste no-op.
    /// `fileprivate` pour que le callback C top-level (voir bas de fichier) le lise.
    fileprivate static let axPushEnabled =
        ProcessInfo.processInfo.environment["SOUFFLEUSE_AX_PUSH_OFF"] == nil  // ON par défaut (endgame Phase A)
    /// Upper bound on activation attempts for a PID that has never been live —
    /// generous for Chromium's async tree build, bounded so non-Electron apps
    /// stop after a few seconds. NOTE: ticks where the AX app element returns
    /// `.cannotComplete` (host still coming to the foreground) do NOT count
    /// against this budget (see `ensureAccessibilityActivated`), so this bounds
    /// REAL attempts where the app actually responded, not foreground latency.
    static let maxInitialActivationAttempts = 40

    public init() {
        self.systemWide = AXUIElementCreateSystemWide()
    }

    /// Forces a Chromium/Electron host (Signal Desktop, Slack, Discord, VS
    /// Code, …) to expose its accessibility tree by setting the two well-known
    /// activation attributes AT processes use. No-op (and harmless) on Cocoa-
    /// native apps that already expose AX.
    ///
    /// Without this, Electron hosts return `text=nil` for the focused element
    /// — their AX tree stays dormant until an AT trips it; then Chromium keeps
    /// it live for the host PROCESS lifetime (which is why Souffleuse used to
    /// only work in Signal *after* another AT — Cotypist/VoiceOver — had woken
    /// it, and kept working even once that AT was killed). Two correctness
    /// requirements drive the retry design here:
    ///   1. The tree builds ASYNCHRONOUSLY — the first focused read after the
    ///      attribute-set races the build and comes back empty, so a single
    ///      fire-once attempt never sticks. We retry across snapshot ticks
    ///      until `readSnapshot` reports a live tree (`recordTreeLiveness`).
    ///   2. `AXManualAccessibility` is unsupported on Electron < 23.3.1 even
    ///      though the host IS Electron; `AXEnhancedUserInterface` does the
    ///      work there — so we set BOTH and never gate success on the set's
    ///      return code.
    private func ensureAccessibilityActivated(for appEl: AXUIElement, bundleID: String) {
        var pid: pid_t = 0
        AXUIElementGetPid(appEl, &pid)
        guard pid != 0 else { return }
        // Tree is live right now → nothing to do (no redundant attribute writes).
        if treeLiveNowPIDs.contains(pid) { return }
        // Dormant. A never-live PID gets a bounded initial wake budget (so a
        // Cocoa app with no AX tree isn't re-written at the poll rate forever);
        // a PID that WAS live and went dormant (AutoDisableAccessibility) is
        // retried unbounded until it wakes again. The attempt is COUNTED below,
        // after the sets, and only when the app actually responded — so the
        // foreground-latency window (cannotComplete) never burns the budget.
        let everLive = treeEverLivePIDs.contains(pid)
        if !everLive {
            guard initialActivationAttempts[pid, default: 0] < Self.maxInitialActivationAttempts else { return }
        }

        // Step 1: set BOTH activation attributes on the per-application element.
        // Cocoa apps return `.attributeUnsupported` (harmless); Electron honors
        // at least one. Return codes are NOT a success signal (see doc above).
        let r1 = AXUIElementSetAttributeValue(appEl, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
        let r2 = AXUIElementSetAttributeValue(appEl, "AXManualAccessibility" as CFString, kCFBooleanTrue)

        // Step 2: trip the modern (Feb-2021 Chromium) read-trigger — reading an
        // attribute off a Chrome accessibility element enables basic a11y. The
        // value is unused; the read itself is the point.
        _ = copyAttr(appEl, kAXRoleAttribute)

        // Step 3: register a no-op AXObserver ONCE per PID. It is NOT the
        // activation trigger — it only pumps extra run-loop turns while the
        // tree builds and keeps a live AT signature. Guarded on
        // `observersByPID[pid] == nil` so a retry never overwrites and leaks a
        // prior observer's run-loop source.
        var observerStatus: AXError = .success
        if observersByPID[pid] == nil {
            var observer: AXObserver?
            // Callback C : NE PEUT PAS capturer (function pointer). On récupère
            // l'AXClient via le `refcon`. Hors flag push → garde + return ⇒
            // strictement no-op (identique à l'ancien `{ _,_,_,_ in }`). Fire sur
            // le MAIN run-loop (la source est ajoutée à `CFRunLoopGetMain`), donc
            // `onHostAXChanged` est invoqué côté main, sans hop. Référence une
            // fonction TOP-LEVEL (et non un closure inline) pour éviter un crash
            // du pass SIL `SendNonSendable` du compilateur sur cette méthode.
            let create = AXObserverCreate(pid, souffleuseAXPushObserverCallback, &observer)
            if create == .success, let observer {
                // `refcon` = pointeur NON retenu vers self. Sûr : self (AXClient)
                // possède l'observer (`observersByPID`) et lui survit donc toujours.
                let refcon = Unmanaged.passUnretained(self).toOpaque()
                let add = AXObserverAddNotification(
                    observer, appEl,
                    kAXFocusedUIElementChangedNotification as CFString,
                    refcon
                )
                // PUSH (Fix 2) : abonnements valeur + sélection en PLUS, uniquement
                // sous flag. C'est ce qui transforme l'observer keep-alive en vrai
                // déclencheur de détection (texte modifié / caret déplacé → tick).
                // Posés sur l'élément application ; les apps qui ne propagent pas au
                // niveau app retombent sur le poll 50 ms (aucune régression).
                if Self.axPushEnabled {
                    _ = AXObserverAddNotification(observer, appEl,
                        kAXValueChangedNotification as CFString, refcon)
                    _ = AXObserverAddNotification(observer, appEl,
                        kAXSelectedTextChangedNotification as CFString, refcon)
                }
                if add == .success {
                    CFRunLoopAddSource(
                        CFRunLoopGetMain(),
                        AXObserverGetRunLoopSource(observer),
                        .defaultMode
                    )
                    observersByPID[pid] = observer  // strong retain
                } else {
                    observerStatus = add
                }
            } else {
                observerStatus = create
            }
        }

        // Count this attempt against the initial-wake budget ONLY when the app
        // actually responded. `.cannotComplete` on BOTH sets means the AX
        // application element isn't ready yet (host still coming to the
        // foreground) — those ticks must not burn the budget, or a slow
        // foreground exhausts it before the attribute set even lands (live
        // trace: attempts 1-10 were cannotComplete; AXManualAccessibility only
        // began succeeding at attempt 11, right against the old cap of 25).
        // `.success` (Electron accepted it) and the unsupported codes (Cocoa →
        // no tree, must stay bounded) both count.
        if !everLive, !(r1 == .cannotComplete && r2 == .cannotComplete) {
            initialActivationAttempts[pid, default: 0] += 1
        }

        if ProcessInfo.processInfo.environment["SOUFFLEUSE_PREDICT_LOG"]?.isEmpty == false {
            let line = "[\(ISO8601DateFormatter().string(from: Date()))] ax_activate bundle=\(bundleID) pid=\(pid) everLive=\(everLive) initAttempt=\(initialActivationAttempts[pid, default: 0]) enhanced=\(axErrorName(r1)) manual=\(axErrorName(r2)) observer=\(axErrorName(observerStatus))\n"
            if let data = line.data(using: .utf8) {
                let path = "/tmp/souffleuse-tick.log"
                if let h = FileHandle(forWritingAtPath: path) {
                    h.seekToEndOfFile(); try? h.write(contentsOf: data); try? h.close()
                } else { FileManager.default.createFile(atPath: path, contents: data) }
            }
        }
    }

    /// Record the result of `readSnapshot`'s focused-element read so activation
    /// knows whether the tree is live. Confirm on ANY focused element, NOT only
    /// a text field: an awake Chromium host can have a non-text control focused,
    /// and gating on a focused TEXT element would spin activation forever.
    ///
    /// `focusedReadable == false` means the tree is dormant (or just went
    /// dormant via AutoDisableAccessibility) → re-arm so `ensureAccessibilityActivated`
    /// retries on the next tick.
    private func recordTreeLiveness(pid: pid_t, focusedReadable: Bool) {
        guard pid != 0 else { return }
        if focusedReadable {
            treeLiveNowPIDs.insert(pid)
            treeEverLivePIDs.insert(pid)
            initialActivationAttempts[pid] = nil  // reclaim the counter slot
        } else {
            treeLiveNowPIDs.remove(pid)
        }
    }

    @discardableResult
    public static func ensureTrusted(prompt: Bool) -> Bool {
        // Hardcoded to avoid touching the non-Sendable global `kAXTrustedCheckOptionPrompt`.
        let opts = ["AXTrustedCheckOptionPrompt": prompt] as CFDictionary
        return AXIsProcessTrustedWithOptions(opts)
    }

    public static var isTrusted: Bool {
        AXIsProcessTrusted()
    }

    public func snapshot() -> AXSnapshot {
        queue.sync { readSnapshot() }
    }

    /// Inject `text` at the caret of the currently focused element.
    ///
    /// Tries the AX write path first (clean, undoable in the host app) and falls back
    /// to posting Unicode key events via the HID system when the host doesn't accept
    /// AX writes (Electron apps, some web fields).
    ///
    /// Returns true if either path appeared to succeed.
    @discardableResult
    public func inject(_ text: String) -> Bool {
        queue.sync {
            guard let appEl = focusedAppElement() else { return false }
            var focusedRef: AnyObject?
            guard AXUIElementCopyAttributeValue(appEl, kAXFocusedUIElementAttribute as CFString, &focusedRef) == .success,
                  let focused = focusedRef else {
                return injectViaCGEvent(text)
            }
            let element = focused as! AXUIElement

            // Refuse to inject into secure fields.
            if copyStringAttr(element, kAXSubroleAttribute) == "AXSecureTextField" {
                return false
            }

            let textBefore = copyStringAttr(element, kAXValueAttribute) ?? ""
            let status = AXUIElementSetAttributeValue(
                element,
                kAXSelectedTextAttribute as CFString,
                text as CFString
            )
            if status == .success {
                // Give the host ~50 ms to apply, then verify the value changed.
                usleep(50_000)
                let textAfter = copyStringAttr(element, kAXValueAttribute) ?? ""
                if textAfter != textBefore {
                    return true
                }
            }
            return injectViaCGEvent(text)
        }
    }

    /// Marqueur posé sur le `CGEventSource` de TOUS nos événements clavier
    /// synthétiques (flèches de `moveCaretRight`, backspaces, inserts unicode).
    /// Les events créés sur cette source portent la valeur dans leur champ
    /// `.eventSourceUserData` — le `KeyInterceptor` la lit pour LAISSER PASSER
    /// nos propres événements. Sans ce marqueur, les flèches → synthétiques de
    /// l'accept mid-line étaient résolues comme `acceptAll` (binding défaut →,
    /// keyCode 124 sans modificateur) par notre propre tap : avalées (le caret
    /// ne bougeait jamais) ET déclenchant des accepts en cascade qui
    /// détruisaient le champ (reproduit dans TextEdit, 2026-06-10).
    /// JUMEAU : `KeyInterceptor.syntheticEventUserData` (SouffleuseInput) —
    /// les deux targets n'ont aucune dépendance commune, la constante est
    /// dupliquée et verrouillée par un test d'égalité (SouffleuseTests).
    public static let syntheticEventUserData: Int64 = 0x534F_5546   // "SOUF"

    /// Source d'événements synthétiques MARQUÉE (voir `syntheticEventUserData`).
    private static func makeSyntheticSource(stateID: CGEventSourceStateID) -> CGEventSource? {
        let source = CGEventSource(stateID: stateID)
        source?.userData = syntheticEventUserData
        return source
    }

    /// Avance le caret de `count` caractères vers la droite, et ne REND la main
    /// que lorsque le déplacement est CONFIRMÉ (lecture AX de la position).
    ///
    /// Utilisé par l'accept mid-line : les segments de la complétion qui existent
    /// déjà après le caret sont SAUTÉS au lieu d'être ré-injectés (« p|our » +
    /// accept « our… » ne doit pas produire « pourour »). L'injection qui SUIT le
    /// saut est un write AX synchrone — sans confirmation, elle part de
    /// l'ANCIENNE position (constaté : « hom|me. » + Tab → « hom me. », l'espace
    /// injecté avant que les flèches soient traitées).
    ///
    /// Stratégie : (1) write direct de `kAXSelectedTextRangeAttribute`, relu pour
    /// vérification — des hôtes (Notes / RichTextEdit) répondent `.success` puis
    /// IGNORENT ; (2) fallback flèches → synthétiques (universelles), PUIS poll
    /// de la position jusqu'à confirmation (~200 ms max) ; (3) hôte sans caret
    /// lisible : flèches + settle aveugle.
    @discardableResult
    public func moveCaretRight(by count: Int) -> Bool {
        guard count > 0 else { return true }
        return queue.sync {
            let element: AXUIElement? = {
                guard let appEl = focusedAppElement() else { return nil }
                var focusedRef: AnyObject?
                guard AXUIElementCopyAttributeValue(appEl, kAXFocusedUIElementAttribute as CFString, &focusedRef) == .success,
                      let focused = focusedRef else { return nil }
                return (focused as! AXUIElement)
            }()
            let caretBefore = element.flatMap { readCaretLocation($0) }

            // 1. Write AX direct (instantané quand l'hôte l'honore), vérifié.
            if let el = element, let before = caretBefore {
                var target = CFRange(location: before + count, length: 0)
                if let value = AXValueCreate(.cfRange, &target) {
                    AXUIElementSetAttributeValue(el, kAXSelectedTextRangeAttribute as CFString, value)
                    usleep(20_000)
                    if readCaretLocation(el) == before + count { return true }
                }
            }

            // 2. Flèches → synthétiques (virtual key 124), même cadence que
            //    `backspaceAndInjectViaCGEvent`, puis poll de confirmation.
            let source = Self.makeSyntheticSource(stateID: .hidSystemState)
            usleep(5_000)
            for _ in 0..<count {
                guard let down = CGEvent(keyboardEventSource: source, virtualKey: 124, keyDown: true),
                      let up = CGEvent(keyboardEventSource: source, virtualKey: 124, keyDown: false) else {
                    return false
                }
                down.post(tap: .cghidEventTap)
                up.post(tap: .cghidEventTap)
                usleep(2_000)
            }
            if let el = element, let before = caretBefore {
                for _ in 0..<20 {   // ~200 ms max
                    if readCaretLocation(el) == before + count { return true }
                    usleep(10_000)
                }
                return false
            }
            // 3. Pas de caret lisible : settle aveugle généreux.
            usleep(80_000)
            return true
        }
    }

    /// Position courante du caret (location du `kAXSelectedTextRangeAttribute`),
    /// lue pour vérifier qu'un déplacement a bien été appliqué par l'hôte.
    private func readCaretLocation(_ element: AXUIElement) -> Int? {
        guard let rangeRef = copyAttr(element, kAXSelectedTextRangeAttribute) else { return nil }
        var range = CFRange(location: 0, length: 0)
        guard AXValueGetValue(rangeRef as! AXValue, .cfRange, &range) else { return nil }
        return range.location
    }

    /// Replace the last `deleteChars` characters before the caret with `text`.
    /// Used by typo correction and emoji expansion.
    ///
    /// We deliberately skip the AX selection-replace path because hosts like
    /// Notes / RichTextEdit accept `kAXSelectedTextRangeAttribute` writes with
    /// status `.success` but silently ignore them — the subsequent
    /// `kAXSelectedTextAttribute` set then inserts at caret instead of
    /// replacing, producing `BonjouBonjour`-style duplications.
    ///
    /// Posting N CGEvent backspaces is universally honored: every host treats
    /// a hardware Backspace press as "delete one char before caret".
    @discardableResult
    public func replaceTrailing(deleteChars: Int, with text: String) -> Bool {
        guard deleteChars > 0 else {
            return inject(text)
        }
        return backspaceAndInjectViaCGEvent(count: deleteChars, text: text)
    }

    private func backspaceAndInjectViaCGEvent(count: Int, text: String) -> Bool {
        let source = Self.makeSyntheticSource(stateID: .hidSystemState)
        // Settle delay after the Tab key event we just consumed in the
        // CGEventTap callback. Without this, fast hosts (Brave, Electron,
        // some text fields) drop the first backspace because they're still
        // post-processing the consumed Tab event. Empirically 5 ms is
        // enough on M-series machines; cheap insurance.
        usleep(5_000)
        for _ in 0..<count {
            // virtual key 51 = Delete (backspace)
            guard let down = CGEvent(keyboardEventSource: source, virtualKey: 51, keyDown: true),
                  let up = CGEvent(keyboardEventSource: source, virtualKey: 51, keyDown: false) else {
                return false
            }
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
            // Inter-event delay. Bursting N backspaces in one go can cause
            // the host to drop events mid-stream (observed on
            // long replaceTrailing on Notes / Mail). 2 ms keeps the user
            // experience fast (12 ms for 6-char replace) while letting the
            // event queue drain.
            usleep(2_000)
        }
        // Pause before the unicode insert so the deletions are committed
        // before the new text is interpreted.
        usleep(5_000)
        return injectViaCGEvent(text)
    }

    /// Replace the trailing `deleteChars` characters with `text`, SAFE to call
    /// while the user still physically holds the commit modifier (⌘). Used by the
    /// translation commit.
    ///
    /// Two hazards this avoids vs the naive paths:
    /// 1. **Held modifier contamination** — `replaceTrailing`/`injectViaCGEvent`
    ///    post events whose flags reflect the hardware state (`.hidSystemState`),
    ///    so a held ⌘ turns each Backspace into ⌘-Backspace (delete-line) and the
    ///    Unicode insert into a no-op ⌘-shortcut. Here every event's `flags` is
    ///    EXPLICITLY cleared and the source is `.privateState`.
    /// 2. **Layout-dependent ⌘-shortcuts** — we never synthesize ⌘A/⌘V: on AZERTY
    ///    `virtualKey 0` is 'Q', so ⌘+virtualKey0 = ⌘Q would QUIT the host app.
    ///    Backspace (keyCode 51) and `keyboardSetUnicodeString` are
    ///    layout-independent.
    /// Refuses secure fields.
    @discardableResult
    public func replaceForCommit(deleteChars: Int, with text: String) -> Bool {
        queue.sync {
            // Secure-field guard (mirrors inject()).
            if let appEl = focusedAppElement() {
                var focusedRef: AnyObject?
                if AXUIElementCopyAttributeValue(appEl, kAXFocusedUIElementAttribute as CFString, &focusedRef) == .success,
                   let focused = focusedRef {
                    let element = focused as! AXUIElement
                    if copyStringAttr(element, kAXSubroleAttribute) == "AXSecureTextField" {
                        return false
                    }
                }
            }
            // Private source + cleared flags → the physically-held ⌘ never bleeds
            // into our synthetic Backspace / insert events.
            let source = Self.makeSyntheticSource(stateID: .privateState)
            let noFlags = CGEventFlags(rawValue: 0)
            usleep(5_000)
            for _ in 0..<max(0, deleteChars) {
                guard let down = CGEvent(keyboardEventSource: source, virtualKey: 51, keyDown: true),
                      let up = CGEvent(keyboardEventSource: source, virtualKey: 51, keyDown: false) else {
                    return false
                }
                down.flags = noFlags
                up.flags = noFlags
                down.post(tap: .cghidEventTap)
                up.post(tap: .cghidEventTap)
                usleep(1_500)
            }
            usleep(5_000)
            let utf16 = Array(text.utf16)
            guard let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
                  let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) else {
                return false
            }
            down.flags = noFlags
            up.flags = noFlags
            utf16.withUnsafeBufferPointer { buf in
                down.keyboardSetUnicodeString(stringLength: buf.count, unicodeString: buf.baseAddress)
                up.keyboardSetUnicodeString(stringLength: buf.count, unicodeString: buf.baseAddress)
            }
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
            return true
        }
    }

    /// Remplace le CHAMP ENTIER par `text` via une sélection AX **vérifiée par
    /// relecture**, puis un unique Backspace + injection unicode (source privée,
    /// flags nettoyés — même hygiène que `replaceForCommit`).
    ///
    /// Pourquoi cette voie existe (UAT 11/06, Gmail) : le remplacement COMPTÉ
    /// (`replaceForCommit`) suppose que N Characters AX = N backspaces ; dans les
    /// contenteditable Chromium ce n'est pas toujours vrai (la suppression s'est
    /// arrêtée 5 caractères trop tôt → « BonjoHola, »). Sélectionner tout puis
    /// effacer supprime la classe d'erreur entière — aucun comptage.
    ///
    /// Pourquoi pas ⌘A : layout-dépendant (sur AZERTY `virtualKey 0` = Q → ⌘Q
    /// quitterait l'hôte). Pourquoi la relecture : des hôtes (Notes/RichTextEdit)
    /// répondent `.success` à l'écriture de `kAXSelectedTextRangeAttribute` en
    /// l'ignorant — on ne détruit RIEN tant que la sélection n'est pas confirmée.
    /// `false` (hôte menteur, champ vide, sécurisé…) → l'appelant retombe sur le
    /// chemin compté. Un Backspace sur une sélection active l'efface en entier
    /// dans tous les hôtes (geste utilisateur standard).
    @discardableResult
    public func replaceWholeFieldForCommit(with text: String) -> Bool {
        queue.sync {
            guard let appEl = focusedAppElement() else { return false }
            var focusedRef: AnyObject?
            guard AXUIElementCopyAttributeValue(appEl, kAXFocusedUIElementAttribute as CFString, &focusedRef) == .success,
                  let focused = focusedRef else { return false }
            let element = focused as! AXUIElement
            if copyStringAttr(element, kAXSubroleAttribute) == "AXSecureTextField" { return false }
            guard let current = copyStringAttr(element, kAXValueAttribute), !current.isEmpty else { return false }
            // CFRange AX en unités UTF-16 (sémantique NSString).
            var wanted = CFRange(location: 0, length: current.utf16.count)
            guard let rangeValue = AXValueCreate(.cfRange, &wanted),
                  AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, rangeValue) == .success else {
                return false
            }
            // Relecture : la sélection doit couvrir EXACTEMENT [0, len) — sinon
            // l'hôte a menti (ou tronqué) et on ne touche pas au champ.
            var readbackRef: AnyObject?
            guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &readbackRef) == .success,
                  let readback = readbackRef, CFGetTypeID(readback) == AXValueGetTypeID() else {
                return false
            }
            var got = CFRange(location: 0, length: 0)
            guard AXValueGetValue(readback as! AXValue, .cfRange, &got),
                  got.location == 0, got.length == wanted.length else {
                return false
            }
            // Sélection confirmée → un seul Backspace l'efface, puis injection.
            let source = Self.makeSyntheticSource(stateID: .privateState)
            let noFlags = CGEventFlags(rawValue: 0)
            usleep(5_000)
            guard let bsDown = CGEvent(keyboardEventSource: source, virtualKey: 51, keyDown: true),
                  let bsUp = CGEvent(keyboardEventSource: source, virtualKey: 51, keyDown: false) else {
                return false
            }
            bsDown.flags = noFlags
            bsUp.flags = noFlags
            bsDown.post(tap: .cghidEventTap)
            bsUp.post(tap: .cghidEventTap)
            usleep(5_000)
            let utf16 = Array(text.utf16)
            guard let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
                  let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) else {
                return false
            }
            down.flags = noFlags
            up.flags = noFlags
            utf16.withUnsafeBufferPointer { buf in
                down.keyboardSetUnicodeString(stringLength: buf.count, unicodeString: buf.baseAddress)
                up.keyboardSetUnicodeString(stringLength: buf.count, unicodeString: buf.baseAddress)
            }
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
            return true
        }
    }

    private func injectViaCGEvent(_ text: String) -> Bool {
        let source = Self.makeSyntheticSource(stateID: .hidSystemState)
        let utf16 = Array(text.utf16)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) else {
            return false
        }
        utf16.withUnsafeBufferPointer { buf in
            down.keyboardSetUnicodeString(stringLength: buf.count, unicodeString: buf.baseAddress)
            up.keyboardSetUnicodeString(stringLength: buf.count, unicodeString: buf.baseAddress)
        }
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        return true
    }

    private func focusedAppElement() -> AXUIElement? {
        if let app = copyAttr(systemWide, kAXFocusedApplicationAttribute) {
            return (app as! AXUIElement)
        }
        if let running = NSWorkspace.shared.frontmostApplication {
            return AXUIElementCreateApplication(running.processIdentifier)
        }
        return nil
    }

    public func diagnostic() -> String {
        queue.sync { readDiagnostic() }
    }

    /// Walks every regular GUI app and reports which ones expose a focused text element.
    /// Useful when NSWorkspace.frontmostApplication lies (e.g. Ghostty quick-terminal mode).
    public func scanAllApps() -> [String] {
        queue.sync {
            var rows: [String] = []
            for running in NSWorkspace.shared.runningApplications {
                guard running.activationPolicy == .regular else { continue }
                let pid = running.processIdentifier
                let bid = running.bundleIdentifier ?? "?"
                let appEl = AXUIElementCreateApplication(pid)
                var focused: AnyObject?
                let s = AXUIElementCopyAttributeValue(appEl, kAXFocusedUIElementAttribute as CFString, &focused)
                if s == .success, let focused {
                    let el = focused as! AXUIElement
                    let role = copyStringAttr(el, kAXRoleAttribute) ?? "?"
                    let active = running.isActive ? "ACTIVE" : "      "
                    rows.append("  \(active) [\(bid)] pid=\(pid) focusedRole=\(role)")
                }
            }
            return rows
        }
    }

    private func readDiagnostic() -> String {
        var out: [String] = []
        out.append("trusted=\(AXIsProcessTrusted())")

        let frontmost = NSWorkspace.shared.frontmostApplication
        out.append("NSWorkspace.frontmost=\(frontmost?.bundleIdentifier ?? "nil") pid=\(frontmost?.processIdentifier ?? -1)")

        var appRef: AnyObject?
        let appStatus = AXUIElementCopyAttributeValue(systemWide, kAXFocusedApplicationAttribute as CFString, &appRef)
        out.append("systemWide.FocusedApplication status=\(axErrorName(appStatus))")

        let appEl: AXUIElement
        let bid: String
        if appStatus == .success, let app = appRef {
            appEl = app as! AXUIElement
            var pid: pid_t = 0
            AXUIElementGetPid(appEl, &pid)
            bid = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier ?? "nil"
            out.append("ax.app pid=\(pid) bundle=\(bid) (via systemWide)")
        } else if let running = NSWorkspace.shared.frontmostApplication {
            appEl = AXUIElementCreateApplication(running.processIdentifier)
            bid = running.bundleIdentifier ?? "nil"
            out.append("ax.app pid=\(running.processIdentifier) bundle=\(bid) (via NSWorkspace fallback)")
        } else {
            return out.joined(separator: " | ")
        }

        var focusedRef: AnyObject?
        let focStatus = AXUIElementCopyAttributeValue(appEl, kAXFocusedUIElementAttribute as CFString, &focusedRef)
        out.append("app.FocusedUIElement status=\(axErrorName(focStatus))")
        guard focStatus == .success, let focused = focusedRef else {
            return out.joined(separator: " | ")
        }
        let element = focused as! AXUIElement
        let role = copyStringAttr(element, kAXRoleAttribute) ?? "nil"
        let subrole = copyStringAttr(element, kAXSubroleAttribute) ?? "nil"
        out.append("element role=\(role) subrole=\(subrole)")
        return out.joined(separator: " | ")
    }

    private func axErrorName(_ e: AXError) -> String {
        switch e {
        case .success: return "success"
        case .failure: return "failure"
        case .illegalArgument: return "illegalArgument"
        case .invalidUIElement: return "invalidUIElement"
        case .invalidUIElementObserver: return "invalidUIElementObserver"
        case .cannotComplete: return "cannotComplete"
        case .attributeUnsupported: return "attributeUnsupported"
        case .actionUnsupported: return "actionUnsupported"
        case .notificationUnsupported: return "notificationUnsupported"
        case .notImplemented: return "notImplemented"
        case .notificationAlreadyRegistered: return "notificationAlreadyRegistered"
        case .notificationNotRegistered: return "notificationNotRegistered"
        case .apiDisabled: return "apiDisabled"
        case .noValue: return "noValue"
        case .parameterizedAttributeUnsupported: return "parameterizedAttributeUnsupported"
        case .notEnoughPrecision: return "notEnoughPrecision"
        @unknown default: return "unknown(\(e.rawValue))"
        }
    }

    private func readSnapshot() -> AXSnapshot {
        // Try systemWide first; fall back to NSWorkspace.frontmostApplication when
        // it returns nil (some host apps, e.g. Ghostty, fail systemWide queries).
        let (appEl, bundleID): (AXUIElement?, String?) = {
            if let app = copyAttr(systemWide, kAXFocusedApplicationAttribute) {
                let el = app as! AXUIElement
                var pid: pid_t = 0
                AXUIElementGetPid(el, &pid)
                return (el, NSRunningApplication(processIdentifier: pid)?.bundleIdentifier)
            }
            if let running = NSWorkspace.shared.frontmostApplication {
                return (AXUIElementCreateApplication(running.processIdentifier), running.bundleIdentifier)
            }
            return (nil, nil)
        }()

        guard let appEl else {
            return AXSnapshot(bundleID: nil, role: nil, subrole: nil, text: nil, caretIndex: nil, caretRect: nil, caretFont: nil)
        }

        var appPID: pid_t = 0
        AXUIElementGetPid(appEl, &appPID)

        // Chromium/Electron unlock: wake the AX tree on first sight of this
        // app. Cheap no-op on Cocoa-native apps. Done BEFORE the focused-
        // element query so Signal et al. have a chance to populate. Retried
        // across ticks (the tree builds async) until the focused read below
        // reports it live.
        if let bid = bundleID {
            ensureAccessibilityActivated(for: appEl, bundleID: bid)
        }

        guard let focused = copyAttr(appEl, kAXFocusedUIElementAttribute) else {
            // Tree dormant (or just went dormant) ⇒ re-arm so the next ticks
            // re-wake it — recovers from Chromium's AutoDisableAccessibility
            // flipping the tree back off mid-session.
            recordTreeLiveness(pid: appPID, focusedReadable: false)
            return AXSnapshot(bundleID: bundleID, role: nil, subrole: nil, text: nil, caretIndex: nil, caretRect: nil, caretFont: nil)
        }
        // A focused element is readable ⇒ the (Chromium/Electron) AX tree is
        // live ⇒ stop re-attempting activation for this process.
        recordTreeLiveness(pid: appPID, focusedReadable: true)
        let element = focused as! AXUIElement

        let role = copyStringAttr(element, kAXRoleAttribute)
        let subrole = copyStringAttr(element, kAXSubroleAttribute)

        // SECURITY: never read content of secure text fields.
        if subrole == "AXSecureTextField" {
            return AXSnapshot(bundleID: bundleID, role: role, subrole: subrole, text: nil, caretIndex: nil, caretRect: nil, caretFont: nil)
        }

        guard let role, Self.textRoles.contains(role) else {
            return AXSnapshot(bundleID: bundleID, role: role, subrole: subrole, text: nil, caretIndex: nil, caretRect: nil, caretFont: nil)
        }

        let text = copyStringAttr(element, kAXValueAttribute)
        let (rawCaretIndex, caretRect) = readCaret(element)

        // ── Remap du caret Chromium multi-blocs (Linear dans Brave, 11/06) ──
        // Pour un contenteditable à plusieurs paragraphes (ProseMirror…),
        // Chromium rapporte un AXSelectedTextRange qui NE COMPTE PAS les
        // séparateurs de blocs, alors que l'AXValue matérialise un "\n" par
        // bloc : caret décalé de (nb de blocs avant lui), donc « mid-line »
        // détecté à tort en fin de texte et préfixe amputé. Reproduit : 2
        // paragraphes → caret = len-1, 3 → len-2 ; le <textarea> compte juste.
        // Gate triple : texte multi-lignes + caret pas déjà en fin + structure
        // composite Chromium (ChromeAXNodeId ET enfants AX = un par bloc) —
        // Notes (1 enfant, pas de ChromeAXNodeId) et les textarea (0 enfant)
        // ne matchent pas.
        let caretIndex: Int? = {
            guard let raw = rawCaretIndex, let text,
                  raw < text.count,
                  text.contains(where: \.isNewline),
                  isChromiumCompositeText(element) else { return rawCaretIndex }
            return Self.remapBlockCaret(text: text, reported: raw)
        }()
        let elementRect = readElementRect(element)
        let caretFont = caretIndex.flatMap { readFont(element, at: $0) }

        // ── Phase 2: high-signal slot inputs (read at snapshot time, D-15b) ──
        // Placeholder + help: zero-cost direct reads via the existing
        // copyStringAttr helper. Both skipped automatically by the
        // secure-field guard above (early return before this block).
        let placeholder = copyStringAttr(element, kAXPlaceholderValueAttribute)
        let help = copyStringAttr(element, kAXHelpAttribute)

        // textAfterCaret: only meaningful when we have both `text` and
        // `caretIndex` AND the caret is strictly before end-of-text. Cap
        // the read at 500 chars — well above the 120-token afterCursor budget
        // (D-14d) but bounded.
        // Sous-chaîne de `text` (kAXValue), PAS de lecture paramétrée
        // kAXStringForRange : Chromium/Brave la renvoie nil/erratique, et le
        // plan de fusion mid-line recevait alors "" → ré-injection de ce qui
        // existait déjà après le caret (UAT 11/06 : « caret|ret » + Tab →
        // « caretret »). La soustraction text+caretIndex est la MÊME source
        // que la détection mid-line du tick et le préfixe du ghost — une seule
        // vérité, les deux côtés voient le même « après-caret ».
        let textAfterCaret: String? = {
            guard let text, let caretIndex,
                  caretIndex >= 0, caretIndex < text.count else { return nil }
            let length = min(text.count - caretIndex, 500)
            let start = text.index(text.startIndex, offsetBy: caretIndex)
            let end = text.index(start, offsetBy: length)
            return String(text[start..<end])
        }()

        // Focused window title — used by the allowlist regex matcher.
        // Nil if no window is focused or AX denies the read.
        let windowTitle: String? = {
            guard let windowRef = copyAttr(appEl, kAXFocusedWindowAttribute) else { return nil }
            let windowEl = windowRef as! AXUIElement
            return copyStringAttr(windowEl, kAXTitleAttribute)
        }()

        // Marqueurs de champ utilitaire (omnibox…) : 3 lectures de plus par
        // tick, seulement pour les champs single-line — les barres d'adresse
        // sont toujours des AXTextField/AXComboBox, jamais des AXTextArea, et
        // la composition (le cas chaud) reste à coût inchangé.
        var identifier: String?
        var domIdentifier: String?
        var domClassList: [String]?
        var hasPopup = false
        var autocompleteKind: String?
        if role != "AXTextArea" {
            identifier = copyStringAttr(element, kAXIdentifierAttribute)
            domIdentifier = copyStringAttr(element, "AXDOMIdentifier")
            domClassList = copyAttr(element, "AXDOMClassList") as? [String]
            hasPopup = (copyAttr(element, "AXHasPopup") as? Bool) ?? false
            autocompleteKind = copyStringAttr(element, "AXAutocompleteValue")
        }

        return AXSnapshot(
            bundleID: bundleID,
            role: role,
            subrole: subrole,
            text: text,
            caretIndex: caretIndex,
            caretRect: caretRect,
            caretFont: caretFont,
            windowTitle: windowTitle,
            elementRect: elementRect,
            placeholder: placeholder,
            help: help,
            textAfterCaret: textAfterCaret,
            identifier: identifier,
            domIdentifier: domIdentifier,
            domClassList: domClassList,
            hasPopup: hasPopup,
            autocompleteKind: autocompleteKind
        )
    }

    /// Structure « texte composite » Chromium : l'élément vient du contenu web
    /// (attribut propriétaire `ChromeAXNodeId` lisible) ET expose des enfants
    /// AX — un par bloc pour un contenteditable. C'est exactement la forme dont
    /// les offsets de caret sont décalés (voir le remap dans `readSnapshot`).
    /// 2 IPC max, et seulement quand le texte est multi-lignes.
    private func isChromiumCompositeText(_ element: AXUIElement) -> Bool {
        var ref: AnyObject?
        guard AXUIElementCopyAttributeValue(element, "ChromeAXNodeId" as CFString, &ref) == .success else {
            return false
        }
        var childCount: CFIndex = 0
        AXUIElementGetAttributeValueCount(element, kAXChildrenAttribute as CFString, &childCount)
        return childCount > 0
    }

    /// Convertit un offset de caret « sans séparateurs de blocs » (quirk
    /// Chromium contenteditable) vers l'index réel dans `text` (où chaque bloc
    /// est séparé par un "\n"). Marche en consommant `reported` caractères
    /// NON-newline ; à égalité sur une frontière de bloc, place le caret AVANT
    /// le "\n" (fin de ligne = le cas de frappe courant, et un ghost y reste
    /// légitime). Identité quand `text` ne contient pas de newline.
    public static func remapBlockCaret(text: String, reported: Int) -> Int {
        guard reported >= 0 else { return reported }
        var consumed = 0
        for (index, ch) in text.enumerated() {
            if consumed == reported { return index }
            if !ch.isNewline { consumed += 1 }
        }
        return text.count
    }

    private func readFont(_ element: AXUIElement, at caret: Int) -> AXFontInfo? {
        // Probe the character before the caret (or after if caret is at 0) to get
        // the font of the text being edited.
        let probeStart = max(0, caret - 1)
        var range = CFRange(location: probeStart, length: 1)
        guard let axRange = AXValueCreate(.cfRange, &range) else { return nil }

        var attrRef: AnyObject?
        let status = AXUIElementCopyParameterizedAttributeValue(
            element,
            kAXAttributedStringForRangeParameterizedAttribute as CFString,
            axRange,
            &attrRef
        )
        guard status == .success, let attr = attrRef as? NSAttributedString, attr.length > 0 else {
            return nil
        }
        guard let font = attr.attribute(.font, at: 0, effectiveRange: nil) as? NSFont else {
            return nil
        }
        return AXFontInfo(familyName: font.fontName, pointSize: Double(font.pointSize))
    }

    /// Resolves the caret position via a cascade of techniques (in priority order):
    ///
    /// 1. **`AXBoundsForRange` with `length=0`** — the canonical caret query.
    ///    Most native Cocoa apps return a thin caret rect whose `origin.x` is
    ///    the exact caret X. We use this FIRST. (We previously defaulted to
    ///    `length=1`, which returns the bounds of the character AT the caret
    ///    position — its `origin.x` is the LEFT edge of that character, off
    ///    by one char-width when the caret is at end of text and AX falls
    ///    back to returning the previous char's bounds.)
    ///
    /// 2. **`AXBoundsForTextMarkerRange`** — Chromium/WebKit fallback. Brave,
    ///    Chrome, Edge, Discord and other CEF/Electron apps refuse NSRange
    ///    queries on web content but honour their internal `AXTextMarker`
    ///    selection objects. We read `AXSelectedTextMarkerRange`, hand it back
    ///    in `AXBoundsForTextMarkerRange`, and get a precise caret rect.
    ///
    /// 3. **`AXBoundsForRange` with `length=1` on the PREVIOUS character** —
    ///    when length=0 returns a degenerate rect (some hosts) and AXTextMarker
    ///    isn't honoured, we probe the character before the caret and snap to
    ///    its `maxX` (trailing edge = caret position). Works because the
    ///    previous-character path doesn't have the "end of text" ambiguity
    ///    that length=1-at-caret suffers from.
    ///
    /// 4. **`AXBoundsForRange` with `length=1` AT the caret** — last resort,
    ///    used when nothing else works. Trusts `origin.x` as the caret X
    ///    (correct mid-text; off by one char at end of text — but better than
    ///    nothing). Followed downstream by OCR refinement on bundles where AX
    ///    is unreliable.
    ///
    /// All branches validate the returned rect with `width > 0 && height > 0`
    /// to filter out Chromium's degenerate `(0, Y, 0, 0)` placeholders. When
    /// a branch returns a suspiciously wide rect (>= ~30 px = line fragment
    /// rather than caret), we collapse it to a thin caret of the same height.
    /// Inspired by Tabby's `AXTextGeometryResolver` (AGPL).
    private func readCaret(_ element: AXUIElement) -> (Int?, CGRect?) {
        guard let rangeRef = copyAttr(element, kAXSelectedTextRangeAttribute) else {
            return (nil, nil)
        }
        var cfRange = CFRange(location: 0, length: 0)
        guard AXValueGetValue(rangeRef as! AXValue, .cfRange, &cfRange) else {
            return (nil, nil)
        }
        let caretIndex = cfRange.location

        // Pre-fetch the rect for the previous character once. It anchors Y
        // and height (the prev char is necessarily on the caret's visual
        // line, modulo soft-wrap edge cases) while length=0 anchors X.
        let prevRect: CGRect? = {
            guard caretIndex > 0,
                  let r = boundsForRange(element, location: caretIndex - 1, length: 1),
                  isPlausibleCaretRect(r)
            else { return nil }
            return r
        }()

        // Branch 1: zero-length range at caret. Ideal source of X (the
        // length=0 contract treats origin.x as the caret column, even at
        // end-of-text where length=1 returns the previous char's bounds).
        // Y from length=0 is unreliable in some hosts — it can describe
        // the line gap rather than the caret line. So we MERGE: take X
        // from length=0, but Y/height from prevRect when available.
        if let zero = boundsForRange(element, location: caretIndex, length: 0),
           isPlausibleCaretRect(zero) {
            let caretX = zero.origin.x
            if let prev = prevRect {
                return (caretIndex, CGRect(
                    x: caretX, y: prev.minY,
                    width: 1, height: prev.height
                ))
            }
            // No prev char (caretIndex == 0 or AX refused): trust length=0
            // fully. Empty-field case — the Y mismatch is usually invisible
            // because there's no other text to compare against.
            return (caretIndex, collapseToCaret(zero))
        }

        // Branch 1.5: AXTextMarker — Chromium / WebKit. Apps like Brave,
        // Chrome, Edge, Discord, Slack refuse NSRange queries on web
        // content but honour their internal AXTextMarker selection.
        if let marker = textMarkerCaretRect(element),
           isPlausibleCaretRect(marker) {
            // Marker queries return a usable rect for both axes — webview
            // hosts produce a true thin caret box, not a line-gap shim.
            return (caretIndex, collapseToCaret(marker))
        }

        // Branch 2: previous character's trailing edge, used when length=0
        // returns nothing AND AXTextMarker isn't honoured. prev.maxX is
        // the exact caret X for non-wrapped lines.
        if let prev = prevRect {
            return (caretIndex, CGRect(
                x: prev.maxX, y: prev.minY,
                width: 1, height: prev.height
            ))
        }

        // Branch 3: length=1 at caret. Last resort — caret-at-end suffers
        // the "previous char's bounds" ambiguity here, but with everything
        // else failing this is still better than nothing.
        if let primary = boundsForRange(element, location: caretIndex, length: 1),
           isPlausibleCaretRect(primary) {
            return (caretIndex, collapseToCaret(primary))
        }

        return (caretIndex, nil)
    }

    /// Reject degenerate AX returns: zero-size rects (Chromium placeholders),
    /// negative dimensions, and visually impossible coords.
    private func isPlausibleCaretRect(_ rect: CGRect) -> Bool {
        rect.width >= 0 && rect.height > 0 && rect.size != .zero
    }

    /// Stricter gate for a multi-character WORD rect: it must have real width
    /// (a caret-thin or zero rect means the host couldn't resolve the range and
    /// we should try the marker path), finite, on-screen extent.
    private func isPlausibleWordRect(_ rect: CGRect) -> Bool {
        rect.width >= 2 && rect.height >= 2
            && rect.origin.x.isFinite && rect.origin.y.isFinite
            && rect.width < 4000 && rect.height < 400
    }

    /// When a host returns a line-fragment rect for a zero-length range query
    /// (Notes, some browsers), collapse the width down to 1 px while keeping
    /// `origin.x` (which IS the caret X in the length=0 contract — even when
    /// the rect is wide, origin.x marks the caret column on that line).
    private func collapseToCaret(_ rect: CGRect) -> CGRect {
        guard rect.width > 6 else {
            return rect.width > 0
                ? rect
                : CGRect(x: rect.origin.x, y: rect.origin.y, width: 1, height: rect.height)
        }
        return CGRect(x: rect.origin.x, y: rect.origin.y, width: 1, height: rect.height)
    }

    /// Chromium and WebKit apps (Brave, Chrome, Edge, Discord, Slack, many
    /// Electron apps) refuse `AXBoundsForRange` queries against NSRange on web
    /// content, but they expose a private-but-stable Accessibility selection
    /// object called `AXTextMarkerRange`. Asking for `AXSelectedTextMarkerRange`
    /// then handing it back in `AXBoundsForTextMarkerRange` returns the exact
    /// caret bounding box that NSRange queries failed to produce.
    ///
    /// This bypasses the need to translate between web positions and NSRange
    /// indices entirely — the browser does its own range→pixel resolution.
    private func textMarkerCaretRect(_ element: AXUIElement) -> CGRect? {
        // Step 1: ask the element for its current selected text marker range.
        var markerValue: CFTypeRef?
        let step1 = AXUIElementCopyAttributeValue(
            element,
            "AXSelectedTextMarkerRange" as CFString,
            &markerValue
        )
        guard step1 == .success, let marker = markerValue else { return nil }

        // Step 2: ask the element to compute the bounding box for that exact
        // marker range. This is a parameterized attribute on the same element.
        var boundsValue: CFTypeRef?
        let step2 = AXUIElementCopyParameterizedAttributeValue(
            element,
            "AXBoundsForTextMarkerRange" as CFString,
            marker,
            &boundsValue
        )
        guard step2 == .success, let bounds = boundsValue else { return nil }
        // Type-guard before unsafe-cast — AXValue is a CF type, not Swift class.
        guard CFGetTypeID(bounds) == AXValueGetTypeID() else { return nil }
        let axBounds = unsafeBitCast(bounds, to: AXValue.self)
        guard AXValueGetType(axBounds) == .cgRect else { return nil }
        var rect = CGRect.zero
        guard AXValueGetValue(axBounds, .cgRect, &rect) else { return nil }
        return rect
    }

    /// Pixel-perfect screen-space (Quartz, top-left origin) bounds of the focused
    /// element's text range `[location, location+length)`, in **UTF-16 units**.
    /// Used to strike the misspelled word in place.
    ///
    /// This path is `AXBoundsForRange` (NSRange) only — it is exact on native
    /// AppKit hosts (Notes, TextEdit, Mail). Chromium/WebKit (Brave, Slack,
    /// Electron) refuse NSRange queries for ranges and their text-marker walk
    /// proved unreliable (it resolves whole-line bounding boxes, not the word),
    /// so the caller estimates the word rect geometrically from the caret rect
    /// instead. Returns nil whenever the host can't give a genuine word box.
    public func boundsForFocusedRange(location: Int, length: Int) -> CGRect? {
        guard location >= 0, length > 0 else { return nil }
        return queue.sync {
            guard let appEl = focusedAppElement() else { return nil }
            var focusedRef: AnyObject?
            guard AXUIElementCopyAttributeValue(appEl, kAXFocusedUIElementAttribute as CFString, &focusedRef) == .success,
                  let focused = focusedRef else {
                return nil
            }
            let element = focused as! AXUIElement
            // Accept only a rect with real WORD extent — Chromium answers
            // .success with a zero/1px caret-like rect for a multi-char range,
            // which `isPlausibleCaretRect` (built for thin carets) would wrongly
            // accept. Requiring genuine width makes those return nil so the
            // caller's geometric estimate takes over.
            guard let r = boundsForRange(element, location: location, length: length),
                  isPlausibleWordRect(r) else {
                return nil
            }
            return r
        }
    }

    /// Thin wrapper around `kAXBoundsForRangeParameterizedAttribute` that
    /// returns a `CGRect` (Quartz screen coordinates) or nil if the host
    /// refuses the query. Used by the caret-probe narrowing path.
    private func boundsForRange(_ element: AXUIElement, location: Int, length: Int) -> CGRect? {
        var probe = CFRange(location: location, length: length)
        guard let axRange = AXValueCreate(.cfRange, &probe) else { return nil }
        var bounds: AnyObject?
        let status = AXUIElementCopyParameterizedAttributeValue(
            element,
            kAXBoundsForRangeParameterizedAttribute as CFString,
            axRange,
            &bounds
        )
        guard status == .success, let bounds else { return nil }
        var rect = CGRect.zero
        guard AXValueGetValue(bounds as! AXValue, .cgRect, &rect) else { return nil }
        return rect
    }

    /// Frame of the focused element in screen coordinates (Quartz). Combines
    /// `kAXPositionAttribute` + `kAXSizeAttribute`. Nil if either read fails.
    private func readElementRect(_ element: AXUIElement) -> CGRect? {
        guard let posRef = copyAttr(element, kAXPositionAttribute),
              let sizeRef = copyAttr(element, kAXSizeAttribute) else {
            return nil
        }
        var origin = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(posRef as! AXValue, .cgPoint, &origin),
              AXValueGetValue(sizeRef as! AXValue, .cgSize, &size) else {
            return nil
        }
        return CGRect(origin: origin, size: size)
    }

    private func copyAttr(_ element: AXUIElement, _ attribute: String) -> AnyObject? {
        var ref: AnyObject?
        let status = AXUIElementCopyAttributeValue(element, attribute as CFString, &ref)
        guard status == .success else { return nil }
        return ref
    }

    private func copyStringAttr(_ element: AXUIElement, _ attribute: String) -> String? {
        copyAttr(element, attribute) as? String
    }
}

/// Callback C de l'observer AX push (Fix 2, flag `SOUFFLEUSE_AX_PUSH`). Volontairement
/// au TOP-LEVEL (et non un closure dans `ensureAccessibilityActivated`) : le placer
/// dans le corps de la méthode fait crasher le pass SIL `SendNonSendable` du
/// compilateur. `@convention(c)` ⇒ aucune capture ; l'AXClient transite par `refcon`
/// (pointeur non retenu, valide car l'AXClient possède l'observer et lui survit).
/// Hors flag → garde + return ⇒ strictement no-op. Invoqué sur le MAIN run-loop.
private func souffleuseAXPushObserverCallback(
    _ observer: AXObserver,
    _ element: AXUIElement,
    _ notification: CFString,
    _ refcon: UnsafeMutableRawPointer?
) {
    guard AXClient.axPushEnabled, let refcon else { return }
    let client = Unmanaged<AXClient>.fromOpaque(refcon).takeUnretainedValue()
    client.onHostAXChanged?()
}
