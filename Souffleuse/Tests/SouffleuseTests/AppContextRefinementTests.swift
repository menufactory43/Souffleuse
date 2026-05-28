import XCTest
@testable import SouffleuseContext

final class AppContextRefinementTests: XCTestCase {
    // MARK: - displayName (unchanged behavior)

    func testDisplayNamePrefersBundleID() {
        let ctx = AppContext(bundleID: "com.brave.Browser", localizedName: "Brave", windowTitle: nil)
        XCTAssertEqual(ctx.displayName, "com.brave.Browser")
    }

    func testDisplayNameFallsBackToLocalizedName() {
        let ctx = AppContext(bundleID: nil, localizedName: "Brave", windowTitle: nil)
        XCTAssertEqual(ctx.displayName, "Brave")
    }

    // MARK: - promptAppName (new)

    func testPromptAppNamePrefersLocalizedNameOverBundleID() {
        let ctx = AppContext(bundleID: "com.brave.Browser", localizedName: "Brave", windowTitle: "Some page")
        XCTAssertEqual(ctx.promptAppName, "Brave")
    }

    func testPromptAppNameBareBrowserWithoutKnownWebAppKeepsBrowserName() {
        let ctx = AppContext(bundleID: "com.brave.Browser", localizedName: "Brave",
                             windowTitle: "Hacker News")
        XCTAssertEqual(ctx.promptAppName, "Brave")
    }

    func testPromptAppNameDetectsIntercomInBrave() {
        let ctx = AppContext(bundleID: "com.brave.Browser", localizedName: "Brave",
                             windowTitle: "Inbox · Intercom")
        XCTAssertEqual(ctx.promptAppName, "Intercom (support client)")
    }

    func testPromptAppNameDetectsIntercomInSafari() {
        let ctx = AppContext(bundleID: "com.apple.Safari", localizedName: "Safari",
                             windowTitle: "Sophie Martin · facturation · Intercom")
        XCTAssertEqual(ctx.promptAppName, "Intercom (support client)")
    }

    func testPromptAppNameDetectsZendesk() {
        let ctx = AppContext(bundleID: "com.google.Chrome", localizedName: "Chrome",
                             windowTitle: "Tickets - Zendesk")
        XCTAssertEqual(ctx.promptAppName, "Zendesk (support client)")
    }

    func testPromptAppNameDetectsHelpScoutBothSpellings() {
        let withSpace = AppContext(bundleID: "com.brave.Browser", localizedName: "Brave",
                                   windowTitle: "Inbox - Help Scout")
        XCTAssertEqual(withSpace.promptAppName, "Help Scout (support client)")
        let condensed = AppContext(bundleID: "com.brave.Browser", localizedName: "Brave",
                                   windowTitle: "Inbox - HelpScout")
        XCTAssertEqual(condensed.promptAppName, "Help Scout (support client)")
    }

    func testPromptAppNameNativeIntercomNotMisrefined() {
        // Hypothetical native Intercom app — must NOT be wrapped in
        // "(support client)" via the browser path, because the localizedName
        // already conveys the app identity.
        let ctx = AppContext(bundleID: "com.intercom.intercom-mac", localizedName: "Intercom",
                             windowTitle: "Sophie Martin · facturation")
        XCTAssertEqual(ctx.promptAppName, "Intercom")
    }

    func testPromptAppNameEmptyWindowTitleKeepsBrowserName() {
        let ctx = AppContext(bundleID: "com.brave.Browser", localizedName: "Brave",
                             windowTitle: "")
        XCTAssertEqual(ctx.promptAppName, "Brave")
    }

    func testPromptAppNameNoBundleIDOrLocalizedReturnsDash() {
        let ctx = AppContext(bundleID: nil, localizedName: nil, windowTitle: "anything")
        XCTAssertEqual(ctx.promptAppName, "-")
    }

    func testPromptAppNameDetectsGmail() {
        let ctx = AppContext(bundleID: "com.brave.Browser", localizedName: "Brave",
                             windowTitle: "Inbox (12) - me@example.com - Gmail")
        XCTAssertEqual(ctx.promptAppName, "Gmail")
    }

    func testPromptAppNameDetectsNotionSuffix() {
        let ctx = AppContext(bundleID: "com.brave.Browser", localizedName: "Brave",
                             windowTitle: "Roadmap Q3 – Notion")
        XCTAssertEqual(ctx.promptAppName, "Notion")
    }

    // MARK: - Native Intercom edge case: native Intercom test above checks
    // that the localizedName 'Intercom' alone (no browser) returns 'Intercom'.
    // The intent is that customer-support hint is added only when the
    // browser→web-app context is the LLM's only signal.
}
