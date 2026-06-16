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
@Test func overlayEstimatedFontSplitsWebCaretRectVariance() {
    // ÷1,15 — la hauteur du rect AX est la *boîte de ligne*, pas la police.
    // Mesuré au pixel le 13/06/2026 (ghost vs cap-height du texte hôte) dans
    // les deux hôtes sans police AX : Signal (Electron, caret 17px → ~15pt) et
    // Intercom/Brave (Chromium) — les deux convergent à ~1,15. L'ancien 1,27
    // rendait le ghost ~10–15 % trop petit. 18 → ~15,65.
    let f = OverlayWindow.estimatedFont(forCaretRectHeight: 18)
    #expect(f != nil)
    #expect(abs((f?.pointSize ?? 0) - 18.0 / OverlayWindow.caretRectToFontRatio) < 0.01)
}

@MainActor
@Test func overlayEstimatedFontClampsExtremes() {
    // Tiny line heights (e.g. 6pt rect) clamp up to the 11pt minimum so the
    // ghost never renders sub-readable.
    let small = OverlayWindow.estimatedFont(forCaretRectHeight: 6)
    #expect((small?.pointSize ?? 0) == 11)
    // Degenerate line-box rects on empty lines (e.g. 200pt) are capped at
    // 20pt — a conservative ceiling so the ghost never blows up. The
    // per-bundle reliable-font cache (SouffleuseAppDelegate) is the primary
    // mitigation; this clamp is the safety net.
    let huge = OverlayWindow.estimatedFont(forCaretRectHeight: 200)
    #expect((huge?.pointSize ?? 0) == 20)
}

@MainActor
@Test func overlayUsableWordRectRejectsDegenerate() {
    // A real word rect (some extent, finite, on-screen) is usable for the
    // in-place strike. Zero/placeholder rects from web hosts and absurdly
    // large/non-finite returns must fall back to the caret-anchored hint.
    #expect(OverlayWindow.isUsableWordRect(CGRect(x: 100, y: 200, width: 48, height: 18)))
    #expect(!OverlayWindow.isUsableWordRect(.zero))
    #expect(!OverlayWindow.isUsableWordRect(CGRect(x: 0, y: 0, width: 1, height: 18)))
    #expect(!OverlayWindow.isUsableWordRect(CGRect(x: 0, y: 0, width: 48, height: 1)))
    #expect(!OverlayWindow.isUsableWordRect(CGRect(x: 0, y: 0, width: 9000, height: 18)))
    #expect(!OverlayWindow.isUsableWordRect(CGRect(x: CGFloat.infinity, y: 0, width: 48, height: 18)))
}

// MARK: - OverlayWindow mid-line pill geometry

@MainActor
@Test func overlayPillFrameSizesWithPadding() {
    // The pill is a padded box: content size + hPad/vPad on each side, and its
    // left edge is inset by hPad so the suggestion text starts under the caret.
    let font = NSFont.systemFont(ofSize: 15)
    let text = "mon premier post sur le"
    let caret = CGRect(x: 120, y: 200, width: 1, height: 18)
    let f = OverlayWindow.pillFrame(belowCaret: caret, text: text, font: font)
    let textSize = (text as NSString).size(withAttributes: [.font: font])
    #expect(f.width == ceil(textSize.width) + PillView.hPad * 2)
    #expect(f.height == ceil(textSize.height) + PillView.vPad * 2)
    #expect(f.origin.x == caret.origin.x - PillView.hPad)
}

@MainActor
@Test func overlayPillFrameClampsToLeftEdge() {
    // A caret near the left edge must not push the pill off-screen (negative x):
    // the inset is clamped at 0.
    let font = NSFont.systemFont(ofSize: 15)
    let caret = CGRect(x: 3, y: 200, width: 1, height: 18)
    let f = OverlayWindow.pillFrame(belowCaret: caret, text: "x", font: font)
    #expect(f.origin.x == 0)
}

