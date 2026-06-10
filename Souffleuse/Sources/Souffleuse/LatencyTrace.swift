import Foundation

/// Trace de latence BOUT-EN-BOUT du ghost — DEV uniquement, activée par
/// `SOUFFLEUSE_LATENCY_TRACE=1`. Mesure ce que les events `Log` ne couvrent
/// pas : la chaîne complète frappe → tick (quantization du poll 80 ms) →
/// debounce → predict → génération → suggestion → REPAINT overlay. C'est elle
/// qui localise la latence perçue (le segment LLM seul est déjà ventilé par
/// `ghost_beam_*_ms`).
///
/// Une ligne JSONL par étape : `{"t":<epoch ms>,"e":"<étape>","k":<clé>,"i":<info>}`.
/// `k` = hash FNV-1a du préfixe — corrèle les étapes d'un même cycle SANS
/// écrire de texte utilisateur (le fichier ne contient que des nombres et des
/// noms d'étapes). `i` = info libre (longueur, code source 1=instant 2=cache
/// 3=undo 4=beam). Analyse : `tools/latency_report.py`.
///
/// Hors flag : `enabled == false`, chaque `mark` est un test booléen et un
/// retour — zéro coût prod. Fichier `/tmp` (même famille que
/// `SOUFFLEUSE_PREDICT_LOG`, hors périmètre du log JSONL audité).
enum LatencyTrace {
    static let enabled: Bool =
        ProcessInfo.processInfo.environment["SOUFFLEUSE_LATENCY_TRACE"]?.isEmpty == false
    static let path = "/tmp/souffleuse-latency.jsonl"
    private static let lock = NSLock()

    /// Hash FNV-1a 64 bits du préfixe — clé de corrélation stable, aucun texte.
    static func key(_ s: String) -> Int {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        for b in s.utf8 { h = (h ^ UInt64(b)) &* 0x0000_0100_0000_01b3 }
        return Int(bitPattern: UInt(truncatingIfNeeded: h))
    }

    /// Horodate une étape. `event` en `StaticString` (littéral compile-time,
    /// même invariant privacy-by-typesystem que `Log`).
    static func mark(_ event: StaticString, key: Int = 0, info: Int = 0) {
        guard enabled else { return }
        let t = Int(Date().timeIntervalSince1970 * 1000)
        let line = "{\"t\":\(t),\"e\":\"\(event)\",\"k\":\(key),\"i\":\(info)}\n"
        guard let data = line.data(using: .utf8) else { return }
        lock.lock()
        defer { lock.unlock() }
        if let handle = FileHandle(forWritingAtPath: path) {
            handle.seekToEndOfFile()
            try? handle.write(contentsOf: data)
            try? handle.close()
        } else {
            FileManager.default.createFile(atPath: path, contents: data)
        }
    }
}
