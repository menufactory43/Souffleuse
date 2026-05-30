import Foundation
import NaturalLanguage

/// Langues cibles de la traduction HUD.
///
/// Périmètre V1 figé par le gate Phase 0 (`SouffleuseTranslateBench`,
/// `TRANSLATION-SPEC.md §1bis`) : **EN/ES/DE/IT** shippables. **JA hors V1**
/// (le 1B-it hallucine — « BNB smart contract » inventé) mais gardé dans l'enum,
/// `isV1 == false`, pour que l'UI puisse le griser / le marquer « best-effort »
/// sans type séparé.
public enum TranslationTarget: String, Sendable, CaseIterable, Codable {
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

    /// Détecte la langue dominante du **message du correspondant** et la mappe
    /// vers une cible : la langue DÉTECTÉE est la cible (on traduit le FR vers la
    /// langue de l'autre). Renvoie `nil` quand on ne doit PAS proposer de cible —
    /// texte trop court/ambigu (mêmes seuils que `LlamaPromptBuilder.detectLanguage`
    /// : ≥ 8 chars, confiance ≥ 0.5), français (pas de FR→FR), ou langue hors
    /// périmètre V1. Pur, on-device (`NLLanguageRecognizer`), aucun réseau.
    public static func detected(in text: String) -> TranslationTarget? {
        let trimmed = String(text.suffix(512)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 8 else { return nil }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(trimmed)
        guard let lang = recognizer.dominantLanguage else { return nil }
        if let confidence = recognizer.languageHypotheses(withMaximum: 1)[lang], confidence < 0.5 {
            return nil
        }
        guard let target = from(languageCode: lang.rawValue), target.isV1 else { return nil }
        return target
    }
}

/// Choix de cible pour UNE conversation : suivre la détection (`auto`) ou une
/// cible FIXE posée à la main via la touche de cycle.
///
/// La capture d'écran étant **opt-in et désactivée par défaut**, l'`auto` est
/// souvent aveugle (rien à lire) — le cycle manuel est donc le mécanisme de
/// première classe, l'`auto` un bonus quand la capture est active (cf.
/// `TRANSLATION-SPEC.md §2.7`, verdict adverse « la cible AUTO est best-effort »).
public enum TargetSelection: Sendable, Equatable, Codable {
    case auto
    case fixed(TranslationTarget)

    /// Ordre de défilement de la touche de cycle : les cibles V1 puis AUTO
    /// (EN → ES → DE → IT → AUTO → EN…). JA exclu (hors V1).
    public static let cycleOrder: [TranslationTarget] = [.en, .es, .de, .it]

    /// Cible suivante dans le cycle. Depuis AUTO on entre sur la 1re cible ;
    /// après la dernière cible fixe on revient à AUTO.
    public func cycleNext() -> TargetSelection {
        switch self {
        case .auto:
            return .fixed(Self.cycleOrder[0])
        case .fixed(let t):
            guard let i = Self.cycleOrder.firstIndex(of: t), i + 1 < Self.cycleOrder.count else {
                return .auto
            }
            return .fixed(Self.cycleOrder[i + 1])
        }
    }

    /// Résout la cible effective au moment du commit : une cible fixe l'emporte
    /// toujours ; `auto` suit `detected` et retombe sur `fallback` (défaut EN)
    /// quand rien n'a pu être détecté.
    public func resolve(detected: TranslationTarget?, fallback: TranslationTarget = .en) -> TranslationTarget {
        switch self {
        case .fixed(let t): return t
        case .auto: return detected ?? fallback
        }
    }

