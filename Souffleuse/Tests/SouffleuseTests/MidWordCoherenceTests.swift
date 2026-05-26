import Testing
import Foundation
@testable import Souffleuse
import SouffleuseTyping

/// Guards the mid-word coherence fix : when the caret sits mid-word and the
/// ghost continues the SAME word, the spliced candidate must be a real word —
/// otherwise the model produced an incoherent continuation
/// ("…procéd" + "blème" → "procédblème") and the ghost is dropped. Coherent
/// splices ("problè" + "me…" → "problème") and non-mid-word ghosts (caret
/// after a space) are kept.
///
/// Pure-function level (`OutputFilter.midWordCandidate`) + spell-validation
/// level (`TypoDetector.isValidWord`). The full drop decision is the AND of
/// the two and is exercised end-to-end in the probe.
@Suite("Mid-word coherence guard")
struct MidWordCoherenceTests {

    // MARK: - OutputFilter.trailingPartialWord

    @Test func trailingPartialWordExtractsInProgressWord() {
        #expect(ModelRuntime.OutputFilter.trailingPartialWord("Coucou, petit test de procéd") == "procéd")
        #expect(ModelRuntime.OutputFilter.trailingPartialWord("Il y a un gros problè") == "problè")
    }

    @Test func trailingPartialWordEmptyAfterSpaceOrPunct() {
        #expect(ModelRuntime.OutputFilter.trailingPartialWord("Bonjour ") == "")
        #expect(ModelRuntime.OutputFilter.trailingPartialWord("Bonjour,") == "")
        #expect(ModelRuntime.OutputFilter.trailingPartialWord("") == "")
    }

    // MARK: - OutputFilter.leadingWordRun

    @Test func leadingWordRunTakesLeadingWordChars() {
        #expect(ModelRuntime.OutputFilter.leadingWordRun("blème avec le modèle") == "blème")
        #expect(ModelRuntime.OutputFilter.leadingWordRun("me avec le modèle") == "me")
    }

    @Test func leadingWordRunEmptyWhenGhostStartsWithSeparator() {
        #expect(ModelRuntime.OutputFilter.leadingWordRun(" avec le modèle") == "")
        #expect(ModelRuntime.OutputFilter.leadingWordRun(", suite") == "")
        #expect(ModelRuntime.OutputFilter.leadingWordRun("") == "")
    }

    // MARK: - OutputFilter.midWordCandidate

    @Test func midWordCandidateSplicesPartialAndHead() {
        #expect(ModelRuntime.OutputFilter.midWordCandidate(userTail: "…de procéd", ghost: "blème") == "procédblème")
        #expect(ModelRuntime.OutputFilter.midWordCandidate(userTail: "Il y a un gros problè", ghost: "me avec le modèle") == "problème")
    }

    @Test func midWordCandidateNilWhenNotMidWord() {
        // Caret after a space → not mid-word → guard does not apply.
        #expect(ModelRuntime.OutputFilter.midWordCandidate(userTail: "Bonjour ", ghost: "Madame") == nil)
    }

    @Test func midWordCandidateNilWhenGhostDoesNotContinueWord() {
        // Ghost starts with a separator → continues a NEW word, not the partial.
        #expect(ModelRuntime.OutputFilter.midWordCandidate(userTail: "Il y a un gros problè", ghost: " avec le modèle") == nil)
    }

    @Test func midWordCandidateNilForHyphenAndApostropheCompounds() {
        // French inversion / elision / compounds: the joiner starts a NEW word,
        // so the splice is never a single dictionary word — the guard must NOT
        // apply (otherwise it wrongly suppresses "allez-vous", "j'ai", etc.).
        #expect(ModelRuntime.OutputFilter.midWordCandidate(userTail: "Bonjour, comment allez-", ghost: "vous") == nil)
        #expect(ModelRuntime.OutputFilter.midWordCandidate(userTail: "Je pense que j'", ghost: "ai raison") == nil)
        #expect(ModelRuntime.OutputFilter.midWordCandidate(userTail: "Dis-moi, est-", ghost: "ce que tu viens") == nil)
        #expect(ModelRuntime.OutputFilter.midWordCandidate(userTail: "On se voit au rendez-", ghost: "vous") == nil)
        #expect(ModelRuntime.OutputFilter.midWordCandidate(userTail: "C'est aujourd'", ghost: "hui") == nil)
    }

