---
phase: quick-260616-eoy
plan: 01
type: execute
wave: 1
depends_on: []
files_modified:
  - Souffleuse/Sources/SouffleuseOverlay/OverlayWindow.swift
  - Souffleuse/Sources/Souffleuse/SouffleuseAppDelegate.swift
  - Souffleuse/Tests/SouffleuseTests/SouffleuseTests.swift
autonomous: true
requirements:
  - QUICK-260616-eoy

must_haves:
  truths:
    - "Un souffle inline plus long que l'espace restant sur la ligne WRAP à la ligne suivante au lieu de déborder le bord droit du champ hôte."
    - "Les lignes enroulées repartent au bord gauche du champ ; la première ligne démarre au caret."
    - "Quand elementRect est absent ou aberrant (Chromium/Electron sans frame fiable), le rendu single-line bottom-anchored ACTUEL est préservé au pixel près (pas de régression)."
    - "audit.sh passe (aucun print/NSLog, aucun texte user loggé) et la suite ~640 @Test reste verte."
  artifacts:
    - path: "Souffleuse/Sources/SouffleuseOverlay/OverlayWindow.swift"
      provides: "Prédicat isUsableElementRect + frame multi-ligne wrap (static/pur) + chemin de rendu wrap dans show()."
      contains: "isUsableElementRect"
    - path: "Souffleuse/Tests/SouffleuseTests/SouffleuseTests.swift"
      provides: "Tests géométrie : prédicat, frame multi-ligne (origin/width/height + indent 1re ligne), régression fallback == single-line existant."
      contains: "isUsableElementRect"
  key_links:
    - from: "Souffleuse/Sources/Souffleuse/SouffleuseAppDelegate.swift"
      to: "OverlayWindow.show"
      via: "passe snap.elementRect aux 5 sites d'appel inline du ghost"
      pattern: "overlay\\.show\\(.*elementRect"
    - from: "Souffleuse/Sources/SouffleuseOverlay/OverlayWindow.swift"
      to: "isUsableElementRect"
      via: "show() branche wrap vs single-line selon le prédicat"
      pattern: "isUsableElementRect"
---

<objective>
Le souffle inline (`OverlayWindow.show`) déborde le bord droit du champ hôte quand la
suggestion dépasse l'espace restant sur la ligne : `appKitFrame` (OverlayWindow.swift:482)
calcule `width = ceil(textSize.width) + 4` sur la suggestion ENTIÈRE et ancre à
`caret.origin.x` sans borne droite ; le `lineBreakMode = .byTruncatingTail` (:50) ne
déclenche jamais car le panneau fait exactement la largeur du texte. Constaté à l'écran
dans un composer webmail Chromium.

Décision verrouillée = **WRAP à la ligne suivante** (parité avec le texte tapé), PAS de
troncature ni de masquage.

Purpose: parité subjective Cotypist — un souffle long reste lisible et rangé dans le champ.
Output: prédicat `isUsableElementRect`, frame multi-ligne pure et testable, chemin de
rendu wrap branché dans `show()`, threading de `snap.elementRect` aux 5 sites d'appel
inline, et tests de géométrie. Fallback single-line strictement préservé.
</objective>

<execution_context>
@$HOME/.claude/get-shit-done/workflows/execute-plan.md
@$HOME/.claude/get-shit-done/templates/summary.md
</execution_context>

<context>
@./CLAUDE.md

# Fichiers à modifier (déjà lus pendant la planification — re-lire seulement la zone éditée) :
# - Souffleuse/Sources/SouffleuseOverlay/OverlayWindow.swift
# - Souffleuse/Sources/Souffleuse/SouffleuseAppDelegate.swift (sites show inline : 1991, 2134, 2153, 2183, 2429)
# - Souffleuse/Tests/SouffleuseTests/SouffleuseTests.swift (// MARK: - OverlayWindow)

<interfaces>
<!-- Contrats déjà extraits du codebase ; pas d'exploration nécessaire. -->

Depuis Souffleuse/Sources/SouffleuseAX/AXClient.swift (AXSnapshot) :
```swift
public struct AXSnapshot: Sendable, Equatable {
    public let caretRect: CGRect?
    public let caretIndex: Int?
    /// Frame du champ texte focalisé (coords Quartz, origine top-left). left + width fiables.
    public let elementRect: CGRect?
    // ...
}
```

