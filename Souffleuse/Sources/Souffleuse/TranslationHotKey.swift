import AppKit
import Carbon.HIToolbox

/// Raccourci GLOBAL de traduction (⌥⌘T) via `RegisterEventHotKey` — déclenche la
/// traduction du champ focus à TOUT moment, ghost affiché ou non.
///
/// Pourquoi Carbon et pas le `KeyInterceptor` : le CGEventTap n'est armé que
/// pendant qu'une suggestion (ou le HUD) s'affiche — exiger un ghost actif pour
/// traduire était le trou d'UX d'origine. Une hot key système est consommée par
/// macOS avant l'app hôte, ne coûte rien par frappe (aucun callback sur les
/// touches ordinaires), et ne réclame aucune permission supplémentaire.
///
/// Choix de ⌥⌘T : deux modificateurs contigus + T = tapable d'une main sans
/// casser le flow (critère utilisateur). Conflit système connu et accepté :
/// « Afficher/Masquer la barre d'outils » (Finder/Aperçu) est ombré tant que
/// l'app tourne. Kill-switch runtime : `SOUFFLEUSE_TRANSLATE_HOTKEY_OFF`.
@MainActor
final class TranslationHotKey {
    /// Kill-switch env (pattern `midWordLongGhostEnabled`) : ON par défaut.
    static var isEnabled: Bool {
        ProcessInfo.processInfo.environment["SOUFFLEUSE_TRANSLATE_HOTKEY_OFF"] == nil
    }

    private var hotKeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    private let onPress: @MainActor () -> Void

    /// Retourne nil si le kill-switch est posé ou si l'enregistrement échoue
    /// (combo déjà prise par une autre hot key système) — l'app continue sans.
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

        // kVK_ANSI_T = position physique de T — suit le layout (AZERTY inclus).
        let hotKeyID = EventHotKeyID(signature: OSType(0x534F_5546 /* SOUF */), id: 1)
        guard RegisterEventHotKey(UInt32(kVK_ANSI_T), UInt32(cmdKey | optionKey),
                                  hotKeyID, GetApplicationEventTarget(), 0, &hotKeyRef) == noErr,
              hotKeyRef != nil else {
            if let eventHandler { RemoveEventHandler(eventHandler) }
            return nil
        }
    }

    // Durée de vie = celle de l'app (propriété de l'AppDelegate) : pas de
    // désenregistrement nécessaire, macOS nettoie à la sortie du process.
}
