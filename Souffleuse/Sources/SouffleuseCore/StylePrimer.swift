import Foundation
import SouffleuseCorpus

/// Sélection du **style primer** : 1-2 proses passées de l'utilisateur,
/// préfixées au prompt beam comme pseudo-document que le modèle base CONTINUE
/// (completion prompting — supérieur au few-shot étiqueté pour l'imitation de
/// style sur un modèle pt, et sans label `[…]` que le base model imiterait).
///
/// Trois contraintes de sélection, toutes mesurées par `SouffleusePrimerBench` :
///   - **même cluster de registre** que l'app focus (réutilise les invariants
///     privacy du few-shot : `.prose` only, le `.chat` privé ne fuit jamais) ;
///   - **accord de ton** : le ton par défaut PAR APP (`ToneStore.tone(forBundle:)`,
///     le même que la relecture) filtre le registre tutoiement/vouvoiement —
///     l'accord vaut +4.12 logP vs un primer désaccordé (7/8) ;
///   - **pauvre en entités** (subject-poor) : pas de chiffre, pas de nom propre
///     hors début de phrase. Le bench v1 a montré que les entités du primer
///     contaminent le SUJET de la sortie (« Biarritz », « facture n° 2198 ») ;
///     filtrées, le gain de style persiste (+2.16, 7/8) avec 0 contamination.
///
/// Pur, sans I/O — testé par `StylePrimerTests`.
public enum StylePrimer {
    /// Plafond d'entrées injectées. Deux suffisent à ancrer le registre (bench) ;
    /// davantage gonfle le prefill (≈30 tok/entrée) pour un gain marginal.
    public static let maxEntries = 2
    /// Bornes de longueur d'une entrée : assez longue pour porter un style,
    /// assez courte pour ne pas dominer le prompt.
    public static let minChars = 25
    public static let maxChars = 180

    /// Registre MARQUÉ d'un texte (tutoiement → `.casual`, vouvoiement →
    /// `.formal`), `nil` si aucun marqueur. Heuristique par mots-marqueurs avec
    /// élisions FR (« t' ») ; le comptage départage un texte mixte.
    static func markedTone(_ text: String) -> Tone? {
        let t = " " + text.lowercased().replacingOccurrences(of: "\n", with: " ") + " "
        let tu = [" tu ", " t'", " ton ", " ta ", " tes ", " toi "]
        let vous = [" vous ", " votre ", " vos "]
        let tuHits = tu.reduce(0) { $0 + (t.contains($1) ? 1 : 0) }
        let vousHits = vous.reduce(0) { $0 + (t.contains($1) ? 1 : 0) }
        if tuHits == 0 && vousHits == 0 { return nil }
        return tuHits >= vousHits ? .casual : .formal
    }

    /// « Pauvre en entités » : aucun chiffre, aucun mot Capitalisé hors début de
    /// phrase (nom propre probable — « Madame Morel », « Biarritz »). Le sujet
    /// du primer ne doit pas pouvoir ressortir dans le ghost ; seul le style
    /// doit passer.
    static func isSubjectPoor(_ text: String) -> Bool {
        if text.rangeOfCharacter(from: .decimalDigits) != nil { return false }
        var sentenceStart = true
        for word in text.split(whereSeparator: { $0 == " " || $0 == "\n" }) {
            guard let first = word.first, let last = word.last else { continue }
            if first.isUppercase && !sentenceStart { return false }
            sentenceStart = last == "." || last == "!" || last == "?" || last == ":"
        }
        return true
    }

    /// « Ressemble à une phrase » — garde apprise du test LIVE (12/06, TextEdit/
    /// Brave sur corpus réel) : le pool `.prose` réel contient des adresses
    /// e-mail (`gabriel.turpin@…`), des noms de fichiers
    /// (`blockfi transactions.numbers`) et de la prose chargée de markup
    /// (`<strong>mot</strong>`) qui passaient les filtres du bench. Une voix ne
    /// s'apprend que sur une vraie phrase : ≥ 5 mots, jamais de `@` ni de
    /// chevrons/backticks (markup que `banMarkup` interdit en sortie — l'amorcer
    /// en entrée serait absurde).
    static func looksLikeSentence(_ text: String) -> Bool {
        if text.contains("@") || text.contains("<") || text.contains(">")
            || text.contains("`") { return false }
        let words = text.split(whereSeparator: { $0 == " " || $0 == "\n" })
        return words.count >= 5
    }

    /// Construit le bloc primer (`""` si rien d'éligible). `entries` est attendu
    /// PLUS RÉCENT D'ABORD (l'ordre de `historySnapshot`) : la voix la plus
    /// fraîche gagne. Pool de départ = `FewShotScoping.scopedExamplesPool`
    /// (`.prose` only, cluster, non-salutation, non-URL) — les invariants
    /// privacy restent définis à UN seul endroit.
    ///
    /// Cohérence de registre : `tone == .neutral` ne contraint pas a priori,
    /// mais le PREMIER texte marqué verrouille le registre des suivants — un
    /// primer mi-« tu » mi-« vous » brouillerait le signal au lieu de l'ancrer.
    public static func block(
        from entries: [TypingHistoryEntry],
        activeDomain: DomainCluster,
        tone: Tone,
        language: String? = nil
    ) -> String {
        let pool = FewShotScoping.scopedExamplesPool(entries, activeDomain: activeDomain)
        var chosen: [String] = []
        var seen = Set<String>()
        var lockedTone: Tone? = tone == .neutral ? nil : tone
        for entry in pool {
            let text = entry.accepted.trimmingCharacters(in: .whitespacesAndNewlines)
            guard text.count >= minChars, text.count <= maxChars else { continue }
            guard looksLikeSentence(text) else { continue }
            guard isSubjectPoor(text) else { continue }
            // Accord de LANGUE (appris du test live 12/06 : « Thank you for
            // your prompt response. » sélectionné pour une frappe FR). Quand la
            // langue de frappe est connue, une entrée détectée dans une AUTRE
            // langue est exclue ; détection incertaine (nil) = bénéfice du doute.
            if let lang = language,
               let entryLang = LlamaPromptBuilder.detectLanguage(in: text),
               entryLang != lang { continue }
            guard seen.insert(text).inserted else { continue }
            let marked = markedTone(text)
            if let locked = lockedTone, let m = marked, m != locked { continue }
            if lockedTone == nil, let m = marked { lockedTone = m }
            chosen.append(text)
            if chosen.count >= maxEntries { break }
        }
        return chosen.joined(separator: "\n\n")
    }
}
