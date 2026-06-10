import Testing
@testable import SouffleuseTyping

// Détection pure du trigger « // » — aucune dépendance AX, miroir des règles
// d'EmojiExpander (garde du caractère AVANT le trigger, remontée depuis le caret).

@Suite("SlashTransformDetector")
struct SlashTransformDetectorTests {

    // MARK: - Ouverture du trigger

    @Test("« // » nu après une espace ouvre l'état (filtre vide)")
    func bareTriggerAfterSpace() {
        let state = SlashTransformDetector.detect(textBeforeCaret: "Bonjour //")
        #expect(state != nil)
        #expect(state?.filter == "")
        #expect(state?.scopeText == "Bonjour")
        #expect(state?.isScopeTruncated == false)
    }

    @Test("« // » en tout début de champ → nil (portée vide)")
    func triggerAtFieldStartHasNoScope() {
        #expect(SlashTransformDetector.detect(textBeforeCaret: "//") == nil)
        // Portée non vide mais trimée vide (que des espaces) → rien à transformer.
        #expect(SlashTransformDetector.detect(textBeforeCaret: "   //") == nil)
    }

    @Test("champ vide avant le caret → nil")
    func emptyField() {
        #expect(SlashTransformDetector.detect(textBeforeCaret: "") == nil)
    }

    @Test("« // » après un saut de ligne déclenche, portée = texte avant")
    func triggerAfterNewline() {
        let state = SlashTransformDetector.detect(textBeforeCaret: "Para1\n//cor")
        #expect(state?.scopeText == "Para1")
        #expect(state?.filter == "cor")
    }

    @Test("« // » après une tabulation déclenche")
    func triggerAfterTab() {
        let state = SlashTransformDetector.detect(textBeforeCaret: "col1\tcol2\t//")
        #expect(state != nil)
        #expect(state?.scopeText == "col1\tcol2")
    }

    // MARK: - Faux positifs neutralisés

    @Test("« // » collé à un mot ne déclenche pas")
    func triggerGluedToWord() {
        #expect(SlashTransformDetector.detect(textBeforeCaret: "path//file") == nil)
        #expect(SlashTransformDetector.detect(textBeforeCaret: "mot//") == nil)
    }

    @Test("URL ne déclenche pas (« : » avant la paire)")
    func urlDoesNotTrigger() {
        #expect(SlashTransformDetector.detect(textBeforeCaret: "voir https://exemple.fr") == nil)
        #expect(SlashTransformDetector.detect(textBeforeCaret: "https://") == nil)
    }

    @Test("triple slash ne déclenche pas (« / » avant la paire)")
    func tripleSlashDoesNotTrigger() {
        #expect(SlashTransformDetector.detect(textBeforeCaret: "x ///doc") == nil)
    }

    @Test("slash isolé dans le filtre ferme l'état")
    func lonelySlashInFilterCloses() {
        #expect(SlashTransformDetector.detect(textBeforeCaret: "x //a/b") == nil)
        // Un « / » seul (pas de paire) ne déclenche jamais.
        #expect(SlashTransformDetector.detect(textBeforeCaret: "x /a") == nil)
        #expect(SlashTransformDetector.detect(textBeforeCaret: "/") == nil)
    }

    @Test("saut de ligne après le trigger ferme l'état")
    func newlineAfterTriggerCloses() {
        #expect(SlashTransformDetector.detect(textBeforeCaret: "x //abc\ndef") == nil)
    }

    // MARK: - Filtre

    @Test("filtre avec espaces et accents conservé verbatim")
    func filterWithSpacesAndAccents() {
        let state = SlashTransformDetector.detect(textBeforeCaret: "Salut //rends ça plus poli")
        #expect(state?.filter == "rends ça plus poli")
        #expect(state?.scopeText == "Salut")
    }

    @Test("filtre > maxFilterLength → nil ; à la limite exacte → état ouvert")
    func filterLengthCap() {
        let overCap = "x //" + String(repeating: "a", count: SlashTransformDetector.maxFilterLength + 1)
        #expect(SlashTransformDetector.detect(textBeforeCaret: overCap) == nil)
        let atCap = "x //" + String(repeating: "a", count: SlashTransformDetector.maxFilterLength)
        #expect(SlashTransformDetector.detect(textBeforeCaret: atCap) != nil)
    }

    // MARK: - deleteCharsOnAccept

    @Test("deleteCharsOnAccept portée pleine = portée brute + 2 + filtre")
    func deleteCharsFullScope() {
        let text = "Bonjour monsieur //cor"
        let state = SlashTransformDetector.detect(textBeforeCaret: text)
        #expect(state?.deleteCharsOnAccept == 22)
        #expect(state?.deleteCharsOnAccept == "Bonjour monsieur ".count + 2 + 3)
        // La portée pleine couvre tout le préfixe : suppression = tout le texte tapé.
        #expect(state?.deleteCharsOnAccept == text.count)
    }

