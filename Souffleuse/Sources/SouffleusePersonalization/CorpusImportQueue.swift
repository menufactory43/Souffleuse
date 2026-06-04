import Foundation

/// Staging payload written by `SouffleuseCorpusSeed` and consumed by
/// `TypingHistoryStore.importPendingIfNeeded`.
///
/// The optional `bundleID` lets the seeder tag imported prose with the app whose
/// writing style it represents, so the prose lands in the right `DomainCluster`
/// at runtime (P2.3) — e.g. importing past support replies as `com.brave.Browser`
/// (`.web`) so they reach the live browser pool instead of an orphan `.other`
/// `com.intercom.conversations` tag. When `bundleID` is `nil` (or when the legacy
/// `[String]` format is on disk), the importer falls back to the default Intercom
/// tag, preserving backward compatibility.
public struct CorpusImportQueue: Codable, Sendable {
    public let bundleID: String?
    public let messages: [String]

    public init(bundleID: String?, messages: [String]) {
        self.bundleID = bundleID
        self.messages = messages
    }
}
