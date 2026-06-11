import Foundation

/// État d'un trigger « // » ouvert juste avant le caret. `deleteCharsOnAccept`
/// compte la portée NON trimée + « // » + le filtre — exactement ce que
/// `replaceForCommit` supprime à l'acceptation (Tab). `scopeText` est la version
/// trimée envoyée au modèle.
public struct SlashTransformState: Sendable, Equatable {
    /// Texte de la portée (trimé whitespace/newlines) injecté dans le prompt.
    public let scopeText: String
    /// Vrai quand la portée ne couvre PAS tout le champ (paragraphe du trigger,
    /// ou repli > `maxFullFieldLength`) ; le header du HUD doit l'indiquer.
    public let isScopeTruncated: Bool
    /// Texte tapé après « // » (filtre d'intention ou instruction libre).
    /// Peut contenir espaces et accents ; jamais de saut de ligne.
    public let filter: String
    /// Caractères avant le caret à supprimer à l'acceptation :
    /// portée brute (non trimée, depuis son début dans le champ) + 2 + filter.count.
    public let deleteCharsOnAccept: Int

    public init(scopeText: String, isScopeTruncated: Bool, filter: String, deleteCharsOnAccept: Int) {
        self.scopeText = scopeText
        self.isScopeTruncated = isScopeTruncated
        self.filter = filter
        self.deleteCharsOnAccept = deleteCharsOnAccept
    }
}

/// Détection pure du trigger « // » — miroir des règles d'`EmojiExpander`
/// (garde du caractère AVANT le trigger, remontée depuis le caret, zéro AX).
public enum SlashTransformDetector {

    /// Au-delà de cette longueur de portée, on retombe sur le dernier paragraphe.
    public static let maxFullFieldLength = 1500
    /// Longueur max du filtre/instruction libre — au-delà, le picker se ferme
    /// (l'utilisateur ne filtre plus, il rédige).
    public static let maxFilterLength = 200
    /// Mêmes apps que l'emoji : « // » y est un commentaire ou un chemin.
    public static let disabledBundles: Set<String> = EmojiExpander.disabledBundles

    /// Renvoie l'état du picker, ou nil si aucun trigger valide n'est ouvert.
    ///
    /// Règles (miroir `EmojiExpander.pickerCandidates`) :
    /// - remonte depuis le caret en acceptant tout caractère SAUF « \n » et « / »,
    ///   jusqu'à trouver « // » ; un « \n » avant le trigger → nil (autre ligne).
    /// - le caractère AVANT « // » doit être espace / « \n » / « \t » ou le début
    ///   du champ. Lettre, chiffre, « / », « : » ou ponctuation → nil. Ça neutralise
    ///   « https:// », « /usr//bin », « ///doc », « path//file » sans liste d'exceptions.
    /// - portée = texte avant « // » ; trimée vide → nil (rien à transformer).
    /// - filtre > `maxFilterLength` → nil.
    public static func detect(textBeforeCaret: String) -> SlashTransformState? {
        // Remontée depuis le caret : on accumule le filtre jusqu'au « / » le plus
        // proche. Un saut de ligne d'abord = le trigger est sur une autre ligne.
        var i = textBeforeCaret.endIndex
        var filter = ""
        var secondSlash: String.Index?
        while i > textBeforeCaret.startIndex {
            let prev = textBeforeCaret.index(before: i)
            let c = textBeforeCaret[prev]
            if c == "\n" { return nil }
            if c == "/" {
                secondSlash = prev
                break
            }
            filter = String(c) + filter
            i = prev
        }
        // Le « / » trouvé doit être le second d'une paire : un « / » isolé dans le
        // filtre est refusé — ça élimine les chemins (« //a/b », « /usr/bin »).
        guard let secondSlash, secondSlash > textBeforeCaret.startIndex else { return nil }
        let firstSlash = textBeforeCaret.index(before: secondSlash)
        guard textBeforeCaret[firstSlash] == "/" else { return nil }
        // Garde du caractère AVANT la paire (miroir de la garde « : » de l'emoji
        // picker) : seul un séparateur franc ou le début du champ ouvre le picker.
        // « https:// » (précédé de « : »), « ///doc » (précédé de « / ») et
        // « path//file » (précédé d'une lettre) tombent tous ici.
        if firstSlash > textBeforeCaret.startIndex {
            let before = textBeforeCaret[textBeforeCaret.index(before: firstSlash)]
            guard before == " " || before == "\n" || before == "\t" else { return nil }
        }

        // Au-delà du cap, l'utilisateur rédige une phrase, pas un filtre — on
        // rend la main à la saisie normale.
        guard filter.count <= maxFilterLength else { return nil }

        let prefixBeforeTrigger = textBeforeCaret[..<firstSlash]
        let (rawScope, truncated) = resolveScope(prefixBeforeTrigger: prefixBeforeTrigger)
        let scopeText = rawScope.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !scopeText.isEmpty else { return nil }

        // Compte en `Character` (pas UTF-16) : replaceForCommit envoie un
        // backspace par Character, même contrat que l'emoji picker.
        return SlashTransformState(
            scopeText: scopeText,
            isScopeTruncated: truncated,
            filter: filter,
            deleteCharsOnAccept: rawScope.count + 2 + filter.count
        )
    }

