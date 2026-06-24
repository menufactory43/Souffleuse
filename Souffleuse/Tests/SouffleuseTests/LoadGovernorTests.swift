import Testing
import Foundation
import SouffleuseCore

/// Verrouille les invariants du `LoadGovernor` — la pièce « steadier under
/// heavy load ». Tout est fonction PURE de `LoadLevel` → testable sans GGUF ni
/// état thermique réel.
///
/// Invariants couverts :
///   - transparence à `.nominal` (multiplicateur 1.0, aucun gate) ⇒ pas de
///     régression hors pression ;
///   - monotonie : plus la pression monte, plus on throttle (debounce ↗,
///     spéculatif coupé, skip chaud retiré) ;
///   - mapping `ProcessInfo.ThermalState` → `LoadLevel` exhaustif ;
///   - parse de l'override DEV `SOUFFLEUSE_FORCE_LOAD_LEVEL` ;
///   - **coalescence** : sur une rafale de frappe, le debounce allongé sous
///     charge réduit le nombre de générations démarrées (= moins de churn
///     GPU/CPU), ce qui matérialise le gain « moins de charge sous heavy load ».
@Suite struct LoadGovernorTests {

    // MARK: - Transparence à nominal (anti-régression)

    @Test func nominalIsTransparent() {
        #expect(LoadGovernor.debounceMultiplier(for: .nominal) == 1.0)
        #expect(LoadGovernor.lookaheadWords(base: 8, for: .nominal) == 8)
        #expect(LoadGovernor.allowsWarmDebounceSkip(for: .nominal) == true)
    }

    // MARK: - Monotonie du throttling

    @Test func debounceMultiplierIsMonotonicNonDecreasing() {
        let levels = LoadLevel.allCases.sorted()
        for (a, b) in zip(levels, levels.dropFirst()) {
            #expect(LoadGovernor.debounceMultiplier(for: a) <= LoadGovernor.debounceMultiplier(for: b))
        }
        // Et strictement croissant en pratique (paliers distincts).
        #expect(LoadGovernor.debounceMultiplier(for: .critical) > LoadGovernor.debounceMultiplier(for: .nominal))
    }

