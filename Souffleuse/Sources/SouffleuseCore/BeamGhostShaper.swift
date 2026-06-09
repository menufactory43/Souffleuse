import Foundation

// MARK: - BeamGhostShaper
//
// Logique de MISE EN FORME PURE du cœur de génération beam (`SOUFFLEUSE_BEAM_CORE`).
// Extrait VERBATIM (zéro changement de comportement) des helpers privés de
// `ModelRuntime.generateGhostBeam` — `beamPostFilter`, `currentSentenceLetterCount`,
// `beamMinSentenceLetters` — PLUS deux nouvelles décisions pures qui étaient inline
// dans `generateGhostBeam` (le choix requiredPrefix/largeur mid-mot vs frontière, et
// le choix des slots de prompt).
//
// POURQUOI ici (SouffleuseCore) plutôt que dans le target `Souffleuse` :
//  - `SouffleuseCore` est IMPORTABLE par un exécutable de probe (`SouffleuseBeamGhostProbe`),
//    alors que le target exécutable `Souffleuse` ne l'est pas.
//  - Toutes les dépendances (`OutputFilter`, `SuggestionPolicy`, `LlamaPromptBuilder`)
//    vivent DÉJÀ dans SouffleuseCore → aucune nouvelle dépendance de module.
//
// `enum` sans cas = simple espace de noms de fonctions `static`, style maison
// (cf. `OutputFilter`, `LlamaPromptBuilder`). Toutes les fonctions sont PURES et
// `nonisolated` : aucun état, aucun effet de bord, testables hors MainActor.
public enum BeamGhostShaper {

    // MARK: - G2 : reprise après le point (seuil de phrase)

    /// « Quelques lettres » de G2 — seuil d'amorce d'une nouvelle phrase. Sous ce
    /// nombre de lettres dans la phrase EN COURS, le ghost se tait (juste après un
    /// point ⇒ silence ; reprise dès quelques lettres). Valeur extraite VERBATIM
    /// de `ModelRuntime.beamMinSentenceLetters`.
    public nonisolated static let beamMinSentenceLetters = 3

    /// Nombre de lettres de la PHRASE EN COURS = depuis le dernier terminateur de
    /// phrase (`.` `!` `?`) jusqu'à la fin du texte. Pilote G2 : juste après un
    /// point ⇒ 0 ⇒ silence ; on reprend dès quelques lettres de la nouvelle phrase.
    /// Extrait VERBATIM de `ModelRuntime.currentSentenceLetterCount`.
    public nonisolated static func currentSentenceLetterCount(_ text: String) -> Int {
        var count = 0
        for ch in text.reversed() {
            if ".!?".contains(ch) { break }
            if ch.isLetter { count += 1 }
        }
        return count
    }

    /// G2 sous forme de prédicat : la phrase en cours est-elle assez amorcée pour
    /// qu'on propose un ghost ? `false` ⇒ silence (juste après un point). Le seuil
    /// est paramétrable pour le balayage de la probe ; défaut = `beamMinSentenceLetters`.
    public nonisolated static func sentenceArmed(
        userTail: String, minLetters: Int = beamMinSentenceLetters
    ) -> Bool {
        currentSentenceLetterCount(userTail) >= minLetters
    }

    // MARK: - Choix de config beam : requiredPrefix + largeur (mid-mot vs frontière)

    /// Décision de config du beam pour CE préfixe :
    ///  - partiel NON VIDE (caret dans un mot, même si le fragment est un mot
    ///    valide du dico) → `requiredPrefix = partial`, largeur K plein. La
    ///    contrainte n'empêche PAS le mot de se terminer : le beam peut émettre
    ///    un espace juste après le partiel (« la » → « la bonne ») — elle
    ///    interdit seulement d'ABANDONNER le fragment tapé.
    ///  - VRAI après-espace (partiel vide) → `requiredPrefix = ""`, largeur 1
    ///    (décode libre ≡ greedy ; le beam n'aide pas après-espace).
    ///
    /// HISTORIQUE : la première version cédait aussi la contrainte quand
    /// `defaultPartialWordIsComplete` jugeait le fragment « mot complet ».
    /// `isValidWord` (permissif FR+EN) acceptant « d », « vo », « co »,
    /// « dispo »…, ~41 % des frappes réellement mid-mot partaient en décode
    /// libre K=1 + espace forcé du post-filtre (« proc » → « proc édure »).
    /// Mesuré par SouffleuseParityEval (PARITY-FINDINGS.md) : avec la contrainte
    /// systématique, mot juste à ≤1 lettre 0 % → 55 %, médiane 4 → 1 lettre,
    /// stabilité k→k+1 66 % → 100 %.
    ///
    /// `beamWidth` = le K plein de la config (typiquement 3). Tuple nommé, style maison.
    public nonisolated static func beamConfigChoice(
        userTail: String, beamWidth: Int
    ) -> (requiredPrefix: String, width: Int, isBoundary: Bool) {
        let partial = OutputFilter.trailingPartialWord(userTail)
        let isBoundary = partial.isEmpty
        let requiredPrefix = isBoundary ? "" : partial
        let width = isBoundary ? 1 : beamWidth
        return (requiredPrefix, width, isBoundary)
    }

