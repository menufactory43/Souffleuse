import AppKit

/// Charte visuelle **« livret »**, partagée par les *apparitions* de Souffleuse —
/// le panneau de traduction/relecture et le carnet — et par elles seules. Les
/// *coulisses* (Préférences, onboarding, historique) restent en natif macOS : on
/// n'habille que ce qui surgit par-dessus les autres apps.
///
/// Clair = **LE LIVRET** (papier crème · encre · bordeaux).
/// Sombre = **LA SALLE DANS LA PÉNOMBRE** (charbon tiède · parchemin · or).
///
/// Source de vérité unique : les valeurs sRGB ne vivent QUE ici, pour que les
/// deux apparitions ne dérivent jamais l'une de l'autre.
public enum LivretPalette {
    public static func paper(_ dark: Bool) -> NSColor {
        dark ? NSColor(srgbRed: 0.11, green: 0.095, blue: 0.085, alpha: 0.97)
             : NSColor(srgbRed: 0.937, green: 0.914, blue: 0.843, alpha: 0.98)
    }
    public static func ink(_ dark: Bool) -> NSColor {
        dark ? NSColor(srgbRed: 0.90, green: 0.87, blue: 0.80, alpha: 1)
             : NSColor(srgbRed: 0.12, green: 0.10, blue: 0.085, alpha: 1)
    }
    /// En-tête + filets : bordeaux en clair, or doux en sombre.
    public static func accent(_ dark: Bool) -> NSColor {
        dark ? NSColor(srgbRed: 0.84, green: 0.70, blue: 0.44, alpha: 1)
             : NSColor(srgbRed: 0.46, green: 0.17, blue: 0.17, alpha: 1)
    }
    /// Avertissement (garde-fou C) : bordeaux en clair, ambre en sombre.
    public static func warn(_ dark: Bool) -> NSColor {
        dark ? NSColor(srgbRed: 0.90, green: 0.71, blue: 0.36, alpha: 1)
             : NSColor(srgbRed: 0.46, green: 0.17, blue: 0.17, alpha: 1)
    }
    public static func rule(_ dark: Bool) -> NSColor {
        dark ? NSColor(srgbRed: 0.80, green: 0.66, blue: 0.40, alpha: 0.40)
             : NSColor(srgbRed: 0.30, green: 0.24, blue: 0.20, alpha: 0.45)
    }
    public static func border(_ dark: Bool) -> NSColor {
        dark ? NSColor(srgbRed: 0.80, green: 0.66, blue: 0.40, alpha: 0.40)
             : NSColor(srgbRed: 0.46, green: 0.17, blue: 0.17, alpha: 0.38)
    }

    /// Serif d'affichage façon livret : Didot si présent (macOS), sinon le serif
    /// système (New York). `italic` pour les notes en marge.
    public static func didot(size: CGFloat, italic: Bool = false) -> NSFont {
        if let d = NSFont(name: italic ? "Didot-Italic" : "Didot", size: size) { return d }
        return serif(size: size, italic: italic)
    }
    public static func serif(size: CGFloat, italic: Bool = false) -> NSFont {
        let base = NSFont.systemFont(ofSize: size, weight: .regular)
        var desc = base.fontDescriptor.withDesign(.serif) ?? base.fontDescriptor
        if italic { desc = desc.withSymbolicTraits(.italic) }
        return NSFont(descriptor: desc, size: size) ?? base
    }

    /// Apparence sombre effective pour cette vue ? (suit clair/sombre du système).
    public static func isDark(_ view: NSView) -> Bool {
        view.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }
}
