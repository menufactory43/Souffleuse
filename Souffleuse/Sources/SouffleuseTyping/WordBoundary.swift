import Foundation

/// Primitive **unique** de frontière de mot pour tout le pipeline.
///
/// « Qu'est-ce qu'un caractère de mot / un mot partiel » est une notion du
/// domaine qui était redéfinie indépendamment dans 6 modules
/// (`OutputFilter`, `TypingHistoryStore`, `ChunkSplitter`, `TypoDetector`,
/// `WordCompleter`, `PrefixCorrector`), maintenue à la main par des commentaires
/// « mirrors OutputFilter… ». Elles avaient **déjà drifté** : `TypingHistoryStore`
/// avait perdu l'apostrophe courbe `’` (U+2019) — l'apostrophe typographique que
/// macOS substitue automatiquement en français (`l'app` → `l’app`) — ce qui
/// faisait segmenter ses gardes d'admission différemment du reste du pipeline.
///
/// Définie ici une seule fois (`SouffleuseTyping` est déjà la feuille commune de
/// `SouffleuseCore` et `SouffleusePersonalization`), le drift devient impossible.
public enum WordBoundary {
    /// Un caractère « de mot » : lettre, chiffre, ou joiner intra-mot (apostrophe
    /// droite `'`, apostrophe courbe `’`, trait d'union `-`). C'est LA définition
    /// de référence ; tous les autres modules délèguent ici.
    public static func isWordChar(_ c: Character) -> Bool {
        c.isLetter || c.isNumber || c == "'" || c == "\u{2019}" || c == "-"
    }

    /// Run de caractères de mot en FIN de `s` (le mot partiel en cours). Vide si
    /// le caret suit un espace / une ponctuation (donc PAS en milieu de mot).
    public static func trailingPartialWord(_ s: String) -> String {
        var end = s.endIndex
        while end > s.startIndex {
            let prev = s.index(before: end)
            if isWordChar(s[prev]) { end = prev } else { break }
        }
        return String(s[end...])
    }

    /// Run de caractères de mot en TÊTE de `s` (la part qui s'épisserait sur un
    /// mot partiel). Vide si `s` commence par un espace / une ponctuation.
    public static func leadingWordRun(_ s: String) -> String {
        var out = ""
        for c in s {
            if isWordChar(c) { out.append(c) } else { break }
        }
        return out
    }
}
