import AppKit
import Foundation
import Testing
@testable import Souffleuse
@testable import SouffleuseLog
@testable import SouffleuseOverlay
@testable import SouffleuseTyping

// MARK: - TypoDetector

@Test func typoLastWordAtCaretIgnoresMidWordCaret() {
    // Caret in the middle of "Bonjuor" → no word boundary, no detection.
    let r = TypoDetector.lastWord(in: "Bonjuor world", before: 4)
    #expect(r == nil)
}

@Test func typoLastWordAtCaretReturnsPrecedingWord() {
    // Caret right after "Bonjuor " → previous word is "Bonjuor".
    guard let r = TypoDetector.lastWord(in: "Bonjuor ", before: 8) else {
        #expect(Bool(false), "expected to find a word")
        return
    }
    #expect(r.word == "Bonjuor")
}

// MARK: - OverlayWindow (ghost rendering geometry)

@MainActor
@Test func overlayEstimatedFontReturnsNilForZeroHeight() {
    #expect(OverlayWindow.estimatedFont(forCaretRectHeight: 0) == nil)
    #expect(OverlayWindow.estimatedFont(forCaretRectHeight: -3) == nil)
}

@MainActor
@Test func overlayEstimatedFontInvertsLineHeightRatio() {
    // Standard system text: line-height ≈ font-size × 1.2.
    // A 18pt line height should give us roughly 15pt.
    let f = OverlayWindow.estimatedFont(forCaretRectHeight: 18)
    #expect(f != nil)
    #expect(abs((f?.pointSize ?? 0) - 15) < 0.5)
}

@MainActor
@Test func overlayEstimatedFontClampsExtremes() {
    // Tiny line heights (e.g. 8pt rect) clamp up to 12pt minimum so the
    // ghost never renders sub-readable.
    let small = OverlayWindow.estimatedFont(forCaretRectHeight: 6)
    #expect((small?.pointSize ?? 0) == 12)
    // Comically tall rects clamp down so a 200pt header doesn't blast a
    // huge ghost onto the screen.
    let huge = OverlayWindow.estimatedFont(forCaretRectHeight: 200)
    #expect((huge?.pointSize ?? 0) == 64)
}

@MainActor
@Test func overlayCorrectCaretRectNoOpForCaretSizedRect() {
    // A thin rect (<= 30 px) is treated as a real caret rect — passed
    // through untouched, no font-measurement correction.
    let rect = CGRect(x: 100, y: 50, width: 1, height: 18)
    let result = OverlayWindow.correctCaretRect(
        rect, hostText: "Bonjour", caretIndex: 7, font: .systemFont(ofSize: 15)
    )
    #expect(result == rect)
}

// MARK: - CaretEstimator (Brave / web fallback positioning)

@MainActor
@Test func caretEstimatorRejectsDegenerateInputs() {
    // Zero-size elementRect → nil (Brave's `(0,900,0x0)` pattern).
    #expect(CaretEstimator.estimateRect(
        in: CGRect(x: 0, y: 900, width: 0, height: 0),
        text: "abc",
        caretIndex: 1
    ) == nil)
    // Out-of-range caretIndex → nil.
    #expect(CaretEstimator.estimateRect(
        in: CGRect(x: 0, y: 0, width: 200, height: 30),
        text: "abc",
        caretIndex: 10
    ) == nil)
    #expect(CaretEstimator.estimateRect(
        in: CGRect(x: 0, y: 0, width: 200, height: 30),
        text: "abc",
        caretIndex: -1
    ) == nil)
}

@MainActor
@Test func caretEstimatorAtFieldStart() {
    // Empty text, caret at 0 → rect at the field's top-left + padding.
    let field = CGRect(x: 100, y: 200, width: 400, height: 30)
    let r = CaretEstimator.estimateRect(in: field, text: "", caretIndex: 0)
    #expect(r != nil)
    #expect(r!.minX == field.minX + CaretEstimator.defaultPadding)
    #expect(r!.minY == field.minY + CaretEstimator.defaultPadding)
    #expect(r!.width == 1)
}

@MainActor
@Test func caretEstimatorAfterSingleLineText() {
    // Single-line "Bonjour" → caret X shifted by measured width of "Bonjour".
    let field = CGRect(x: 100, y: 200, width: 400, height: 30)
    let font = CaretEstimator.defaultFont()
    let text = "Bonjour"
    let r = CaretEstimator.estimateRect(in: field, text: text, caretIndex: text.count, font: font)
    #expect(r != nil)
    let measured = (text as NSString).size(withAttributes: [.font: font]).width
    let expectedX = field.minX + CaretEstimator.defaultPadding + measured
    #expect(abs(r!.minX - expectedX) < 0.5)
    // No wrap → caret still on visual line 0.
    #expect(abs(r!.minY - (field.minY + CaretEstimator.defaultPadding)) < 0.5)
}