@MainActor
@Test func overlayPillFrameTypedFragmentShiftsLeftAndWidens() {
    // Le fragment du mot en cours (`typed`) est mesuré DANS la largeur et décale
    // la pill vers la gauche de sa propre largeur : le fragment se lit sous ses
    // glyphes, la suggestion reste alignée sous le caret.
    let font = NSFont.systemFont(ofSize: 15)
    let caret = CGRect(x: 120, y: 200, width: 1, height: 18)
    let bare = OverlayWindow.pillFrame(belowCaret: caret, text: "he demain", font: font)
    let withTyped = OverlayWindow.pillFrame(belowCaret: caret, text: "he demain", typed: "couc", font: font)
    let typedWidth = ceil(("couc" as NSString).size(withAttributes: [.font: font]).width)
    let fullWidth = ceil(("couche demain" as NSString).size(withAttributes: [.font: font]).width)
    #expect(withTyped.width == fullWidth + PillView.hPad * 2)
    #expect(withTyped.origin.x == bare.origin.x - typedWidth)
    // Toujours clampé au bord gauche de l'écran.
    let clamped = OverlayWindow.pillFrame(belowCaret: CGRect(x: 3, y: 200, width: 1, height: 18),
                                          text: "he", typed: "couc", font: font)
    #expect(clamped.origin.x == 0)
}

@MainActor
@Test func overlayPillFrameHangsBelowCaretLine() {
    // Quartz Y grows downward; a caret one line lower (greater maxY) drops the
    // pill's AppKit y by exactly the same delta — the pill tracks the caret line.
    let font = NSFont.systemFont(ofSize: 15)
    let a = OverlayWindow.pillFrame(belowCaret: CGRect(x: 50, y: 100, width: 1, height: 18), text: "abc", font: font)
    let b = OverlayWindow.pillFrame(belowCaret: CGRect(x: 50, y: 140, width: 1, height: 18), text: "abc", font: font)
    #expect(abs((a.origin.y - b.origin.y) - 40) < 0.001)
}

// MARK: - OverlayWindow (wrap multi-ligne)

@MainActor
@Test func overlayIsUsableElementRectAcceptsValidRect() {
    // Un rect de champ sain avec le caret DANS sa largeur → usable.
    let field = CGRect(x: 50, y: 100, width: 400, height: 300)
    let caretX: CGFloat = 200 // bien dans [50, 450]
    #expect(OverlayWindow.isUsableElementRect(field, caretX: caretX))
}

@MainActor
@Test func overlayIsUsableElementRectRejectsZeroOrNarrow() {
    // rect.zero / width trop faible → inutilisable.
    #expect(!OverlayWindow.isUsableElementRect(.zero, caretX: 0))
    #expect(!OverlayWindow.isUsableElementRect(CGRect(x: 50, y: 100, width: 1, height: 300), caretX: 50))
}

@MainActor
@Test func overlayIsUsableElementRectRejectsAberrant() {
    // Largeur aberrante ou origines non finies → inutilisable.
    #expect(!OverlayWindow.isUsableElementRect(CGRect(x: 50, y: 100, width: 5000, height: 300), caretX: 200))
    #expect(!OverlayWindow.isUsableElementRect(CGRect(x: CGFloat.infinity, y: 100, width: 400, height: 300), caretX: 200))
    #expect(!OverlayWindow.isUsableElementRect(CGRect(x: 50, y: 100, width: CGFloat.infinity, height: 300), caretX: 200))
}

@MainActor
@Test func overlayIsUsableElementRectRejectsCaretOutsideField() {
    // Le caret hors de la largeur du champ → on n'accroche pas le wrap sur ce champ.
    let field = CGRect(x: 50, y: 100, width: 400, height: 300) // minX=50, maxX=450
    #expect(!OverlayWindow.isUsableElementRect(field, caretX: 10))  // à gauche
    #expect(!OverlayWindow.isUsableElementRect(field, caretX: 500)) // à droite
}