    @Test("scopeText est trimé mais deleteChars compte le brut")
    func scopeTrimmedButDeleteCountsRaw() {
        let state = SlashTransformDetector.detect(textBeforeCaret: "Texte  //x")
        #expect(state?.scopeText == "Texte")
        #expect(state?.deleteCharsOnAccept == 10)
    }

    @Test("émoji dans la portée : compte en Character, pas en UTF-16")
    func emojiCountedAsCharacters() {
        let text = "Bravo 🎉 //cor"
        let state = SlashTransformDetector.detect(textBeforeCaret: text)
        // Même contrat que l'emoji picker : un backspace par Character.
        #expect(state?.deleteCharsOnAccept == text.count)
        #expect(state?.deleteCharsOnAccept == 13)
        #expect(state?.scopeText == "Bravo 🎉")
    }

    // MARK: - Portée > 1500 (dernier paragraphe)

    @Test("portée > 1500 → dernier paragraphe (séparateur \\n\\n) + flag")
    func oversizedScopeFallsBackToLastParagraph() {
        let text = String(repeating: "x", count: 1600) + "\n\nDernier para. //"
        let state = SlashTransformDetector.detect(textBeforeCaret: text)
        #expect(state?.scopeText == "Dernier para.")
        #expect(state?.isScopeTruncated == true)
        #expect(state?.deleteCharsOnAccept == "Dernier para. ".count + 2)
    }

    @Test("portée > 1500 sans double saut → dernière ligne (séparateur \\n)")
    func oversizedScopeFallsBackToLastLine() {
        let text = String(repeating: "x", count: 1600) + "\nDernière ligne. //"
        let state = SlashTransformDetector.detect(textBeforeCaret: text)
        #expect(state?.scopeText == "Dernière ligne.")
        #expect(state?.isScopeTruncated == true)
        #expect(state?.deleteCharsOnAccept == "Dernière ligne. ".count + 2)
    }

    @Test("portée > 1500 sans aucun saut → suffix(1500)")
    func oversizedScopeWithoutNewlineTakesSuffix() {
        let text = String(repeating: "x", count: 1600) + " //"
        let state = SlashTransformDetector.detect(textBeforeCaret: text)
        #expect(state?.isScopeTruncated == true)
        // rawScope = 1500 derniers Characters du préfixe (espace final inclus).
        #expect(state?.deleteCharsOnAccept == SlashTransformDetector.maxFullFieldLength + 2)
        #expect(state?.scopeText == String(repeating: "x", count: 1499))
    }

    @Test("portée ≤ 1500 → pas tronquée")
    func scopeUnderCapIsNotTruncated() {
        let text = String(repeating: "x", count: 1500) + " //"
        let state = SlashTransformDetector.detect(textBeforeCaret: text)
        #expect(state?.isScopeTruncated == false)
        #expect(state?.deleteCharsOnAccept == text.count)
    }

    @Test("préfixe finissant en \\n\\n : remonte au dernier paragraphe non vide")
    func trailingBlankParagraphIsSkipped() {
        let text = String(repeating: "x", count: 1600) + "\n\nPara plein.\n\n//"
        let state = SlashTransformDetector.detect(textBeforeCaret: text)
        #expect(state?.scopeText == "Para plein.")
        #expect(state?.isScopeTruncated == true)
        // rawScope démarre après le « \n\n » qui précède « Para plein. » et
        // inclut le « \n\n » final (brut jusqu'au trigger).
        #expect(state?.deleteCharsOnAccept == "Para plein.\n\n".count + 2)
    }

    // MARK: - resolveScope (seam interne)

    @Test("resolveScope renvoie le préfixe entier sous le cap")
    func resolveScopeFullPrefix() {
        let prefix = Substring("Bonjour monsieur ")
        let (raw, truncated) = SlashTransformDetector.resolveScope(prefixBeforeTrigger: prefix)
        #expect(String(raw) == "Bonjour monsieur ")
        #expect(truncated == false)
    }

    @Test("resolveScope au-dessus du cap renvoie le substring BRUT du dernier paragraphe")
    func resolveScopeLastParagraphIsRaw() {
        let prefix = Substring(String(repeating: "x", count: 1600) + "\n\n  Fin.  ")
        let (raw, truncated) = SlashTransformDetector.resolveScope(prefixBeforeTrigger: prefix)
        // Brut : les espaces autour de « Fin. » restent (le trim arrive après,
        // dans detect ; le compte de suppression part du début du substring).
        #expect(String(raw) == "  Fin.  ")
        #expect(truncated == true)
    }
}
