import Testing
import SouffleuseCore

/// Gardes visuelles du ghost : markup (balises HTML, markdown) et runs de
/// chiffres absurdes ("10000000000") ne doivent JAMAIS s'afficher — sur le
/// chemin streaming (`ChunkFilter`) COMME sur le chemin beam
/// (`BeamGhostShaper.beamPostFilter`), qui laissait fuir les deux (bug visuel,
/// 12/06). Sans dégrader la qualité : années, prix, heures, dates et ordinaux
/// légitimes survivent.
@Suite("OutputFilter.stripMarkup")
struct StripMarkupTests {

    @Test func dropsCompleteHTMLTags() {
        #expect(OutputFilter.stripMarkup("<strong>très important</strong>") == "très important")
        #expect(OutputFilter.stripMarkup("un saut<br/>de ligne") == "un sautde ligne")
        #expect(OutputFilter.stripMarkup("<em>oui</em> bien sûr") == "oui bien sûr")
    }

    @Test func dropsTrailingPartialTag() {
        // Le ">" n'a pas encore streamé : la balise partielle en queue ne doit
        // jamais s'afficher, le texte qui précède reste.
        #expect(OutputFilter.stripMarkup("Bonjour <stron") == "Bonjour ")
        #expect(OutputFilter.stripMarkup("Bonjour </stro") == "Bonjour ")
        #expect(OutputFilter.stripMarkup("Bonjour <") == "Bonjour ")
    }

    @Test func dropsMarkdownEmphasisAndReplacementChar() {
        #expect(OutputFilter.stripMarkup("**gras** et __souligné__") == "gras et souligné")
        #expect(OutputFilter.stripMarkup("du `code` inline") == "du code inline")
        #expect(OutputFilter.stripMarkup("abc\u{FFFD}def") == "abcdef")
    }

    @Test func keepsComparisonOperator() {
        // Un "<" de comparaison n'est pas une balise (pas de lettre collée).
        #expect(OutputFilter.stripMarkup("3 < 5 et 7 > 2") == "3 < 5 et 7 > 2")
    }

    @Test func keepsPlainProse() {
        for s in ["informer que", " de port. Mais", "1er janvier"] {
            #expect(OutputFilter.stripMarkup(s) == s, "should keep «\(s)»")
        }
    }
}

@Suite("OutputFilter.cutAbsurdNumberRun")
struct CutAbsurdNumberRunTests {

    @Test func cutsHugeDigitRuns() {
        // Coupe juste AVANT le run : la tête reste affichable.
        #expect(OutputFilter.cutAbsurdNumberRun("coûte 10000000000 euros") == "coûte")
        #expect(OutputFilter.cutAbsurdNumberRun("10000000000") == "")
        #expect(OutputFilter.cutAbsurdNumberRun("1234567 résultats") == "")
    }

    @Test func cutsGroupedHugeNumbers() {
        // Les séparateurs de groupe entre chiffres comptent dans le même run.
        #expect(OutputFilter.cutAbsurdNumberRun("environ 10 000 000 000") == "environ")
        #expect(OutputFilter.cutAbsurdNumberRun("soit 1.000.000.000 de") == "soit")
        #expect(OutputFilter.cutAbsurdNumberRun("soit 10'000'000 CHF") == "soit")
    }

    @Test func keepsLegitimateNumbers() {
        for s in [
            "en 2026", "à 14:30", "1er janvier", "100% des cas",
            "100 000 €", "le 12 mars 2026", "page 999 999",
            "1/2 tasse de farine", "12 rue de la Paix",
        ] {
            #expect(OutputFilter.cutAbsurdNumberRun(s) == s, "should keep «\(s)»")
        }
    }

    @Test func separatorNotFollowedByDigitClosesTheRun() {
        // "100, et 200." : la virgule n'est pas suivie d'un chiffre → deux
        // runs courts distincts, rien n'est coupé.
        let s = "il y en a 100, et 200."
        #expect(OutputFilter.cutAbsurdNumberRun(s) == s)
    }
}

@Suite("ChunkFilter — markup & nombre absurde (chemin streaming)")
struct ChunkFilterMarkupTests {

    @Test func stripsTagsFromStreamedGhost() {
        let r = ChunkFilter.filterChunk(
            accumulated: "<strong>Bonjour</strong> à tous",
            userTail: "", caretAfterSpace: false, maxWords: 20)
        #expect(r.verdict == .emit("Bonjour à tous"))
    }

    @Test func neverShowsTrailingPartialTag() {
        // Mi-stream : "<stron" est arrivé, pas encore le ">". La balise
        // partielle est invisible, la prose qui précède s'affiche.
        let r = ChunkFilter.filterChunk(
            accumulated: "Bonjour <stron",
            userTail: "", caretAfterSpace: false, maxWords: 20)
        #expect(r.verdict == .emit("Bonjour "))
    }