@MainActor
@Test func overlayWrapFrameWidthEqualsFieldWidth() {
    // La largeur du panneau wrap == ceil(fieldRect.width).
    let font = NSFont.systemFont(ofSize: 15)
    let caret = CGRect(x: 120, y: 200, width: 1, height: 18)
    let field = CGRect(x: 50, y: 100, width: 380, height: 200)
    let (frame, _) = OverlayWindow.wrapFrame(forGhostAfterCaret: caret, fieldRect: field,
                                              text: "Bonjour à tous et bienvenue", font: font)
    #expect(frame.width == ceil(field.width))
}

@MainActor
@Test func overlayWrapFrameFirstLineIndentStartsAtCaret() {
    // L'indentation de la 1re ligne = distance entre le bord gauche du champ et le caret.
    let font = NSFont.systemFont(ofSize: 15)
    let caret = CGRect(x: 120, y: 200, width: 1, height: 18)
    let field = CGRect(x: 50, y: 100, width: 380, height: 200)
    let (_, firstLineIndent) = OverlayWindow.wrapFrame(forGhostAfterCaret: caret, fieldRect: field,
                                                        text: "Bonjour", font: font)
    #expect(firstLineIndent == max(0, caret.origin.x - field.minX))
}

@MainActor
@Test func overlayWrapFrameOriginAlignedToFieldLeft() {
    // Le bord gauche du panneau doit être aligné sur le bord gauche du champ.
    // Le TOP du panneau doit correspondre à la ligne du caret (appKitY = primaryHeight - caret.origin.y - height).
    let font = NSFont.systemFont(ofSize: 15)
    let caret = CGRect(x: 120, y: 200, width: 1, height: 18)
    let field = CGRect(x: 50, y: 100, width: 380, height: 200)
    let text = "Bonjour"
    let (frame, _) = OverlayWindow.wrapFrame(forGhostAfterCaret: caret, fieldRect: field, text: text, font: font)
    let primaryHeight = NSScreen.screens.first?.frame.height ?? NSScreen.main?.frame.height ?? 0
    // X aligné sur le bord gauche du champ (coords AppKit).
    #expect(frame.origin.x == field.minX)
    // appKitY = primaryHeight - caret.origin.y - height (TOP-anchored sur la ligne du caret).
    #expect(abs(frame.origin.y - (primaryHeight - caret.origin.y - frame.height)) < 0.001)
}

@MainActor
@Test func overlayWrapFrameHeightCoversWrappedLines() {
    // Un texte long wrap sur plusieurs lignes → height >= caret.height et >= hauteur d'une ligne seule.
    let font = NSFont.systemFont(ofSize: 15)
    let caret = CGRect(x: 300, y: 200, width: 1, height: 18) // caret proche du bord droit
    let field = CGRect(x: 50, y: 100, width: 320, height: 200)  // champ étroit
    // Texte assez long pour déborder sur la largeur restante (320 - (300-50) = 70px disponibles).
    let text = "suggestion très longue qui devrait enrouler à la ligne suivante dans le champ"
    let (frame, _) = OverlayWindow.wrapFrame(forGhostAfterCaret: caret, fieldRect: field, text: text, font: font)
    #expect(frame.height >= caret.height)
    // Le texte DOIT prendre au moins 2 lignes (vérifie que le wrap a eu lieu).
    let singleLineSize = (text as NSString).size(withAttributes: [.font: font])
    #expect(frame.height > ceil(singleLineSize.height), "le texte doit enrouler sur plusieurs lignes")
}

// MARK: - SouffleuseAppDelegate mid-line accept plan (fusion avec l'existant)

