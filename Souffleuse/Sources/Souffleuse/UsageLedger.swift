import Foundation
import Observation
import SouffleuseCore
import SouffleuseLog

/// Statistiques d'usage d'UN jour (clé = date locale « yyyy-MM-dd »).
///
/// Ne stocke QUE des compteurs — jamais de texte. Le carnet est une mesure de
/// valeur (frappes épargnées, actes), pas un journal de contenu : rien ici ne
/// franchit l'audit de confidentialité.
struct DayStat: Codable, Sendable, Equatable {
    var date: String
    var keystrokesSaved: Int = 0
    var ghostsAccepted: Int = 0
    var translations: Int = 0
    var reformulations: Int = 0
    /// Transformations « // » acceptées (Tab sur le preview).
    var transformations: Int = 0

    init(date: String, keystrokesSaved: Int = 0, ghostsAccepted: Int = 0,
         translations: Int = 0, reformulations: Int = 0, transformations: Int = 0) {
        self.date = date
        self.keystrokesSaved = keystrokesSaved
        self.ghostsAccepted = ghostsAccepted
        self.translations = translations
        self.reformulations = reformulations
        self.transformations = transformations
    }

    /// Décodage tolérant : les fichiers écrits AVANT l'ajout d'un compteur n'ont
    /// pas sa clé — `decodeIfPresent` évite de réinitialiser tout le carnet à
    /// l'ajout d'une statistique (le décodage synthétisé jetterait le fichier).
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        date = try c.decode(String.self, forKey: .date)
        keystrokesSaved = try c.decodeIfPresent(Int.self, forKey: .keystrokesSaved) ?? 0
        ghostsAccepted = try c.decodeIfPresent(Int.self, forKey: .ghostsAccepted) ?? 0
        translations = try c.decodeIfPresent(Int.self, forKey: .translations) ?? 0
        reformulations = try c.decodeIfPresent(Int.self, forKey: .reformulations) ?? 0
        transformations = try c.decodeIfPresent(Int.self, forKey: .transformations) ?? 0
    }
}

/// Enveloppe versionnée sur disque (`usage-ledger.json`). Porte l'historique
/// journalier + l'accumulateur global de cadence (toutes sessions confondues).
private struct LedgerFile: Codable {
    var version: Int = 1
    var cadenceTypedChars: Int = 0
    var cadenceTypedMillis: Double = 0
    var days: [DayStat] = []
}

/// Carnet d'usage : frappes épargnées, actes (traductions/relectures) et cadence
/// de frappe mesurée, agrégés par jour dans
/// `~/Library/Application Support/Souffleuse/usage-ledger.json`.
///
/// Le « temps gagné » n'est PAS stocké : c'est une fonction pure des frappes
/// épargnées × la cadence mesurée − le coût d'acceptation (cf.
/// `SuggestionPolicy.Tuning.ledger*`). Toute l'arithmétique vit dans des
/// `nonisolated static func` testables sans disque ni MainActor.
@MainActor
@Observable
final class UsageLedger {
    private(set) var days: [DayStat] = []
    private(set) var cadenceTypedChars: Int = 0
    private(set) var cadenceTypedMillis: Double = 0
    @ObservationIgnored private let fileURL: URL
    @ObservationIgnored private var lastSaveAt: Date?

    private typealias T = SuggestionPolicy.Tuning

