import Foundation
import CryptoKit

/// Captures the six prompt slots that, together, define the "invariance window"
/// of a KV cache session. A predict() call may extend a cache cross-keystroke
/// only if every slot here is byte-identical to the previous predict — the only
/// slot allowed to differ is `beforeCursor`, which is intentionally NOT
/// represented in this type (the extension/trim axis per D-KV-03).
///
/// Slot order is FROZEN: changing the ordering changes the on-disk fingerprint
/// and silently invalidates every running session cache. Do not reorder.
public struct InvariancePrefix: Sendable, Equatable {
    /// US (Unit Separator, 0x1F) — non-printable, never occurs in slot bodies,
    /// so joining with it is collision-free w.r.t. concatenation ambiguity.
    private static let separator: Character = "\u{1F}"

    public let system: String
    public let customInstructions: String
    public let contextPrefix: String
    public let fieldContext: String
    public let afterCursor: String
    public let previousUserInputs: String

    public init(
        system: String,
        customInstructions: String,
        contextPrefix: String,
        fieldContext: String,
        afterCursor: String,
        previousUserInputs: String
    ) {
        self.system = system
        self.customInstructions = customInstructions
        self.contextPrefix = contextPrefix
        self.fieldContext = fieldContext
        self.afterCursor = afterCursor
        self.previousUserInputs = previousUserInputs
    }

    /// SHA256 (lower-case hex, 64 chars) of the canonical slot concatenation.
    /// Deterministic by construction — fed solely from constant fields.
    public var fingerprint: String {
        let canonical = [
            system, customInstructions, contextPrefix,
            fieldContext, afterCursor, previousUserInputs,
        ].joined(separator: String(Self.separator))
        let digest = SHA256.hash(data: Data(canonical.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Canonicalise a `previousUserInputs` block before it is fed into
    /// `InvariancePrefix`. `SimilarHistoryRetrieval` returns few-shot entries
    /// in *similarity-ranked* order, which is NOT stable predict-to-predict:
    /// two retrievals with the same content set may return them in different
    /// orders, which would change the fingerprint and silently invalidate
    /// the cache on every predict — defeating the whole phase win.
    ///
    /// Contract: split the block on a known delimiter (the executor in
    /// Plan 03-02 controls this delimiter — typically "\n\n" between
    /// few-shot examples), sort lexicographically, collapse runs of
    /// whitespace within each entry, rejoin. The result is the value
    /// callers should pass as `previousUserInputs:`.
    ///
    /// This is a NORMALISATION layer, not part of the fingerprint itself —
    /// the fingerprint stays byte-faithful. Callers OPT IN by routing
    /// their few-shot string through this helper before construction.
    public static func canonicalizePreviousUserInputs(
        _ raw: String,
        delimiter: String = "\n\n"
    ) -> String {
        if raw.isEmpty { return raw }
        let parts = raw.components(separatedBy: delimiter)
        let normalised = parts
            .map { $0.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ") }
            .filter { !$0.isEmpty }
            .sorted()
        return normalised.joined(separator: delimiter)
    }
}

/// Holds the live KV cache array for a typing session in a single field, plus
/// the fingerprint of the invariant-prefix window the cache currently
/// corresponds to, plus the token count of `beforeCursor` already prefilled
/// into the cache.
///
/// Owned by `PredictorViewModel` (`@MainActor`). The `caches` array stores
/// reference-typed `KVCache`-protocol objects from MLX, which is why the
/// holder itself is a `final class` and `@MainActor`-isolated (mirrors
/// `PredictorViewModel`'s isolation domain).
///
/// **Storage type rationale (Plan 03-01 scope):** the cache element type is
/// kept opaque as `Any` in this plan so the holder can be unit-tested without
/// linking `MLXLMCommon`. Plan 03-02 introduces the typed bridge: it stores
/// real `KVCache` instances and casts them back on retrieval at the
/// `PredictorViewModel` call site. The array shape is preserved so future
/// plans can map/cast each element without restructuring the holder.
@MainActor
public final class KVCacheHolder {
    /// `nil` ⇒ cold (no session active; next predict must rebuild).
    ///
    /// Element type is `Any` to keep this plan free of `MLXLMCommon`. Plan
    /// 03-02 will cast each element back to the `KVCache` protocol at the
    /// MLX call site.
    public private(set) var caches: [Any]?
    /// SHA256 of the invariance prefix `caches` currently represents.
    /// `nil` ⇒ holder is cold.
    public private(set) var fingerprint: String?
    /// Count of `beforeCursor` tokens already prefilled into `caches`.
    /// Used to compute the extend/trim delta per predict (per discovery note
    /// §"Decision tree par predict"). Meaningless when `caches == nil`.
    public private(set) var beforeCursorTokens: Int = 0

    public init() {}

    /// Why the cache became cold this predict. count-only event arg.
    public enum InvalidationReason: Sendable {
        /// Holder was previously `nil` — first predict of this session.
        case cold
        /// Invariance fingerprint changed (any of the 6 invariant slots flipped).
        case fingerprintChanged
        /// `beforeCursor` diverged from the prefilled tokens (paste / cursor jump).
        case beforeCursorDiverged
        /// Caller explicitly invalidated (e.g. swapModel, env-var bypass).
        case explicit
    }

    /// Reset to cold state. Plan 03-02 calls this on `swapModel` + on
    /// fingerprint changes. Wave-3 tests assert this drops `caches` to nil.
    public func invalidate(reason: InvalidationReason) {
        caches = nil
        fingerprint = nil
        beforeCursorTokens = 0
        _ = reason // consumed by caller's Log.info per KV-07
    }

    /// Install a freshly-built cache array along with the fingerprint it was
    /// built for and the token count of the initial beforeCursor prefill.
    ///
    /// The `caches` parameter is `[Any]` so this plan does not depend on
    /// `MLXLMCommon`. Plan 03-02 passes the real `[KVCache]` (which conforms
    /// to `Any`) and downcasts on retrieval.
    public func install(
        caches: [Any],
        fingerprint: String,
        beforeCursorTokens: Int
    ) {
        self.caches = caches
        self.fingerprint = fingerprint
        self.beforeCursorTokens = beforeCursorTokens
    }

    /// Update the prefilled token count after an extend or trim. Plan 03-02
    /// only — does NOT mutate `caches` itself (MLX does that in place).
    public func updateBeforeCursorTokens(_ n: Int) {
        beforeCursorTokens = max(0, n)
    }
}