@MainActor
@Test func midLineAcceptPlanSkipsExistingWordLetters() {
    // « p|our » + Tab « our » : les lettres existent déjà → saut pur, zéro injection.
    let t = SouffleuseAppDelegate.midLineAcceptPlan(chunk: "our", afterCaret: "our reste")
    #expect(t.ops == [.skip(3)])
    #expect(t.effective == "our")
    // Avec « espace après chaque mot » (Tab partiel « our ») : l'espace du chunk
    // FUSIONNE avec l'espace existant (pas de double espace).
    let u = SouffleuseAppDelegate.midLineAcceptPlan(chunk: "our ", afterCaret: "our reste")
    #expect(u.ops == [.skip(4)])
    #expect(u.effective == "our ")
}

@MainActor
@Test func midLineAcceptPlanWeavesNewWordIntoExistingText() {
    // Le cas de l'écran : « m'ai|der  trouver mon rapport fiscal. » + ghost
    // « der à trouver » — « der » et « trouver » existent déjà, seul « à »
    // manque. Le plan saute l'existant et n'injecte QUE le « à », en réutilisant
    // les deux espaces existants comme séparateurs.
    let p = SouffleuseAppDelegate.midLineAcceptPlan(
        chunk: "der à trouver", afterCaret: "der  trouver mon rapport fiscal.")
    #expect(p.ops == [.skip(4), .inject("à"), .skip(8)])
    #expect(p.effective == "der à trouver")
    // Le même en walk Tab mot-par-mot : chaque chunk replanifie sur l'AX frais.
    let t1 = SouffleuseAppDelegate.midLineAcceptPlan(chunk: "der ", afterCaret: "der  trouver mon")
    #expect(t1.ops == [.skip(4)])      // « der » + 1 espace fusionné
    let t2 = SouffleuseAppDelegate.midLineAcceptPlan(chunk: "à ", afterCaret: " trouver mon")
    #expect(t2.ops == [.inject("à"), .skip(1)])
    let t3 = SouffleuseAppDelegate.midLineAcceptPlan(chunk: "trouver", afterCaret: "trouver mon")
    #expect(t3.ops == [.skip(7)])
}

@MainActor
@Test func midLineAcceptPlanBoundaryAndEndOfLine() {
    // End-of-line (rien après le caret) → une seule injection, byte-identique.
    let c = SouffleuseAppDelegate.midLineAcceptPlan(chunk: "our suite", afterCaret: "")
    #expect(c.ops == [.inject("our suite")])
    #expect(c.effective == "our suite")
    // Frontière « word| reste » + ghost « votre… » : insertion, avec la couture
    // qui rétablit le séparateur devant le mot existant.
    let a = SouffleuseAppDelegate.midLineAcceptPlan(chunk: " votre", afterCaret: " reste")
    #expect(a.ops == [.skip(1), .inject("votre ")])
    #expect(a.effective == " votre ")
}

@MainActor
@Test func midLineAcceptPlanSkipsSegmentsCarryingPunctuation() {
    // UAT 11/06 : « Mientras esperas, ¿podrías… » déjà présent après le caret —
    // le 2ᵉ Tab (chunk « esperas, ») doit SAUTER le segment identique malgré la
    // virgule ; l'ancienne garde isWordChar le rendait inmatchable et le
    // ré-injectait (« esperas, esperas, »).
    let p = SouffleuseAppDelegate.midLineAcceptPlan(
        chunk: "esperas, ", afterCaret: "esperas, ¿podrías contarme")
    #expect(p.ops == [.skip(9)])
    #expect(p.effective == "esperas, ")
    // Ponctuation d'OUVERTURE espagnole portée par le segment.
    let q = SouffleuseAppDelegate.midLineAcceptPlan(
        chunk: "¿podrías ", afterCaret: "¿podrías contarme")
    #expect(q.ops == [.skip(9)])
    #expect(q.effective == "¿podrías ")
    // Garde-fou intact : « de » ne matche toujours pas « demain » (frontière) —
    // injection, plus la couture qui pose le séparateur devant le mot existant.
    let r = SouffleuseAppDelegate.midLineAcceptPlan(chunk: "de", afterCaret: "demain")
    #expect(r.ops == [.inject("de ")])
}