    /// Libellé court pour le panneau (« AUTO », « EN », « ES »…).
    public var shortLabel: String {
        switch self {
        case .auto: return "AUTO"
        case .fixed(let t): return t.code
        }
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
/// Modèle instruct utilisé pour la TRADUCTION. Chaque modèle a son GGUF et son
/// chat-template — familles INCOMPATIBLES (Gemma `<start_of_turn>` vs Qwen ChatML
/// `<|im_start|>`), d'où l'aiguillage dans `GemmaChatPrompt.translation`. Déchargé
/// à l'idle (Phase 7) → le surcoût RAM du plus gros n'est tenu que pendant l'usage.
public enum InstructModel: String, Sendable, CaseIterable, Codable {
    case gemma1b
    case qwen1_5b

    /// Nom de fichier GGUF attendu dans `~/Library/Application Support/Souffleuse/Models/`.
    public var ggufFilename: String {
        switch self {
        case .gemma1b: return "gemma-3-1b-it-Q4_K_M.gguf"
        case .qwen1_5b: return "qwen2.5-1.5b-instruct-q4_k_m.gguf"
        }
    }

    /// Libellé Préférences.
    public var displayName: String {
        switch self {
        case .gemma1b: return "Gemma 3 1B — léger, rapide"
        case .qwen1_5b: return "Qwen2.5 1.5B — multilingue (DE/IT/JA)"
        }
    }

    /// URL HF (resolve) du GGUF, pour le téléchargement in-app si absent. Réseau
    /// autorisé UNIQUEMENT pour ce premier téléchargement (cf. contraintes : pas
    /// de réseau au runtime sauf récupération du modèle).
    public var downloadURL: URL {
        switch self {
        case .gemma1b:
            return URL(string: "https://huggingface.co/ggml-org/gemma-3-1b-it-GGUF/resolve/main/gemma-3-1b-it-Q4_K_M.gguf")!
        case .qwen1_5b:
            return URL(string: "https://huggingface.co/bartowski/Qwen2.5-1.5B-Instruct-GGUF/resolve/main/Qwen2.5-1.5B-Instruct-Q4_K_M.gguf")!
        }
    }

    /// Taille approximative (Mo) du GGUF, pour l'affichage du bouton de téléchargement.
    public var approxSizeMB: Int {
        switch self {
        case .gemma1b: return 769
        case .qwen1_5b: return 940
        }
    }

    /// Descripteur de téléchargement unifié (consommé par `ModelDownloadManager`).
    public var downloadable: DownloadableModel {
        DownloadableModel(
            id: "translate-" + rawValue,
            displayName: displayName,
            filename: ggufFilename,
            url: downloadURL,
            approxSizeMB: approxSizeMB)
    }
}

public enum GemmaChatPrompt {
    /// Marqueurs de tour (chat-template Gemma). Le BOS est ajouté par le
    /// tokenizer (`addSpecial: true`), donc PAS inclus ici.
    static let userOpen = "<start_of_turn>user\n"
    static let turnClose = "<end_of_turn>\n"
    static let modelOpen = "<start_of_turn>model\n"

    /// Assemble le prompt de traduction selon le chat-template du `model`.
    /// `examples` (paires FR→cible de style, optionnelles) sont injectées dans la
    /// consigne, AVANT le message, pour que celui-ci reste en dernier (KV-LCP).
    public static func translation(
        of frenchText: String,
        into target: TranslationTarget,
        examples: [String] = [],
        model: InstructModel = .gemma1b
    ) -> String {
        let instruction = translationInstruction(target: target, examples: examples)
        switch model {
        case .gemma1b:
            // Gemma-3 : pas de rôle système séparé → consigne + message dans le
            // tour user, message EN DERNIER (réutilisation KV-cache LCP).
            let user = instruction + "\n\nMessage : \(frenchText)"
            return userOpen + user + turnClose + modelOpen
        case .qwen1_5b:
            // Qwen2.5 : ChatML, consigne en SYSTÈME (préfixe stable → KV-LCP),
            // message en user.
            return "<|im_start|>system\n" + instruction + "<|im_end|>\n"
                + "<|im_start|>user\n" + frenchText + "<|im_end|>\n"
                + "<|im_start|>assistant\n"
        }
    }

    /// Consigne de traduction fidèle (sans le message). Partagée par les deux
    /// familles de template.
    static func translationInstruction(target: TranslationTarget, examples: [String]) -> String {
        var instruction = """
        Tu es un traducteur professionnel. Traduis FIDÈLEMENT le message ci-dessous du français vers \(target.towardName) — ne le reformule pas, n'y réponds pas, ne l'adapte pas (« comment allez-vous » → « how are you », jamais « how can I help you »).
        Conserve exactement le sens, le registre, les noms propres, montants, pourcentages, dates, nombres et termes techniques (wallet, Binance, staking, NFT, gas, CSV, PDF, Stripe…).
        Réponds UNIQUEMENT par la traduction, sans commentaire ni guillemets.
        """
        if !examples.isEmpty {
            instruction += "\n\nExemples de mon style :\n" + examples.joined(separator: "\n")
        }
        return instruction
    }

    /// Tronque à la PREMIÈRE balise de fin de tour rencontrée (Gemma
    /// `<end_of_turn>`, Qwen ChatML `<|im_end|>` / `<|endoftext|>`) puis retire les
    /// blancs — robuste aux deux familles, que le moteur s'arrête sur l'EOS ou non.
    public static func cleanCompletion(_ raw: String) -> String {
        var cut = raw.endIndex
        for stop in ["<end_of_turn>", "<|im_end|>", "<|endoftext|>"] {
            if let r = raw.range(of: stop), r.lowerBound < cut { cut = r.lowerBound }
        }
        return String(raw[..<cut]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
