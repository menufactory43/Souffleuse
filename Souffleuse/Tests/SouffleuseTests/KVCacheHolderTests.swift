import Testing
import Foundation
@testable import Souffleuse

@Suite("KVCacheHolder + InvariancePrefix")
struct KVCacheHolderTests {

    private func make(
        system: String = "sys",
        customInstructions: String = "ci",
        contextPrefix: String = "ctx",
        fieldContext: String = "fc",
        afterCursor: String = "ac",
        previousUserInputs: String = "pui"
    ) -> InvariancePrefix {
        InvariancePrefix(
            system: system,
            customInstructions: customInstructions,
            contextPrefix: contextPrefix,
            fieldContext: fieldContext,
            afterCursor: afterCursor,
            previousUserInputs: previousUserInputs
        )
    }

    @Test func fingerprintDeterministic() {
        #expect(make().fingerprint == make().fingerprint)
    }

    @Test func fingerprintLengthAndAlphabet() {
        let fp = make().fingerprint
        #expect(fp.count == 64)
        #expect(fp.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil)
    }

    @Test func fingerprintChangesPerSlot_system() {
        #expect(make().fingerprint != make(system: "sys2").fingerprint)
    }
    @Test func fingerprintChangesPerSlot_customInstructions() {
        #expect(make().fingerprint != make(customInstructions: "ci2").fingerprint)
    }
    @Test func fingerprintChangesPerSlot_contextPrefix() {
        #expect(make().fingerprint != make(contextPrefix: "ctx2").fingerprint)
    }
    @Test func fingerprintChangesPerSlot_fieldContext() {
        #expect(make().fingerprint != make(fieldContext: "fc2").fingerprint)
    }
    @Test func fingerprintChangesPerSlot_afterCursor() {
        #expect(make().fingerprint != make(afterCursor: "ac2").fingerprint)
    }
    @Test func fingerprintChangesPerSlot_previousUserInputs() {
        #expect(make().fingerprint != make(previousUserInputs: "pui2").fingerprint)
    }

    /// Unit-separator joining must distinguish `("foo", "bar")` from `("", "foobar")`.
    /// Without a separator both would canonicalise to the same byte string and
    /// the fingerprint would falsely collide → wrong ghost (medium-sev threat T-03-01).
    @Test func fingerprintSeparatorIsAmbiguityFree() {
        let a = InvariancePrefix(system: "foo", customInstructions: "bar",
                                 contextPrefix: "", fieldContext: "",
                                 afterCursor: "", previousUserInputs: "")
        let b = InvariancePrefix(system: "", customInstructions: "foobar",
                                 contextPrefix: "", fieldContext: "",
                                 afterCursor: "", previousUserInputs: "")
        #expect(a.fingerprint != b.fingerprint)
    }

    /// Empty-string slot is NOT the same as a whitespace-only slot: the type
    /// is byte-faithful and DOES NOT normalise its inputs (callers own that).
    @Test func fingerprintEmptyVsWhitespace() {
        let empty = InvariancePrefix(system: "", customInstructions: "",
                                     contextPrefix: "", fieldContext: "",
                                     afterCursor: "", previousUserInputs: "")
        let ws = InvariancePrefix(system: " ", customInstructions: "",
                                  contextPrefix: "", fieldContext: "",
                                  afterCursor: "", previousUserInputs: "")
        #expect(empty.fingerprint != ws.fingerprint)
    }

    /// Warning #2 from plan-checker: SimilarHistoryRetrieval ranks entries by
    /// similarity, not lexicographic order. Two retrievals over the same
    /// content set may return entries in DIFFERENT orders predict-to-predict.
    /// If the raw output is fed directly to `previousUserInputs`, the
    /// fingerprint flips on every predict and the cache is invalidated
    /// constantly — defeating the entire phase win.
    ///
    /// `canonicalizePreviousUserInputs(_:)` must produce IDENTICAL output for
    /// two inputs containing the same entries in different orders.
    @Test func canonicalizePreviousUserInputs_orderInvariant() {
        let a = "user: hello\n\nuser: how are you\n\nuser: goodbye"
        let b = "user: goodbye\n\nuser: hello\n\nuser: how are you"
        let canonA = InvariancePrefix.canonicalizePreviousUserInputs(a)
        let canonB = InvariancePrefix.canonicalizePreviousUserInputs(b)
        #expect(canonA == canonB)
        // And the resulting fingerprints are identical:
        let fpA = InvariancePrefix(system: "", customInstructions: "", contextPrefix: "",
                                   fieldContext: "", afterCursor: "",
                                   previousUserInputs: canonA).fingerprint
        let fpB = InvariancePrefix(system: "", customInstructions: "", contextPrefix: "",
                                   fieldContext: "", afterCursor: "",
                                   previousUserInputs: canonB).fingerprint
        #expect(fpA == fpB)
    }

    /// Whitespace runs are collapsed so that "user:  hello" and "user: hello"
    /// canonicalise to the same form. Trailing trim of empty entries is also
    /// required so a stray "\n\n\n" delimiter run does not introduce empty
    /// shards that would shift the sort order.
    @Test func canonicalizePreviousUserInputs_whitespaceCollapse() {
        let a = "user:   hello   world\n\nuser: foo"
        let b = "user: hello world\n\nuser:  foo"
        #expect(InvariancePrefix.canonicalizePreviousUserInputs(a)
             == InvariancePrefix.canonicalizePreviousUserInputs(b))
    }

    /// Empty input round-trips to empty — no spurious delimiter or shard.
    @Test func canonicalizePreviousUserInputs_emptyIsEmpty() {
        #expect(InvariancePrefix.canonicalizePreviousUserInputs("") == "")
    }

    @MainActor
    @Test func holderStartsCold() {
        let h = KVCacheHolder()
        #expect(h.caches == nil)
        #expect(h.fingerprint == nil)
        #expect(h.beforeCursorTokens == 0)
    }

    @MainActor
    @Test func holderInvalidateClearsState_explicit() {
        let h = KVCacheHolder()
        h.updateBeforeCursorTokens(7)
        #expect(h.beforeCursorTokens == 7)
        h.invalidate(reason: .explicit)
        #expect(h.caches == nil)
        #expect(h.fingerprint == nil)
        #expect(h.beforeCursorTokens == 0)
    }

    @MainActor
    @Test func holderUpdateTokensClamps() {
        let h = KVCacheHolder()
        h.updateBeforeCursorTokens(-3)
        #expect(h.beforeCursorTokens == 0)
    }

    /// `install(...)` snapshots all three fields atomically; subsequent
    /// `invalidate(...)` must clear them all. Element type stays opaque
    /// (`[Any]`) in this plan — Plan 03-02 bridges to `[KVCache]`.
    @MainActor
    @Test func holderInstallThenInvalidate() {
        let h = KVCacheHolder()
        let dummy: [Any] = [NSObject(), NSObject()]
        h.install(caches: dummy, fingerprint: "abc123", beforeCursorTokens: 42)
        #expect(h.caches != nil)
        #expect(h.caches?.count == 2)
        #expect(h.fingerprint == "abc123")
        #expect(h.beforeCursorTokens == 42)

        h.invalidate(reason: .fingerprintChanged)
        #expect(h.caches == nil)
        #expect(h.fingerprint == nil)
        #expect(h.beforeCursorTokens == 0)
    }
}
