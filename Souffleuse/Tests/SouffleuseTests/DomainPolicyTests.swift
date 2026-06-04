import Testing
import Foundation
import SouffleuseCore

/// Couvre le scoping de personnalisation par registre générique : un bundleID
/// connu doit tomber dans son cluster, un préfixe de famille (JetBrains) suit la
/// famille, et tout inconnu — comme `nil` — retombe en `.other` (= pas de scope).
@Suite("DomainCluster — registre générique déduit du bundleID")
struct DomainPolicyTests {

    @Test("code : Xcode/VSCode/Terminal mappés sur .code")
    func codeCluster() {
        #expect(DomainCluster.cluster(for: "com.apple.dt.Xcode") == .code)
        #expect(DomainCluster.cluster(for: "com.microsoft.VSCode") == .code)
        #expect(DomainCluster.cluster(for: "com.apple.Terminal") == .code)
        #expect(DomainCluster.cluster(for: "com.todesktop.230313mzl4w4u92") == .code)
    }

    @Test("chat privé : Signal/iMessage/WhatsApp/Telegram mappés sur .chat")
    func chatCluster() {
        #expect(DomainCluster.cluster(for: "org.whispersystems.signal-desktop") == .chat)
        #expect(DomainCluster.cluster(for: "com.apple.MobileSMS") == .chat)
        #expect(DomainCluster.cluster(for: "net.whatsapp.WhatsApp") == .chat)
        #expect(DomainCluster.cluster(for: "org.telegram.desktop") == .chat)
        #expect(DomainCluster.cluster(for: "com.hnc.Discord") == .chat)
    }

    @Test("chat pro : Slack/Teams mappés sur .work")
    func workCluster() {
        #expect(DomainCluster.cluster(for: "com.tinyspeck.slackmacgap") == .work)
        #expect(DomainCluster.cluster(for: "com.microsoft.teams") == .work)
        #expect(DomainCluster.cluster(for: "com.microsoft.teams2") == .work)
    }

    @Test("mail : Mail/Outlook/Spark mappés sur .mail")
    func mailCluster() {
        #expect(DomainCluster.cluster(for: "com.apple.mail") == .mail)
        #expect(DomainCluster.cluster(for: "com.microsoft.Outlook") == .mail)
        #expect(DomainCluster.cluster(for: "com.readdle.smartemail-Mac") == .mail)
    }

    @Test("web : Brave/Chrome/Safari/Arc mappés sur .web")
    func webCluster() {
        #expect(DomainCluster.cluster(for: "com.brave.Browser") == .web)
        #expect(DomainCluster.cluster(for: "com.google.Chrome") == .web)
        #expect(DomainCluster.cluster(for: "com.apple.Safari") == .web)
        #expect(DomainCluster.cluster(for: "company.thebrowser.Browser") == .web)
    }

    @Test("docs : Notes/Word/Obsidian/Notion mappés sur .docs")
    func docsCluster() {
        #expect(DomainCluster.cluster(for: "com.apple.Notes") == .docs)
        #expect(DomainCluster.cluster(for: "com.microsoft.Word") == .docs)
        #expect(DomainCluster.cluster(for: "md.obsidian") == .docs)
        #expect(DomainCluster.cluster(for: "notion.id") == .docs)
    }

    @Test("famille par préfixe : tout com.jetbrains.* → .code")
    func jetbrainsPrefix() {
        #expect(DomainCluster.cluster(for: "com.jetbrains.intellij") == .code)
        #expect(DomainCluster.cluster(for: "com.jetbrains.pycharm") == .code)
        #expect(DomainCluster.cluster(for: "com.jetbrains.WebStorm") == .code)
    }

    @Test("nil → .other (pas de scope)")
    func nilIsOther() {
        #expect(DomainCluster.cluster(for: nil) == .other)
    }

    @Test("bundleID inconnu → .other")
    func unknownIsOther() {
        #expect(DomainCluster.cluster(for: "com.acme.UnknownApp") == .other)
        #expect(DomainCluster.cluster(for: "") == .other)
    }

    @Test("apps explicitement fourre-tout → .other (Intercom, Claude, Spotlight)")
    func explicitOtherApps() {
        #expect(DomainCluster.cluster(for: "com.intercom.conversations") == .other)
        #expect(DomainCluster.cluster(for: "com.anthropic.claudefordesktop") == .other)
        #expect(DomainCluster.cluster(for: "com.apple.Spotlight") == .other)
    }
}
