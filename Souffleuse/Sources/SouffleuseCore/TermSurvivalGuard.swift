import Foundation

/// Garde-fou C (TRANSLATION-SPEC §2.8) : vérifie, **sans aucun appel LLM**, que
/// les tokens « durs » de la source française survivent dans la traduction.
///
/// Le gate Phase 0 a montré que le 1B-it corrompt parfois les montants
/// (« 1 250,50 € » → « 250,50 € ») et « adapte » les termes métier. Ces erreurs
/// sont silencieuses pour l'utilisateur qui ne lit pas la langue cible — d'où ce
/// filet purement déterministe qui compare source et traduction et renvoie la
/// liste des tokens disparus, affichés en badge ambre sur le HUD.
///
/// Trois catégories :
/// - **Nombres / montants / pourcentages** : comparés sur leurs chiffres
///   canoniques (séparateurs de milliers et décimales ignorés), donc robustes
///   aux reformatages de locale (`1 250,50` ≡ `1,250.50`).
/// - **Termes métier** d'une liste de haute précision (insensible à la casse).
/// - **Noms propres capitalisés** non couverts par la liste (insensible à la
///   casse), hors début de phrase.
///
/// Pur, `Sendable`, on-device, aucun réseau. Tous les seuils viennent de
/// `SuggestionPolicy.Tuning.*` (Pitfall 6 : aucun littéral de seuil ici).
public enum TermSurvivalGuard {

    /// Un token dur de la source absent de la traduction.
    public struct Missing: Sendable, Equatable {
        public enum Kind: String, Sendable, Equatable {
            case number, term, properNoun
        }
        /// Le token tel qu'il apparaît dans la source (pour l'affichage).
        public let text: String
        public let kind: Kind

        public init(text: String, kind: Kind) {
            self.text = text
            self.kind = kind
        }
    }

    /// Tokens durs de `source` (FR) absents de `translation`. Vide = rien à
    /// signaler. Préserve l'ordre d'apparition dans la source et déduplique.
    public static func missingTokens(
        source: String,
        translation: String,
        businessTerms: [String] = SuggestionPolicy.Tuning.termSurvivalBusinessTerms,
        minNumberDigits: Int = SuggestionPolicy.Tuning.termSurvivalMinNumberDigits,
        properNounMinLength: Int = SuggestionPolicy.Tuning.termSurvivalProperNounMinLength
    ) -> [Missing] {
        let lowerTranslation = translation.lowercased()
        let translationDigitTokens = Set(numberTokens(in: translation).map(canonicalDigits))

        var out: [Missing] = []
        var seen = Set<String>()
        func emit(_ text: String, _ kind: Missing.Kind, key: String) {
            let dedup = kind.rawValue + "\u{1}" + key
            if key.isEmpty || seen.contains(dedup) { return }
            seen.insert(dedup)
            out.append(Missing(text: text, kind: kind))
        }

        // 1. Nombres / montants / pourcentages.
        for token in numberTokens(in: source) {
            let canon = canonicalDigits(token)
            guard canon.count >= minNumberDigits else { continue }
            if !translationDigitTokens.contains(canon) {
                emit(token.trimmingCharacters(in: .whitespaces), .number, key: canon)
            }
        }

        // 2. Termes métier (liste). Insensible à la casse, multi-mots autorisés.
        for term in businessTerms {
            let lt = term.lowercased()
            guard source.range(of: lt, options: .caseInsensitive) != nil else { continue }
            if lowerTranslation.range(of: lt) == nil {
                emit(term, .term, key: lt)
            }
        }

        // 3. Noms propres capitalisés (hors liste, hors début de phrase).
        let termSet = Set(businessTerms.map { $0.lowercased() })
        for noun in properNouns(in: source, minLength: properNounMinLength) {
            let ln = noun.lowercased()
            if termSet.contains(ln) { continue }          // déjà couvert par (2)
            if lowerTranslation.range(of: ln) == nil {
                emit(noun, .properNoun, key: ln)
            }
        }

        return out
    }

