import Foundation
import CoreGraphics
import Vision

public enum VisionOCRError: Error {
    case requestFailed(Error)
}

/// Wraps VNRecognizeTextRequest with parameters tuned for low latency on
/// the ContextEnricher hot path: .fast level, no language correction,
/// fr+en recognition.
public actor VisionOCR {
    public static let maxChars = 500

    private var languages: [String]

    public init(languages: [String] = ["fr-FR", "en-US"]) {
        self.languages = languages
    }

    public func setLanguages(_ langs: [String]) {
        self.languages = langs.isEmpty ? ["fr-FR"] : langs
    }

    /// `excludeNormalised` is in Vision's coordinate system (bottom-left origin,
    /// normalised 0..1). Observations whose bounding box centre falls inside
    /// it are discarded — used to mask out the focused text field, whose
    /// content the model already gets verbatim via AX.
    ///
    /// `includeNormalised`, when set, restricts the kept observations to those
    /// whose centre falls *inside* it — used by `ContextEnricher` to target the
    /// conversation pane (anchored above the focused field) so browser chrome,
    /// sidebars and bookmark bars don't fill the 240-char visible budget before
    /// the actual message content. Both filters compose: an observation is
    /// kept iff it is inside `includeNormalised` (or `includeNormalised` is
    /// nil) AND not inside `excludeNormalised`.
    public func extract(
        from image: CGImage,
        excludeNormalised: CGRect? = nil,
        includeNormalised: CGRect? = nil
    ) async throws -> String {
        let langs = self.languages
        let excluded = excludeNormalised
        let included = includeNormalised
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<String, Error>) in
            let request = VNRecognizeTextRequest { request, error in
                if let error {
                    cont.resume(throwing: VisionOCRError.requestFailed(error))
                    return
                }
                var observations = request.results as? [VNRecognizedTextObservation] ?? []
                if let included {
                    observations = observations.filter { obs in
                        let centre = CGPoint(x: obs.boundingBox.midX, y: obs.boundingBox.midY)
                        return included.contains(centre)
                    }
                }
                if let excluded {
                    observations = observations.filter { obs in
                        let centre = CGPoint(x: obs.boundingBox.midX, y: obs.boundingBox.midY)
                        return !excluded.contains(centre)
                    }
                }
                // Spatial clustering — select the bottom-most substantial
                // cluster (≈ the latest message bubble in a chat surface),
                // discarding the conversation header, older messages, and
                // side-pane chrome before the 240-char visible budget is
                // applied downstream. Disable via SOUFFLEUSE_OCR_NO_CLUSTERING
                // (escape hatch for the rare case where the heuristic mis-
                // fires on a layout it wasn't tuned for — falls back to a
                // flat join of all kept observations).
                let clusteringDisabled = ProcessInfo.processInfo
                    .environment["SOUFFLEUSE_OCR_NO_CLUSTERING"]?.isEmpty == false
                let joined: String
                if clusteringDisabled {
                    joined = observations
                        .compactMap { $0.topCandidates(1).first?.string }
                        .joined(separator: " ")
                } else {
                    let typed: [OCRObservation] = observations.compactMap { obs in
                        guard let text = obs.topCandidates(1).first?.string else { return nil }
                        return OCRObservation(
                            text: text,
                            boundingBox: obs.boundingBox,
                            confidence: obs.confidence
                        )
                    }
                    joined = OCRClustering.selectBottomCluster(typed)
                }
                if joined.count <= Self.maxChars {
                    cont.resume(returning: joined)
                } else {
                    cont.resume(returning: String(joined.prefix(Self.maxChars)) + "…")
                }
            }
            // Diagnostic 2026-05-28 — bumped from .fast + language-correction
            // OFF (the original low-latency tuning) to .accurate + correction
            // ON, after the OCR dev log showed Vision returning garbled UI
            // text on dense surfaces (Intercom-via-Brave timestamps came back
            // as "OIIQWIO25VA345" instead of "01/12/2025"). Latency cost
            // estimated +100-200ms per capture; tolerable because the
            // enricher hot path is async + cached 5s per bundle.
            request.recognitionLevel = .accurate
            request.recognitionLanguages = langs
            request.usesLanguageCorrection = true

            let handler = VNImageRequestHandler(cgImage: image, options: [:])
            do {
                try handler.perform([request])
            } catch {
                cont.resume(throwing: VisionOCRError.requestFailed(error))
            }
        }
    }
}
