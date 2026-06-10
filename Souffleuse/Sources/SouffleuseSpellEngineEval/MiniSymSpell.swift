import Foundation

/// Implémentation minimale de l'algorithme **SymSpell** (symmetric delete,
/// Wolf Garbe) pour l'éval comparative — code DEV, pas shipping.
///
/// Principe : à l'indexation, chaque mot du dictionnaire engendre toutes ses
/// variantes par SUPPRESSION (≤ `maxDistance` chars) ; au lookup, l'entrée
/// engendre les siennes ; une coquille à distance ≤ d du mot juste partage
/// forcément une variante. Optimisation « prefix » du SymSpell officiel : les
/// deletes ne sont générés que sur les `prefixLength` premiers caractères
/// (mémoire ÷ ~10) ; la confirmation se fait par vraie distance
/// Damerau-Levenshtein (OSA) sur les chaînes complètes.
///
/// Les clés sont des hashes FNV-1a 64 bits plutôt que des String — une
/// collision ne produit qu'un candidat de plus, éliminé par la vérification.
final class MiniSymSpell {
    private(set) var frequencies: [String: Int] = [:]
    private var words: [String] = []
    private var deletes: [UInt64: [Int32]] = [:]
    let maxDistance: Int
    let prefixLength: Int

    init(maxDistance: Int = 2, prefixLength: Int = 7) {
        self.maxDistance = maxDistance
        self.prefixLength = prefixLength
    }

    /// Charge un dictionnaire « mot fréquence » (un par ligne). Cumulable —
    /// FR + EN dans le même index ; un mot présent deux fois garde le max.
    func load(dictionaryAt url: URL) throws {
        let text = try String(contentsOf: url, encoding: .utf8)
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: " ")
            guard parts.count == 2, let count = Int(parts[1]) else { continue }
            let word = String(parts[0])
            frequencies[word] = max(frequencies[word] ?? 0, count)
        }
    }

    /// Variante : charge un dictionnaire déjà en mémoire (dicos nettoyés).
    func load(frequencyTable table: [String: Int]) {
        for (word, count) in table {
            frequencies[word] = max(frequencies[word] ?? 0, count)
        }
    }

    /// Construit l'index des deletes. À appeler une fois, après les `load`.
    func build() {
        words = Array(frequencies.keys)
        deletes.reserveCapacity(words.count * 16)
        for (i, word) in words.enumerated() {
            let prefix = String(word.prefix(prefixLength))
            for variant in Self.deleteVariants(of: prefix, maxDistance: maxDistance) {
                deletes[Self.fnv1a(variant), default: []].append(Int32(i))
            }
        }
    }

    struct Suggestion {
        let term: String
        let distance: Int
        let frequency: Int
    }

    /// Candidats à distance OSA ≤ `maxDistance`, triés distance croissante puis
    /// fréquence décroissante. Une entrée qui EST un mot du dictionnaire sort
    /// en tête avec distance 0 (l'appelant y lit « pas une coquille »).
    func lookup(_ input: String) -> [Suggestion] {
        let prefix = String(input.prefix(prefixLength))
        var candidateIndices = Set<Int32>()
        for variant in Self.deleteVariants(of: prefix, maxDistance: maxDistance) {
            if let hits = deletes[Self.fnv1a(variant)] {
                candidateIndices.formUnion(hits)
            }
        }
        let inputChars = Array(input)
        var out: [Suggestion] = []
        for idx in candidateIndices {
            let word = words[Int(idx)]
            guard abs(word.count - input.count) <= maxDistance else { continue }
            let d = Self.damerauOSA(inputChars, Array(word), cap: maxDistance)
            guard d <= maxDistance else { continue }
            out.append(Suggestion(term: word, distance: d, frequency: frequencies[word] ?? 0))
        }
        return out.sorted {
            $0.distance != $1.distance ? $0.distance < $1.distance : $0.frequency > $1.frequency
        }
    }

    // MARK: - Primitives

    /// Toutes les variantes par suppression de ≤ `maxDistance` caractères,
    /// l'original inclus. BFS niveau par niveau, dédupliqué.
    static func deleteVariants(of s: String, maxDistance: Int) -> Set<String> {
        var all: Set<String> = [s]
        var frontier: Set<String> = [s]
        for _ in 0..<maxDistance {
            var next: Set<String> = []
            for word in frontier where word.count > 1 {
                var chars = Array(word)
                for i in 0..<chars.count {
                    let removed = chars.remove(at: i)
                    next.insert(String(chars))
                    chars.insert(removed, at: i)
                }
            }
            frontier = next.subtracting(all)
            all.formUnion(next)
        }
        return all
    }

    /// Damerau-Levenshtein OSA, avec early-exit quand toute la rangée dépasse
    /// `cap` (les candidats hors budget ne méritent pas le O(n·m) complet).
    static func damerauOSA(_ s: [Character], _ t: [Character], cap: Int) -> Int {
        let n = s.count, m = t.count
        if n == 0 { return m }
        if m == 0 { return n }
        if abs(n - m) > cap { return cap + 1 }
        var d = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
        for i in 0...n { d[i][0] = i }
        for j in 0...m { d[0][j] = j }
        for i in 1...n {
            var rowMin = Int.max
            for j in 1...m {
                let cost = s[i - 1] == t[j - 1] ? 0 : 1
                d[i][j] = Swift.min(d[i - 1][j] + 1, d[i][j - 1] + 1, d[i - 1][j - 1] + cost)
                if i > 1, j > 1, s[i - 1] == t[j - 2], s[i - 2] == t[j - 1] {
                    d[i][j] = Swift.min(d[i][j], d[i - 2][j - 2] + 1)
                }
                rowMin = Swift.min(rowMin, d[i][j])
            }
            if rowMin > cap { return cap + 1 }
        }
        return d[n][m]
    }

    static func fnv1a(_ s: String) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in s.utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x0000_0100_0000_01b3
        }
        return hash
    }
}