@MainActor
@Test func midLineAcceptPlanDropsTrailingSeparatorBeforePunctuation() {
    // Le cas de l'écran : « …un hom|me. » + ghost « me qui m… », Tab « me  » :
    // « me » existe → saut pur ; l'espace de fin du chunk collé au point existant
    // est JETÉ (pas de « homme . »), et surtout pas injecté à l'ancienne position
    // (« hom me. »).
    let p = SouffleuseAppDelegate.midLineAcceptPlan(chunk: "me ", afterCaret: "me.")
    #expect(p.ops == [.skip(2)])
    #expect(p.effective == "me")
    // En fin de champ (rien après le mot sauté), l'espace de continuation reste.
    let q = SouffleuseAppDelegate.midLineAcceptPlan(chunk: "me ", afterCaret: "me")
    #expect(q.ops == [.skip(2), .inject(" ")])
    #expect(q.effective == "me ")
    // Entre deux mots, le séparateur reste indispensable : « qui » inséré avant
    // le point existant garde son espace de tête, pas celui de queue.
    let r = SouffleuseAppDelegate.midLineAcceptPlan(chunk: " qui", afterCaret: ".")
    #expect(r.ops == [.inject(" qui")])
}

@MainActor
@Test func midLineAcceptPlanWordBoundaryGuards() {
    // « de » ne matche PAS « demain » (le mot existant continue) : tout est
    // injecté, pas de mot existant éventré.
    let b = SouffleuseAppDelegate.midLineAcceptPlan(chunk: "de quoi ", afterCaret: "demain")
    #expect(b.effective == "de quoi ")
    #expect(b.ops == [.inject("de quoi ")])
    // Casse pliée : « Our » saute devant « our… » et le préfixe effectif garde la
    // casse EXISTANTE (l'égalité stricte du walk en dépend).
    let d = SouffleuseAppDelegate.midLineAcceptPlan(chunk: "Our suite", afterCaret: "our reste")
    #expect(d.effective.hasPrefix("our"))
    // Divergence dès la 1ʳᵉ lettre → injection (+ couture séparatrice).
    let e = SouffleuseAppDelegate.midLineAcceptPlan(chunk: "ropose", afterCaret: "our reste")
    #expect(e.ops == [.inject("ropose ")])
}

// MARK: - SouffleuseAppDelegate mid-text suppression

