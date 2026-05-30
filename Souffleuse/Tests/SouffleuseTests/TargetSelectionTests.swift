import Testing
@testable import SouffleuseCore

/// Couvre la résolution de cible de traduction (P5) : détection de la langue du
/// correspondant, modèle `TargetSelection` (cycle + résolution), tous purs et
/// on-device. Le wiring HUD/store/clavier est testé ailleurs.
@Suite("TargetSelection & détection de langue")
struct TargetSelectionTests {

    // MARK: - TranslationTarget.detected

    @Test("détecte l'anglais d'un message client → cible EN")
    func detectsEnglish() {
        #expect(TranslationTarget.detected(in: "Hello, I cannot withdraw my funds from my wallet, please help.") == .en)
    }

    @Test("détecte l'allemand → cible DE")
    func detectsGerman() {
        #expect(TranslationTarget.detected(in: "Guten Tag, ich kann meine Kryptowährungen nicht verkaufen.") == .de)
    }

    @Test("détecte l'espagnol → cible ES")
    func detectsSpanish() {
        #expect(TranslationTarget.detected(in: "Hola, no puedo conectar mi monedero a la plataforma.") == .es)
    }

    @Test("le français ne produit AUCUNE cible (pas de FR→FR)")
    func frenchYieldsNil() {
        #expect(TranslationTarget.detected(in: "Bonjour, je n'arrive pas à retirer mes fonds du portefeuille.") == nil)
    }

    @Test("texte trop court → nil (seuil ≥ 8 chars)")
    func tooShortYieldsNil() {
        #expect(TranslationTarget.detected(in: "ok") == nil)
        #expect(TranslationTarget.detected(in: "   ") == nil)
    }

    @Test("langue hors V1 (japonais) → nil même si détectée")
    func nonV1YieldsNil() {
        // JA est hors V1 (isV1 == false) : la détection ne doit pas le proposer.
        #expect(TranslationTarget.detected(in: "こんにちは、ウォレットから資金を引き出せません。助けてください。") == nil)
    }

    // MARK: - TargetSelection.cycleNext

    @Test("le cycle suit EN→ES→DE→IT→AUTO→EN")
    func cycleOrder() {
        var s: TargetSelection = .auto
        s = s.cycleNext(); #expect(s == .fixed(.en))
        s = s.cycleNext(); #expect(s == .fixed(.es))
        s = s.cycleNext(); #expect(s == .fixed(.de))
        s = s.cycleNext(); #expect(s == .fixed(.it))
        s = s.cycleNext(); #expect(s == .auto)
        s = s.cycleNext(); #expect(s == .fixed(.en))
    }

    @Test("une cible hors ordre de cycle (JA) revient à AUTO")
    func cycleFromNonCycleTarget() {
        #expect(TargetSelection.fixed(.ja).cycleNext() == .auto)
    }

    // MARK: - TargetSelection.resolve

    @Test("une cible FIXE l'emporte sur la détection")
    func fixedWinsOverDetected() {
        #expect(TargetSelection.fixed(.de).resolve(detected: .es) == .de)
    }

    @Test("AUTO suit la langue détectée")
    func autoFollowsDetected() {
        #expect(TargetSelection.auto.resolve(detected: .it) == .it)
    }

    @Test("AUTO sans détection retombe sur le fallback EN")
    func autoFallsBackToEnglish() {
        #expect(TargetSelection.auto.resolve(detected: nil) == .en)
        #expect(TargetSelection.auto.resolve(detected: nil, fallback: .es) == .es)
    }

    @Test("shortLabel lisible pour le panneau")
    func shortLabels() {
        #expect(TargetSelection.auto.shortLabel == "AUTO")
        #expect(TargetSelection.fixed(.en).shortLabel == "EN")
        #expect(TargetSelection.fixed(.de).shortLabel == "DE")
    }
}

/// Couvre le budget de tokens adaptatif de la traduction (TRANSLATION-SPEC §2.9,
/// anti-troncature) : proportionnel à la source, mais clampé plancher/plafond.
@Suite("Traduction — budget de tokens adaptatif")
struct TranslationMaxTokensTests {
    typealias T = SuggestionPolicy.Tuning

    @Test("un message court prend le plancher (pas en-dessous)")
    func shortMessageHitsFloor() {
        #expect(T.translationMaxNewTokens(sourceChars: 10) == T.translationMaxNewTokensFloor)
        #expect(T.translationMaxNewTokens(sourceChars: 0) == T.translationMaxNewTokensFloor)
    }

    @Test("un message long est plafonné (jamais au-delà du cap)")
    func longMessageHitsCap() {
        #expect(T.translationMaxNewTokens(sourceChars: 100_000) == T.translationMaxNewTokensCap)
    }

    @Test("un message moyen grandit avec la source (entre plancher et plafond)")
    func mediumScalesWithSource() {
        let small = T.translationMaxNewTokens(sourceChars: 600)
        let big = T.translationMaxNewTokens(sourceChars: 1200)
        #expect(small > T.translationMaxNewTokensFloor)
        #expect(small < T.translationMaxNewTokensCap)
        #expect(big > small)   // monotone croissant
    }
}
