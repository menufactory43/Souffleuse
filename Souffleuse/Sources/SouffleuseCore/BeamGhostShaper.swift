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

    // MARK: - Mid-line : coupe anti-recopie du texte après le curseur

    /// Le texte qui suit le caret, restreint à la LIGNE COURANTE. `nil` quand il
    /// n'y a rien à recopier (caret en fin de ligne, ou seulement du blanc avant
    /// le prochain retour) — c'est le gate qui garde le chemin end-of-line
    /// byte-identique : un `textAfterCaret` qui ne contient que les paragraphes
    /// SUIVANTS (« \nSuite… ») ne déclenche pas la coupe.
    public nonisolated static func sameLineAfterCaret(_ afterCaret: String?) -> String? {
        guard let after = afterCaret, !after.isEmpty else { return nil }
        let line = String(after.prefix(while: { $0 != "\n" && $0 != "\r" }))
        guard line.contains(where: { !$0.isWhitespace }) else { return nil }
        return line
    }

    /// Mot normalisé pour la comparaison de recopie : casse pliée, ponctuation
    /// d'extrémité ignorée (« content, » ≍ « content »). L'intérieur est préservé
    /// (« l'ai » reste « l'ai »).
    private nonisolated static func normalizedWord(_ w: Substring) -> String {
        w.lowercased().trimmingCharacters(in: .punctuationCharacters)
    }

    /// **Coupe anti-recopie mid-line.** Quand le caret est au MILIEU d'une ligne,
    /// le modèle (qui ne voit que le préfixe) prédit très souvent… les mots qui
    /// suivent déjà le caret — l'utilisateur les avait tapés après ce même
    /// préfixe. La pill proposait alors d'insérer un doublon (« je |suis là » →
    /// ghost « suis là »). Deux formes de recopie, traitées mot à mot
    /// (case-insensitive, ponctuation d'extrémité ignorée) :
    ///
    ///  • **Écho de QUEUE** : un suffixe du ghost == le début du texte après
    ///    caret → on coupe la queue, la tête reste insérable proprement
    ///    (« vraiment suis là » avant « suis là » → « vraiment »). Le cas
    ///    « ghost entier == début d'après-caret » en est le dégénéré → vide.
    ///    Couvre aussi le mid-mot : « couc|ou » + ghost « ou » → vide (le reste
    ///    du mot est déjà là).
    ///  • **Écho de TÊTE** : le ghost COMMENCE par re-taper ≥ 2 mots du texte
    ///    qui suit puis continue autrement (« le 12 et plus » avant
    ///    « le 12 mars ») → tout le ghost s'insérerait avant sa propre copie ;
    ///    abstention. (1 seul mot de tête commun reste légitime : « le rapport »
    ///    inséré avant « le 12 mars » lit bien.)
    ///
    /// Hors mid-line (`sameLineAfterCaret == nil`) ou ghost vide : retour inchangé.
    public nonisolated static func afterCaretEchoCut(ghost: String, afterCaret: String?) -> String {
        guard !ghost.isEmpty, let line = sameLineAfterCaret(afterCaret) else { return ghost }
        let afterWords = line.split(whereSeparator: { $0.isWhitespace })
            .map(normalizedWord).filter { !$0.isEmpty }
        guard !afterWords.isEmpty else { return ghost }

        // Mots du ghost + index de DÉBUT de chacun dans la chaîne brute, pour
        // couper en conservant l'espacement original (espace de tête compris).
        var words: [String] = []
        var starts: [String.Index] = []
        var i = ghost.startIndex
        while i < ghost.endIndex {
            if ghost[i].isWhitespace { i = ghost.index(after: i); continue }
            let start = i
            while i < ghost.endIndex, !ghost[i].isWhitespace { i = ghost.index(after: i) }
            let norm = normalizedWord(ghost[start..<i])
            if !norm.isEmpty {
                words.append(norm)
                starts.append(start)
            }
        }
        guard !words.isEmpty else { return ghost }

        // Écho de TÊTE (≥ 2 mots communs en ouverture) → abstention totale.
        var headRun = 0
        while headRun < min(words.count, afterWords.count), words[headRun] == afterWords[headRun] {
            headRun += 1
        }
        if headRun >= 2 { return "" }

        // Écho de QUEUE : premier index de coupe tel que words[cut...] recopie
        // le début d'afterWords. cut == 0 = recopie intégrale → vide.
        for cut in 0..<words.count {
            let runLen = words.count - cut
            guard runLen <= afterWords.count else { continue }
            var matches = true
            for j in 0..<runLen where words[cut + j] != afterWords[j] {
                matches = false
                break
            }
            if matches {
                if cut == 0 { return "" }
                var head = String(ghost[..<starts[cut]])
                while head.last?.isWhitespace == true { head.removeLast() }
                return head
            }
        }
        return ghost
    }

    /// Sélection du ghost parmi les K candidats du beam (triés par score, best en
    /// tête). Hors mid-line : comportement HISTORIQUE byte-identique — seul le
    /// 1ᵉʳ candidat (best) compte, post-filtré. Mid-line : on prend le PREMIER
    /// candidat qui survit au post-filtre ET à la coupe anti-recopie — c'est
    /// exactement ce que la largeur K achète ici (le best recopie souvent le
    /// texte existant ; un rang 2/3 propose autre chose).
    public nonisolated static func selectGhost(
        rawCandidates: [String], isBoundary: Bool, caretAfterSpace: Bool,
        userTail: String, maxWords: Int, afterCaret: String?, trimDanglingTail: Bool = false
    ) -> String {
        guard sameLineAfterCaret(afterCaret) != nil else {
            return beamPostFilter(
                rawGhost: rawCandidates.first ?? "", isBoundary: isBoundary,
                caretAfterSpace: caretAfterSpace, userTail: userTail, maxWords: maxWords,
                trimDanglingTail: trimDanglingTail)
        }
        for raw in rawCandidates {
            let filtered = beamPostFilter(
                rawGhost: raw, isBoundary: isBoundary,
                caretAfterSpace: caretAfterSpace, userTail: userTail, maxWords: maxWords,
                trimDanglingTail: trimDanglingTail)
            let cut = afterCaretEchoCut(ghost: filtered, afterCaret: afterCaret)
            if !cut.isEmpty { return cut }
        }
        return ""
    }

    // MARK: - Cap « Long » + trim-arrière au dernier stop propre

    /// Pref « Long » : le beam GÉNÈRE jusqu'à `longGhostMaxWords` (au lieu du cap
    /// court par défaut) puis `trimBackToCleanStop` rogne la queue. Validé par
    /// `SouffleuseMaxWordsEval` (commit eval) : 8 = dernier cap avant que la
    /// dérive (bigramme répété) ne décolle (~+40 ms vs Moyen, ~18 ms/mot linéaire).
    /// `triggerWords` sépare Long (request.maxWords 20) de Moyen (3) sans toucher
    /// le mapping `PreferencesStore`. `maxTokens = maxWords×4+2` (mot long FR ≤ 4 tok).
    public static let longGhostTriggerWords = 6
    public static let longGhostMaxWords = 8
    public static let longGhostMaxTokens = longGhostMaxWords * 4 + 2

    /// Recharge INCRÉMENTALE de la fenêtre vivante en Long : on regénère par petits
    /// pas (`longGhostRefillStepWords` mots) dès qu'on descend d'un pas sous la
    /// cible, au lieu d'un gros chunk rare (8 mots ⇒ ~530 ms de decode). Le prefill
    /// étant réutilisé (LCP), des recharges plus nombreuses mais courtes divisent la
    /// latence PAR recharge sans surcoût notable, et lissent la fenêtre.
    public static let longGhostRefillStepWords = 4

    /// Mots-outils FR : un ghost long qui se termine là-dessus est tronqué de façon
    /// incohérente (« …pour la », « …et »). `trimBackToCleanStop` les lâche en fin.
    private static let trailingFunctionWords: Set<String> = [
        "le", "la", "les", "l", "un", "une", "des", "de", "du", "d", "au", "aux",
        "et", "ou", "à", "en", "que", "qui", "dans", "sur", "sous", "pour", "par",
        "avec", "sans", "ce", "cet", "cette", "ces", "mon", "ma", "mes", "ton",
        "ta", "tes", "son", "sa", "ses", "notre", "votre", "leur", "leurs", "ne",
        "se", "je", "tu", "il", "elle", "on", "nous", "vous", "ils", "elles", "ni",
        "car", "donc", "mais", "or", "puis", "afin", "vers", "chez", "est", "a",
        "ont", "sont", "qu",
    ]

    private static func normalizedTailWord(_ s: Substring) -> String {
        s.lowercased().trimmingCharacters(in: .punctuationCharacters)
    }

    /// Trim-arrière : on a généré jusqu'au cap, on RECULE jusqu'au dernier stop
    /// propre (on lâche les mots-outils et tokens ponctuation-seuls traînants). Ne
    /// raccourcit QUE quand la fin est bancale — « lien vers le site de la » →
    /// « lien vers le site » ; « informe que » → « informe ». Une fin sur `.!?`
    /// (phrase finie) est PRÉSERVÉE. La virgule reste attachée au mot.
    public nonisolated static func trimBackToCleanStop(_ ghost: String) -> String {
        var parts = ghost.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        while let last = parts.last {
            if last.contains(where: { ".!?".contains($0) }) { break }   // fin propre : on garde
            let n = normalizedTailWord(Substring(last))
            if n.isEmpty || trailingFunctionWords.contains(n) { parts.removeLast() } else { break }
        }
        return parts.joined(separator: " ")
    }

    /// Tronque le ghost AU PREMIER mot de contenu qui répète un mot de contenu
    /// déjà émis DANS le ghost. Le décode du beam (K=1 « greedy » après-espace
    /// comme K>1 mid-mot) n'applique AUCUNE pénalité de répétition — pas de
    /// `repeatPenalty`, pas de no-repeat-ngram (le greedy `LlamaEngine.generate`
    /// qui en a une ne sert QUE la traduction). Sur un préfixe pauvre, le base/PT
    /// dérive alors en énumération (« révolution, révolutionnaire,
    /// révolutionnaire, … ») que rien n'arrêtait : `echoScore` ne mesure que
    /// l'écho du TAIL utilisateur, pas la répétition INTERNE du ghost. On coupe
    /// AVANT le doublon — la 1ʳᵉ occurrence reste, la boucle disparaît — et on
    /// lâche un séparateur traînant (« …révolutionnaire, »). Conservateur : seuls
    /// les mots de contenu (≥ 3 lettres, hors mots-outils `trailingFunctionWords`)
    /// comptent, donc un « de … de » / « la … la » légitime ne déclenche jamais.
    /// SANS doublon, renvoie l'entrée INCHANGÉE (byte-identique pour un ghost sain).
    public nonisolated static func truncateAtInternalRepeat(_ ghost: String) -> String {
        var seen = Set<String>()
        let parts = ghost.split(separator: " ", omittingEmptySubsequences: false)
        for (i, part) in parts.enumerated() {
            let n = normalizedTailWord(part)
            guard n.count >= 3, !trailingFunctionWords.contains(n) else { continue }
            if seen.contains(n) {
                var kept = parts[0..<i].joined(separator: " ")
                while let last = kept.last, last == "," || last == ";" || last == " " {
                    kept.removeLast()
                }
                return kept
            }
            seen.insert(n)
        }
        return ghost
    }

    // MARK: - Post-filtre de sortie

    /// Garde de sortie du ghost beam — MIROIR des post-filtres du long-ghost
    /// (singleLine, dédup mot répété, séparateur d'espace, écho positionnel,
    /// coupe-clause INCLUSIVE, word-cap), appliquée au suffixe brut renvoyé par le
    /// beam. Extrait VERBATIM de `ModelRuntime.beamPostFilter` (zéro changement).
    /// `nonisolated static` (pures fonctions OutputFilter/SuggestionPolicy).
    public nonisolated static func beamPostFilter(
        rawGhost: String, isBoundary: Bool, caretAfterSpace: Bool,
        userTail: String, maxWords: Int, trimDanglingTail: Bool = false
    ) -> String {
        var result = OutputFilter.singleLine(rawGhost)
        if result.isEmpty { return "" }
        // Markup ("<strong>", **gras**, U+FFFD) + run de chiffres absurde
        // ("10000000000") : le chemin beam ne passe PAS par ChunkFilter et
        // laissait fuir ces ghosts à l'écran (bug visuel, Brave 12/06). Mêmes
        // gardes que le streaming, mutualisées dans OutputFilter.
        result = OutputFilter.stripMarkup(result)
        result = OutputFilter.cutAbsurdNumberRun(result)
        if result.trimmingCharacters(in: .whitespaces).isEmpty { return "" }
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
        // Répétition INTERNE : le décode beam n'a aucune pénalité de répétition
        // → sur préfixe pauvre il part en liste (« révolution, révolutionnaire,
        // révolutionnaire, … »). On coupe au 1ᵉʳ mot de contenu redoublé. AVANT
        // le word-cap pour que le cap compte la version dé-bouclée. No-op (byte-
        // identique) sur un ghost sain.
        result = truncateAtInternalRepeat(result)
        if result.trimmingCharacters(in: .whitespaces).isEmpty { return "" }
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
        // Trim-arrière (Long uniquement) : après le word-cap, on rogne la queue
        // pendante (mots-outils traînants) pour finir sur un stop propre. Inactif
        // par défaut → Court/Moyen byte-identiques.
        if trimDanglingTail {
            let hadLeadingSpace = result.first == " "
            result = trimBackToCleanStop(result)
            if hadLeadingSpace, result.first != " ", !result.isEmpty { result = " " + result }
        }
        // Ponctuation/symboles purs (" .", " :") à TOUTE position : une frappe
        // épargnée au mieux, du bruit visuel au pire — le streaming les droppe
        // déjà partout (branche « aucune lettre » de isDegenerateGhost) ;
        // alignement du beam (ghosts " ." / " :" constatés en live le 12/06).
        if OutputFilter.isPunctuationOnlyGhost(result) { return "" }
        // Frontière : un ghost dégénéré (énumérateur nu "1.") est du bruit —
        // même garde que ChunkFilter. Mid-mot exclu : `isFragmentedGhost` y
        // verrait des consonnes isolées légitimes ("r la suite" complétant
        // "pou").
        if isBoundary, OutputFilter.isDegenerateGhost(result) { return "" }
        return OutputFilter.singleLine(result)
    }
}
