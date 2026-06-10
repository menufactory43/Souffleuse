import CoreGraphics
import Foundation
import os

/// Session-level CGEventTap that consumes Tab/Esc when a suggestion is active.
///
/// The tap runs on a DEDICATED background thread with its own run loop — NOT
/// the main run loop. This is critical: while a ghost is showing the tap is
/// enabled and every keystroke passes through the tap's run loop. On the main
/// run loop that means each key waits behind whatever the main thread is doing
/// (the poll tick, AX snapshots, overlay layout) — fast typing then drops
/// letters and a delayed keyDown trips macOS's press-and-hold accent popup. A
/// dedicated thread keeps key delivery immediate regardless of main-thread load.
///
/// The tap is created up-front but kept disabled until `setActive(true)`.
/// Disabling when no suggestion shows means normal typing never touches the tap.
/// User-selectable key that accepts the WHOLE ghost at once (vs Tab = the
/// word-by-word partial accept). Maps each preset to a hardware keycode + the
/// relevant modifier flags. `.disabled` turns the feature off.
public enum AcceptAllKey: String, CaseIterable, Sendable {
    case disabled, rightArrow, cmdRight, returnKey, shiftTab

    public var keyCode: Int64? {
        switch self {
        case .disabled: return nil
        case .rightArrow, .cmdRight: return 124   // →
        case .returnKey: return 36                // ↩
        case .shiftTab: return 48                 // ⇥ (+ shift)
        }
    }
    public var requiredFlagsRaw: UInt64 {
        switch self {
        case .cmdRight: return CGEventFlags.maskCommand.rawValue
        case .shiftTab: return CGEventFlags.maskShift.rawValue
        default: return 0
        }
    }
    public var label: String {
        switch self {
        case .disabled: return "Désactivé"
        case .rightArrow: return "→ Flèche droite"
        case .cmdRight: return "⌘→ Cmd + Flèche droite"
        case .returnKey: return "↩ Entrée"
        case .shiftTab: return "⇧⇥ Maj + Tab"
        }
    }
}

/// User-selectable key that COMMITS the translation HUD — remplace la ligne du
/// champ focus par le texte en langue cible. Distincte d'`AcceptAllKey` (qui
/// pose le ghost FRANÇAIS). Défaut ⌘↩. `.disabled` la désactive. Même forme
/// (keyCode + masque de flags requis) qu'`AcceptAllKey` pour que
/// `KeyInterceptor.resolveKey` traite les deux bindings identiquement.
public enum CommitKey: String, CaseIterable, Sendable {
    case disabled, cmdReturn, cmdShiftReturn, optionReturn

    public var keyCode: Int64? {
        switch self {
        case .disabled: return nil
        case .cmdReturn, .cmdShiftReturn, .optionReturn: return 36   // ↩
        }
    }
    public var requiredFlagsRaw: UInt64 {
        switch self {
        case .cmdReturn: return CGEventFlags.maskCommand.rawValue
        case .cmdShiftReturn: return CGEventFlags.maskCommand.rawValue | CGEventFlags.maskShift.rawValue
        case .optionReturn: return CGEventFlags.maskAlternate.rawValue
        case .disabled: return 0
        }
    }
    public var label: String {
        switch self {
        case .disabled: return "Désactivé"
        case .cmdReturn: return "⌘↩ Cmd + Entrée"
        case .cmdShiftReturn: return "⌘⇧↩ Cmd + Maj + Entrée"
        case .optionReturn: return "⌥↩ Option + Entrée"
        }
    }
}

/// Touche qui FAIT DÉFILER la langue cible de la traduction (EN→ES→DE→IT→AUTO),
/// pour la conversation courante. Active uniquement pendant qu'un ghost s'affiche
/// (même fenêtre que le commit). Même forme (keyCode + masque de flags) que
/// `CommitKey`/`AcceptAllKey` → `resolveKey` la traite identiquement. Défaut ⌘⇧→.
public enum TargetCycleKey: String, CaseIterable, Sendable {
    case disabled, cmdShiftRight, ctrlRight, optionRight

    public var keyCode: Int64? {
        switch self {
        case .disabled: return nil
        case .cmdShiftRight, .ctrlRight, .optionRight: return 124   // →
        }
    }
    public var requiredFlagsRaw: UInt64 {
        switch self {
        case .cmdShiftRight: return CGEventFlags.maskCommand.rawValue | CGEventFlags.maskShift.rawValue
        case .ctrlRight: return CGEventFlags.maskControl.rawValue
        case .optionRight: return CGEventFlags.maskAlternate.rawValue
        case .disabled: return 0
        }
    }
    public var label: String {
        switch self {
        case .disabled: return "Désactivé"
        case .cmdShiftRight: return "⌘⇧→ Cmd + Maj + Flèche droite"
        case .ctrlRight: return "⌃→ Ctrl + Flèche droite"
        case .optionRight: return "⌥→ Option + Flèche droite"
        }
    }
}