    @Test func midWordCandidateNilWhenGhostStartsWithJoiner() {
        // Regression: partial "S" has NO joiner, but the ghost STARTS with an
        // apostrophe/hyphen — it begins a new sub-word after an elision/compound
        // boundary ("S"+"'il vous plaît" = "S'il"). The guard must SKIP (nil):
        // spell-checking "S'il" across the boundary would wrongly drop the
        // ghost. prefixFit now accepts these; the coherence guard stands aside.
        #expect(ModelRuntime.OutputFilter.midWordCandidate(userTail: "…corrigé. S", ghost: "'il vous plaît, continuez") == nil)
        #expect(ModelRuntime.OutputFilter.midWordCandidate(userTail: "…allez", ghost: "-vous") == nil)
        #expect(ModelRuntime.OutputFilter.midWordCandidate(userTail: "aujourd", ghost: "’hui") == nil)
    }

    @Test func midWordCandidateStopsAtJoinerInGhost() {
        // When the ghost is a same-word continuation (letter-led) that LATER
        // contains a joiner, the validated candidate uses only the leading
        // plain (letters/digits) run — it must NOT cross into the joiner.
        // "problè" + "me-clé" → candidate "problème", not "problème-clé".
        #expect(ModelRuntime.OutputFilter.midWordCandidate(userTail: "Il y a un gros problè", ghost: "me-clé du sujet") == "problème")
    }

    // MARK: - End-to-end drop decision (candidate + spell validation)

    /// Helper mirroring the generateLlama guard : drop when mid-word AND the
    /// spliced candidate is not a valid word.
    private func shouldDrop(userTail: String, ghost: String, language: String?, _ checker: TypoDetector) -> Bool {
        guard let candidate = ModelRuntime.OutputFilter.midWordCandidate(userTail: userTail, ghost: ghost) else {
            return false
        }
        return !checker.isValidWord(candidate, language: language)
    }

    @Test func dropsIncoherentMidWordSplice() {
        let checker = TypoDetector()
        // "procéd" + "blème" → "procédblème" is a non-word → DROP.
        #expect(shouldDrop(userTail: "Coucou, petit test de procéd", ghost: "blème avec le modèle", language: "French", checker))
    }

    @Test func keepsCoherentMidWordSplice() {
        let checker = TypoDetector()
        // "problè" + "me" → "problème" is valid French → KEEP.
        #expect(!shouldDrop(userTail: "Il y a un gros problè", ghost: "me avec le modèle", language: "French", checker))
    }

    @Test func nonMidWordGhostUnaffected() {
        let checker = TypoDetector()
        // Caret after a space → never dropped by this guard regardless of ghost.
        #expect(!shouldDrop(userTail: "Bonjour ", ghost: "zzqxw", language: "French", checker))
    }

    // MARK: - TypoDetector.isValidWord

    @Test func isValidWordAcceptsRealWords() {
        let checker = TypoDetector()
        #expect(checker.isValidWord("problème", language: "French"))
        #expect(checker.isValidWord("bonjour", language: "French"))
        #expect(checker.isValidWord("autocomplete", language: "English"))
    }

    @Test func isValidWordRejectsNonWords() {
        let checker = TypoDetector()
        #expect(!checker.isValidWord("procédblème", language: "French"))
        #expect(!checker.isValidWord("zzqxwk", language: "French"))
    }

    // MARK: - Instruction-echo drop

    @Test func echoesInstructionDetectsLeakedFraming() {
        #expect(ModelRuntime.OutputFilter.echoesInstruction("Voici le texte à continuer :"))
        #expect(ModelRuntime.OutputFilter.echoesInstruction("blabla Suite du texte (à ne pas répéter)"))
        #expect(ModelRuntime.OutputFilter.echoesInstruction("You are an inline autocomplete inside"))
    }

    @Test func echoesInstructionIgnoresRealProse() {
        #expect(!ModelRuntime.OutputFilter.echoesInstruction("me avec le modèle"))
        #expect(!ModelRuntime.OutputFilter.echoesInstruction("bonjour à tous"))
        #expect(!ModelRuntime.OutputFilter.echoesInstruction(""))
    }
}
