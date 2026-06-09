import Testing
import Foundation
import SouffleuseCore

/// Tests du `BeamGhostShaper` — la mise en forme PURE du cœur beam
/// (`SOUFFLEUSE_BEAM_CORE`). On valide les deux gardes de phrase (G1 coupe-clause,
/// G2 seuil d'amorce), le séparateur, la dédup, le word-cap, et la suppression du
/// vide. Le shaper est extrait VERBATIM des helpers de `ModelRuntime.generateGhostBeam` ;
/// ces tests verrouillent le comportement de référence.
@Suite("BeamGhostShaper — mise en forme du cœur beam")
struct BeamGhostShaperTests {

    // MARK: - G2 : seuil d'amorce de phrase (currentSentenceLetterCount / sentenceArmed)

    @Test func g2_countsLettersOfCurrentSentenceOnly() {
        // Compte depuis le DERNIER terminateur jusqu'à la fin.
        #expect(BeamGhostShaper.currentSentenceLetterCount("Bonjour. ab") == 2)
        #expect(BeamGhostShaper.currentSentenceLetterCount("Bonjour. abc") == 3)
        // Pas de terminateur ⇒ toute la chaîne.
        #expect(BeamGhostShaper.currentSentenceLetterCount("salut") == 5)
        // Juste après un point (espace seul) ⇒ 0.
        #expect(BeamGhostShaper.currentSentenceLetterCount("Fini. ") == 0)
        #expect(BeamGhostShaper.currentSentenceLetterCount("Fini.") == 0)
    }

    @Test func g2_ignoresNonLetters() {
        // Chiffres/espaces ne comptent pas comme lettres (mais on compte toute la
        // phrase faute de terminateur).
        #expect(BeamGhostShaper.currentSentenceLetterCount("Voici 12 34") == 5)   // V,o,i,c,i
        #expect(BeamGhostShaper.currentSentenceLetterCount("Mont 1 a") == 5)      // M,o,n,t,a
        // Après un terminateur, seuls les chiffres → 0 lettre (G2 silence).
        #expect(BeamGhostShaper.currentSentenceLetterCount("Fini. 123") == 0)
    }

    @Test func g2_armedThresholdIsThree() {
        #expect(BeamGhostShaper.beamMinSentenceLetters == 3)
        // Silence juste après un point, reprise dès 3 lettres.
        #expect(BeamGhostShaper.sentenceArmed(userTail: "Fini. ") == false)
        #expect(BeamGhostShaper.sentenceArmed(userTail: "Fini. ab") == false)
        #expect(BeamGhostShaper.sentenceArmed(userTail: "Fini. abc") == true)
        // Seuil paramétrable (balayage probe).
        #expect(BeamGhostShaper.sentenceArmed(userTail: "Fini. ab", minLetters: 2) == true)
    }

    // MARK: - Choix de config beam : requiredPrefix + largeur

    @Test func config_midWordUsesRequiredPrefixAndFullWidth() {
        // « confir » mid-mot (pas un mot complet) → requiredPrefix = partial, K plein.
        let c = BeamGhostShaper.beamConfigChoice(userTail: "Je vais confir", beamWidth: 3)
        #expect(c.isBoundary == false)
        #expect(c.requiredPrefix == "confir")
        #expect(c.width == 3)
    }

    @Test func config_afterSpaceIsBoundaryWidthOne() {
        // Après-espace (partiel vide) → frontière, requiredPrefix vide, K=1.
        let c = BeamGhostShaper.beamConfigChoice(userTail: "Je vais ", beamWidth: 3)
        #expect(c.isBoundary == true)
        #expect(c.requiredPrefix == "")
        #expect(c.width == 1)
    }

    // MARK: - Prompt : slots PROSE, pas de few-shot / FIM / Champ

    @Test func prompt_slotsAreProseOnly() {
        let s = BeamGhostShaper.promptSlots(
            customInstr: "Tu es Gabriel.", ctxPrefix: "Contexte: email pro.", llmTail: "Bonjour ")
        #expect(s.system == "")
        #expect(s.customInstr == "Tu es Gabriel.")
        #expect(s.ctxPrefix == "Contexte: email pro.")
        #expect(s.fieldContext == "")   // pas de FIM `Champ:`
        #expect(s.afterCursor == "")    // pas de FIM after-cursor
        #expect(s.beforeCursor == "Bonjour ")
    }

    @Test func prompt_buildEndsWithUserTail() {
        // Le prompt construit doit contenir le texte avant curseur (continuation prose).
        let p = BeamGhostShaper.buildPrompt(customInstr: "", ctxPrefix: "", llmTail: "Je vais confir")
        #expect(p.contains("Je vais confir"))
    }

