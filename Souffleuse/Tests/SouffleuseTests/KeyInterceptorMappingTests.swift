import CoreGraphics
import Testing
@testable import SouffleuseInput

// MARK: - KeyInterceptorMappingTests

/// Couvre la fonction pure `KeyInterceptor.resolveKey` (keyCode + modificateurs
/// → `Key`), extraite du tap pour être testable sans CGEventTap. Garantit que
/// la touche commit (⌘↩) mappe correctement, ne se confond pas avec Tab/Esc,
/// et a priorité sur acceptAll en cas de binding identique.
@Suite("KeyInterceptor key mapping")
struct KeyInterceptorMappingTests {
    typealias K = KeyInterceptor

    private func bind(_ ck: CommitKey) -> (code: Int64, flagsRaw: UInt64)? {
        ck.keyCode.map { (code: $0, flagsRaw: ck.requiredFlagsRaw) }
    }
    private func bind(_ ak: AcceptAllKey) -> (code: Int64, flagsRaw: UInt64)? {
        ak.keyCode.map { (code: $0, flagsRaw: ak.requiredFlagsRaw) }
    }
    private func bind(_ ck: TargetCycleKey) -> (code: Int64, flagsRaw: UInt64)? {
        ck.keyCode.map { (code: $0, flagsRaw: ck.requiredFlagsRaw) }
    }
    private func mask(_ flags: CGEventFlags) -> UInt64 { flags.rawValue & K.relevantFlags }

    @Test("⌘↩ mappe vers .commit quand commit = cmdReturn")
    func commitCmdReturn() {
        let key = K.resolveKey(keyCode: 36, mods: mask(.maskCommand), commit: bind(.cmdReturn), acceptAll: nil)
        #expect(key == .commit)
    }

    @Test("↩ nu n'est PAS un commit (modificateur requis)")
    func bareReturnIsNotCommit() {
        let key = K.resolveKey(keyCode: 36, mods: 0, commit: bind(.cmdReturn), acceptAll: nil)
        #expect(key == nil)
    }

    @Test("⌥↩ mappe vers .commit quand commit = optionReturn")
    func commitOptionReturn() {
        let key = K.resolveKey(keyCode: 36, mods: mask(.maskAlternate), commit: bind(.optionReturn), acceptAll: nil)
        #expect(key == .commit)
        // ⌘↩ ne doit PAS matcher un binding optionReturn.
        #expect(K.resolveKey(keyCode: 36, mods: mask(.maskCommand), commit: bind(.optionReturn), acceptAll: nil) == nil)
    }

    @Test("Tab nu mappe vers .tab")
    func plainTab() {
        #expect(K.resolveKey(keyCode: 48, mods: 0, commit: nil, acceptAll: nil) == .tab)
    }

    @Test("Tab avec Command n'est pas .tab")
    func modifiedTabIsNotTab() {
        #expect(K.resolveKey(keyCode: 48, mods: mask(.maskCommand), commit: nil, acceptAll: nil) == nil)
    }

    @Test("Esc nu mappe vers .esc")
    func esc() {
        #expect(K.resolveKey(keyCode: 53, mods: 0, commit: nil, acceptAll: nil) == .esc)
    }

    @Test("⇧⇥ (acceptAll) ne se confond pas avec Tab nu")
    func shiftTabAcceptAll() {
        #expect(K.resolveKey(keyCode: 48, mods: mask(.maskShift), commit: nil, acceptAll: bind(.shiftTab)) == .acceptAll)
        #expect(K.resolveKey(keyCode: 48, mods: 0, commit: nil, acceptAll: bind(.shiftTab)) == .tab)
    }