@MainActor
@Test func caretEstimatorAfterHardNewline() {
    // "foo\nbar" with caret at end → caret on second visual line, X shifted
    // by measured width of "bar".
    let field = CGRect(x: 0, y: 0, width: 400, height: 60)
    let font = CaretEstimator.defaultFont()
    let text = "foo\nbar"
    let r = CaretEstimator.estimateRect(in: field, text: text, caretIndex: text.count, font: font)
    #expect(r != nil)
    let barWidth = ("bar" as NSString).size(withAttributes: [.font: font]).width
    #expect(abs(r!.minX - (CaretEstimator.defaultPadding + barWidth)) < 0.5)
    let lineHeight = ceil(font.pointSize * CaretEstimator.lineHeightMultiplier)
    let expectedY = CaretEstimator.defaultPadding + lineHeight
    #expect(abs(r!.minY - expectedY) < 0.5)
}

@MainActor
@Test func caretEstimatorSoftWrapsLongLine() {
    // Narrow field forces a long line to wrap. Caret at the end should land
    // on a visual line >= 1.
    let field = CGRect(x: 0, y: 0, width: 80, height: 80)
    let font = CaretEstimator.defaultFont()
    let text = "word1 word2 word3 word4 word5"
    let r = CaretEstimator.estimateRect(in: field, text: text, caretIndex: text.count, font: font)
    #expect(r != nil)
    let lineHeight = ceil(font.pointSize * CaretEstimator.lineHeightMultiplier)
    // Caret must have wrapped at least once → y >= first line height.
    #expect(r!.minY >= CaretEstimator.defaultPadding + lineHeight - 0.5)
}

@MainActor
@Test func caretEstimatorClampsOverflowToFieldBounds() {
    // A pathological case: long single token wider than field. The estimate
    // must stay inside the field's bounds so the ghost never flies away.
    let field = CGRect(x: 100, y: 100, width: 60, height: 30)
    let font = CaretEstimator.defaultFont()
    let text = String(repeating: "a", count: 200)
    let r = CaretEstimator.estimateRect(in: field, text: text, caretIndex: text.count, font: font)
    #expect(r != nil)
    #expect(r!.minX < field.maxX)
    #expect(r!.minX >= field.minX)
}

// MARK: - CaretEstimator with CalibratedMetrics

@MainActor
@Test func caretEstimatorMetricsOverrideDefaultPaddingAndLineHeight() {
    // With calibrated metrics, the caret Y on a hard-wrapped second line
    // should be at the calibrated padding + calibrated lineHeight, NOT
    // the default 14 × lineHeightMultiplier (≈19.6).
    let field = CGRect(x: 0, y: 0, width: 400, height: 200)
    let metrics = CalibratedMetrics(fontPointSize: 18, leftPadding: 12, lineHeight: 30)
    let text = "foo\nbar"
    let r = CaretEstimator.estimateRect(
        in: field,
        text: text,
        caretIndex: text.count,
        font: nil,
        metrics: metrics
    )
    #expect(r != nil)
    // Expected: field.minY + padding + (1 visual line below) * lineHeight.
    let expectedY = field.minY + metrics.leftPadding + metrics.lineHeight
    #expect(abs(r!.minY - expectedY) < 0.5)
    // X must sit past the calibrated left padding.
    #expect(r!.minX >= metrics.leftPadding)
}

@MainActor
@Test func caretEstimatorMetricsClampFontPointSize() {
    // Extreme inputs to the struct must clamp.
    let tiny = CalibratedMetrics(fontPointSize: 4, leftPadding: 0, lineHeight: 4)
    #expect(tiny.fontPointSize == 10)
    let huge = CalibratedMetrics(fontPointSize: 500, leftPadding: -3, lineHeight: 0)
    #expect(huge.fontPointSize == 64)
    #expect(huge.leftPadding == 0)
    // lineHeight floor = fontPointSize (clamped).
    #expect(huge.lineHeight == 64)
}