    // MARK: - Post-filtre : suppression du vide

    @Test func filter_emptyYieldsEmpty() {
        // Brut vide → vide (court-circuit `singleLine` vide). C'est la voie de
        // suppression du ghost vide (le call-site fait `show: !ghost.isEmpty`).
        #expect(BeamGhostShaper.beamPostFilter(
            rawGhost: "", isBoundary: false, caretAfterSpace: false,
            userTail: "Je vais confir", maxWords: 4) == "")
        // Un newline seul est aussi écrasé par `singleLine` → vide.
        #expect(BeamGhostShaper.beamPostFilter(
            rawGhost: "\n", isBoundary: false, caretAfterSpace: false,
            userTail: "Je vais confir", maxWords: 4) == "")
    }

    // MARK: - Post-filtre : G1 coupe-clause INCLUSIVE

    @Test func filter_g1_cutsAtClauseBoundaryInclusive() {
        // Mid-mot « confir » → ghost « mer le rendez-vous. Et ensuite » : on coupe au
        // point INCLUS, on ne propose pas la phrase suivante.
        let out = BeamGhostShaper.beamPostFilter(
            rawGhost: "mer le rendez-vous. Et ensuite", isBoundary: false, caretAfterSpace: false,
            userTail: "Je vais confir", maxWords: 8)
        #expect(out == "mer le rendez-vous.")
    }

    @Test func filter_g1_cutsAtSemicolonInclusive() {
        let out = BeamGhostShaper.beamPostFilter(
            rawGhost: "rer ceci; puis cela", isBoundary: false, caretAfterSpace: false,
            userTail: "Je vais prepa", maxWords: 8)
        #expect(out == "rer ceci;")
    }

    // MARK: - Post-filtre : word-cap

    @Test func filter_wordCapTruncatesToMaxWords() {
        // Frontière after-space : 6 mots → cap à 3 (le séparateur est géré à part).
        let out = BeamGhostShaper.beamPostFilter(
            rawGhost: "un deux trois quatre cinq six", isBoundary: true, caretAfterSpace: true,
            userTail: "Voici ", maxWords: 3)
        #expect(out.split(whereSeparator: { $0.isWhitespace }).count == 3)
        #expect(out == "un deux trois")
    }

    @Test func filter_wordCapPreservesLeadingSpace() {
        // Frontière NON précédée d'espace → séparateur rétabli, puis cap garde l'espace.
        let out = BeamGhostShaper.beamPostFilter(
            rawGhost: "un deux trois quatre", isBoundary: true, caretAfterSpace: false,
            userTail: "message.", maxWords: 2)
        #expect(out.first == " ")
        #expect(out == " un deux")
    }

    // MARK: - Post-filtre : séparateur d'espace à la frontière

    @Test func filter_boundaryWithoutSpaceGetsSeparator() {
        // « message.| » + ghost « Bonjour » → un séparateur d'espace est rétabli.
        let out = BeamGhostShaper.beamPostFilter(
            rawGhost: "Bonjour", isBoundary: true, caretAfterSpace: false,
            userTail: "message.", maxWords: 4)
        #expect(out == " Bonjour")
    }

    @Test func filter_boundaryAfterSpaceNoExtraSeparator() {
        // Caret déjà après un espace → pas de double espace.
        let out = BeamGhostShaper.beamPostFilter(
            rawGhost: "Bonjour", isBoundary: true, caretAfterSpace: true,
            userTail: "Voici ", maxWords: 4)
        #expect(out == "Bonjour")
    }

    @Test func filter_midWordStaysGlued() {
        // Mid-mot : le suffixe reste collé (complétion de mot, pas de séparateur).
        let out = BeamGhostShaper.beamPostFilter(
            rawGhost: "mer", isBoundary: false, caretAfterSpace: false,
            userTail: "Je vais confir", maxWords: 4)
        #expect(out == "mer")
    }

    // MARK: - Post-filtre : dédup d'un mot répété en tête

    @Test func filter_dedupLeadingRepeatedWord() {
        // Le beam re-émet le dernier mot tapé (« confirmer ») : la dédup le retire.
        // (dépend de SuggestionPolicy.dedupLeadingRepeat — on vérifie l'intégration.)
        let out = BeamGhostShaper.beamPostFilter(
            rawGhost: " confirmer le rendez-vous", isBoundary: true, caretAfterSpace: true,
            userTail: "Je vais confirmer", maxWords: 4)
        // Le mot « confirmer » dupliqué ne doit pas réapparaître en tête.
        #expect(!out.hasPrefix("confirmer"))
    }
}