    /// Résumé compact pour le badge HUD : `« 1 250,50 €, Binance, +2 »`, ou `nil`
    /// si rien ne manque. Borné par `maxItems`.
    public static func badgeSummary(
        for missing: [Missing],
        maxItems: Int = SuggestionPolicy.Tuning.termSurvivalMaxBadgeItems
    ) -> String? {
        guard !missing.isEmpty else { return nil }
        let shown = missing.prefix(maxItems).map(\.text)
        var summary = shown.joined(separator: ", ")
        let overflow = missing.count - shown.count
        if overflow > 0 { summary += ", +\(overflow)" }
        return summary
    }

    // MARK: - Extraction (pur, interne — exposé pour les tests)

    /// Réduit un token numérique à ses seuls chiffres (séparateurs de milliers /
    /// décimales retirés) : `« 1 250,50 »` → `« 125050 »`. Robuste aux locales.
    static func canonicalDigits(_ token: String) -> String {
        String(token.unicodeScalars.filter { CharacterSet.decimalDigits.contains($0) }
            .map(Character.init))
    }

    /// Tokens numériques maximaux d'un texte : un chiffre, éventuellement suivi de
    /// chiffres et de séparateurs internes (espaces — y compris fines/insécables —,
    /// `.` et `,`) puis d'un chiffre. Capture `« 1 250,50 »` en un seul token et
    /// `« 12,5 »` de même ; un chiffre isolé est aussi capturé (filtré ensuite par
    /// la longueur minimale).
    static func numberTokens(in text: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        let separators = CharacterSet(charactersIn: " .,\u{00A0}\u{202F}\u{2009}")
        let scalars = Array(text.unicodeScalars)
        func isDigit(_ s: Unicode.Scalar) -> Bool { CharacterSet.decimalDigits.contains(s) }

        var i = 0
        while i < scalars.count {
            let s = scalars[i]
            if isDigit(s) {
                current.unicodeScalars.append(s)
                i += 1
            } else if !current.isEmpty, separators.contains(s) {
                // Un séparateur ne fait partie du nombre QUE s'il est suivi d'un
                // chiffre (sinon il clôt le token).
                if i + 1 < scalars.count, isDigit(scalars[i + 1]) {
                    current.unicodeScalars.append(s)
                    i += 1
                } else {
                    tokens.append(current)
                    current = ""
                    i += 1
                }
            } else {
                if !current.isEmpty { tokens.append(current); current = "" }
                i += 1
            }
        }
        if !current.isEmpty { tokens.append(current) }
        return tokens
    }

    /// Noms propres capitalisés (initiale majuscule + au moins une minuscule, ou
    /// acronyme tout-majuscule ≥ 2), de longueur ≥ `minLength`, hors **premier mot
    /// de phrase** (initiale majuscule attendue là, donc non signifiante).
    static func properNouns(in text: String, minLength: Int) -> [String] {
        var nouns: [String] = []
        // Découpe en « mots » sur les espaces/ponctuation, en gardant trace du
        // caractère significatif précédent pour repérer les débuts de phrase.
        let wordChars = CharacterSet.letters
        var words: [(text: String, atSentenceStart: Bool)] = []
        var current = ""
        var sentenceStart = true
        for scalar in text.unicodeScalars {
            if wordChars.contains(scalar) {
                current.unicodeScalars.append(scalar)
            } else {
                if !current.isEmpty {
                    words.append((current, sentenceStart))
                    current = ""
                    sentenceStart = false
                }
                if scalar == "." || scalar == "!" || scalar == "?" || scalar == "\n" {
                    sentenceStart = true
                }
            }
        }
        if !current.isEmpty { words.append((current, sentenceStart)) }

        for word in words where !word.atSentenceStart {
            guard word.text.count >= minLength, let first = word.text.first, first.isUppercase else { continue }
            let rest = word.text.dropFirst()
            let isCapitalized = rest.contains(where: { $0.isLowercase })
            let isAcronym = word.text.allSatisfy { $0.isUppercase }
            if isCapitalized || isAcronym {
                nouns.append(word.text)
            }
        }
        return nouns
    }
}