@MainActor
@Test func caretEstimatorWithNilMetricsBehavesLikeLegacyAPI() {
    // Same call with metrics=nil must produce the same result as the
    // legacy single-argument overload.
    let field = CGRect(x: 50, y: 60, width: 400, height: 30)
    let text = "Bonjour"
    let legacy = CaretEstimator.estimateRect(in: field, text: text, caretIndex: text.count)
    let modern = CaretEstimator.estimateRect(in: field, text: text, caretIndex: text.count, font: nil, metrics: nil)
    #expect(legacy == modern)
}

@MainActor
@Test func overlayCorrectCaretRectShiftsByMeasuredWidth() {
    // Wide rect (Notes-style line rect) → origin.x is the line start; the
    // corrected rect should land at line-start + measured-width-of-prefix.
    let lineStart: CGFloat = 50
    let lineRect = CGRect(x: lineStart, y: 100, width: 400, height: 18)
    let font = NSFont.systemFont(ofSize: 15)
    let text = "Bonjour, je"
    let result = OverlayWindow.correctCaretRect(
        lineRect, hostText: text, caretIndex: text.count, font: font
    )
    let measured = (text as NSString).size(withAttributes: [.font: font]).width
    #expect(abs(result.origin.x - (lineStart + measured)) < 0.5)
    #expect(result.width == 1)
}

// MARK: - TypoDetector

@Test func typoLevenshteinIsCorrect() {
    #expect(TypoDetector.levenshtein("kitten", "sitting") == 3)
    // Transposition u↔o counts as 2 substitutions in pure Levenshtein.
    #expect(TypoDetector.levenshtein("Bonjuor", "Bonjour") == 2)
    // Single insertion is distance 1.
    #expect(TypoDetector.levenshtein("Bonjor", "Bonjour") == 1)
    #expect(TypoDetector.levenshtein("", "abc") == 3)
    #expect(TypoDetector.levenshtein("abc", "abc") == 0)
}

// MARK: - EmojiExpander

@Test func emojiDetectsValidShortcodeWithSpace() {
    let r = EmojiExpander.detect(textBeforeCaret: "hello :smile: ")
    #expect(r?.insert == "😄 ")
    #expect(r?.shortcode == "smile")
    #expect(r?.deleteChars == ":smile: ".count)
}

@Test func emojiDetectsValidShortcodeWithNewline() {
    let r = EmojiExpander.detect(textBeforeCaret: "wow :tada:\n")
    #expect(r?.insert == "🎉\n")
}

@Test func emojiRejectsWithoutTrailingTrigger() {
    #expect(EmojiExpander.detect(textBeforeCaret: ":smile:") == nil)
}

@Test func emojiRejectsUnknownShortcode() {
    #expect(EmojiExpander.detect(textBeforeCaret: ":notarealemoji: ") == nil)
}

@Test func emojiRejectsCxxScopeOperator() {
    // `std::vector` after a space should not be misread as a shortcode.
    #expect(EmojiExpander.detect(textBeforeCaret: "std::vector ") == nil)
}

@Test func emojiCaseInsensitiveLookup() {
    let r = EmojiExpander.detect(textBeforeCaret: ":SMILE: ")
    #expect(r?.insert == "😄 ")
}


@Test func allowlistBundleOnlyRuleMatchesAnyTitle() {
    let rules = [AllowlistRule(bundleID: "com.apple.mail", mode: .disabled)]
    #expect(AllowlistStore.mode(forBundle: "com.apple.mail", windowTitle: "anything", rules: rules) == .disabled)
    #expect(AllowlistStore.mode(forBundle: "com.apple.mail", windowTitle: nil, rules: rules) == .disabled)
    #expect(AllowlistStore.mode(forBundle: "com.apple.Notes", windowTitle: nil, rules: rules) == .active)
}

@Test func allowlistRegexMatchesOnlyMatchingTitle() {
    let rules = [
        AllowlistRule(bundleID: "com.apple.Safari", titleRegex: "^Banque", mode: .disabled),
        AllowlistRule(bundleID: "com.apple.Safari", mode: .clipboardOnly),
    ]
    #expect(AllowlistStore.mode(forBundle: "com.apple.Safari", windowTitle: "Banque Boursorama", rules: rules) == .disabled)
    // Falls through to the bundle-only rule when the regex doesn't match.
    #expect(AllowlistStore.mode(forBundle: "com.apple.Safari", windowTitle: "Hacker News", rules: rules) == .clipboardOnly)
}

@Test func allowlistInvalidRegexIsIgnoredNotFatal() {
    let rules = [AllowlistRule(bundleID: "com.apple.mail", titleRegex: "[unclosed", mode: .disabled)]
    // Invalid regex → rule is skipped → falls through to default.
    #expect(AllowlistStore.mode(forBundle: "com.apple.mail", windowTitle: "Re: Invoice", rules: rules) == .active)
}

