import Foundation

// MARK: - Crash report detection (pur, testable)

/// Repère un plantage récent de Souffleuse à partir des rapports macOS
/// (`~/Library/Logs/DiagnosticReports/`), pour proposer — UNE fois, sur
/// consentement — d'envoyer le rapport.
///
/// Philosophie privacy : Souffleuse est zéro-réseau / zéro-télémétrie par design.
/// Donc PAS de Sentry/Crashlytics. Mais sans rien, un plantage chez un utilisateur
/// reste invisible des deux côtés. Ce détecteur ne LIT que les rapports déjà écrits
/// par macOS ; l'envoi est manuel (l'utilisateur copie et écrit lui-même l'e-mail).
/// Aucun rapport n'est jamais transmis automatiquement.
enum CrashReportDetector {

    /// Vrai si le nom de fichier est un rapport de plantage de NOTRE process. Le
    /// process s'appelle exactement « Souffleuse » → le rapport est
    /// `Souffleuse-<date>.ips` (ou `_`/`.crash` sur d'anciens macOS). Le tiret/
    /// underscore juste après écarte un éventuel « SouffleuseHelper-… ».
    static func isOurReport(filename: String) -> Bool {
        (filename.hasPrefix("Souffleuse-") || filename.hasPrefix("Souffleuse_"))
            && (filename.hasSuffix(".ips") || filename.hasSuffix(".crash"))
    }

    /// Renvoie le rapport le plus récent strictement postérieur au repère `since`,
    /// ou `nil` s'il n'y a rien de neuf.
    ///
    /// - `since` : date du dernier rapport déjà proposé. `nil` au tout premier
    ///   lancement → on se limite à une fenêtre récente (`firstRunWindow`) pour
    ///   capter un crash juste avant ce lancement sans déterrer d'anciens rapports.
    static func newestUnseen(
        reports: [(url: URL, date: Date)],
        since: Date?,
        now: Date,
        firstRunWindow: TimeInterval = 24 * 3600
    ) -> (url: URL, date: Date)? {
        let cutoff = since ?? now.addingTimeInterval(-firstRunWindow)
        return reports
            .filter { $0.date > cutoff }
            .max { $0.date < $1.date }
    }
}
