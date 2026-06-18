import AppKit
import SouffleuseCore
import SwiftUI

// MARK: - About window (À propos)

/// Petite fenêtre « À propos » d'une app menu-bar (`LSUIElement`) : icône, nom,
/// version, tagline et liens. Encapsule du SwiftUI derrière une frontière AppKit
/// (NSWindow + NSHostingController) pour que l'AppDelegate reste AppKit pur et
/// n'importe pas SwiftUI. Reprend EXACTEMENT la DA de `PresenceConfirmation`
/// (serif, accent sang-de-bœuf adaptatif dark/light) — cohérence visuelle.
@MainActor
final class AboutWindow {
    private var window: NSWindow?

    /// Crée la fenêtre au premier appel, sinon ramène l'existante au premier plan.
    /// Non redimensionnée, centrée, `isReleasedWhenClosed = false` (retenue par
    /// l'AppDelegate via une propriété stockée).
    func show() {
        if let existing = window {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let host = NSHostingController(rootView: AboutView())
        // S'auto-dimensionne sur le contenu (la largeur est bornée DANS la vue),
        // comme le popover de présence — pas de contentSize fixe qui tasse le serif.
        host.sizingOptions = [.preferredContentSize]

        let w = NSWindow(contentViewController: host)
        w.styleMask = [.titled, .closable, .fullSizeContentView]
        w.titleVisibility = .hidden
        w.titlebarAppearsTransparent = true
        w.isMovableByWindowBackground = true
        w.title = tr(fr: "À propos de Souffleuse", en: "About Souffleuse")
        w.isReleasedWhenClosed = false
        w.center()
        window = w

        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

// MARK: - Color (sang-de-bœuf, miroir de l'onboarding / du popover de présence)

private extension Color {
    /// Sang-de-bœuf (#8c2b21), éclairci en dark pour rester lisible — même accent
    /// que le wizard, l'icône souffle et le popover de présence (cohérence DA).
    static var aboutAccent: Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let dark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return dark
                ? NSColor(srgbRed: 0xd0 / 255, green: 0x6a / 255, blue: 0x5d / 255, alpha: 1)
                : NSColor(srgbRed: 0x8c / 255, green: 0x2b / 255, blue: 0x21 / 255, alpha: 1)
        })
    }
}

// MARK: - View

private struct AboutView: View {
    /// Version lue dynamiquement à l'`Info.plist` : « 0.3.0 (12) ». `CFBundleVersion`
    /// (build) entre parenthèses ; repli silencieux si une clé manque.
    private var versionLine: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "—"
        let build = info?["CFBundleVersion"] as? String
        if let build, !build.isEmpty, build != short {
            return tr(fr: "Version \(short) (\(build))", en: "Version \(short) (\(build))")
        }
        return tr(fr: "Version \(short)", en: "Version \(short)")
    }

    var body: some View {
        VStack(spacing: 10) {
            if let icon = NSApp.applicationIconImage {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 72, height: 72)
                    .accessibilityHidden(true)
            }

            Text("Souffleuse")
                .font(.system(size: 18, weight: .semibold, design: .serif))

            Text(versionLine)
                .font(.system(size: 11, design: .serif))
                .foregroundStyle(.secondary)

            Text(tr(
                fr: "L'assistant de frappe qui souffle, au creux du curseur.",
                en: "The typing assistant that whispers, right at your caret."
            ))
            .font(.system(size: 12, design: .serif))
            .italic()
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .lineSpacing(1)
            .padding(.top, 2)

            Divider()
                .padding(.vertical, 2)

            VStack(spacing: 6) {
                aboutLink(
                    fr: "Site", en: "Website",
                    url: "https://souffleuse.app",
                    a11yFr: "Ouvrir le site souffleuse.app",
                    a11yEn: "Open the souffleuse.app website"
                )
                aboutLink(
                    fr: "Confidentialité", en: "Privacy",
                    url: "https://souffleuse.app/confidentialite.html",
                    a11yFr: "Ouvrir la page de confidentialité",
                    a11yEn: "Open the privacy page"
                )
                aboutLink(
                    fr: "Nous écrire", en: "Contact us",
                    url: "mailto:contact@souffleuse.app",
                    a11yFr: "Écrire un e-mail à contact@souffleuse.app",
                    a11yEn: "Send an email to contact@souffleuse.app"
                )
            }
        }
        // Largeur fixe + hauteur naturelle : une carte nette, pas un pavé étiré.
        .frame(width: 280)
        .padding(.horizontal, 24)
        .padding(.top, 26)
        .padding(.bottom, 22)
    }

    /// Lien serif accentué sang-de-bœuf. SwiftUI `Link` ouvre l'URL via le système
    /// (NSWorkspace), `mailto:` compris. Label VoiceOver explicite par lien.
    @ViewBuilder
    private func aboutLink(fr: String, en: String, url: String, a11yFr: String, a11yEn: String) -> some View {
        if let dest = URL(string: url) {
            Link(destination: dest) {
                Text(tr(fr: fr, en: en))
                    .font(.system(size: 13, design: .serif))
                    .foregroundStyle(Color.aboutAccent)
            }
            .accessibilityLabel(Text(tr(fr: a11yFr, en: a11yEn)))
        }
    }
}
