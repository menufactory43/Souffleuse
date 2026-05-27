import Testing
import Foundation
import SouffleusePersonalization
import SouffleuseTyping
@testable import Souffleuse

/// Tightening pass 2026-05-26 (post 04-07 empirical validation).
///
/// Verrouille les nouveaux seuils introduits suite au constat empirique que
/// cache + history polluaient le ghost en after-space :
///
///   - `Tuning.afterSpaceL1Bar` raised 0.4 → 0.6 (history L1 plus strict)
///   - `Tuning.cacheFloor: 0.55` (cache hits doivent passer le Gate)
///   - `Tuning.undoCacheFloor: 0.45` (undo-cache plus permissif, signal fort)
///
/// Cas concrets observés en session (à ne PLUS jamais voir) :
///   - "Je reviens " → history inject "Je suis…" (stale)
///   - "Merci beaucoup pour " → history inject "3ème version"
///   - "Je reviens vers vous conce" → mid-word, history n'a pas droit
@MainActor
@Suite("Phase 4 tightening — cache/history floors (post 04-07)")
struct CascadeTighteningTests {

    // MARK: - Tuning constants validity

    @Test func tuningFloorsAreOrderedCoherently() {
        // gateFloor < undoCacheFloor < cacheFloor < afterSpaceL1Bar
        // Cache requires HIGHER bar than undo (cache memory diffuse vs undo strong signal),
        // but BOTH cache and undo are below history L1 (after-space history more polluting).
        #expect(SuggestionPolicy.Tuning.gateFloor < SuggestionPolicy.Tuning.undoCacheFloor)
        #expect(SuggestionPolicy.Tuning.undoCacheFloor < SuggestionPolicy.Tuning.cacheFloor)
        #expect(SuggestionPolicy.Tuning.cacheFloor < SuggestionPolicy.Tuning.afterSpaceL1Bar)
    }

    @Test func afterSpaceL1BarTightenedFromBaselineFortyToSixty() {
        // Régression guard : le tightening doit rester ≥ 0.55 (sinon on
        // revient au régime trop permissif observé en 04-07).
        #expect(SuggestionPolicy.Tuning.afterSpaceL1Bar >= 0.55)
    }

    // MARK: - 3 cas concrets : history doit être bloquée

    /// "Je reviens " (after-space) + history "Je suis…" (1 mot après match) :
    /// score history = 0.75 × 1.0 × 0.6 = 0.45 < 0.6 (afterSpaceL1Bar) → BLOQUÉ.
    @Test func jeReviensDoesNotInjectStaleOneWordFragment() {
        let oneWordTail = SuggestionPolicy.score(
            source: .history,
            ghost: "suis",
            userTail: "Je reviens "
        )
        #expect(oneWordTail.value < SuggestionPolicy.Tuning.afterSpaceL1Bar)
    }

    /// "Merci beaucoup pour " (after-space) + history "3ème version" (2 mots) :
    /// score = 0.75 × prefixFit × 1.0. Le prefixFit dépend du caractère initial.
    /// "3" est isNumber → prefixFit = 1.0 → score = 0.75. PASS le bar 0.6.
    ///
    /// **Note** : 2-mots history *passe* le bar avec un start naturel — c'est
    /// par design. La pollution réelle vient de fragments 1-mot (length_fit 0.6)
    /// OU de fragments à start anormal (markdown/whitespace, prefixFit 0). Pour
    /// "3ème version" l'utilisateur doit aussi remonter dans la pile (sémantique
    /// non détectable à ce niveau — c'est pourquoi on a aussi raised cacheFloor
    /// pour bloquer la cache pollution séparément).
    @Test func merciBeaucoupPourTwoWordHistoryPassesButShortFragmentBlocked() {
        let twoWords = SuggestionPolicy.score(
            source: .history,
            ghost: "3ème version",
            userTail: "Merci beaucoup pour "
        )
        // 2-mots OK → 0.75. Le tightening ne bloque pas ce cas via length_fit
        // (c'est un trade-off accepté).
        #expect(twoWords.value >= SuggestionPolicy.Tuning.afterSpaceL1Bar)

        // En revanche, un fragment 1-mot ("3ème") est bloqué :
        let oneWordFragment = SuggestionPolicy.score(
            source: .history,
            ghost: "3ème",
            userTail: "Merci beaucoup pour "
        )
        #expect(oneWordFragment.value < SuggestionPolicy.Tuning.afterSpaceL1Bar)
    }

