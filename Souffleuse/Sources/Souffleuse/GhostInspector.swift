import AppKit
import Foundation

/// Sonde d'**observabilité DEV** du chemin ghost. À chaque décision du pipeline
/// (affiché / gaté / dropé / stub), on enregistre ce que le modèle voulait
/// montrer + le verdict + le motif de gate. Rendu en direct par
/// `GhostInspectorWindow`. Outil DEV : piloté depuis le menu (build Debug
/// uniquement), `isActive` ne passe à `true` que quand la fenêtre est ouverte —
/// aucun enregistrement (ni tee disque) tant qu'on n'inspecte pas.
///
/// **Privacy / trust :** affiche du texte ghost à l'écran (même niveau de
/// confiance que l'overlay), mais n'est JAMAIS routé par `Log.*` (qui interdit
/// le texte utilisateur). Buffer mémoire + fenêtre, rien sur disque.
@MainActor
final class GhostInspector {
    static let shared = GhostInspector()
    /// Activé seulement pendant que la fenêtre d'inspection est affichée
    /// (basculé par l'AppDelegate en build Debug). Inerte en Release.
    var isActive = false

    enum Verdict: String { case shown = "AFFICHÉ", gated = "GATÉ", dropped = "DROP", stub = "STUB" }

    struct Entry: Identifiable {
        let id: Int
        let tail: String       // fin du préfixe tapé (contexte)
        let verdict: Verdict
        let reason: String     // motif de gate ("keep_under_bar"…), "" si affiché
        let content: String    // ce que le modèle voulait afficher
    }

    private(set) var entries: [Entry] = []
    private var seq = 0
    private let cap = 22
    /// Notifié à chaque nouvelle entrée (l'AppDelegate y branche le rafraîchissement).
    var onChange: (@MainActor () -> Void)?

    func record(tail: String, verdict: Verdict, reason: String, content: String) {
        guard isActive else { return }
        let t = String(tail.suffix(28))
        let c = String(content.replacingOccurrences(of: "\n", with: "⏎").prefix(52))
        // Le stream répète la même décision. Deux dédups :
        // 1) AFFICHÉ : on collapse un ghost déjà à l'écran même si des entrées
        //    GATÉ/DROP/STUB se sont intercalées (re-affirmation par cycle predict)
        //    ou si le tail a avancé d'un caractère (frappe mid-mot). On compare au
        //    DERNIER affiché, pas à l'entrée précédente, et sur le contenu seul.
        // 2) Autres verdicts : dédup consécutif strict (token-par-token, tail inclus).
        if verdict == .shown {
            if let lastShown = entries.last(where: { $0.verdict == .shown }),
               lastShown.content == c {
                return
            }
        } else if let last = entries.last,
                  last.verdict == verdict, last.content == c, last.tail == t {
            return
        }
        seq += 1
        entries.append(Entry(id: seq, tail: t, verdict: verdict, reason: reason, content: c))
        if entries.count > cap { entries.removeFirst(entries.count - cap) }
        Self.tee(verdict: verdict.rawValue, reason: reason, content: c, tail: t)
        onChange?()
    }

    /// Tee disque DEV (même gate que l'inspecteur) : permet de relire le trace
    /// hors écran (`/tmp/souffleuse-ghost-inspector.log`). Jamais via `Log.*`
    /// (texte user) ; même catégorie dev-only que `souffleuse-predict.log`.
    private static let teePath = "/tmp/souffleuse-ghost-inspector.log"
    private static func tee(verdict: String, reason: String, content: String, tail: String) {
        let line = "\(verdict)\t\(reason)\tcontent=\(content)\ttail=\(tail)\n"
        guard let data = line.data(using: .utf8) else { return }
        if let h = FileHandle(forWritingAtPath: teePath) {
            h.seekToEndOfFile(); try? h.write(contentsOf: data); try? h.close()
        } else {
            FileManager.default.createFile(atPath: teePath, contents: data)
        }
    }
}
