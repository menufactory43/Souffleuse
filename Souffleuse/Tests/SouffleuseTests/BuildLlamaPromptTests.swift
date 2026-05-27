import Testing
import SouffleuseCore
@testable import Souffleuse

/// Guards the trailing-space strip in `buildLlamaPrompt` — the fix for the
/// grammar/loop bug ("on va y " → loop / "arrivait" vs "on va y" → " arriver.").
/// A SentencePiece base model emits the next token WITH its leading space, so a
/// trailing space in the prompt derails greedy decoding. The model must never
/// see one; the caret-after-space case re-aligns the ghost's leading space
/// downstream (in generateLlama).
@MainActor
@Suite("buildLlamaPrompt trailing-space strip")
struct BuildLlamaPromptTests {

    private func build(_ before: String, instr: String = "", ctx: String = "", field: String = "") -> String {
        ModelRuntime.buildLlamaPrompt(
            system: "", customInstr: instr, ctxPrefix: ctx,
            fieldContext: field, afterCursor: "", beforeCursor: before
        )
    }

    @Test("trailing space is stripped")
    func stripsTrailingSpace() {
        #expect(build("on va y ") == "on va y")
        #expect(build("Merci beaucoup pour votre  ") == "Merci beaucoup pour votre")
        #expect(build("a\t") == "a")
    }

    @Test("no trailing space is left untouched")
    func keepsNonSpaceEnding() {
        #expect(build("les frais") == "les frais")
        #expect(build("Bonj") == "Bonj")
    }

    @Test("trailing newline is preserved (intentional fresh line)")
    func keepsTrailingNewline() {
        #expect(build("Cher Monsieur,\n") == "Cher Monsieur,\n")
    }

    @Test("context prefix is prepended, then trimmed beforeCursor")
    func prependsContext() {
        #expect(build("on va y ", ctx: "Note") == "Note\n\non va y")
    }

    // MARK: - Custom instructions injected as a "Contexte :" prose block

    /// The user's personalisation is injected as a French "Contexte :" prose
    /// block (not a chat command) so a base model CONTINUES from the stated
    /// fact — "Je m'appelle " → the right name. (Probe VOLET PERSONA.)
    @Test("custom instructions become a Contexte: prefix")
    func injectsCustomInstructionsAsContexte() {
        #expect(build("Je m'appelle ", instr: "Je m'appelle Gabriel.")
                == "Contexte : Je m'appelle Gabriel.\n\nJe m'appelle")
    }

    /// The persona block is prepended FIRST (most global), before the screen/
    /// field context, and the user's (trimmed) text still ends the prompt.
    @Test("custom instructions precede the screen context")
    func customInstructionsPrecedeContext() {
        #expect(build("Bonjour ", instr: "Je suis Gabriel.", ctx: "App Mail")
                == "Contexte : Je suis Gabriel.\n\nApp Mail\n\nBonjour")
    }

    /// Empty / whitespace-only instructions inject nothing (no stray label).
    @Test("blank custom instructions inject nothing")
    func blankInstructionsInjectNothing() {
        #expect(build("salut", instr: "   \n ") == "salut")
        #expect(build("salut", instr: "") == "salut")
    }
}