    @Test func hugeNumberAloneIsDropped() {
        // Run absurde seul → coupé à vide → dégénéré → drop, on continue.
        let r = ChunkFilter.filterChunk(
            accumulated: "10000000000",
            userTail: "", caretAfterSpace: false, maxWords: 20)
        #expect(r.verdict == .dropKeepGenerating)
    }

    @Test func hugeNumberMidGhostKeepsHead() {
        let r = ChunkFilter.filterChunk(
            accumulated: "Il y en a 10000000000",
            userTail: "", caretAfterSpace: false, maxWords: 20)
        #expect(r.verdict == .emit("Il y en a"))
    }
}

@Suite("BeamGhostShaper — markup & nombre absurde (chemin beam)")
struct BeamPostFilterMarkupTests {

    @Test func stripsTagsFromBeamGhost() {
        let out = BeamGhostShaper.beamPostFilter(
            rawGhost: "<strong>confirmer</strong> le rendez-vous", isBoundary: true,
            caretAfterSpace: true, userTail: "Je vais ", maxWords: 8)
        #expect(out == "confirmer le rendez-vous")
    }

    @Test func hugeNumberGhostIsSuppressed() {
        #expect(BeamGhostShaper.beamPostFilter(
            rawGhost: "10000000000", isBoundary: true,
            caretAfterSpace: true, userTail: "Il y en a ", maxWords: 8) == "")
    }

    @Test func hugeNumberTailIsCutKeepingHead() {
        let out = BeamGhostShaper.beamPostFilter(
            rawGhost: "environ 10000000000", isBoundary: true,
            caretAfterSpace: true, userTail: "Cela coûte ", maxWords: 8)
        #expect(out == "environ")
    }

    @Test func boundaryDegenerateEnumeratorIsSuppressed() {
        // "1." à une frontière = bruit d'énumérateur — même garde que le
        // streaming (ChunkFilter), absente du beam jusqu'ici.
        #expect(BeamGhostShaper.beamPostFilter(
            rawGhost: "1.", isBoundary: true,
            caretAfterSpace: true, userTail: "Voici les étapes : ", maxWords: 8) == "")
    }

    @Test func midWordContinuationWithLoneConsonantSurvives() {
        // Mid-mot, la garde dégénérée est EXCLUE : "r la suite" (complétant
        // "pou") contient un "r" isolé que isFragmentedGhost condamnerait.
        let out = BeamGhostShaper.beamPostFilter(
            rawGhost: "r la suite", isBoundary: false,
            caretAfterSpace: false, userTail: "Je lis pou", maxWords: 8)
        #expect(out == "r la suite")
    }

    @Test func legitimateNumbersSurviveBeamPath() {
        let out = BeamGhostShaper.beamPostFilter(
            rawGhost: "1er janvier 2026", isBoundary: true,
            caretAfterSpace: true, userTail: "Rendez-vous le ", maxWords: 8)
        #expect(out == "1er janvier 2026")
    }
}

@Suite("Ghost ponctuation seule — supprimé à toute position (chemin beam)")
struct PunctuationOnlyGhostTests {

    @Test func detectsPurePunctuation() {
        for s in [" .", " :", " !", "…", ")", " — ", "..."] {
            #expect(OutputFilter.isPunctuationOnlyGhost(s), "should flag «\(s)»")
        }
    }

    @Test func keepsAnythingWithALetterOrDigit() {
        for s in ["mot.", "o :", "r la suite", " 1er", "à", ""] {
            #expect(!OutputFilter.isPunctuationOnlyGhost(s), "should keep «\(s)»")
        }
    }

    @Test func midWordPunctuationGhostIsSuppressed() {
        // Les deux cas constatés en live (12/06) : "asso" + " :" et
        // "…la balise" + " ." — mid-mot, donc hors de portée de la garde
        // dégénérée de frontière. La garde ponctuation-seule les tait.
        #expect(BeamGhostShaper.beamPostFilter(
            rawGhost: " :", isBoundary: false,
            caretAfterSpace: false, userTail: "asso", maxWords: 8) == "")
        #expect(BeamGhostShaper.beamPostFilter(
            rawGhost: " .", isBoundary: false,
            caretAfterSpace: false, userTail: "on utilise la balise", maxWords: 8) == "")
    }

    @Test func boundaryPunctuationGhostIsSuppressed() {
        // Même après l'insertion du séparateur d'espace (" " + "!"), le ghost
        // reste ponctuation pure → silence.
        #expect(BeamGhostShaper.beamPostFilter(
            rawGhost: "!", isBoundary: true,
            caretAfterSpace: false, userTail: "Merci", maxWords: 8) == "")
    }

    @Test func midWordWordCompletionStillSurvives() {
        // Garantie de non-régression : la complétion mid-mot ordinaire passe.
        #expect(BeamGhostShaper.beamPostFilter(
            rawGhost: "mer le rendez-vous.", isBoundary: false,
            caretAfterSpace: false, userTail: "Je vais confir", maxWords: 8)
            == "mer le rendez-vous.")
    }
}
