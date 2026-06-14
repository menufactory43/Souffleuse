import Testing
@testable import SouffleuseCore

/// Garde la résolution de langue d'interface (FR/EN bilingue). Volontairement
/// limité aux API PURES (`Localizer.resolve`, `systemLanguage`, `pickerLabel`,
/// et un `tr` snapshot) : on NE mute PAS le singleton `Localizer.shared`, qui
/// est lu en parallèle par les autres suites (libellés `tr` de `Tone`, des
/// enums de raccourcis…). Le flipper en plein run ferait flaker ces suites.
@Suite("Localization — résolution de langue")
struct LocalizationTests {
    @Test("une préférence explicite mappe directement sur la langue concrète")
    func explicitPreferenceMapsDirectly() {
        #expect(Localizer.resolve(.fr) == .fr)
        #expect(Localizer.resolve(.en) == .en)
    }

    @Test(".system suit la langue du Mac")
    func systemFollowsMac() {
        #expect(Localizer.resolve(.system) == Localizer.systemLanguage())
    }

    @Test("systemLanguage ne renvoie que fr ou en")
    func systemLanguageIsBinary() {
        let lang = Localizer.systemLanguage()
        #expect(lang == .fr || lang == .en)
    }

    @Test("les libellés concrets du sélecteur sont en nom natif")
    func concretePickerLabelsAreNative() {
        // Indépendants de la langue courante (noms natifs), donc sûrs à tester
        // sans toucher au singleton.
        #expect(UILanguage.fr.pickerLabel == "Français")
        #expect(UILanguage.en.pickerLabel == "English")
    }

    @Test("tr sélectionne selon la langue courante du Localizer partagé")
    func trSelectsByCurrentLanguage() {
        // Lecture seule du singleton : on choisit la variante attendue d'après
        // l'état courant, sans le muter.
        let expected = Localizer.shared.current == .fr ? "Oui" : "Yes"
        #expect(tr(fr: "Oui", en: "Yes") == expected)
    }

    @Test("UILanguage round-trip via rawValue")
    func uiLanguageRawValueRoundTrips() {
        for lang in UILanguage.allCases {
            #expect(UILanguage(rawValue: lang.rawValue) == lang)
        }
    }
}
