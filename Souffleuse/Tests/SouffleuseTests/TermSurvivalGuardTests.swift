import Testing
@testable import SouffleuseCore

/// Couvre le garde-fou C (TRANSLATION-SPEC §2.8) : survie des tokens durs
/// (chiffres/montants/%, termes métier, noms propres) de la source FR dans la
/// traduction. Pur, on-device, zéro LLM.
@Suite("TermSurvivalGuard — survie termes/chiffres")
struct TermSurvivalGuardTests {

    // MARK: - Extraction de nombres (canonique)

    @Test("un montant FR « 1 250,50 » est UN seul token canonique 125050")
    func numberTokenMerging() {
        let toks = TermSurvivalGuard.numberTokens(in: "Le solde est de 1 250,50 € exactement.")
        #expect(toks.map(TermSurvivalGuard.canonicalDigits) == ["125050"])
    }

    @Test("deux nombres séparés par du texte restent distincts")
    func numbersSeparatedByText() {
        let toks = TermSurvivalGuard.numberTokens(in: "12,5% sur 3 ans")
        #expect(toks.map(TermSurvivalGuard.canonicalDigits) == ["125", "3"])
    }

    @Test("la canonicalisation ignore les séparateurs de locale")
    func canonicalIgnoresSeparators() {
        #expect(TermSurvivalGuard.canonicalDigits("1 250,50") == "125050")
        #expect(TermSurvivalGuard.canonicalDigits("1,250.50") == "125050")
    }

    // MARK: - Chiffres : la corruption du gate

    @Test("le bug du gate (1 250,50 € → 250,50 €) est attrapé")
    func gateNumberCorruptionFlagged() {
        let missing = TermSurvivalGuard.missingTokens(
            source: "Le remboursement de 1 250,50 € sera traité.",
            translation: "The refund of 250,50 € will be processed.")
        #expect(missing.contains { $0.kind == .number && $0.text.contains("250,50") })
    }

    @Test("un montant reformaté par la locale cible SURVIT (pas de faux positif)")
    func localeReformattedNumberSurvives() {
        let missing = TermSurvivalGuard.missingTokens(
            source: "Le total est de 1 250,50 €.",
            translation: "The total is 1,250.50 €.")
        #expect(missing.allSatisfy { $0.kind != .number })
    }

    @Test("un pourcentage préservé n'est pas signalé")
    func percentageSurvives() {
        let missing = TermSurvivalGuard.missingTokens(
            source: "Une commission de 12,5% s'applique.",
            translation: "A 12.5% fee applies.")
        #expect(missing.isEmpty)
    }

    @Test("les chiffres isolés sous le seuil sont ignorés")
    func singleDigitBelowThresholdIgnored() {
        let missing = TermSurvivalGuard.missingTokens(
            source: "J'ai 1 question.",
            translation: "I have a question.")  // le « 1 » a disparu mais 1 chiffre < seuil 2
        #expect(missing.allSatisfy { $0.kind != .number })
    }

    // MARK: - Termes métier

    @Test("un terme métier disparu est signalé")
    func businessTermDropped() {
        let missing = TermSurvivalGuard.missingTokens(
            source: "Connectez votre wallet Binance.",
            translation: "Connect your Binance account.")  // « wallet » disparu
        #expect(missing.contains { $0.kind == .term && $0.text == "wallet" })
        #expect(missing.allSatisfy { $0.text != "Binance" })  // Binance a survécu
    }

    @Test("la comparaison de terme est insensible à la casse")
    func termCaseInsensitive() {
        let missing = TermSurvivalGuard.missingTokens(
            source: "Vérifiez votre Wallet.",
            translation: "Check your wallet please.")
        #expect(missing.allSatisfy { $0.kind != .term })
    }

    @Test("un terme multi-mots (smart contract) est géré")
    func multiWordTerm() {
        let missing = TermSurvivalGuard.missingTokens(
            source: "Le smart contract a échoué.",
            translation: "The contract failed.")  // « smart » perdu → smart contract manquant
        #expect(missing.contains { $0.kind == .term && $0.text == "smart contract" })
    }

    // MARK: - Noms propres

    @Test("un nom propre hors liste disparu est signalé")
    func properNounDropped() {
        let missing = TermSurvivalGuard.missingTokens(
            source: "Merci de contacter Gabriel rapidement.",
            translation: "Please reach out quickly.")  // Gabriel disparu
        #expect(missing.contains { $0.kind == .properNoun && $0.text == "Gabriel" })
    }

    @Test("le premier mot de phrase capitalisé n'est PAS un nom propre")
    func sentenceInitialNotProperNoun() {
        // « Bonjour » en tête de phrase ne doit pas être traité comme nom propre.
        let nouns = TermSurvivalGuard.properNouns(in: "Bonjour Mike, comment ça va", minLength: 3)
        #expect(!nouns.contains("Bonjour"))
        #expect(nouns.contains("Mike"))
    }

    @Test("un nom propre préservé n'est pas signalé")
    func properNounSurvives() {
        let missing = TermSurvivalGuard.missingTokens(
            source: "Veuillez contacter Mike au support.",
            translation: "Please contact Mike at support.")
        #expect(missing.allSatisfy { $0.kind != .properNoun })
    }

    // MARK: - Badge + cas heureux

    @Test("une traduction fidèle ne produit aucun signalement")
    func faithfulTranslationClean() {
        let missing = TermSurvivalGuard.missingTokens(
            source: "Bonjour, comment allez-vous ?",
            translation: "Hello, how are you?")
        #expect(missing.isEmpty)
        #expect(TermSurvivalGuard.badgeSummary(for: missing) == nil)
    }

    @Test("le badge agrège au-delà de la limite (+N)")
    func badgeOverflow() {
        let missing = (1...6).map { TermSurvivalGuard.Missing(text: "x\($0)", kind: .term) }
        let summary = TermSurvivalGuard.badgeSummary(for: missing, maxItems: 4)
        #expect(summary == "x1, x2, x3, x4, +2")
    }

    @Test("le badge déduplique un token répété")
    func badgeDedup() {
        let missing = TermSurvivalGuard.missingTokens(
            source: "wallet wallet wallet manquant",
            translation: "missing")
        #expect(missing.filter { $0.text == "wallet" }.count == 1)
    }
}
