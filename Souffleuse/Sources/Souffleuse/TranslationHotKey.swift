import AppKit
import Carbon.HIToolbox
import SouffleuseCore

/// Préréglages du raccourci GLOBAL de traduction, choisis pour rester tapables
/// d'une main sans casser le flow (critère utilisateur). Chaque preset mappe un
/// virtual key POSITIONNEL (suit le layout, AZERTY inclus) + des modificateurs
/// Carbon. `.disabled` coupe la hot key. Même forme que `AcceptAllKey`/`CommitKey`
/// pour que les Réglages la rendent identiquement (Picker + label).
enum TranslateHotKeyOption: String, CaseIterable, Sendable {
    case disabled, optCmdT, ctrlOptT, optCmdY

    /// (virtualKey, modificateurs Carbon) à enregistrer, nil quand désactivé.
    var carbonBinding: (virtualKey: UInt32, modifiers: UInt32)? {
        switch self {
        case .disabled: return nil
        case .optCmdT: return (UInt32(kVK_ANSI_T), UInt32(cmdKey | optionKey))
        case .ctrlOptT: return (UInt32(kVK_ANSI_T), UInt32(controlKey | optionKey))
        case .optCmdY: return (UInt32(kVK_ANSI_Y), UInt32(cmdKey | optionKey))
        }
    }

    var label: String {
        switch self {
        case .disabled: return tr(fr: "Désactivé", en: "Disabled")
        case .optCmdT: return "⌥⌘T"
        case .ctrlOptT: return "⌃⌥T"
        case .optCmdY: return "⌥⌘Y"
        }
    }
}

/// Raccourci GLOBAL de traduction via `RegisterEventHotKey` — déclenche la
/// traduction du champ focus à TOUT moment, ghost affiché ou non.
///
/// Pourquoi Carbon et pas le `KeyInterceptor` : le CGEventTap n'est armé que
/// pendant qu'une suggestion (ou le HUD) s'affiche — exiger un ghost actif pour
/// traduire était le trou d'UX d'origine. Une hot key système est consommée par
/// macOS avant l'app hôte, ne coûte rien par frappe (aucun callback sur les
/// touches ordinaires), et ne réclame aucune permission supplémentaire.
///
/// Le binding est un RÉGLAGE (`PreferencesStore.translateHotKey`, défaut ⌥⌘T) ;
/// `apply(_:)` ré-enregistre à chaud au changement de pref. Conflit système
/// connu du défaut : « Afficher/Masquer la barre d'outils » (Finder/Aperçu) est
/// ombré tant que l'app tourne. Kill-switch env : `SOUFFLEUSE_TRANSLATE_HOTKEY_OFF`.
@MainActor
final class TranslationHotKey {
    /// Kill-switch env (urgence, par-dessus la pref) : ON par défaut.
    static var isEnabled: Bool {
        ProcessInfo.processInfo.environment["SOUFFLEUSE_TRANSLATE_HOTKEY_OFF"] == nil
    }

    private var hotKeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    private var applied: TranslateHotKeyOption = .disabled
    private let onPress: @MainActor () -> Void

    /// Installe le handler Carbon (une fois, durée de vie = l'app). Retourne nil
    /// si le kill-switch est posé ou si l'installation échoue — l'app continue
    /// sans. L'enregistrement de la combinaison se fait via `apply(_:)`.
    init?(onPress: @escaping @MainActor () -> Void) {
        guard Self.isEnabled else { return nil }
        self.onPress = onPress

        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        // Le callback C est dispatché par Carbon sur le run loop PRINCIPAL
        // (GetApplicationEventTarget) → l'assume-isolated est structurel.
        let status = InstallEventHandler(GetApplicationEventTarget(), { _, _, userData in
            guard let userData else { return noErr }
            let me = Unmanaged<TranslationHotKey>.fromOpaque(userData).takeUnretainedValue()
            MainActor.assumeIsolated { me.onPress() }
            return noErr
        }, 1, &spec, selfPtr, &eventHandler)
        guard status == noErr else { return nil }
    }

    /// (Ré)enregistre la combinaison choisie — appelé au lancement et à chaque
    /// changement de la pref. Idempotent ; `.disabled` désenregistre seulement.
    /// Retourne false si macOS refuse la combinaison (déjà prise par une autre
    /// hot key système) — le caller peut le signaler, l'app continue sans.
    @discardableResult
    func apply(_ option: TranslateHotKeyOption) -> Bool {
        guard option != applied else { return true }
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
        applied = option
        guard let binding = option.carbonBinding else { return true }
        let hotKeyID = EventHotKeyID(signature: OSType(0x534F_5546 /* SOUF */), id: 1)
        let ok = RegisterEventHotKey(binding.virtualKey, binding.modifiers,
                                     hotKeyID, GetApplicationEventTarget(), 0, &hotKeyRef) == noErr
            && hotKeyRef != nil
        if !ok { applied = .disabled }
        return ok
    }

    // Durée de vie = celle de l'app (propriété de l'AppDelegate) : pas de
    // désenregistrement nécessaire, macOS nettoie à la sortie du process.
}
