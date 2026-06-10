import Testing
@testable import SouffleuseTyping

// MARK: - TypoDetectorPolicyTests

/// Verrouille la politique multi-langues de `TypoDetector` (revue 2026-06-11,
/// mesurée par `SouffleuseSpellEngineEval`) : préséance de la langue du
/// contexte, exception/restitution de diacritiques, accord inter-dictionnaires,
/// et la non-régression des pathologies inter-langues (« etait » → « eat »,
/// « apres » → « pares », « apelle » → « Kapelle »).
///
/// Les tests de `checkLastWord` dépendent de NSSpellChecker (dicos système
/// fr/en de macOS) — même dépendance assumée que `MidWordCoherenceTests`. Les
/// cas choisis sont vérifiés contre les guesses réels du dico (2026-06-11).
@Suite("TypoDetector multi-language policy")
struct TypoDetectorPolicyTests {

    // MARK: Helpers purs

    @Test("isDiacriticOnlyVariant : accents restitués, rien d'autre")
    func diacriticVariant() {
        #expect(TypoDetector.isDiacriticOnlyVariant("déjà", of: "deja"))
        #expect(TypoDetector.isDiacriticOnlyVariant("même", of: "meme"))
        #expect(TypoDetector.isDiacriticOnlyVariant("École", of: "ecole"))   // casse ignorée
        #expect(!TypoDetector.isDiacriticOnlyVariant("dej", of: "deja"))     // lettres différentes
        #expect(!TypoDetector.isDiacriticOnlyVariant("deja", of: "deja"))    // identique = pas une variante
        #expect(!TypoDetector.isDiacriticOnlyVariant("problem", of: "problme"))
    }

    @Test("contextLanguage : fr, en, et indéterminé sur texte court")
    func contextLanguageDetection() {
        #expect(TypoDetector.contextLanguage("je crois que c'est vraiment une bonne idée") == "fr")
        #expect(TypoDetector.contextLanguage("i think that it is really a good idea") == "en")
        #expect(TypoDetector.contextLanguage("ab") == nil)   // sous le plancher de 12 chars
        #expect(TypoDetector.contextLanguage("") == nil)
    }

    @Test("la préséance du contexte vaut une unité d'édition pleine")
    func marginConstants() {
        // Le rabais transposition (0.85) ne doit JAMAIS suffire à un mot
        // étranger pour battre la langue du contexte.
        #expect(TypoDetector.foreignWinMargin > 1.0 - TypoDetector.transpositionCost)
        // La restitution d'accents bat tout candidat réel, transposition incluse.
        #expect(TypoDetector.accentRestorationDistance < TypoDetector.transpositionCost)
    }

    // MARK: Politique via checkLastWord (NSSpellChecker système)

    private func check(_ word: String, french: Bool) -> String? {
        let carrier = french ? "je crois que c'est vraiment " : "i think that it is really "
        let text = carrier + word + " "
        return TypoDetector().checkLastWord(in: text, caretIndex: text.count)?.suggestion
    }

    @Test("restitution d'accents en contexte français — même si l'anglais accepte le mot")
    func accentRestorationInFrench() {
        #expect(check("deja", french: true) == "déjà")     // « dej » (d1) ne vole plus la place
        #expect(check("meme", french: true) == "même")     // « meme » valide EN — exception
        #expect(check("etait", french: true) == "était")   // tie étai/était départagé par l'accent
    }

    @Test("pas de candidat étranger pire que l'abstention du français")
    func noForeignDowngrade() {
        // Pathologies historiques : le français flague-mais-s'abstient, et le
        // candidat d'une autre langue (souvent plus lointain) gagnait.
        #expect(check("etait", french: true) != "eat")
        #expect(check("apres", french: true) != "pares")
        #expect(check("apelle", french: true) != "Kapelle")
        #expect(check("problme", french: true) != "problem")
    }

    @Test("accord inter-dictionnaires : les deux langues hésitent, un seul candidat commun")
    func crossDictionaryAgreement() {
        // fr {message, pesage, Lesage} ∩ en {message, menage, me-sage, me sage}
        // = {message} → les deux dicos votent message.
        #expect(check("mesage", french: true) == "message")
    }

    @Test("l'exception diacritiques est gatée par le contexte : pas de « thé » en anglais")
    func diacriticExceptionGatedByContext() {
        // « the » est valide en anglais ; en contexte anglais il ne doit JAMAIS
        // devenir « thé ». (En contexte indéterminé non plus — gate fermé.)
        #expect(check("the", french: false) == nil)
        let bare = "the "
        #expect(TypoDetector().checkLastWord(in: bare, caretIndex: bare.count)?.suggestion == nil)
    }

    @Test("les corrections nettes d'une seule langue marchent toujours")
    func singleLanguageStillFires() {
        #expect(check("bonjuor", french: true) == "bonjour")
        #expect(check("teh", french: false) == "the")
    }
}
