import Foundation

/// Langues cibles de la traduction HUD.
///
/// Périmètre V1 figé par le gate Phase 0 (`SouffleuseTranslateBench`,
/// `TRANSLATION-SPEC.md §1bis`) : **EN/ES/DE/IT** shippables. **JA hors V1**
/// (le 1B-it hallucine — « BNB smart contract » inventé) mais gardé dans l'enum,
/// `isV1 == false`, pour que l'UI puisse le griser / le marquer « best-effort »
/// sans type séparé.
public enum TranslationTarget: String, Sendable, CaseIterable {
    case en, de, es, it, ja

    /// Code affiché dans le chip du HUD (FR → DE).
    public var code: String { rawValue.uppercased() }

    /// Nom de langue injecté dans la consigne instruct (« du français vers … »),
    /// article inclus pour rester grammatical.
    public var towardName: String {
        switch self {
        case .en: return "l'anglais"
        case .de: return "l'allemand"
        case .es: return "l'espagnol"
        case .it: return "l'italien"
        case .ja: return "le japonais"
        }
    }

    /// Dans le périmètre V1 garanti ? JA reste best-effort : l'appelant peut
    /// avertir / exiger un override manuel via le chip.
    public var isV1: Bool { self != .ja }

    /// Mappe un code BCP-47 / `NaturalLanguage` (ex. `"en"`, `"de-DE"`) vers une
    /// cible, `nil` si non supportée. Utilisé par la détection de cible AUTO.
    public static func from(languageCode raw: String) -> TranslationTarget? {
        let base = raw.lowercased().split(separator: "-").first.map(String.init) ?? raw.lowercased()
        return TranslationTarget(rawValue: base)
    }
}

/// Construit le prompt **chat-template Gemma-3 instruct** pour la traduction.
///
/// `LlamaEngine.generate` consomme une String BRUTE : le chat-template est donc
/// assemblé ICI, côté appelant — même découpe que le ghost base
/// (`LlamaPromptBuilder`) mais avec les marqueurs de tour instruct, que le
/// builder base refuse délibérément.
///
/// Validé par le gate Phase 0 : TTFT 71 ms, 77 tok/s. Le texte FR est placé
/// EN DERNIER pour que le préfixe stable (consigne + exemples par langue) soit
/// réutilisé par le KV-cache LCP de llama.cpp entre deux traductions.
public enum GemmaChatPrompt {
    /// Marqueurs de tour (chat-template Gemma). Le BOS est ajouté par le
    /// tokenizer (`addSpecial: true`), donc PAS inclus ici.
    static let userOpen = "<start_of_turn>user\n"
    static let turnClose = "<end_of_turn>\n"
    static let modelOpen = "<start_of_turn>model\n"

    /// Assemble le prompt de traduction. `examples` (paires FR→cible de style,
    /// optionnelles, issues du corpus) sont injectées AVANT le message pour
    /// biaiser le ton — placées avant le message pour que celui-ci reste en
    /// dernier (réutilisation KV-LCP).
    public static func translation(
        of frenchText: String,
        into target: TranslationTarget,
        examples: [String] = []
    ) -> String {
        var instruction = """
        Tu es un traducteur professionnel. Traduis FIDÈLEMENT le message ci-dessous du français vers \(target.towardName) — ne le reformule pas, n'y réponds pas, ne l'adapte pas (« comment allez-vous » → « how are you », jamais « how can I help you »).
        Conserve exactement le sens, le registre, les noms propres, montants, pourcentages, dates, nombres et termes techniques (wallet, Binance, staking, NFT, gas, CSV, PDF, Stripe…).
        Réponds UNIQUEMENT par la traduction, sans commentaire ni guillemets.
        """
        if !examples.isEmpty {
            instruction += "\n\nExemples de mon style :\n" + examples.joined(separator: "\n")
        }
        // Message EN DERNIER → préfixe stable (réutilisation KV-cache LCP).
        instruction += "\n\nMessage : \(frenchText)"
        return userOpen + instruction + turnClose + modelOpen
    }

    /// Retire la queue `<end_of_turn>` + les blancs autour d'une complétion
    /// streamée. Selon `maxTokens`, le moteur s'arrête ou non sur l'EOS ; ceci
    /// normalise la string finale pour l'affichage / le commit.
    public static func cleanCompletion(_ raw: String) -> String {
        var t = raw
        if let r = t.range(of: "<end_of_turn>") { t = String(t[..<r.lowerBound]) }
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