    convenience init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Souffleuse", isDirectory: true)
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        self.init(fileURL: support.appendingPathComponent("usage-ledger.json"))
    }

    init(fileURL: URL) {
        self.fileURL = fileURL
        load()
    }

    // MARK: - Enregistrement

    /// Une réplique soufflée a été acceptée : `charsSaved` = caractères injectés
    /// que l'utilisateur n'a pas eu à taper (une touche pressée pour tout le bloc).
    func recordAccepted(charsSaved: Int) {
        guard charsSaved > 0 else { return }
        let i = ensureToday()
        days[i].keystrokesSaved += charsSaved
        days[i].ghostsAccepted += 1
        save()   // accepts rares → écriture immédiate
    }

    /// Un message traduit (FR→cible) a été commité.
    func recordTranslation() {
        let i = ensureToday()
        days[i].translations += 1
        save()
    }

    /// Un message relu (FR→FR) a été commité.
    func recordReformulation() {
        let i = ensureToday()
        days[i].reformulations += 1
        save()
    }

    /// Une transformation « // » a été acceptée (Tab sur le preview).
    func recordTransformation() {
        let i = ensureToday()
        days[i].transformations += 1
        save()
    }

    /// Échantillon de frappe humaine : `chars` caractères apparus en `seconds`.
    /// Alimente l'accumulateur global de cadence (écriture throttlée — fréquent).
    func recordTyping(chars: Int, seconds: Double) {
        guard chars > 0, seconds > 0 else { return }
        cadenceTypedChars += chars
        cadenceTypedMillis += seconds * 1000
        saveThrottled()
    }

    // MARK: - Lecture (dérivés purs)

    /// Stat du jour courant (zéros si rien encore aujourd'hui).
    var today: DayStat {
        let key = Self.dateKey(Date())
        return days.first(where: { $0.date == key }) ?? DayStat(date: key)
    }

    /// Cadence calibrée (ms/caractère), ou défaut tant qu'on manque d'échantillons.
    var millisPerChar: Double {
        Self.millisPerChar(typedChars: cadenceTypedChars, typedMillis: cadenceTypedMillis)
    }

    /// Vrai dès qu'on a assez d'échantillons pour annoncer « à ta cadence ».
    var cadenceCalibrated: Bool {
        cadenceTypedChars >= T.ledgerCadenceMinSampleChars
    }

    /// Temps estimé gagné AUJOURD'HUI (s), formule honnête et conservatrice.
    var estimatedSecondsSavedToday: Double {
        Self.estimatedSecondsSaved(
            keystrokesSaved: today.keystrokesSaved,
            ghostsAccepted: today.ghostsAccepted,
            millisPerChar: millisPerChar)
    }

    /// Les `n` derniers jours (chronologiques), complétés par des jours vides en
    /// tête si l'historique est plus court — pour une sparkline de longueur fixe.
    func lastDays(_ n: Int) -> [DayStat] {
        Self.lastDays(days, count: n, today: Date())
    }

    // MARK: - Persistance

    private func ensureToday() -> Int {
        let key = Self.dateKey(Date())
        if let i = days.firstIndex(where: { $0.date == key }) { return i }
        days.append(DayStat(date: key))
        days = Self.capped(days, maxDays: T.ledgerHistoryDays)
        return days.firstIndex(where: { $0.date == key })!
    }

    func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        do {
            let file = try JSONDecoder().decode(LedgerFile.self, from: data)
            days = Self.capped(file.days, maxDays: T.ledgerHistoryDays)
            cadenceTypedChars = max(0, file.cadenceTypedChars)
            cadenceTypedMillis = max(0, file.cadenceTypedMillis)
        } catch {
            Log.warn(.ui, "usage_ledger_load_corrupt_reset")
            days = []
            cadenceTypedChars = 0
            cadenceTypedMillis = 0
        }
    }

    private func saveThrottled() {
        let now = Date()
        if let last = lastSaveAt, now.timeIntervalSince(last) < T.ledgerSaveThrottleSeconds { return }
        save()
    }

    func save() {
        lastSaveAt = Date()
        let file = LedgerFile(
            cadenceTypedChars: cadenceTypedChars,
            cadenceTypedMillis: cadenceTypedMillis,
            days: days)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(file) else {
            Log.error(.ui, "usage_ledger_encode_failed")
            return
        }
        do {
            try data.write(to: fileURL, options: .atomic)
        } catch {
            Log.error(.ui, "usage_ledger_write_failed")
        }
    }

    // MARK: - Arithmétique pure (testable)

    /// Clé de jour locale « yyyy-MM-dd » (tri lexicographique == chronologique).
    nonisolated static func dateKey(_ date: Date) -> String {
        let c = Calendar(identifier: .gregorian).dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// Cadence calibrée, ou défaut sous le seuil d'échantillons.
    nonisolated static func millisPerChar(typedChars: Int, typedMillis: Double) -> Double {
        guard typedChars >= SuggestionPolicy.Tuning.ledgerCadenceMinSampleChars, typedMillis > 0 else {
            return SuggestionPolicy.Tuning.ledgerDefaultMillisPerChar
        }
        return typedMillis / Double(typedChars)
    }

    /// Temps gagné (s) = frappes épargnées × cadence − coût d'acceptation, planché à 0.
    nonisolated static func estimatedSecondsSaved(keystrokesSaved: Int, ghostsAccepted: Int, millisPerChar: Double) -> Double {
        let gross = Double(keystrokesSaved) * millisPerChar / 1000.0
        let overhead = Double(ghostsAccepted) * SuggestionPolicy.Tuning.ledgerAcceptOverheadSeconds
        return max(0, gross - overhead)
    }

    /// Garde les `maxDays` jours les plus récents (tri chronologique par clé).
    nonisolated static func capped(_ days: [DayStat], maxDays: Int) -> [DayStat] {
        Array(days.sorted { $0.date < $1.date }.suffix(max(0, maxDays)))
    }

    /// Renvoie exactement `count` jours finissant aujourd'hui, en complétant par
    /// des jours vides les dates absentes — fenêtre stable pour la sparkline.
    nonisolated static func lastDays(_ days: [DayStat], count: Int, today: Date) -> [DayStat] {
        guard count > 0 else { return [] }
        let byDate = Dictionary(days.map { ($0.date, $0) }, uniquingKeysWith: { a, _ in a })
        let cal = Calendar(identifier: .gregorian)
        return (0..<count).reversed().map { back in
            let d = cal.date(byAdding: .day, value: -back, to: today) ?? today
            let key = dateKey(d)
            return byDate[key] ?? DayStat(date: key)
        }
    }
}
