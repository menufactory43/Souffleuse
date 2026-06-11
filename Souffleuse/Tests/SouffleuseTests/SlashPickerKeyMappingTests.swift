import CoreGraphics
import Testing
@testable import SouffleuseInput

// MARK: - SlashPickerKeyMappingTests

/// Couvre les extensions PURES de `KeyInterceptor` pour le picker « // » et le
/// preview de transformation : résolution de la rangée 1–9 (`slashPickerArmed` /
/// `slashDigitsArmed`), du ⏎ nu (`.enter`, gaté par `slashEnterArmed`), et la
/// politique de consommation (`shouldConsume`) des nouvelles sources d'armement.
/// Miroir de `KeyInterceptorMappingTests` — ne touche pas à ce fichier.
@Suite("KeyInterceptor slash picker mapping")
struct SlashPickerKeyMappingTests {
    typealias K = KeyInterceptor

    private func mask(_ flags: CGEventFlags) -> UInt64 { flags.rawValue & K.relevantFlags }

    @Test("rangée physique 1–9 nue → .digit quand le picker « // » est armé avec digits")
    func digitRowResolvesWhenSlashPickerArmed() {
        // KeyCodes ANSI positionnels — y compris le désordre matériel 5↔6.
        let expected: [Int64: Int] = [18: 1, 19: 2, 20: 3, 21: 4, 23: 5, 22: 6, 26: 7, 28: 8, 25: 9]
        for (code, n) in expected {
            #expect(K.resolveKey(keyCode: code, mods: 0, commit: nil, acceptAll: nil,
                                 slashPickerArmed: true, slashDigitsArmed: true) == .digit(n))
        }
    }

    @Test("digits NON résolus quand slashDigitsArmed == false (mode instruction libre)")
    func digitsPassInFreeInstructionMode() {
        // « //passe en 3 points » : le « 3 » doit rester de la saisie normale.
        #expect(K.resolveKey(keyCode: 18, mods: 0, commit: nil, acceptAll: nil,
                             slashPickerArmed: true, slashDigitsArmed: false) == nil)
        #expect(K.resolveKey(keyCode: 25, mods: 0, commit: nil, acceptAll: nil,
                             slashPickerArmed: true, slashDigitsArmed: false) == nil)
    }

    @Test("picker « // » non armé : la rangée 1–9 n'est pas résolue")
    func digitsPassWhenSlashPickerNotArmed() {
        #expect(K.resolveKey(keyCode: 18, mods: 0, commit: nil, acceptAll: nil,
                             slashPickerArmed: false) == nil)
    }

    @Test("⇧ + rangée 1–9 passe même picker « // » armé — le vrai chiffre AZERTY reste à l'hôte")
    func shiftedDigitRowPasses() {
        #expect(K.resolveKey(keyCode: 18, mods: mask(.maskShift), commit: nil, acceptAll: nil,
                             slashPickerArmed: true, slashDigitsArmed: true) == nil)
    }

    @Test("keyCode 36 nu → .enter seulement si le picker « // » est armé")
    func bareReturnResolvesOnlyWhenSlashPickerArmed() {
        #expect(K.resolveKey(keyCode: 36, mods: 0, commit: nil, acceptAll: nil,
                             slashPickerArmed: true) == .enter)
        #expect(K.resolveKey(keyCode: 36, mods: 0, commit: nil, acceptAll: nil,
                             slashPickerArmed: false) == nil)
    }

    @Test("⌘↩ / ⇧↩ ne sont PAS .enter (⏎ nu exigé)")
    func modifiedReturnIsNotEnter() {
        #expect(K.resolveKey(keyCode: 36, mods: mask(.maskCommand), commit: nil, acceptAll: nil,
                             slashPickerArmed: true) == nil)
        #expect(K.resolveKey(keyCode: 36, mods: mask(.maskShift), commit: nil, acceptAll: nil,
                             slashPickerArmed: true) == nil)
    }

    @Test("⏎ NON résolu quand slashEnterArmed == false (« // » nu → saut de ligne normal)")
    func enterPassesWhenFilterEmpty() {
        #expect(K.resolveKey(keyCode: 36, mods: 0, commit: nil, acceptAll: nil,
                             slashPickerArmed: true, slashEnterArmed: false) == nil)
    }

    @Test("le binding commit (⌘↩) garde priorité sur .enter quand les deux sont possibles")
    func commitWinsOverEnter() {
        let cmdReturn: (code: Int64, flagsRaw: UInt64) = (36, CGEventFlags.maskCommand.rawValue)
        #expect(K.resolveKey(keyCode: 36, mods: mask(.maskCommand), commit: cmdReturn, acceptAll: nil,
                             slashPickerArmed: true) == .commit)
        // Le ⏎ NU reste .enter (le binding ⌘↩ exige son modificateur).
        #expect(K.resolveKey(keyCode: 36, mods: 0, commit: cmdReturn, acceptAll: nil,
                             slashPickerArmed: true) == .enter)
    }

    // MARK: - shouldConsume

    @Test("shouldConsume(.enter) : vrai seulement picker « // » armé")
    func consumeEnterOnlyWhenSlashPickerArmed() {
        #expect(K.shouldConsume(key: .enter, ghostArmed: false, slashPickerArmed: true))
        #expect(!K.shouldConsume(key: .enter, ghostArmed: false, slashPickerArmed: false))
        #expect(!K.shouldConsume(key: .enter, ghostArmed: true, slashPickerArmed: false))
    }

    @Test("shouldConsume(.tab) : vrai si preview armé sans ghost ; faux HUD-seul (non-régression)")
    func consumeTabForPreview() {
        #expect(K.shouldConsume(key: .tab, ghostArmed: false, previewArmed: true))
        #expect(!K.shouldConsume(key: .tab, ghostArmed: false, previewArmed: false))
        // HUD-seul (traduction visible) : Tab reste à l'hôte — historique conservé.
        #expect(!K.shouldConsume(key: .tab, ghostArmed: false))
    }

    @Test("shouldConsume(.esc) : vrai pour chacune des sources isolément")
    func consumeEscForEachSource() {
        #expect(K.shouldConsume(key: .esc, ghostArmed: true))
        #expect(K.shouldConsume(key: .esc, ghostArmed: false, pickerArmed: true))
        #expect(K.shouldConsume(key: .esc, ghostArmed: false, slashPickerArmed: true))
        #expect(K.shouldConsume(key: .esc, ghostArmed: false, previewArmed: true))
        #expect(!K.shouldConsume(key: .esc, ghostArmed: false))
    }

    @Test("shouldConsume(.digit) : vrai si picker emoji OU picker « // » armé")
    func consumeDigitForEitherPicker() {
        #expect(K.shouldConsume(key: .digit(1), ghostArmed: false, pickerArmed: true))
        #expect(K.shouldConsume(key: .digit(1), ghostArmed: false, slashPickerArmed: true))
        #expect(!K.shouldConsume(key: .digit(1), ghostArmed: false))
        #expect(!K.shouldConsume(key: .digit(1), ghostArmed: true))
    }

    @Test("preview armé seul : acceptAll et digits restent à l'hôte")
    func previewOnlyConsumesTabAndEsc() {
        #expect(!K.shouldConsume(key: .acceptAll, ghostArmed: false, previewArmed: true))
        #expect(!K.shouldConsume(key: .digit(1), ghostArmed: false, previewArmed: true))
        #expect(!K.shouldConsume(key: .enter, ghostArmed: false, previewArmed: true))
    }

    // MARK: - Non-régression (défauts = comportement historique)

    @Test("non-régression : resolveKey sans les nouveaux paramètres est inchangé")
    func defaultsPreserveLegacyBehaviour() {
        #expect(K.resolveKey(keyCode: 48, mods: 0, commit: nil, acceptAll: nil) == .tab)
        #expect(K.resolveKey(keyCode: 53, mods: 0, commit: nil, acceptAll: nil) == .esc)
        // ⏎ nu sans slash picker : nil (jamais résolu hors picker « // »).
        #expect(K.resolveKey(keyCode: 36, mods: 0, commit: nil, acceptAll: nil) == nil)
        // Rangée 1–9 : seulement le picker emoji historique.
        #expect(K.resolveKey(keyCode: 18, mods: 0, commit: nil, acceptAll: nil,
                             pickerArmed: true) == .digit(1))
    }

    @Test("non-régression : shouldConsume avec les nouveaux paramètres en défaut")
    func defaultsPreserveLegacyConsumePolicy() {
        for key in [K.Key.tab, .esc, .acceptAll, .commit, .cycleTarget] {
            #expect(K.shouldConsume(key: key, ghostArmed: true))
        }
        #expect(K.shouldConsume(key: .commit, ghostArmed: false))
        #expect(K.shouldConsume(key: .cycleTarget, ghostArmed: false))
        #expect(!K.shouldConsume(key: .tab, ghostArmed: false))
        #expect(!K.shouldConsume(key: .esc, ghostArmed: false))
        #expect(!K.shouldConsume(key: .acceptAll, ghostArmed: false))
    }
}