public final class KeyInterceptor: @unchecked Sendable {
    public enum Key: Sendable, Equatable {
        case tab
        case esc
        case acceptAll
        case commit
        case cycleTarget
        /// Position 1…9 de la RANGÉE PHYSIQUE de chiffres, sans modificateur —
        /// sélection d'un candidat du picker emoji. Résolu UNIQUEMENT quand le
        /// picker est armé : sur AZERTY ces touches nues produisent « &é"'(… »
        /// (jamais un chiffre — taper « 14:30 » exige Maj, qui passe à l'hôte) ;
        /// sur QWERTY le panneau ne s'ouvre pas après un chiffre (garde 14:30),
        /// donc le vol d'un vrai chiffre reste marginal.
        case digit(Int)
    }

    /// Called on the tap thread when a Tab/Esc keyDown arrives while active.
    /// Return true to CONSUME the key (swallow it), false to let it pass. The
    /// implementation must NOT block on the main thread — dispatch any
    /// main-actor work asynchronously and return the consume decision at once.
    public typealias Handler = @Sendable (Key) -> Bool

    private let handler: Handler
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var tapThread: Thread?
    private var tapRunLoop: CFRunLoop?
    /// `active` is written from the main thread (`setActive`) and read on the
    /// tap thread (`handle`), so it is guarded by a lock.
    private let lock = OSAllocatedUnfairLock(initialState: false)
    /// SOURCES d'armement du tap : `ghost` (une suggestion s'affiche — sémantique
    /// historique de `setActive`), `hud` (le panneau de traduction est visible —
    /// permet ⌘↩/⌘⇧→ SANS ghost) et `picker` (le picker emoji est visible —
    /// permet la rangée 1–9 et Esc). Le tap est armé si l'une est vraie ; la
    /// POLITIQUE DE CONSOMMATION diffère (voir `shouldConsume`) : armé-HUD-seul,
    /// Tab/Esc/accept-all restent à l'hôte ; armé-picker-seul, seuls les digits
    /// et Esc nous appartiennent — la frappe normale continue dans l'app hôte.
    /// Écrit du main (`setActive`/`setHUDArmed`/`setPickerArmed`), lu sur le
    /// thread du tap.
    private let armSources = OSAllocatedUnfairLock<(ghost: Bool, hud: Bool, picker: Bool)>(
        initialState: (false, false, false))
    /// Configurable "accept all" binding (keyCode + relevant modifier flags as a
    /// raw mask), nil when disabled. Written from the main thread
    /// (`setAcceptAllKey`), read on the tap thread (`handle`); its own lock.
    private let acceptBinding = OSAllocatedUnfairLock<(code: Int64, flagsRaw: UInt64)?>(initialState: nil)
    /// Configurable "commit" binding (translation HUD → replace field). Même
    /// forme et même discipline de lock qu'`acceptBinding` ; écrit depuis le main
    /// (`setCommitKey`), lu sur le thread du tap (`handle`).
    private let commitBinding = OSAllocatedUnfairLock<(code: Int64, flagsRaw: UInt64)?>(initialState: nil)
    /// Configurable "cycle target language" binding. Même forme et même
    /// discipline de lock que `commitBinding` ; écrit depuis le main
    /// (`setTargetCycleKey`), lu sur le thread du tap (`handle`).
    private let cycleBinding = OSAllocatedUnfairLock<(code: Int64, flagsRaw: UInt64)?>(initialState: nil)

    public init(handler: @escaping Handler) {
        self.handler = handler
    }

