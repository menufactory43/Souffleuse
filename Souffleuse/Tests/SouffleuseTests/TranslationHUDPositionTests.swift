import CoreGraphics
import Testing
@testable import SouffleuseOverlay

/// Couvre le calcul pur de position du HUD de traduction (§3b) : application du
/// décalage utilisateur mémorisé + clamp à l'écran, sans écran/AppKit réel.
@Suite("TranslationHUD — position + offset (§3b)")
struct TranslationHUDPositionTests {
    typealias HUD = TranslationHUDWindow
    let panel = CGSize(width: 320, height: 80)
    let screen = CGSize(width: 1440, height: 900)

    @Test("offset nul → position par défaut inchangée")
    func zeroOffsetKeepsDefault() {
        let o = HUD.clampedOrigin(
            defaultOrigin: CGPoint(x: 200, y: 500), offset: .zero,
            panelSize: panel, screenSize: screen)
        #expect(o == CGPoint(x: 200, y: 500))
    }

    @Test("un offset déplace le panneau d'autant (dans l'écran)")
    func offsetShifts() {
        let o = HUD.clampedOrigin(
            defaultOrigin: CGPoint(x: 200, y: 500), offset: CGSize(width: 120, height: -60),
            panelSize: panel, screenSize: screen)
        #expect(o == CGPoint(x: 320, y: 440))
    }

    @Test("clamp à droite : ne sort pas de l'écran (marge 8)")
    func clampsRight() {
        let o = HUD.clampedOrigin(
            defaultOrigin: CGPoint(x: 1300, y: 500), offset: CGSize(width: 1000, height: 0),
            panelSize: panel, screenSize: screen)
        #expect(o.x == screen.width - panel.width - 8)   // 1440-320-8 = 1112
    }

    @Test("clamp en bas/à gauche : ne descend pas sous la marge 8")
    func clampsBottomLeft() {
        let o = HUD.clampedOrigin(
            defaultOrigin: CGPoint(x: 100, y: 100), offset: CGSize(width: -1000, height: -1000),
            panelSize: panel, screenSize: screen)
        #expect(o.x == 8)
        #expect(o.y == 8)
    }

    @Test("clamp en haut : ne dépasse pas screenH - panelH - 8")
    func clampsTop() {
        let o = HUD.clampedOrigin(
            defaultOrigin: CGPoint(x: 100, y: 800), offset: CGSize(width: 0, height: 1000),
            panelSize: panel, screenSize: screen)
        #expect(o.y == screen.height - panel.height - 8)   // 900-80-8 = 812
    }
}