    /// Résout la portée, paragraphe-d'abord (UAT 11/06 : « // » collé à un
    /// paragraphe doit viser CE paragraphe, pas tout le champ) :
    /// 1. S'il y a une ligne vide (« \n\n ») au-dessus et que le paragraphe du
    ///    trigger est non vide → ce paragraphe seul. Un simple « \n » reste
    ///    interne (lignes d'un même message chat).
    /// 2. Sinon — champ mono-paragraphe, OU « // » seul après une ligne vide
    ///    (échappatoire « agis sur tout ») — champ entier si sa version trimée
    ///    tient sous `maxFullFieldLength` ; sinon repli : dernier paragraphe
    ///    non vide, à défaut dernière ligne, à défaut `suffix(maxFullFieldLength)`.
    /// Renvoie le substring BRUT (le compte de suppression part de son début)
    /// + le flag « portée ≠ champ entier ».
    /// Interne mais non-private pour les tests (`@testable`).
    static func resolveScope(prefixBeforeTrigger: Substring)
        -> (rawScope: Substring, truncated: Bool)
    {
        if let sep = prefixBeforeTrigger.range(of: "\n\n", options: .backwards) {
            let triggerParagraph = prefixBeforeTrigger[sep.upperBound...]
            if !triggerParagraph.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return capToMaxLength(triggerParagraph)
            }
        }
        let trimmedCount = prefixBeforeTrigger
            .trimmingCharacters(in: .whitespacesAndNewlines).count
        guard trimmedCount > maxFullFieldLength else {
            return (prefixBeforeTrigger, false)
        }
        if let paragraph = suffixAfterLastSeparator("\n\n", in: prefixBeforeTrigger) {
            return (paragraph, true)
        }
        if let line = suffixAfterLastSeparator("\n", in: prefixBeforeTrigger) {
            return (line, true)
        }
        return (prefixBeforeTrigger.suffix(maxFullFieldLength), true)
    }

    /// Cap du mode paragraphe : un paragraphe unique > `maxFullFieldLength`
    /// retombe sur sa dernière ligne, à défaut sur ses derniers caractères —
    /// même filet que le mode champ entier.
    private static func capToMaxLength(_ scope: Substring)
        -> (rawScope: Substring, truncated: Bool)
    {
        guard scope.trimmingCharacters(in: .whitespacesAndNewlines).count > maxFullFieldLength else {
            return (scope, true)
        }
        if let line = suffixAfterLastSeparator("\n", in: scope) {
            return (line, true)
        }
        return (scope.suffix(maxFullFieldLength), true)
    }

    /// Suffixe après la DERNIÈRE occurrence de `separator` dont le contenu n'est
    /// pas que du blanc — un préfixe finissant en « \n\n » ne doit pas produire
    /// une portée vide alors qu'un paragraphe plein la précède.
    private static func suffixAfterLastSeparator(
        _ separator: String, in text: Substring
    ) -> Substring? {
        var searchUpper = text.endIndex
        while let found = text.range(
            of: separator, options: .backwards, range: text.startIndex..<searchUpper
        ) {
            let candidate = text[found.upperBound...]
            if !candidate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return candidate
            }
            searchUpper = found.lowerBound
        }
        return nil
    }
}