    /// Create the tap and start its dedicated run-loop thread. Must be called
    /// from the main thread. Returns false if the tap couldn't be created
    /// (typically missing Accessibility / Input Monitoring permission).
    @discardableResult
    public func install() -> Bool {
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, refcon in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                let me = Unmanaged<KeyInterceptor>.fromOpaque(refcon).takeUnretainedValue()
                return me.handle(type: type, event: event)
            },
            userInfo: selfPtr
        ) else {
            return false
        }
        self.tap = tap

        // Run the tap's source on a dedicated thread's run loop so key delivery
        // is never delayed by main-thread work.
        let thread = Thread { [weak self] in
            guard let self, let tap = self.tap else { return }
            let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
            self.runLoopSource = source
            let rl = CFRunLoopGetCurrent()
            self.tapRunLoop = rl
            CFRunLoopAddSource(rl, source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: false)  // start disabled
            CFRunLoopRun()
        }
        thread.name = "app.cocotypist.keytap"
        thread.qualityOfService = .userInteractive
        thread.start()
        self.tapThread = thread
        return true
    }

    /// Toggle whether the tap consumes Tab/Esc. When inactive, all key events
    /// flow through untouched (Tab still does its normal job in forms, etc.).
    /// Sémantique HISTORIQUE conservée pour les ~35 call-sites : pilote la
    /// source `ghost` uniquement — l'armement HUD (`setHUDArmed`) survit.
    public func setActive(_ active: Bool) {
        setArm(ghost: active)
    }

    /// Arme/désarme le tap pour le PANNEAU DE TRADUCTION (visible sans ghost) :
    /// ⌘↩ (commit) et ⌘⇧→ (cycle) deviennent interceptables pendant que le HUD
    /// est à l'écran ; Tab/Esc/accept-all restent à l'hôte (voir `shouldConsume`).
    public func setHUDArmed(_ armed: Bool) {
        setArm(hud: armed)
    }

    /// Arme/désarme le tap pour le PICKER EMOJI (panneau « : » au caret) : la
    /// rangée physique 1–9 sans modificateur et Esc deviennent interceptables
    /// tant que le panneau est visible ; tout le reste passe à l'hôte.
    public func setPickerArmed(_ armed: Bool) {
        setArm(picker: armed)
    }

    /// Recalcule l'état effectif (OR des sources) et (dés)active le tap.
    private func setArm(ghost: Bool? = nil, hud: Bool? = nil, picker: Bool? = nil) {
        guard let tap else { return }
        let effective = armSources.withLock { s in
            if let g = ghost { s.ghost = g }
            if let h = hud { s.hud = h }
            if let p = picker { s.picker = p }
            return s.ghost || s.hud || s.picker
        }
        lock.withLock { $0 = effective }
        CGEvent.tapEnable(tap: tap, enable: effective)
    }

    /// Politique de consommation PURE (testable sans tap) : armé pour un ghost,
    /// toute touche résolue nous appartient (comportement historique — le
    /// handler décide et on avale) ; armé pour le HUD SEULEMENT, seules les
    /// touches de traduction (.commit/.cycleTarget) sont consommées — un Tab,
    /// un Esc ou la touche accept-all (souvent →) tapés pendant que le panneau
    /// est visible continuent leur vie normale dans l'app hôte. Armé pour le
    /// PICKER emoji, les digits 1–9 et Esc nous appartiennent (fermer/choisir).
    static func shouldConsume(key: Key, ghostArmed: Bool, pickerArmed: Bool = false) -> Bool {
        switch key {
        case .commit, .cycleTarget: return true
        case .digit: return pickerArmed
        case .esc: return ghostArmed || pickerArmed
        case .tab, .acceptAll: return ghostArmed
        }
    }

    /// Update the user-selected "accept all" key. Safe to call from main.
    public func setAcceptAllKey(_ k: AcceptAllKey) {
        acceptBinding.withLock { state in
            state = k.keyCode.map { (code: $0, flagsRaw: k.requiredFlagsRaw) }
        }
    }

    /// Update the user-selected "commit" key. Safe to call from main.
    public func setCommitKey(_ k: CommitKey) {
        commitBinding.withLock { state in
            state = k.keyCode.map { (code: $0, flagsRaw: k.requiredFlagsRaw) }
        }
    }

    /// Update the user-selected "cycle target language" key. Safe to call from main.
    public func setTargetCycleKey(_ k: TargetCycleKey) {
        cycleBinding.withLock { state in
            state = k.keyCode.map { (code: $0, flagsRaw: k.requiredFlagsRaw) }
        }
    }

    /// Modifier bits that matter for binding comparison (caps lock, fn, numeric
    /// pad, etc. are ignored).
    static let relevantFlags: UInt64 = CGEventFlags.maskCommand.rawValue | CGEventFlags.maskShift.rawValue
        | CGEventFlags.maskAlternate.rawValue | CGEventFlags.maskControl.rawValue

    /// Marqueur des événements clavier SYNTHÉTIQUES de l'app elle-même (posés
    /// par `AXClient` : flèches de saut mid-line, backspaces, inserts unicode).
    /// Ils DOIVENT traverser le tap sans être résolus : la flèche → synthétique
    /// de `moveCaretRight` a le même keyCode 124 sans modificateur que le
    /// binding accept-all par défaut — sans cette garde, notre propre tap
    /// l'avalait (caret immobile) et re-déclenchait un accept en cascade
    /// (champ détruit, reproduit dans TextEdit 2026-06-10).
    /// JUMEAU : `AXClient.syntheticEventUserData` (SouffleuseAX) — aucune
    /// dépendance commune entre les deux targets, constante dupliquée et
    /// verrouillée par un test d'égalité (SouffleuseTests).
    public static let syntheticEventUserData: Int64 = 0x534F_5546   // "SOUF"

    /// Pure decision seam : l'événement porte-t-il notre marqueur synthétique ?
    static func isOwnSyntheticEvent(userData: Int64) -> Bool {
        userData == syntheticEventUserData
    }

    /// KeyCodes POSITIONNELS (ANSI) de la rangée de chiffres → position 1…9.
    /// Les keycodes macOS sont attachés à la touche physique, pas au glyphe :
    /// la même table vaut pour AZERTY (où la touche nue tape « & é " '… »)
    /// et QWERTY. Notez le désordre matériel historique (5↔6, 7/8/9).
    static let digitRowPositions: [Int64: Int] = [
        18: 1, 19: 2, 20: 3, 21: 4, 23: 5, 22: 6, 26: 7, 28: 8, 25: 9,
    ]

    /// Pure keyCode + modifier → `Key` resolution, extracted from `handle` so it
    /// is unit-testable without a live CGEventTap. `commit` est testé AVANT
    /// `acceptAll` (priorité à l'action de traduction) ; un binding configuré
    /// peut recouvrir un Tab modifié (ex. ⇧⇥) donc il est testé avant les
    /// Tab/Esc nus, qui exigent AUCUN modificateur. Renvoie nil quand rien ne
    /// matche → la touche passe sans être consommée.
    ///
    /// `pickerArmed` : les digits 1–9 ne sont RÉSOLUS que pendant que le picker
    /// emoji est visible — sinon une frappe « & » (AZERTY) ou « 1 » (QWERTY)
    /// pendant un ghost serait résolue puis avalée par la politique historique
    /// « armé-ghost consomme tout ».
    static func resolveKey(
        keyCode: Int64,
        mods: UInt64,
        commit: (code: Int64, flagsRaw: UInt64)?,
        acceptAll: (code: Int64, flagsRaw: UInt64)?,
        cycleTarget: (code: Int64, flagsRaw: UInt64)? = nil,
        pickerArmed: Bool = false
    ) -> Key? {
        if let b = commit, keyCode == b.code, mods == (b.flagsRaw & relevantFlags) { return .commit }
        if let b = cycleTarget, keyCode == b.code, mods == (b.flagsRaw & relevantFlags) { return .cycleTarget }
        if let b = acceptAll, keyCode == b.code, mods == (b.flagsRaw & relevantFlags) { return .acceptAll }
        if pickerArmed, mods == 0, let n = digitRowPositions[keyCode] { return .digit(n) }
        switch keyCode {
        case 48 where mods == 0: return .tab
        case 53 where mods == 0: return .esc
        default: return nil
        }
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            // macOS disabled the tap (we took too long, or user input quirk).
            // Re-enable so we keep working — only if we're still meant to be on.
            if let tap, lock.withLock({ $0 }) {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }
        guard type == .keyDown else {
            return Unmanaged.passUnretained(event)
        }
        // Nos propres événements synthétiques (AXClient) passent sans résolution
        // — voir `syntheticEventUserData`. Les frappes matérielles portent 0.
        if Self.isOwnSyntheticEvent(userData: event.getIntegerValueField(.eventSourceUserData)) {
            return Unmanaged.passUnretained(event)
        }
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let mods = event.flags.rawValue & Self.relevantFlags
        let arm = armSources.withLock { $0 }
        guard let key = Self.resolveKey(
            keyCode: keyCode,
            mods: mods,
            commit: commitBinding.withLock { $0 },
            acceptAll: acceptBinding.withLock { $0 },
            cycleTarget: cycleBinding.withLock { $0 },
            pickerArmed: arm.picker
        ) else {
            return Unmanaged.passUnretained(event)
        }
        // Armé pour le HUD seul (pas de ghost) : Tab/Esc/accept-all passent —
        // seules les touches de traduction sont à nous. Armé-picker : digits + Esc.
        guard Self.shouldConsume(key: key, ghostArmed: arm.ghost, pickerArmed: arm.picker) else {
            return Unmanaged.passUnretained(event)
        }
        if handler(key) {
            return nil
        }
        return Unmanaged.passUnretained(event)
    }
}
