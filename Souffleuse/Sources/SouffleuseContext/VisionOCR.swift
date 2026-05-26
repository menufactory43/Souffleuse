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
    public func extract(from image: CGImage, excludeNormalised: CGRect? = nil) async throws -> String {
        let langs = self.languages
        let excluded = excludeNormalised
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<String, Error>) in
            let request = VNRecognizeTextRequest { request, error in
                if let error {
                    cont.resume(throwing: VisionOCRError.requestFailed(error))
                    return
                }
                var observations = request.results as? [VNRecognizedTextObservation] ?? []
                if let excluded {
                    observations = observations.filter { obs in
                        let centre = CGPoint(x: obs.boundingBox.midX, y: obs.boundingBox.midY)
                        return !excluded.contains(centre)
                    }
                }
                let lines = observations.compactMap { $0.topCandidates(1).first?.string }
                let joined = lines.joined(separator: " ")
                if joined.count <= Self.maxChars {
                    cont.resume(returning: joined)
                } else {
                    cont.resume(returning: String(joined.prefix(Self.maxChars)) + "…")
                }
            }
            request.recognitionLevel = .fast
            request.recognitionLanguages = langs
            request.usesLanguageCorrection = false

            let handler = VNImageRequestHandler(cgImage: image, options: [:])
            do {
                try handler.perform([request])
            } catch {
                cont.resume(throwing: VisionOCRError.requestFailed(error))
            }
        }
    }
}