@MainActor
@Test func allowlistRoundTripsToDisk() throws {
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("souffleuse-allowlist-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: tmp) }

    let store = AllowlistStore(fileURL: tmp)
    #expect(store.rules.isEmpty)

    let r1 = AllowlistRule(bundleID: "com.apple.mail", mode: .disabled)
    let r2 = AllowlistRule(bundleID: "com.apple.Safari", titleRegex: "^Banque", mode: .clipboardOnly)
    store.upsert(r1)
    store.upsert(r2)

    let reload = AllowlistStore(fileURL: tmp)
    #expect(reload.rules.count == 2)
    let mail = reload.rules.first { $0.bundleID == "com.apple.mail" }
    let safari = reload.rules.first { $0.bundleID == "com.apple.Safari" }
    #expect(mail?.mode == .disabled)
    #expect(safari?.mode == .clipboardOnly)
    #expect(safari?.titleRegex == "^Banque")

    reload.delete(r1.id)
    let reload2 = AllowlistStore(fileURL: tmp)
    #expect(reload2.rules.count == 1)
    #expect(reload2.rules.first?.bundleID == "com.apple.Safari")
}

@MainActor
@Test func allowlistCorruptFileResetsToEmpty() throws {
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("souffleuse-allowlist-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: tmp) }
    try "{ not valid json".data(using: .utf8)!.write(to: tmp)

    let store = AllowlistStore(fileURL: tmp)
    #expect(store.rules.isEmpty)
}

@Test func logWritesJSONLWithWhitelistedFieldsOnly() async throws {
    let logURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/Souffleuse.log")
    // Don't clobber an active log; only verify by reading the tail after a write.
    let beforeSize = (try? FileManager.default.attributesOfItem(atPath: logURL.path)[.size] as? Int) ?? 0

    Log.info(.ui, "unit_test_marker")
    Log.warn(.predictor, "model_load_failed")
    Log.error(.input, "key_interceptor_install_failed", count: 3)

    // Writer is async; give it a beat.
    try await Task.sleep(nanoseconds: 300_000_000)

    let data = try Data(contentsOf: logURL)
    let suffix = data.suffix(data.count - beforeSize)
    let text = String(decoding: suffix, as: UTF8.self)
    let lines = text.split(separator: "\n").filter { !$0.isEmpty }
    #expect(lines.count >= 3)

    let allowed: Set<String> = ["ts", "level", "module", "event", "count"]
    for line in lines.suffix(3) {
        let obj = try JSONSerialization.jsonObject(with: Data(line.utf8)) as! [String: Any]
        for key in obj.keys {
            #expect(allowed.contains(key), "unexpected field: \(key)")
        }
        #expect(obj["ts"] is String)
        #expect(["info", "warn", "error"].contains(obj["level"] as? String ?? ""))
    }
}

// MARK: - PredictorViewModel prefix→suggestion cache

@MainActor
@Test func predictCacheStoresAndRetrievesEntry() {
    let p = PredictorViewModel()
    p.cache.store(prefix: "hello", suggestion: " world")
    #expect(p.cache.predictCacheSnapshot["hello"] == " world")
    #expect(p.cache.predictCacheOrderSnapshot == ["hello"])
}

@MainActor
@Test func predictCacheStoresEmptySuggestion() {
    // Empty result is a valid memo — known-sterile prefix shouldn't
    // re-trigger the LLM on a retry.
    let p = PredictorViewModel()
    p.cache.store(prefix: "stérile", suggestion: "")
    #expect(p.cache.predictCacheSnapshot["stérile"] == "")
    #expect(p.cache.predictCacheOrderSnapshot == ["stérile"])
}

@MainActor
@Test func predictCacheUpdatesExistingKeyWithoutReordering() {
    // Re-store on an existing key should overwrite the value without
    // bumping its position — FIFO order is preserved so old keys still
    // age out predictably.
    let p = PredictorViewModel()
    p.cache.store(prefix: "a", suggestion: "1")
    p.cache.store(prefix: "b", suggestion: "2")
    p.cache.store(prefix: "a", suggestion: "1-updated")
    #expect(p.cache.predictCacheSnapshot["a"] == "1-updated")
    #expect(p.cache.predictCacheOrderSnapshot == ["a", "b"])
}

@MainActor
@Test func predictCacheRespectsCapacityAndEvictsFIFO() {
    let p = PredictorViewModel()
    let capacity = CompletionCache.predictCacheCapacity
    // Fill the cache to capacity.
    for i in 0..<capacity {
        p.cache.store(prefix: "key\(i)", suggestion: "val\(i)")
    }
    #expect(p.cache.predictCacheSnapshot.count == capacity)
    #expect(p.cache.predictCacheOrderSnapshot.count == capacity)
    #expect(p.cache.predictCacheSnapshot["key0"] == "val0")

    // Insert one more → oldest (key0) should evict.
    p.cache.store(prefix: "newkey", suggestion: "newval")
    #expect(p.cache.predictCacheSnapshot.count == capacity)
    #expect(p.cache.predictCacheSnapshot["key0"] == nil)
    #expect(p.cache.predictCacheSnapshot["newkey"] == "newval")
    #expect(p.cache.predictCacheOrderSnapshot.first == "key1")
    #expect(p.cache.predictCacheOrderSnapshot.last == "newkey")
}

@MainActor
@Test func clearPredictCacheRemovesAllEntries() {
    let p = PredictorViewModel()
    p.cache.store(prefix: "a", suggestion: "1")
    p.cache.store(prefix: "b", suggestion: "2")
    p.clearPredictCache()
    #expect(p.cache.predictCacheSnapshot.isEmpty)
    #expect(p.cache.predictCacheOrderSnapshot.isEmpty)
}

@MainActor
@Test func cancelPreservesPredictCache() {
    // Regression: cancel() must NOT clear the cache. It is called on every
    // Tab accept, live-consume, typo flag, etc. Wiping the cache there would
    // defeat undo-as-ghost — user accepts "world", deletes "ld" to refine,
    // expects to see "ld" restored as ghost. That only works if the longer
    // cached key survives the accept-time cancel().
    let p = PredictorViewModel()
    p.cache.store(prefix: "ferme d'an", suggestion: "imer, un générateur a")
    p.cancel()
    #expect(p.cache.predictCacheSnapshot["ferme d'an"] == "imer, un générateur a")
    #expect(p.cache.predictCacheOrderSnapshot == ["ferme d'an"])
    // suggestion is wiped so the overlay stops showing it
    #expect(p.suggestion == "")
}

@MainActor
@Test func cancelClearsActiveSuggestion() {
    // cancel() still wipes the visible ghost — only the cache survives.
    let p = PredictorViewModel()
    p.suggestion = "anything"
    p.cancel()
    #expect(p.suggestion == "")
}

// MARK: - Undo-as-ghost via longest-prefix cache lookup

@MainActor
@Test func cacheLongestPrefixMatchReturnsCorrectDelta() {
    let vm = PredictorViewModel()
    vm.cache.store(prefix: "donc j'ai besoin d'aide", suggestion: "pour avancer.")
    // Simulate the lookup logic manually since `predict` is async / heavy.
    // Find longest key starting with "donc j'ai besoin d":
    let userTail = "donc j'ai besoin d"
    let candidates = vm.cache.predictCacheSnapshot.keys.filter {
        $0.count > userTail.count && $0.hasPrefix(userTail)
    }
    let longest = candidates.max(by: { $0.count < $1.count })
    #expect(longest == "donc j'ai besoin d'aide")
    let delta = String((longest ?? "").dropFirst(userTail.count))
    #expect(delta == "'aide")
}

@MainActor
@Test func cacheLongestPrefixPicksTheLongestOfMultipleMatches() {
    let vm = PredictorViewModel()
    vm.cache.store(prefix: "Bonjour je", suggestion: "vais bien")
    vm.cache.store(prefix: "Bonjour je suis", suggestion: "Gabriel")
    vm.cache.store(prefix: "Bonjour je suis Gabriel", suggestion: "et toi?")
    let userTail = "Bonjour je"
    let candidates = vm.cache.predictCacheSnapshot.keys.filter {
        $0.count > userTail.count && $0.hasPrefix(userTail)
    }
    let longest = candidates.max(by: { $0.count < $1.count })
    #expect(longest == "Bonjour je suis Gabriel")
}

@MainActor
@Test func cacheNoLongerKeyMeansNoUndoCandidate() {
    let vm = PredictorViewModel()
    vm.cache.store(prefix: "Bonjour", suggestion: "monde")
    let userTail = "Salut"
    let candidates = vm.cache.predictCacheSnapshot.keys.filter {
        $0.count > userTail.count && $0.hasPrefix(userTail)
    }
    #expect(candidates.isEmpty)
}