    // MARK: - Choix de prompt (slots)

    /// Slots du prompt beam, identiques à l'inline de `generateGhostBeam` : contexte
    /// PROSE (persona `customInstr` + `ctxPrefix` app/fenêtre/OCR) + tout le texte
    /// avant curseur. EXCLUS volontairement : `system`, exemples few-shot (pollueur
    /// prouvé du base/PT), `fieldContext`/`afterCursor` (FIM), `examples`. Tuple
    /// nommé prêt à passer à `LlamaPromptBuilder.buildLlamaPrompt`.
    public nonisolated static func promptSlots(
        customInstr: String, ctxPrefix: String, llmTail: String
    ) -> (system: String, customInstr: String, ctxPrefix: String,
          fieldContext: String, afterCursor: String, beforeCursor: String) {
        (system: "", customInstr: customInstr, ctxPrefix: ctxPrefix,
         fieldContext: "", afterCursor: "", beforeCursor: llmTail)
    }

    /// Construit directement le texte de prompt beam via `LlamaPromptBuilder`, en
    /// appliquant `promptSlots`. Sucre pour les call-sites (ModelRuntime + probe).
    public nonisolated static func buildPrompt(
        customInstr: String, ctxPrefix: String, llmTail: String
    ) -> String {
        let s = promptSlots(customInstr: customInstr, ctxPrefix: ctxPrefix, llmTail: llmTail)
        return LlamaPromptBuilder.buildLlamaPrompt(
            system: s.system, customInstr: s.customInstr, ctxPrefix: s.ctxPrefix,
            fieldContext: s.fieldContext, afterCursor: s.afterCursor, beforeCursor: s.beforeCursor)
    }

    // MARK: - Post-filtre de sortie

    /// Garde de sortie du ghost beam — MIROIR des post-filtres du long-ghost
    /// (singleLine, dédup mot répété, séparateur d'espace, écho positionnel,
    /// coupe-clause INCLUSIVE, word-cap), appliquée au suffixe brut renvoyé par le
    /// beam. Extrait VERBATIM de `ModelRuntime.beamPostFilter` (zéro changement).
    /// `nonisolated static` (pures fonctions OutputFilter/SuggestionPolicy).
    public nonisolated static func beamPostFilter(
        rawGhost: String, isBoundary: Bool, caretAfterSpace: Bool,
        userTail: String, maxWords: Int
    ) -> String {
        var result = OutputFilter.singleLine(rawGhost)
        if result.isEmpty { return "" }
        // Dédup d'un mot répété en tête (le beam peut re-émettre le dernier mot tapé).
        result = SuggestionPolicy.dedupLeadingRepeat(ghost: result, userTail: userTail)
        if result.isEmpty { return "" }
        // Séparateur : le beam strippe déjà l'espace de tête après-espace
        // (ghostText, requiredPrefixLen==0). À une frontière NON précédée d'un
        // espace (« message.| »), on rétablit un séparateur ; le mid-mot reste
        // collé (complétion de mot, pas de séparateur).
        if isBoundary, !caretAfterSpace, let f = result.first, f != " ", f != "\t" {
            result = " " + result
        }
        // Écho positionnel : tue les vraies boucles (run verbatim ≥ seuil), garde
        // la réutilisation de vocabulaire — même garde que midWordLongGhost.
        let echo = OutputFilter.echoScore(ghost: result, tail: userTail)
        if echo >= OutputFilter.continuationEchoThreshold {
            let run = OutputFilter.longestVerbatimRunWords(ghost: result, tail: userTail)
            if run >= SuggestionPolicy.Tuning.echoMinVerbatimRunWords { return "" }
        }
        // Coupe à la 1ʳᵉ frontière de clause/phrase (newline . ! ? ; :), bornes
        // INCLUSES — exactement « comme d'hab » (long-ghost) : on montre la suite
        // jusqu'à la fin de phrase comprise, on ne va pas AU-DELÀ. Ne pas proposer
        // la phrase SUIVANTE est le rôle de G2 (reprise après le point), pas de
        // supprimer la complétion en cours.
        if let idx = result.firstIndex(where: { "\n.!?;:".contains($0) }) {
            result = String(result[...idx])
        }
        // Cap à maxWords mots entiers, espace de tête préservé.
        let words = result.split(whereSeparator: { $0.isWhitespace })
        if words.count > max(1, maxWords) {
            let hadLeadingSpace = result.first == " "
            result = words.prefix(max(1, maxWords)).joined(separator: " ")
            if hadLeadingSpace, result.first != " ", !result.isEmpty { result = " " + result }
        }
        return OutputFilter.singleLine(result)
    }
}
