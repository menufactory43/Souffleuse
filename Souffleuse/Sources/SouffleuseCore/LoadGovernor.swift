import Foundation

/// Niveau de pression système, dérivé de `ProcessInfo.ThermalState` (et, à
/// terme, d'autres signaux de charge). Modélisé séparément de l'enum Apple
/// pour rester `Sendable`, testable hors-runtime (sans dépendre de l'état
/// thermique réel de la machine de CI) et stable si l'OS ajoute des cas.
///
/// `Comparable` par ordre de sévérité croissante (`nominal < … < critical`)
/// pour que les gates s'expriment en `level >= .serious`.
public enum LoadLevel: Int, Sendable, Comparable, CaseIterable {
    case nominal = 0
    case fair = 1
    case serious = 2
    case critical = 3

    public static func < (lhs: LoadLevel, rhs: LoadLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// **Gouverneur de charge** — la pièce manquante pour « steadier performance
/// when your Mac is under heavy load » (parité Cotypist).
///
/// Problème : à 50 ms de poll + cancel-on-keystroke, une frappe rapide démarre
/// puis JETTE beaucoup de décodes llama.cpp (chaque préfixe annule le précédent
/// avant qu'il ait fini). Quand le Mac est déjà sous pression (thermique ou
/// CPU), ce churn aggrave la situation : on dépense du GPU/CPU pour des ghosts
/// qui ne s'afficheront jamais.
///
/// Réponse : sous pression on **coalesce** (debounce allongé → moins de
/// générations démarrées-puis-annulées) et on **coupe le travail spéculatif**
/// (le refill de la fenêtre vivante, « nice-to-have »). Le *seed* — le ghost
/// que l'utilisateur voit réellement — n'est JAMAIS dégradé en qualité : on ne
/// change que la CADENCE et la quantité de travail jeté, pas le contenu généré.
/// C'est l'invariant central : *même ghost, moins de gaspillage*.
///
/// Toutes les décisions sont des fonctions PURES de `LoadLevel` → testables
/// sans GGUF ni état thermique réel. Le mapping depuis `ProcessInfo` est isolé
/// dans `level(from:)` pour la même raison.
public enum LoadGovernor {
    /// Multiplicateur appliqué au debounce de predict (`predictDebounceNanos`).
    /// Sous pression on ALLONGE la fenêtre de debounce : davantage de frappes
    /// tombent dans le même intervalle et sont coalescées en UNE génération au
    /// lieu de N démarrées-puis-annulées. À `.nominal` le multiplicateur vaut
    /// `1.0` → comportement byte-identique à avant le gouverneur.
    ///
    /// Les paliers (1.0 / 1.6 / 3.0 / 5.0) sont choisis pour que, sur une
    /// rafale de frappe typique (~120 ms entre frappes), `.serious` (×3 → 45 ms
    /// sur la base 15 ms) commence à coalescer les frappes adjacentes sans
    /// jamais dépasser un debounce perceptible (< ~75 ms), et `.critical` (×5)
    /// privilégie franchement la coalescence.
    public static func debounceMultiplier(for level: LoadLevel) -> Double {
        switch level {
        case .nominal:  return 1.0
        case .fair:     return 1.5
        case .serious:  return 2.0
        case .critical: return 3.0
        }
    }

    /// Sous pression `.serious`/`.critical`, on coupe le refill SPÉCULATIF (la
    /// recharge de la fenêtre vivante pendant la consommation). C'est la 1re
    /// source de décodes gaspillés sous charge : le ghost *seed* reste affiché
    /// et utile, il fond simplement vers sa fin sans être re-rechargé tant que
    /// la pression dure. Dès que la pression retombe (`<= .fair`), le refill
    /// reprend → la fenêtre vivante se re-remplit. La continuité n'est donc pas
    /// supprimée, elle est mise en veille le temps que le Mac récupère.
    /// **Le vrai levier de charge, mesuré (SouffleuseLoadProfile).** Profondeur
    /// de look-ahead du ghost (mots maintenus DEVANT le caret) en fonction de la
    /// charge. Un modèle 1B se trompe souvent au mot près sur un texte précis :
    /// tout ce qu'on génère au-delà de ~3 mots d'avance est presque toujours
    /// JETÉ à la prochaine divergence de frappe. Raccourcir le look-ahead sous
    /// charge coupe le décodage GPU (~46 %) et le CPU (~32 %) — SANS jamais
    /// vider le ghost (plancher ≥ 3) : la fenêtre vivante reste affichée, juste
    /// moins profonde. C'est la différence avec l'ancienne « suppression du
    /// refill » qui, elle, tuait le ghost.
    ///
    /// `base` = profondeur souhaitée hors charge (préférence/longGhost). À
    /// `.nominal`/`.fair` on la respecte telle quelle (byte-identique) ; sous
    /// pression on la rabote vers un plancher non-vide.
    public static func lookaheadWords(base: Int, for level: LoadLevel) -> Int {
        switch level {
        case .nominal, .fair: return base
        case .serious:        return max(4, base / 2)   // ~moitié de la spéculation
        case .critical:       return max(3, base / 3)   // minimal mais non-vide
        }
    }

    /// Le skip de debounce sur réserve chaude sert le ghost depuis la réserve
    /// DÉJÀ calculée (~1 ms) — ce n'est JAMAIS du travail gaspillé, donc rien à
    /// gagner à le couper sous charge, et beaucoup à perdre : le désactiver
    /// forçait des générations complètes en cascade (« vraiment long à
    /// afficher », retour terrain). On le garde donc **toujours actif**. La
    /// coalescence sous charge se fait via le seul `debounceMultiplier` (qui ne
    /// retarde QUE les predicts froids, pas les avancées chaudes).
    public static func allowsWarmDebounceSkip(for level: LoadLevel) -> Bool {
        _ = level
        return true
    }

    /// Mapping `ProcessInfo.ThermalState` → `LoadLevel`. Isolé ici pour garder
    /// le reste du gouverneur pur et testable. Un état futur inconnu de l'OS est
    /// traité prudemment comme `.fair` (léger throttling plutôt que rien).
    public static func level(from thermal: ProcessInfo.ThermalState) -> LoadLevel {
        switch thermal {
        case .nominal:  return .nominal
        case .fair:     return .fair
        case .serious:  return .serious
        case .critical: return .critical
        @unknown default: return .fair
        }
    }

    /// Parse d'un override DEV (`SOUFFLEUSE_FORCE_LOAD_LEVEL=serious`) pour
    /// l'A/B et les evals : permet de mesurer le comportement sous chaque palier
    /// sans devoir réellement chauffer la machine. Insensible à la casse ;
    /// accepte aussi les rawValues `0..3`. `nil` si non posé / non reconnu.
    public static func forcedLevel(from raw: String?) -> LoadLevel? {
        guard let raw = raw?.trimmingCharacters(in: .whitespaces).lowercased(),
              !raw.isEmpty else { return nil }
        switch raw {
        case "nominal", "0":  return .nominal
        case "fair", "1":     return .fair
        case "serious", "2":  return .serious
        case "critical", "3": return .critical
        default:              return nil
        }
    }
}
