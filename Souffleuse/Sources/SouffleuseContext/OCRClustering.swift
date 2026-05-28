import Foundation
import CoreGraphics

/// Minimal value-type mirror of `VNRecognizedTextObservation` exposing only
/// the fields the clustering algorithm needs. Keeps the spatial-clustering
/// logic Vision-agnostic so it can be unit-tested with synthetic fixtures
/// (no image, no Vision request, no `VNImageRequestHandler`).
public struct OCRObservation: Sendable, Equatable {
    public let text: String
    public let boundingBox: CGRect    // Vision-normalised, bottom-left origin
    public let confidence: Float

    public init(text: String, boundingBox: CGRect, confidence: Float) {
        self.text = text
        self.boundingBox = boundingBox
        self.confidence = confidence
    }
}

/// Reorganises raw OCR observations into a single string biased towards the
/// **latest message bubble** in a chat-style interface.
///
/// The Souffleuse use case: an assistant typing into the focused reply field,
/// with the conversation pane *visually above* that field. In Vision's
/// normalised image coordinates (bottom-left origin), the bottom edge of the
/// captured image (`y ≈ 0`) is closest to the reply field, so observations
/// with low `minY` are spatially *just above* where the user is typing —
/// i.e. the latest message they're replying to. We keep that cluster and
/// discard the conversation header, the older messages, and the right-pane
/// metadata that would otherwise eat the 240-char LLM budget.
///
/// **Bottom-cluster rule.** Observations are sorted by `minY` ascending,
/// grouped into clusters whenever the vertical gap to the next observation
/// exceeds `clusterGap`, and the bottom-most "substantial" cluster wins. A
/// cluster is "substantial" if it contains ≥ `minObservationsForSubstantial`
/// items — short isolated labels (timestamps, "Fermer", "Détails") that
/// happen to land near the focus field don't qualify and the algorithm
/// promotes the next cluster up.
///
/// **Short-bubble expansion.** Real customer messages can be short ("ok",
/// "merci"). When the elected bottom cluster joins to < `minClusterChars`,
/// the algorithm appends the next-higher cluster so the LLM has at least a
/// minimum signal to act on, even at the cost of one extra cluster's noise.
///
/// **Graceful degradation.** When the input has fewer than
/// `minTotalObservationsForClustering` observations, clustering provides
/// no statistical advantage — falls back to the legacy flat-join behavior.
/// Same when no cluster qualifies as substantial.
public enum OCRClustering {
    public static let clusterGap: CGFloat = 0.04
    public static let minObservationsForSubstantial: Int = 2
    public static let minClusterChars: Int = 30
    public static let minTotalObservationsForClustering: Int = 5

    /// Returns the joined text of the elected cluster(s), in top-to-bottom
    /// reading order. Falls back to a flat join over all observations when
    /// the input is too sparse to cluster usefully.
    public static func selectBottomCluster(_ observations: [OCRObservation]) -> String {
        guard observations.count >= minTotalObservationsForClustering else {
            return flatJoin(observations)
        }

        let clusters = buildClusters(observations)
        let substantial = clusters.filter { $0.count >= minObservationsForSubstantial }

        // No substantial cluster — degrade gracefully to flat join over the
        // original observations rather than returning empty.
        guard !substantial.isEmpty else { return flatJoin(observations) }

        // Clusters are already in bottom-first order from buildClusters.
        let bottom = substantial[0]
        let bottomText = joinTopDown(bottom)

        if bottomText.count >= minClusterChars || substantial.count < 2 {
            return bottomText
        }

        // Bottom too short — fold in the next cluster up.
        let extended = substantial[0] + substantial[1]
        return joinTopDown(extended)
    }

    /// Groups observations into vertical clusters in bottom-to-top order.
    /// Each returned cluster preserves the order it was traversed in
    /// (bottom-up); call `joinTopDown` to produce reading order.
    static func buildClusters(_ observations: [OCRObservation]) -> [[OCRObservation]] {
        let sorted = observations.sorted { $0.boundingBox.minY < $1.boundingBox.minY }
        var clusters: [[OCRObservation]] = []
        var current: [OCRObservation] = []
        var lastMaxY: CGFloat = -1

        for obs in sorted {
            if current.isEmpty {
                current.append(obs)
                lastMaxY = obs.boundingBox.maxY
            } else if obs.boundingBox.minY <= lastMaxY + clusterGap {
                current.append(obs)
                lastMaxY = max(lastMaxY, obs.boundingBox.maxY)
            } else {
                clusters.append(current)
                current = [obs]
                lastMaxY = obs.boundingBox.maxY
            }
        }
        if !current.isEmpty { clusters.append(current) }
        return clusters
    }

    /// Joins observations in top-down reading order (Vision-normalised:
    /// highest Y first), which is how a human reads a text block.
    static func joinTopDown(_ observations: [OCRObservation]) -> String {
        return observations
            .sorted { $0.boundingBox.minY > $1.boundingBox.minY }
            .map(\.text)
            .joined(separator: " ")
    }

    /// Order-preserving flat join, used when clustering can't yield a
    /// confident selection (sparse input, no substantial cluster).
    static func flatJoin(_ observations: [OCRObservation]) -> String {
        return observations.map(\.text).joined(separator: " ")
    }
}
