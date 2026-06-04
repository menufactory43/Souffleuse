import Testing
import Foundation
import SouffleuseCore
import SouffleuseCorpus
import SouffleusePersonalization

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

/// Verrouille `DomainCluster.scopedProse` — le **point unique** du scope de
/// personnalisation, partagé désormais par le recall L1 (`SuggestionPolicy`) et
/// le few-shot L2 (`FewShotScoping`). Avant l'extraction, ce prédicat vivait
/// dupliqué dans les deux ; ces tests garantissent que l'invariant (privé jamais
/// hors cluster, `.accept` jamais rappelé, `.other` = pas de scope) reste défini
/// à un seul endroit.
@Suite("DomainCluster.scopedProse — seam unique du scope perso")
struct ScopedProseTests {

    private func prose(_ text: String, _ bundle: String?) -> TypingHistoryEntry {
        TypingHistoryEntry(timestamp: Date(), contextBefore: "", accepted: text,
                           bundleID: bundle, source: .prose)
    }
    private func accept(_ text: String, _ bundle: String?) -> TypingHistoryEntry {
        TypingHistoryEntry(timestamp: Date(), contextBefore: "", accepted: text,
                           bundleID: bundle, source: .accept)
    }

    @Test(".accept toujours exclu, même dans le bon cluster (recall verbatim seulement prose)")
    func acceptAlwaysExcluded() {
        let snap = [prose("votre relevé arrive demain", "com.brave.Browser"),
                    accept("levé arrive demain", "com.brave.Browser")]
        let out = DomainCluster.scopedProse(snap, to: .web)
        #expect(out.count == 1)
        #expect(out.first?.source == .prose)
    }

    @Test("scope cluster : le privé .chat ne fuit jamais hors de son cluster")
    func privateNeverLeaks() {
        let snap = [prose("on se voit ce soir", "org.whispersystems.signal-desktop")]
        #expect(DomainCluster.scopedProse(snap, to: .web).isEmpty)
        #expect(DomainCluster.scopedProse(snap, to: .mail).isEmpty)
        #expect(DomainCluster.scopedProse(snap, to: .chat).count == 1)   // rappelé dans son propre registre
    }

    @Test("activeDomain .other ⇒ aucun scope (comportement historique préservé)")
    func otherNoScope() {
        let snap = [prose("a", "com.brave.Browser"),
                    prose("b", "org.whispersystems.signal-desktop"),
                    accept("c", "com.brave.Browser")]   // .accept toujours filtré, même en .other
        let out = DomainCluster.scopedProse(snap, to: .other)
        #expect(out.count == 2)
    }

    @Test("bundleID nil reste éligible en .other mais jamais dans un cluster connu")
    func nilBundleScoping() {
        let snap = [prose("texte sans app connue", nil)]
        #expect(DomainCluster.scopedProse(snap, to: .other).count == 1)
        #expect(DomainCluster.scopedProse(snap, to: .web).isEmpty)   // nil → .other ≠ .web
    }
}
