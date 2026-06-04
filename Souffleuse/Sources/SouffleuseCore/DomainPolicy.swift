import Foundation

/// Cluster de **registre générique** déduit du bundleID de l'app focus.
///
/// Le but n'est PAS d'étiqueter un métier ou une marque, mais de regrouper les
/// apps par *registre d'écriture* partagé (du code, du chat privé, de la
/// messagerie pro, du mail, du web, des documents). On scope la personnalisation
/// (recall L1, few-shot L2) sur ce cluster pour que :
///   - le **privé ne fuie/pollue jamais** un autre registre — `.chat` regroupe
///     Signal/iMessage/WhatsApp/Telegram/Discord, les apps les plus sensibles
///     en vie privée : leur prose ne doit jamais ressortir dans un mail ou un
///     navigateur ;
///   - la **précision monte** — un corpus homogène en registre produit des
///     rappels et des démonstrations few-shot plus pertinents.
///
/// Le mapping est volontairement **générique** (aucun label métier) pour
/// fonctionner chez tout utilisateur. `.other` est le cluster fourre-tout : il
/// déclenche le comportement historique (AUCUN scope), donc une app inconnue ou
/// un bundleID `nil` ne change rien au comportement existant.
public enum DomainCluster: String, Sendable, CaseIterable {
    case code
    case chat
    case work
    case mail
    case web
    case docs
    case other
}

extension DomainCluster {
    /// Résout le cluster de registre d'un bundleID. PURE (aucun side-effect,
    /// aucun I/O) : lookup O(1) sur des `Set<String>` statiques + gestion des
    /// familles par préfixe (ex. tous les IDE JetBrains sous `com.jetbrains.`).
    ///
    /// `nil` → `.other` (cluster fourre-tout = pas de scope). Tout ce qui n'est
    /// pas explicitement mappé tombe aussi en `.other`.
    public static func cluster(for bundleID: String?) -> DomainCluster {
        guard let id = bundleID else { return .other }

        // Familles par préfixe (testées avant l'exact-match : un préfixe couvre
        // une marque entière qu'on ne veut pas énumérer ID par ID).
        for (prefix, cluster) in familyPrefixes where id.hasPrefix(prefix) {
            return cluster
        }

        if codeIDs.contains(id) { return .code }
        if chatIDs.contains(id) { return .chat }
        if workIDs.contains(id) { return .work }
        if mailIDs.contains(id) { return .mail }
        if webIDs.contains(id) { return .web }
        if docsIDs.contains(id) { return .docs }
        return .other
    }

    // Familles couvertes par préfixe — liste de départ, à étendre.
    private static let familyPrefixes: [(String, DomainCluster)] = [
        ("com.jetbrains.", .code),   // IntelliJ, PyCharm, WebStorm, CLion, etc.
    ]

    // Éditeurs de code / terminaux / IDE — liste de départ, à étendre.
    private static let codeIDs: Set<String> = [
        "com.apple.dt.Xcode",
        "com.microsoft.VSCode",
        "com.microsoft.VSCodeInsiders",
        "com.sublimetext.4",
        "com.sublimetext.3",
        "dev.zed.Zed",
        "com.googlecode.iterm2",
        "com.apple.Terminal",
        "com.openai.codex",
        "com.todesktop.230313mzl4w4u92",   // Cursor
        "com.github.atom",
        "com.panic.Nova",
    ]

    // Chat PERSONNEL (privacy-sensible) — liste de départ, à étendre. Ce cluster
    // est le plus sensible : sa prose ne doit jamais ressortir ailleurs.
    private static let chatIDs: Set<String> = [
        "org.whispersystems.signal-desktop",
        "com.apple.MobileSMS",
        "net.whatsapp.WhatsApp",
        "WhatsApp",
        "org.telegram.desktop",
        "ru.keepcoder.Telegram",
        "com.hnc.Discord",
        "com.facebook.archon",   // Messenger
        "com.apple.iChat",
    ]

    // Chat PRO — liste de départ, à étendre.
    private static let workIDs: Set<String> = [
        "com.tinyspeck.slackmacgap",
        "com.microsoft.teams",
        "com.microsoft.teams2",
    ]

    // Clients mail — liste de départ, à étendre.
    private static let mailIDs: Set<String> = [
        "com.apple.mail",
        "com.readdle.smartemail-Mac",
        "com.microsoft.Outlook",
        "it.bloop.airmail2",
        "com.CanaryMail.Mail",
    ]

    // Navigateurs web — liste de départ, à étendre.
    private static let webIDs: Set<String> = [
        "com.brave.Browser",
        "com.google.Chrome",
        "com.google.Chrome.canary",
        "com.apple.Safari",
        "company.thebrowser.Browser",   // Arc
        "org.mozilla.firefox",
        "com.microsoft.edgemac",
        "com.operasoftware.Opera",
        "com.vivaldi.Vivaldi",
    ]

    // Éditeurs de documents / prise de notes — liste de départ, à étendre.
    private static let docsIDs: Set<String> = [
        "com.apple.Notes",
        "com.apple.TextEdit",
        "com.microsoft.Word",
        "com.apple.iWork.Pages",
        "com.apple.iWork.Numbers",
        "com.apple.iWork.Keynote",
        "md.obsidian",
        "notion.id",
        "net.shinyfrog.bear",
    ]
}