Depuis OverlayWindow.swift (signature ET implémentation single-line ACTUELLE — la régression doit la reproduire) :
```swift
@MainActor public final class OverlayWindow {
    private let label: NSTextField           // lineBreakMode = .byTruncatingTail ; épinglé BAS (lignes 63-74)
    public func show(text: String, at caretRectQuartz: CGRect)              // surcharge simple
    public func show(text: String, at caretRectQuartz: CGRect,
                     hostText: String?, caretIndex: Int?, hostFont: NSFont?) // surcharge utilisée
    // appKitFrame : caret Quartz -> frame AppKit single-line, ancré caret.origin.x, panneau bottom-anchored.
    static func appKitFrame(forGhostAfterCaret caret: CGRect, text: String, font: NSFont) -> CGRect {
        let textSize = (text as NSString).size(withAttributes: [.font: font])
        let width = ceil(textSize.width) + 4
        let height = max(caret.height, ceil(textSize.height))
        let primaryHeight = NSScreen.screens.first?.frame.height ?? NSScreen.main?.frame.height ?? 0
        let appKitY = primaryHeight - caret.maxY
        let appKitX = caret.origin.x
        return CGRect(x: appKitX, y: appKitY, width: width, height: height)
    }
    // Prédicat de référence (même garde-fous à reprendre pour isUsableElementRect) :
    public static func isUsableWordRect(_ rect: CGRect) -> Bool {
        rect.width >= 2 && rect.height >= 2 && rect.width < 4000 && rect.height < 400
            && rect.origin.x.isFinite && rect.origin.y.isFinite
    }
    public static func estimatedFont(forCaretRectHeight: CGFloat, bundleID: String? = nil) -> NSFont?
}
```

Style de test existant (SouffleuseTests.swift, // MARK: - OverlayWindow) :
```swift
@MainActor @Test func overlayUsableWordRectRejectsDegenerate() {
    #expect(OverlayWindow.isUsableWordRect(CGRect(x: 100, y: 200, width: 48, height: 18)))
    #expect(!OverlayWindow.isUsableWordRect(.zero))
}
```
</interfaces>
</context>

<tasks>

<task type="auto" tdd="true">
  <name>Task 1: Prédicat isUsableElementRect + frame multi-ligne wrap (static/pur) + tests</name>
  <files>Souffleuse/Sources/SouffleuseOverlay/OverlayWindow.swift, Souffleuse/Tests/SouffleuseTests/SouffleuseTests.swift</files>
  <behavior>
    Prédicat `isUsableElementRect(_ rect:CGRect, caretX:CGFloat) -> Bool` :
    - Test 1: rect à extent fini sain (width >= 2, width < 4000, height finie, origins finis) ET caretX
      DANS l'horizontale du rect (`rect.minX - 1 <= caretX <= rect.maxX`) → true.
    - Test 2: rect .zero / width ~0 → false.
    - Test 3: width aberrante (>= 4000) ou origin/width non-finie → false.
    - Test 4: caretX hors du rect (à gauche de minX ou à droite de maxX) → false (évite d'ancrer un
      souffle dans un champ qui n'est pas celui du caret).
    Frame multi-ligne `wrapFrame(forGhostAfterCaret caret:CGRect, fieldRect:CGRect, text:String, font:NSFont) -> (frame:CGRect, firstLineIndent:CGFloat)` :
    - Test 5: width du frame == ceil(fieldRect.width) (le panneau couvre la largeur du champ).
    - Test 6: firstLineIndent == max(0, caret.origin.x - fieldRect.minX) (1re ligne démarre au caret).
    - Test 7: appKitX == fieldRect.minX (origine gauche = bord gauche du champ, coords AppKit) ;
      appKitY ancré en HAUT sur la ligne du caret = primaryHeight - caret.maxY - (height - caret.height),
      i.e. le panneau déborde vers le BAS (Quartz Y descend) ⇒ vérifier que la 1re ligne reste sur la
      ligne du caret (top du panneau aligné caret line, pas une ligne au-dessus).
    - Test 8: height couvre le nombre de lignes enroulées (mesurer le texte dans un container de
      largeur fieldRect.width avec firstLineHeadIndent ; height = ceil(bounding height), >= caret.height).
  </behavior>
  <action>
    Dans OverlayWindow.swift, ajouter DEUX statics PURES (testables sans app, comme `appKitFrame`/`pillFrame`) :

    1) `public static func isUsableElementRect(_ rect: CGRect, caretX: CGFloat) -> Bool` — calquer les
       garde-fous de `isUsableWordRect` (extent fini, borné) MAIS axé largeur de champ : `rect.width >= 2`,
       `rect.width < 4000`, `rect.height.isFinite`, `rect.origin.x.isFinite`, `rect.origin.y.isFinite`, ET
       `caretX.isFinite && caretX >= rect.minX - 1 && caretX <= rect.maxX`. Commentaire FR expliquant le
       POURQUOI : éviter d'ancrer le wrap sur un frame de champ aberrant/absent (Chromium/Electron) ou sur
       un champ qui n'est pas celui du caret → on retombe alors sur le single-line historique.

    2) `static func wrapFrame(forGhostAfterCaret caret: CGRect, fieldRect: CGRect, text: String, font: NSFont) -> (frame: CGRect, firstLineIndent: CGFloat)` :
       - `firstLineIndent = max(0, caret.origin.x - fieldRect.minX)`.
       - Mesurer la hauteur enroulée : construire un `NSMutableParagraphStyle` avec
         `firstLineHeadIndent = firstLineIndent`, `headIndent = 0`, `lineBreakMode = .byWordWrapping`,
         puis `(text as NSString).boundingRect(with: CGSize(width: ceil(fieldRect.width), height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: font, .paragraphStyle: para])`.
         `height = max(caret.height, ceil(boundingRect.height))`.
       - `width = ceil(fieldRect.width)`.
       - `primaryHeight = NSScreen.screens.first?.frame.height ?? NSScreen.main?.frame.height ?? 0`.
       - TOP-anchored sur la ligne du caret, débordant vers le bas : la 1re ligne doit rester sur la ligne
         du caret. En Quartz le top de la ligne = `caret.origin.y` ; en AppKit (origine bottom-left) le bas
         du panneau = `primaryHeight - (caret.origin.y + height)`. Donc
         `appKitY = primaryHeight - caret.origin.y - height` ; `appKitX = fieldRect.minX`.
       - Retourner `(CGRect(x: appKitX, y: appKitY, width: width, height: height), firstLineIndent)`.
       Commentaire FR citant (a) le bug d'overflow bord droit, et (b) la contrainte d'ancrage BAS du
       single-line (lignes 63-74) que ce chemin TOP-anchored ne touche pas.

    NE PAS encore brancher le rendu (Task 2). Ajouter ici les tests sous `// MARK: - OverlayWindow (wrap multi-ligne)`
    dans SouffleuseTests.swift, en miroir du style `@MainActor @Test func overlay…` existant, couvrant
    les 8 cas du bloc <behavior>.
  </action>
  <verify>
    <automated>cd Souffleuse && swift test --filter overlay 2>&1 | tail -30</automated>
  </verify>
  <done>isUsableElementRect + wrapFrame compilent ; les ~8 nouveaux @Test passent ; aucun test existant cassé.</done>
