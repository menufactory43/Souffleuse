import AppKit
import SouffleuseCore
import SwiftUI

// MARK: - Presence confirmation (fin d'onboarding)

/// Bulle de confirmation pointée sur l'icône de la barre de menus, montrée UNE fois
/// à la sortie du wizard. Une app menu-bar sans fenêtre (`LSUIElement`) : sans ce
/// geste, l'utilisateur qui vient de finir l'onboarding ne sait pas OÙ l'app vit
/// désormais et peut la croire disparue. Le popover natif a une flèche qui désigne
/// littéralement l'icône — « voilà où je suis ». Geste classique des apps menu-bar
/// soignées (Bartender, CleanShot, Cotypist).
enum PresenceConfirmation {

    /// Construit le popover prêt à montrer (`show(relativeTo:of:preferredEdge:)`).
    /// `.transient` : se ferme au moindre clic dehors ; le caller pose aussi un
    /// auto-dismiss temporisé.
    @MainActor
    static func makePopover() -> NSPopover {
        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        let host = NSHostingController(rootView: PresenceConfirmationView())
        // S'auto-dimensionne sur le contenu (sinon une contentSize fixe tasse le
        // texte serif en pavé). La largeur est bornée DANS la vue.
        host.sizingOptions = [.preferredContentSize]
        popover.contentViewController = host
        return popover
    }
}

// MARK: - Color (sang-de-bœuf, miroir de l'onboarding)

private extension Color {
    /// Sang-de-bœuf (#8c2b21), éclairci en dark pour rester lisible — même accent
    /// que le wizard et l'icône souffle (cohérence DA).
    static var presenceAccent: Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let dark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return dark
                ? NSColor(srgbRed: 0xd0 / 255, green: 0x6a / 255, blue: 0x5d / 255, alpha: 1)
                : NSColor(srgbRed: 0x8c / 255, green: 0x2b / 255, blue: 0x21 / 255, alpha: 1)
        })
    }
}

// MARK: - View

private struct PresenceConfirmationView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 7) {
                Image(systemName: "text.bubble.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(Color.presenceAccent)
                Text(tr(fr: "Souffleuse est ici", en: "Souffleuse lives here"))
                    .font(.system(size: 14, weight: .semibold, design: .serif))
            }
            Text(tr(
                fr: "Elle veille dans la barre de menus. Écrivez n'importe où, le souffle vient au curseur.",
                en: "It waits in the menu bar. Write anywhere — the whisper comes to your caret."
            ))
            .font(.system(size: 12, design: .serif))
            .italic()
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .lineSpacing(1)
        }
        // Largeur fixe + hauteur naturelle : une bulle nette, pas un pavé étiré.
        .frame(width: 220, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }
}