    @Test func lookaheadShrinksUnderLoadButNeverEmpties() {
        // À nominal/fair : profondeur de base respectée (byte-identique).
        #expect(LoadGovernor.lookaheadWords(base: 8, for: .nominal) == 8)
        #expect(LoadGovernor.lookaheadWords(base: 8, for: .fair) == 8)
        // Sous charge : on rabote — mesuré, c'est ce qui coupe ~46 % du GPU.
        #expect(LoadGovernor.lookaheadWords(base: 8, for: .serious) < 8)
        #expect(LoadGovernor.lookaheadWords(base: 8, for: .critical)
                <= LoadGovernor.lookaheadWords(base: 8, for: .serious))
        // INVARIANT « le ghost reste affiché » : jamais sous un plancher non-vide,
        // même pour une base minuscule.
        for base in [1, 2, 3, 4, 8, 20] {
            for level in LoadLevel.allCases {
                #expect(LoadGovernor.lookaheadWords(base: base, for: level) >= 3
                        || LoadGovernor.lookaheadWords(base: base, for: level) == base)
            }
        }
    }

    @Test func warmSkipAlwaysAllowed() {
        // La réserve chaude est servie depuis du calcul DÉJÀ fait (~1 ms) : ce
        // n'est jamais du travail gaspillé → toujours autorisé, à tous les
        // paliers. La coalescence se fait via le seul debounce des predicts froids.
        for level in LoadLevel.allCases {
            #expect(LoadGovernor.allowsWarmDebounceSkip(for: level) == true)
        }
    }

    // MARK: - Mapping thermique + override

    @Test func thermalMappingIsExhaustive() {
        #expect(LoadGovernor.level(from: .nominal) == .nominal)
        #expect(LoadGovernor.level(from: .fair) == .fair)
        #expect(LoadGovernor.level(from: .serious) == .serious)
        #expect(LoadGovernor.level(from: .critical) == .critical)
    }

    @Test func forcedLevelParsesNamesAndRawValues() {
        #expect(LoadGovernor.forcedLevel(from: "serious") == .serious)
        #expect(LoadGovernor.forcedLevel(from: "CRITICAL") == .critical)
        #expect(LoadGovernor.forcedLevel(from: " fair ") == .fair)
        #expect(LoadGovernor.forcedLevel(from: "2") == .serious)
        #expect(LoadGovernor.forcedLevel(from: "0") == .nominal)
        #expect(LoadGovernor.forcedLevel(from: nil) == nil)
        #expect(LoadGovernor.forcedLevel(from: "") == nil)
        #expect(LoadGovernor.forcedLevel(from: "garbage") == nil)
    }

    @Test func loadLevelIsComparableBySeverity() {
        #expect(LoadLevel.nominal < .fair)
        #expect(LoadLevel.fair < .serious)
        #expect(LoadLevel.serious < .critical)
    }

    // MARK: - Coalescence (le gain mesurable sous charge)

    /// Modèle PUR du debounce cancel-on-keystroke : sur une suite de frappes
    /// espacées de `interKeyMs`, une génération n'est RÉELLEMENT démarrée que
    /// pour une frappe dont la suivante arrive APRÈS la fenêtre de debounce
    /// effective (sinon la frappe suivante annule la Task débouncée avant son
    /// départ). La dernière frappe démarre toujours. Renvoie le nombre de
    /// générations démarrées (= travail llama potentiellement dépensé).
    private func generationsStarted(keystrokes: Int, interKeyMs: Double, level: LoadLevel) -> Int {
        let baseDebounceMs = 15.0
        let effectiveDebounceMs = baseDebounceMs * LoadGovernor.debounceMultiplier(for: level)
        guard keystrokes > 0 else { return 0 }
        var started = 0
        for i in 0..<keystrokes {
            let isLast = (i == keystrokes - 1)
            // La frappe i démarre une génération si aucune frappe ne tombe dans
            // sa fenêtre de debounce (la suivante arrive après), ou si c'est la
            // dernière (rien ne l'annule).
            if isLast || interKeyMs >= effectiveDebounceMs {
                started += 1
            }
        }
        return started
    }

    @Test func loadCoalescesGenerationsOnFastTypingBurst() {
        // Rafale très rapide : 20 frappes à 20 ms d'intervalle.
        let burst = 20
        let interKey = 20.0
        let atNominal = generationsStarted(keystrokes: burst, interKeyMs: interKey, level: .nominal)
        let atSerious = generationsStarted(keystrokes: burst, interKeyMs: interKey, level: .serious)
        let atCritical = generationsStarted(keystrokes: burst, interKeyMs: interKey, level: .critical)

        // À nominal (debounce 15 ms < 20 ms d'intervalle), chaque frappe part :
        // pas de coalescence (comportement historique préservé).
        #expect(atNominal == burst)
        // À serious (×2 → 30 ms > 20 ms) et critical (×3 → 45 ms), les frappes
        // adjacentes se coalescent : seule la dernière démarre.
        #expect(atSerious < atNominal)
        #expect(atCritical <= atSerious)
        // Gain bien supérieur au seuil objectif de 10 % de travail en moins.
        let reduction = Double(atNominal - atCritical) / Double(atNominal)
        #expect(reduction >= 0.10)
    }

    @Test func noCoalescingWhenUserPausesBetweenKeys() {
        // Frappe normale (250 ms entre touches) : même sous charge, chaque frappe
        // dépasse la fenêtre de debounce → aucune génération supprimée (on ne
        // sacrifie pas la réactivité quand l'utilisateur fait des pauses). C'est
        // aussi pourquoi la coalescence n'aide vraiment que sur les rafales très
        // rapides — la frappe humaine typique (~80-120 ms) en profite peu.
        let atNominal = generationsStarted(keystrokes: 10, interKeyMs: 250, level: .nominal)
        let atCritical = generationsStarted(keystrokes: 10, interKeyMs: 250, level: .critical)
        #expect(atNominal == 10)
        #expect(atCritical == 10)
    }
}