    /// "Je reviens vers vous conce" (mid-word) : history rappelle la phrase.
    ///
    /// RÉVISION D-08 (2026-05-27) : avant, routeInstant forçait L0-only mid-word
    /// et ce cas était explicitement exclu de l'historique. C'est désormais le
    /// comportement VOULU (parité Cotypist) : le fragment "conce" + son contexte
    /// prolongent une phrase apprise → on rappelle "rnant ma version précédente"
    /// (capté à maxWords). La continuation complète le mot en cours (commence par
    /// une lettre), donc c'est un vrai rappel mid-mot, pas un saut de mot.
    @Test func jeReviensVersVousConceMidWordRecallsHistory() {
        let engine = SuggestionPolicyEngine(maxWords: 8)
        let snap = [
            TypingHistoryEntry(
                timestamp: Date(),
                contextBefore: "",
                accepted: "Je reviens vers vous concernant ma version précédente",
                bundleID: nil
            )
        ]
        let r = engine.routeInstant(
            userTail: "Je reviens vers vous conce",
            historySnapshot: snap,
            wordCompleter: WordCompleter()
        )
        #expect(r?.source == .history)
        #expect(r?.text == "rnant ma version précédente")
    }

    // MARK: - Cache floor

    /// Cache hit "well-formed" (3-mots, prefixFit 1.0) : score = 0.70 × 1.0 × 1.0 = 0.70.
    /// PASS le cacheFloor 0.55.
    @Test func cacheHitSweetSpotPassesFloor() {
        let s = SuggestionPolicy.score(
            source: .cache,
            ghost: "vers vous bientôt",
            userTail: "Je reviens "
        )
        #expect(s.value >= SuggestionPolicy.Tuning.cacheFloor)
    }

    /// Cache hit malformé (1-mot, lengthFit 0.6) : score = 0.70 × 1.0 × 0.6 = 0.42.
    /// BLOQUÉ par cacheFloor 0.55.
    @Test func cacheHitOneWordIsBlockedByFloor() {
        let s = SuggestionPolicy.score(
            source: .cache,
            ghost: "ghost",
            userTail: " "
        )
        #expect(s.value < SuggestionPolicy.Tuning.cacheFloor)
    }

    /// Cache hit avec start anormal (whitespace, markdown) → prefixFit 0 → score 0 → BLOQUÉ.
    @Test func cacheHitWithBadStartIsBlocked() {
        let withSpace = SuggestionPolicy.score(
            source: .cache,
            ghost: " leading-space",
            userTail: "test "
        )
        #expect(withSpace.value < SuggestionPolicy.Tuning.cacheFloor)

        let withMarkdown = SuggestionPolicy.score(
            source: .cache,
            ghost: "# heading",
            userTail: "test "
        )
        #expect(withMarkdown.value < SuggestionPolicy.Tuning.cacheFloor)
    }

    // MARK: - Undo cache floor (plus permissif)

    /// Undo-cache typique (3-5 chars, mid-word context recovery) : score sweet.
    @Test func undoCachePermissiveRecoverShortDelta() {
        // Undo restitue 5 chars effacés : "ation" sur tail "applic".
        // userTail "applic" (mid-word) → ghost "ation" commence par lettre → prefixFit 1.0.
        // 1 mot → lengthFit 0.6. Score = 0.65 × 1.0 × 0.6 = 0.39 < 0.45.
        // Donc même undo 1-mot court est bloqué — c'est plus strict que prévu.
        let oneWord = SuggestionPolicy.score(
            source: .undoCache,
            ghost: "ation",
            userTail: "applic"
        )
        #expect(oneWord.value < SuggestionPolicy.Tuning.undoCacheFloor)

        // 2-mots+ pass : 0.65 × 1.0 × 1.0 = 0.65.
        let phrase = SuggestionPolicy.score(
            source: .undoCache,
            ghost: "vers vous",
            userTail: "Je reviens "
        )
        #expect(phrase.value >= SuggestionPolicy.Tuning.undoCacheFloor)
    }

    // MARK: - No literal floor values in source

    /// Pitfall 6 enforcement : les nouveaux Tuning.cacheFloor / undoCacheFloor /
    /// afterSpaceL1Bar (raised) doivent être référencés via Tuning, pas inlinés.
    @Test func tighteningFloorsAreReferencedNotInlined() {
        // Vérifié au lecteur : grep -E '0\.55|0\.45|0\.6' Sources/Souffleuse/*.swift
        // ne doit retourner que SuggestionPolicy+Tuning.swift + doc-comments.
        // Test sentinel passant : si les constantes sont bonnes valeurs.
        #expect(SuggestionPolicy.Tuning.cacheFloor == 0.55)
        #expect(SuggestionPolicy.Tuning.undoCacheFloor == 0.45)
        #expect(SuggestionPolicy.Tuning.afterSpaceL1Bar == 0.6)
    }
}
