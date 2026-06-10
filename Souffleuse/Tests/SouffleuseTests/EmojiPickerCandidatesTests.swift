import Testing
@testable import SouffleuseTyping

// MARK: - EmojiPickerCandidatesTests

/// Couvre la fonction pure `EmojiExpander.pickerCandidates` — toute la politique
/// de déclenchement du picker « : » (parité Cotypist) vit là pour être testable
/// sans UI : gardes heures/URL/namespaces, filtrage par préfixe, ranking par
/// fréquence d'usage, complément curé de l'état nu.
@Suite("EmojiExpander picker candidates")
struct EmojiPickerCandidatesTests {

    // MARK: Déclenchement

    @Test("« : » nu après une espace ouvre le panneau avec 9 candidats")
    func bareColonShowsCurated() {
        let state = EmojiExpander.pickerCandidates(textBeforeCaret: "Coucou :")
        #expect(state != nil)
        #expect(state?.fragmentLength == 1)
        #expect(state?.candidates.count == 9)
        // Sans historique d'usage, la liste curée mène — 👋 d'abord.
        #expect(state?.candidates.first?.shortcode == "wave")
    }

    @Test("« : » en tout début de texte ouvre aussi")
    func colonAtStart() {
        #expect(EmojiExpander.pickerCandidates(textBeforeCaret: ":") != nil)
    }

    @Test("« : » après un chiffre ne se déclenche pas (heures, ports)")
    func digitGuard() {
        #expect(EmojiExpander.pickerCandidates(textBeforeCaret: "rdv à 14:") == nil)
        #expect(EmojiExpander.pickerCandidates(textBeforeCaret: "localhost:8") == nil)
    }

    @Test("« : » après une lettre ne se déclenche pas (http:, exemple:)")
    func letterGuard() {
        #expect(EmojiExpander.pickerCandidates(textBeforeCaret: "http:") == nil)
        #expect(EmojiExpander.pickerCandidates(textBeforeCaret: "https://example.com:") == nil)
    }

    @Test("« :: » (namespace C++) ne se déclenche pas")
    func doubleColonGuard() {
        #expect(EmojiExpander.pickerCandidates(textBeforeCaret: "std::") == nil)
        #expect(EmojiExpander.pickerCandidates(textBeforeCaret: "std::v") == nil)
    }

    @Test("pas de fragment ouvert (espace après le deux-points) → nil")
    func noOpenFragment() {
        #expect(EmojiExpander.pickerCandidates(textBeforeCaret: "deux : points") == nil)
        #expect(EmojiExpander.pickerCandidates(textBeforeCaret: "bonjour ") == nil)
    }

    // MARK: Filtrage

    @Test("le fragment filtre par préfixe et fixe la longueur à remplacer")
    func prefixFiltering() {
        let state = EmojiExpander.pickerCandidates(textBeforeCaret: "Bravo :sm")
        #expect(state?.fragmentLength == 3)   // « :sm »
        #expect(state?.candidates.isEmpty == false)
        for c in state?.candidates ?? [] {
            #expect(c.shortcode.hasPrefix("sm"))
        }
    }

    @Test("le fragment est insensible à la casse")
    func caseInsensitiveFragment() {
        let lower = EmojiExpander.pickerCandidates(textBeforeCaret: ":sm")
        let upper = EmojiExpander.pickerCandidates(textBeforeCaret: ":SM")
        #expect(upper == lower)
    }

    @Test("aucun match → nil (le panneau se ferme)")
    func noMatchCloses() {
        #expect(EmojiExpander.pickerCandidates(textBeforeCaret: ":zzzz") == nil)
    }

    @Test("jamais plus de `limit` candidats")
    func limitRespected() {
        let state = EmojiExpander.pickerCandidates(textBeforeCaret: ":s", limit: 4)
        #expect((state?.candidates.count ?? 0) <= 4)
    }

    // MARK: Ranking par fréquence

    @Test("état nu : l'usage personnel prime, le curé complète sans doublon")
    func bareColonFrequencyFirst() {
        let freq = ["rocket": 5, "fire": 2]
        let state = EmojiExpander.pickerCandidates(textBeforeCaret: ":", frequency: freq)
        #expect(state?.candidates[0].shortcode == "rocket")
        #expect(state?.candidates[1].shortcode == "fire")
        // « fire » est aussi dans le curé — il ne doit apparaître qu'une fois.
        let codes = state?.candidates.map(\.shortcode) ?? []
        #expect(codes.filter { $0 == "fire" }.count == 1)
        #expect(state?.candidates.count == 9)
    }

    @Test("matches de préfixe : fréquence décroissante puis alphabétique")
    func prefixFrequencyThenAlpha() {
        let freq = ["smirk": 3]
        let state = EmojiExpander.pickerCandidates(textBeforeCaret: ":sm", frequency: freq)
        #expect(state?.candidates.first?.shortcode == "smirk")
        // Le reste (fréquence 0) est trié alphabétiquement.
        let rest = (state?.candidates.dropFirst().map(\.shortcode)) ?? []
        #expect(Array(rest) == rest.sorted())
    }

    @Test("la sélection d'un candidat donne de quoi remplacer le fragment")
    func selectionPayload() {
        let state = EmojiExpander.pickerCandidates(textBeforeCaret: "GG :ta")
        // « :ta » = 3 chars à supprimer, premier candidat alphabétique = tada.
        #expect(state?.fragmentLength == 3)
        let tada = state?.candidates.first { $0.shortcode == "tada" }
        #expect(tada?.emoji == "🎉")
    }
}