    @Test("commit a priorité sur acceptAll en cas de binding identique")
    func commitWinsOverAcceptAll() {
        // Les deux bound à ⌘↩ → commit doit gagner (testé en premier).
        let acceptCmdReturn: (code: Int64, flagsRaw: UInt64) = (36, CGEventFlags.maskCommand.rawValue)
        let key = K.resolveKey(keyCode: 36, mods: mask(.maskCommand), commit: bind(.cmdReturn), acceptAll: acceptCmdReturn)
        #expect(key == .commit)
    }

    @Test("commit désactivé ne produit aucun match commit")
    func disabledCommit() {
        #expect(CommitKey.disabled.keyCode == nil)
        let key = K.resolveKey(keyCode: 36, mods: mask(.maskCommand), commit: bind(CommitKey.disabled), acceptAll: nil)
        #expect(key == nil)
    }

    @Test("touche inconnue passe (nil)")
    func unknownPasses() {
        #expect(K.resolveKey(keyCode: 0, mods: 0, commit: nil, acceptAll: nil) == nil)
    }

    @Test("presets CommitKey exposent keyCode + flags")
    func commitKeyPresets() {
        #expect(CommitKey.cmdReturn.keyCode == 36)
        #expect(CommitKey.cmdReturn.requiredFlagsRaw == CGEventFlags.maskCommand.rawValue)
        #expect(CommitKey.cmdShiftReturn.requiredFlagsRaw
            == (CGEventFlags.maskCommand.rawValue | CGEventFlags.maskShift.rawValue))
        #expect(CommitKey.optionReturn.requiredFlagsRaw == CGEventFlags.maskAlternate.rawValue)
        #expect(CommitKey.allCases.count == 4)
    }

    // MARK: - Touche de cycle de cible (P5)

    @Test("⌘⇧→ mappe vers .cycleTarget quand cycle = cmdShiftRight")
    func cmdShiftRightMapsToCycle() {
        let key = K.resolveKey(
            keyCode: 124, mods: mask([.maskCommand, .maskShift]),
            commit: nil, acceptAll: nil, cycleTarget: bind(.cmdShiftRight))
        #expect(key == .cycleTarget)
    }

    @Test("→ nu n'est PAS un cycle (modificateurs requis)")
    func bareRightArrowIsNotCycle() {
        let key = K.resolveKey(
            keyCode: 124, mods: 0,
            commit: nil, acceptAll: nil, cycleTarget: bind(.cmdShiftRight))
        #expect(key == nil)
    }

    @Test("commit a priorité sur cycle si bindings identiques")
    func commitWinsOverCycle() {
        // Les deux sur ⌘⇧↩-ish : commit testé en premier dans resolveKey.
        let same: (code: Int64, flagsRaw: UInt64)? = (code: 36, flagsRaw: CGEventFlags.maskCommand.rawValue)
        let key = K.resolveKey(
            keyCode: 36, mods: mask(.maskCommand),
            commit: same, acceptAll: nil, cycleTarget: same)
        #expect(key == .commit)
    }

    @Test("cycle désactivé ne produit aucun match cycle")
    func disabledCycleNoMatch() {
        let key = K.resolveKey(
            keyCode: 124, mods: mask([.maskCommand, .maskShift]),
            commit: nil, acceptAll: nil, cycleTarget: bind(TargetCycleKey.disabled))
        #expect(key == nil)
    }

    @Test("presets TargetCycleKey exposent keyCode + flags")
    func cycleKeyPresets() {
        #expect(TargetCycleKey.cmdShiftRight.keyCode == 124)
        #expect(TargetCycleKey.cmdShiftRight.requiredFlagsRaw
            == (CGEventFlags.maskCommand.rawValue | CGEventFlags.maskShift.rawValue))
        #expect(TargetCycleKey.ctrlRight.requiredFlagsRaw == CGEventFlags.maskControl.rawValue)
        #expect(TargetCycleKey.optionRight.requiredFlagsRaw == CGEventFlags.maskAlternate.rawValue)
        #expect(TargetCycleKey.disabled.keyCode == nil)
        #expect(TargetCycleKey.allCases.count == 4)
    }
}