@MainActor
@Test func midTextSuppressionRule() {
    // Rule: suppress when non-whitespace remains on the CURRENT line after the
    // caret (scan stops at the first newline).
    // Caret inside "hello" (next char 'l', more follows) → suppress.
    #expect(SouffleuseAppDelegate.shouldSuppressForCaretContext(text: "hello", caretIndex: 2))
    // Caret at position 0, whole word follows → suppress.
    #expect(SouffleuseAppDelegate.shouldSuppressForCaretContext(text: "hello", caretIndex: 0))
    // Caret clicked between two words (lands before the inter-word space),
    // "world" still follows on the same line → suppress (the "edit mid-text" case).
    #expect(SouffleuseAppDelegate.shouldSuppressForCaretContext(text: "hello world", caretIndex: 5))
    // Caret at END of first line, "line two" is BELOW (after newline) →
    // do NOT suppress (appending at end of a line, signature beneath is fine).
    #expect(!SouffleuseAppDelegate.shouldSuppressForCaretContext(text: "line one\nline two", caretIndex: 8))
    // Caret mid-first-line ("one" still follows before the newline) → suppress.
    #expect(SouffleuseAppDelegate.shouldSuppressForCaretContext(text: "line one\nline two", caretIndex: 5))
    // Caret at end of text (nothing after) → do NOT suppress.
    #expect(!SouffleuseAppDelegate.shouldSuppressForCaretContext(text: "hello", caretIndex: 5))
    // Caret before ONLY trailing whitespace on the line → do NOT suppress.
    #expect(!SouffleuseAppDelegate.shouldSuppressForCaretContext(text: "hello   ", caretIndex: 5))
    // Caret before a trailing newline only → do NOT suppress.
    #expect(!SouffleuseAppDelegate.shouldSuppressForCaretContext(text: "hello\n", caretIndex: 5))
    // Empty text, caret at 0 → do NOT suppress.
    #expect(!SouffleuseAppDelegate.shouldSuppressForCaretContext(text: "", caretIndex: 0))
    // Out-of-range (negative) → defensive false, no crash.
    #expect(!SouffleuseAppDelegate.shouldSuppressForCaretContext(text: "hello", caretIndex: -1))
    // Out-of-range (beyond count) → defensive false, no crash.
    #expect(!SouffleuseAppDelegate.shouldSuppressForCaretContext(text: "hello", caretIndex: 10))
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

@Test func typoDistancePrefersTransposition() {
    // A transposition costs less than a substitution, so candidate ranking picks
    // the transposition-fix: "sius" → "suis" (swap i,u) beats "sius" → "sous"
    // (substitute i→o), even though plain Levenshtein has sous closer.
    #expect(TypoDetector.typoDistance("suis", "sius") < TypoDetector.typoDistance("sous", "sius"))
    #expect(TypoDetector.levenshtein("sous", "sius") < TypoDetector.levenshtein("suis", "sius")) // baseline was inverted
    // "form" → "from" (transposition) beats "for" (deletion).
    #expect(TypoDetector.typoDistance("from", "form") < TypoDetector.typoDistance("for", "form"))
    // One adjacent transposition is exactly the weighted cost; identity is 0;
    // a plain substitution is 1.
    #expect(TypoDetector.typoDistance("ab", "ba") == TypoDetector.transpositionCost)
    #expect(TypoDetector.typoDistance("abc", "abc") == 0)
    #expect(TypoDetector.typoDistance("cat", "bat") == 1.0)
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

// MARK: - PredictorViewModel : retry de chargement après échec (anti-verrou .failed)

@MainActor
@Test func loadModelRetriesFromFailedStateAfterBackoff() {
    // Panne constatée : un échec ponctuel de chargement posait `.failed` que le
    // guard `.idle` de loadModel() ne refranchissait jamais → ghost mort jusqu'au
    // relaunch, AppDelegate en boucle `ghost_warm_reload`. La décision d'entrée
    // doit retenter depuis `.failed`, espacée par le backoff.
    let now = Date()
    // Champ neuf → charge ; résident / en cours → jamais.
    #expect(PredictorViewModel.shouldAttemptLoad(state: .idle, lastFailureAt: nil, now: now))
    #expect(!PredictorViewModel.shouldAttemptLoad(state: .ready, lastFailureAt: nil, now: now))
    #expect(!PredictorViewModel.shouldAttemptLoad(state: .loading(progress: 0.5), lastFailureAt: nil, now: now))
    // Échec RÉCENT → silence (un GGUF absent ne coûte pas un load par frappe).
    #expect(!PredictorViewModel.shouldAttemptLoad(
        state: .failed("load_failed: gguf"),
        lastFailureAt: now.addingTimeInterval(-2), now: now))
    // Échec plus vieux que le backoff, ou horodatage perdu → retry.
    #expect(PredictorViewModel.shouldAttemptLoad(
        state: .failed("load_failed: gguf"),
        lastFailureAt: now.addingTimeInterval(-PredictorViewModel.loadRetryBackoffSeconds - 1), now: now))
    #expect(PredictorViewModel.shouldAttemptLoad(state: .failed("load_failed: gguf"), lastFailureAt: nil, now: now))
}

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