</task>

<task type="auto" tdd="true">
  <name>Task 2: Brancher le chemin wrap dans show() + threader elementRect aux 5 sites d'appel inline + tests régression fallback</name>
  <files>Souffleuse/Sources/SouffleuseOverlay/OverlayWindow.swift, Souffleuse/Sources/Souffleuse/SouffleuseAppDelegate.swift, Souffleuse/Tests/SouffleuseTests/SouffleuseTests.swift</files>
  <behavior>
    - Test 1 (régression): quand `fieldRect == nil`, le frame produit par `show` est IDENTIQUE au
      `appKitFrame(forGhostAfterCaret:text:font:)` single-line existant (origin/width/height au pixel) →
      exposer un helper pur `frameForShow(caret:fieldRect:text:font:)` qui retourne `appKitFrame(...)` quand
      `fieldRect` est nil OU non-usable, et la `wrapFrame(...).frame` sinon. Asserter l'égalité au cas nil.
    - Test 2: quand `fieldRect` usable et que le texte tient sur la ligne restante (court), le wrap dégénère
      en une seule ligne (height ~ caret.height) — pas de régression visuelle pour les souffles courts.
    - Test 3: quand `fieldRect` usable et que le texte est long, height > caret.height (au moins 2 lignes).
  </behavior>
  <action>
    Dans OverlayWindow.swift :
    1) Étendre la surcharge utilisée :
       `public func show(text:String, at caretRectQuartz:CGRect, hostText:String?, caretIndex:Int?, hostFont:NSFont?, fieldRect:CGRect? = nil)`.
       Garder la surcharge simple `show(text:at:)` qui appelle avec `fieldRect: nil`. Mettre à jour le
       forwarder `show(text:at:)` existant (ligne ~87) pour passer `fieldRect: nil`.
    2) Helper pur `static func frameForShow(caret:CGRect, fieldRect:CGRect?, text:String, font:NSFont) -> (frame:CGRect, wrap:Bool, firstLineIndent:CGFloat)` :
       si `fieldRect` est non-nil ET `isUsableElementRect(fieldRect, caretX: caret.origin.x)`, retourner
       `(wrapFrame(...).frame, true, wrapFrame(...).firstLineIndent)` (calculer une fois) ; sinon
       `(appKitFrame(forGhostAfterCaret: caret, text: text, font: font), false, 0)`.
    3) Dans `show(...)`, après `correctedRect`/`renderFont`, calculer
       `let (frame, wrap, firstLineIndent) = Self.frameForShow(caret: correctedRect, fieldRect: fieldRect, text: text, font: renderFont)`.
       Inclure `wrap` + `firstLineIndent` (ou le frame déjà différent) dans le guard anti-repaint si nécessaire.
       Au rendu :
       - chemin WRAP (`wrap == true`) : poser un `NSMutableParagraphStyle` (firstLineHeadIndent = firstLineIndent,
         headIndent = 0, lineBreakMode = .byWordWrapping) ; `label.maximumNumberOfLines = 0` ;
         `label.lineBreakMode = .byWordWrapping` ; `label.attributedStringValue = NSAttributedString(string: text, attributes: [.font: renderFont, .foregroundColor: label.textColor, .paragraphStyle: para])`.
       - chemin SINGLE-LINE (fallback) : RESTAURER l'état historique AVANT de peindre —
         `label.maximumNumberOfLines = 1` ; `label.lineBreakMode = .byTruncatingTail` ;
         `label.stringValue = text` (comme aujourd'hui). Le label reste épinglé BAS (contraintes lignes 63-74
         inchangées) ⇒ comportement bottom-anchored Chromium/Intercom strictement préservé.
       Commentaire FR : le wrap est TOP-anchored sur la ligne du caret ; le fallback garde l'ancrage BAS.
       NE PAS toucher `pillFrame`/`showPill` (mid-line pill) — hors scope, le noter en commentaire.

    Dans SouffleuseAppDelegate.swift, threader `snap.elementRect` aux 5 sites `overlay.show(...)` INLINE
    (lignes ~1991, 2134, 2153, 2183, 2429) en ajoutant `fieldRect: snap.elementRect`. `snap` est en scope
    à chacun (cf. `snap.elementRect` déjà utilisé lignes 1695, 1765). NE PAS toucher le site `showPill`
    (~1936-1943). Aucun log de texte user ajouté.

    Tests régression dans SouffleuseTests.swift (3 cas du <behavior>) via `frameForShow`.
  </action>
  <verify>
    <automated>cd Souffleuse && swift test 2>&1 | tail -25 && bash audit.sh</automated>
  </verify>
  <done>Les 5 sites inline passent `fieldRect: snap.elementRect` ; `frameForShow(nil)` == `appKitFrame` (régression verte) ; suite ~640 @Test verte ; `audit.sh` PASS ; aucun TTFT impacté (render-only).</done>
