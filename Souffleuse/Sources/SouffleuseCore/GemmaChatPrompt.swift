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

    /// Nom de langue NU (sans article) pour la directive de verrouillage
    /// (« ta réponse doit être ENTIÈREMENT en italien »).
    public var bareName: String {
        switch self {
        case .en: return "anglais"
        case .de: return "allemand"
        case .es: return "espagnol"
        case .it: return "italien"
        case .ja: return "japonais"
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

    /// Vrai si le **message du correspondant** est dominé par le français — signal
    /// de routage vers la RELECTURE (FR→FR) plutôt que la traduction. Symétrique de
    /// `detected(in:)` (mêmes seuils ≥ 8 chars / confiance ≥ 0.5) mais renvoie
    /// précisément le cas que `detected` écarte volontairement (le français). Pur,
    /// on-device (`NLLanguageRecognizer`), aucun réseau.
    public static func correspondentSpeaksFrench(in text: String) -> Bool {
        let trimmed = String(text.suffix(512)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 8 else { return false }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(trimmed)
        guard let lang = recognizer.dominantLanguage else { return false }
        if let confidence = recognizer.languageHypotheses(withMaximum: 1)[lang], confidence < 0.5 {
            return false
        }
        return lang == .french
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
    /// Relecture FR→FR : on ne traduit pas, on RÉÉCRIT le message français selon
    /// le ton de l'app. Posée à la main par la touche de cycle (après IT) ou
    /// déduite en AUTO quand le correspondant écrit français.
    case reformulate

    /// Ordre de défilement des cibles de traduction. Le cycle complet ajoute
    /// `.reformulate` puis AUTO autour (AUTO → EN → ES → DE → IT → FR↺ → AUTO),
    /// géré par `cycleNext`. JA exclu (hors V1).
    public static let cycleOrder: [TranslationTarget] = [.en, .es, .de, .it]

    /// Sélection suivante dans le cycle. Depuis AUTO on entre sur la 1re cible ;
    /// après la dernière cible fixe on passe à la RELECTURE ; après la relecture
    /// on revient à AUTO.
    public func cycleNext() -> TargetSelection {
        switch self {
        case .auto:
            return .fixed(Self.cycleOrder[0])
        case .fixed(let t):
            guard let i = Self.cycleOrder.firstIndex(of: t), i + 1 < Self.cycleOrder.count else {
                return .reformulate
            }
            return .fixed(Self.cycleOrder[i + 1])
        case .reformulate:
            return .auto
        }
    }

    /// Résout la cible de TRADUCTION effective : une cible fixe l'emporte ;
    /// `auto` suit `detected` et retombe sur `fallback`. `.reformulate` n'est pas
    /// une traduction — il retombe sur `fallback` ici et doit être aiguillé en
    /// amont via `action(…)`.
    public func resolve(detected: TranslationTarget?, fallback: TranslationTarget = .en) -> TranslationTarget {
        switch self {
        case .fixed(let t): return t
        case .auto: return detected ?? fallback
        case .reformulate: return fallback
        }
    }

    /// Décide quoi faire au commit ⌘↩ : traduire vers une cible, ou relire (FR→FR).
    /// `.reformulate` relit toujours ; `.fixed` traduit toujours ; `.auto` relit si
    /// le correspondant écrit français, sinon traduit vers la langue détectée
    /// (défaut `fallback`).
    public func action(detected: TranslationTarget?, correspondentIsFrench: Bool,
                       fallback: TranslationTarget = .en) -> CommitAction {
        switch self {
        case .reformulate: return .reformulate
        case .fixed(let t): return .translate(t)
        case .auto: return correspondentIsFrench ? .reformulate : .translate(detected ?? fallback)
        }
    }

    /// Libellé court pour le panneau (« AUTO », « EN », « FR↺ »…).
    public var shortLabel: String {
        switch self {
        case .auto: return "AUTO"
        case .fixed(let t): return t.code
        case .reformulate: return "FR↺"
        }
    }
}

/// Action effective déclenchée par le commit ⌘↩ : traduire vers une cible, ou
/// relire le message français (réécriture FR→FR selon le ton de l'app).
public enum CommitAction: Sendable, Equatable {
    case translate(TranslationTarget)
    case reformulate
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
        case .gemma1b: return tr(fr: "Gemma 3 1B — léger, rapide", en: "Gemma 3 1B — light, fast")
        case .qwen1_5b: return tr(fr: "Qwen2.5 1.5B — multilingue (DE/IT/JA)", en: "Qwen2.5 1.5B — multilingual (DE/IT/JA)")
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
            // Qwen2.5 : ChatML, consigne en SYSTÈME + DEUX tours few-shot FR→cible
            // avant le vrai message (UAT 11/06 : sans eux, le 1.5B « échote » le
            // français corrigé ou RÉPOND au message en ES/IT à greedy — le
            // few-shot verrouille « tu traduis, tu ne réponds pas », la 2e paire
            // ancre chiffres/termes). Préfixe stable par cible → KV-LCP intact.
            let shots = translationFewShot(target: target)
            return "<|im_start|>system\n" + instruction + "<|im_end|>\n"
                + shots.map {
                    "<|im_start|>user\n" + $0.user + "<|im_end|>\n"
                        + "<|im_start|>assistant\n" + $0.assistant + "<|im_end|>\n"
                }.joined()
                + "<|im_start|>user\n" + frenchText + "<|im_end|>\n"
                + "<|im_start|>assistant\n"
        }
    }

    /// Paires few-shot FR→cible injectées en tours ChatML (voie Qwen). Fixes et
    /// courtes : elles coûtent ~60 tokens de préfixe stable (cache-able) et
    /// suppriment le mode « écho / réponse » du 1.5B observé sur ES/IT.
    static func translationFewShot(target: TranslationTarget)
        -> [(user: String, assistant: String)]
    {
        let ex1 = "Merci pour votre retour, je reviens vers vous demain."
        let ex2 = "Le montant de 1 250 € apparaît sur votre wallet depuis le 15 mai."
        switch target {
        case .en: return [
            (ex1, "Thank you for your feedback, I will get back to you tomorrow."),
            (ex2, "The amount of €1,250 has appeared in your wallet since May 15."),
        ]
        case .de: return [
            (ex1, "Vielen Dank für Ihre Rückmeldung, ich melde mich morgen wieder bei Ihnen."),
            (ex2, "Der Betrag von 1 250 € erscheint seit dem 15. Mai in Ihrem Wallet."),
        ]
        case .es: return [
            (ex1, "Gracias por su respuesta, vuelvo a contactarle mañana."),
            (ex2, "El importe de 1 250 € aparece en su wallet desde el 15 de mayo."),
        ]
        case .it: return [
            (ex1, "Grazie per il suo riscontro, la ricontatto domani."),
            (ex2, "L'importo di 1 250 € appare nel suo wallet dal 15 maggio."),
        ]
        case .ja: return [
            (ex1, "ご返信ありがとうございます。明日改めてご連絡いたします。"),
            (ex2, "1 250 €の金額は5月15日からウォレットに表示されています。"),
        ]
        }
    }

    /// Assemble le prompt de **relecture FR→FR** (réécriture selon `tone`) selon
    /// le chat-template du `model`. Strictement symétrique de `translation(…)` :
    /// même découpe, message EN DERNIER pour Gemma (réutilisation KV-cache LCP),
    /// consigne en système pour Qwen.
    public static func reformulation(
        of frenchText: String,
        tone: Tone,
        examples: [String] = [],
        model: InstructModel = .gemma1b
    ) -> String {
        let instruction = reformulationInstruction(tone: tone, examples: examples)
        switch model {
        case .gemma1b:
            let user = instruction + "\n\nMessage : \(frenchText)"
            return userOpen + user + turnClose + modelOpen
        case .qwen1_5b:
            return "<|im_start|>system\n" + instruction + "<|im_end|>\n"
                + "<|im_start|>user\n" + frenchText + "<|im_end|>\n"
                + "<|im_start|>assistant\n"
        }
    }

    /// Consigne de relecture (sans le message). Partagée par les deux familles de
    /// template. Réécrit fidèlement (corrige, ne répond pas) au registre `tone`,
    /// avec la même clause de survie des entités dures que la traduction.
    static func reformulationInstruction(tone: Tone, examples: [String]) -> String {
        var instruction = """
        Tu es un correcteur-rédacteur professionnel. Réécris EN FRANÇAIS le message ci-dessous : corrige l'orthographe, la grammaire et la formulation, sans en changer le sens ni y répondre.
        \(tone.registerInstruction)
        Conserve exactement les noms propres, montants, pourcentages, dates, nombres et termes techniques (wallet, Binance, staking, NFT, gas, CSV, PDF, Stripe…).
        Conserve les sauts de ligne et la structure en paragraphes du message.
        Réponds UNIQUEMENT par la réécriture, sans commentaire ni guillemets.
        """
        if !examples.isEmpty {
            instruction += "\n\nExemples de mon style :\n" + examples.joined(separator: "\n")
        }
        return instruction
    }

    /// Consigne de traduction fidèle (sans le message). Partagée par les deux
    /// familles de template.
    static func translationInstruction(target: TranslationTarget, examples: [String]) -> String {
        var instruction = """
        Tu es un traducteur professionnel. Traduis FIDÈLEMENT le message ci-dessous du français vers \(target.towardName) — ne le reformule pas, n'y réponds pas, ne l'adapte pas (« comment allez-vous » → « how are you », jamais « how can I help you »).
        Conserve exactement le sens, le registre, les noms propres, montants, pourcentages, dates, nombres et termes techniques (wallet, Binance, staking, NFT, gas, CSV, PDF, Stripe…).
        Réponds UNIQUEMENT par la traduction, sans commentaire ni guillemets.
        IMPORTANT : ta réponse doit être ENTIÈREMENT en \(target.bareName). N'écris AUCUN mot français.
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