</task>

</tasks>

<verification>
- `cd Souffleuse && swift build` compile (Swift 6 strict concurrency — toutes les statics nouvelles sont pures, pas de nouvel état partagé).
- `cd Souffleuse && swift test` : suite ~640 @Test verte, incl. nouveaux tests géométrie wrap + régression fallback.
- `bash Souffleuse/audit.sh` PASS (aucun print/NSLog, aucun champ user loggé).
- Inspection : les 5 sites `overlay.show(...)` inline passent `fieldRect: snap.elementRect` ; `showPill` non touché.
</verification>

<success_criteria>
- Souffle inline long → WRAP ligne suivante (1re ligne au caret, lignes suivantes au bord gauche du champ), borné par `fieldRect.width`, jamais de débordement bord droit ni de troncature.
- `fieldRect` nil/aberrant → rendu single-line bottom-anchored ACTUEL au pixel près (Chromium/Electron/Intercom non régressés) — prouvé par le test `frameForShow(nil) == appKitFrame`.
- `audit.sh` PASS, suite verte, zéro régression TTFT (render-only).
- Mid-line pill (`showPill`) explicitement non modifiée.
</success_criteria>

<output>
After completion, create `.planning/quick/260616-eoy-fix-ghost-inline-d-borde-la-zone-de-text/260616-eoy-SUMMARY.md`
</output>
