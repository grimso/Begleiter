import Foundation
import OSLog
#if canImport(UIKit)
import UIKit
#endif
#if canImport(Vision)
import Vision
#endif

private let photoLog = Logger(subsystem: "io.grimso.Begleiter", category: "photo.extraction")

/// Abstract photo OCR backend. Two implementations:
/// - `AppleVisionPhotoEngine` — `VNRecognizeTextRequest` in German.
/// - `MockPhotoEngine` — canned OCR for simulator + unit tests.
///
/// Designed as a protocol seam so the later multimodal-Gemma stretch
/// (iter 5+) can plug in behind the same API without touching the UI.
/// Future engine would skip the OCR pass and feed the image directly to
/// Gemma via MLXVLM.
protocol PhotoExtractionEngine: Actor {
    /// Verify backend availability (e.g. that German script is supported).
    /// Idempotent. Throws clear errors on failure.
    func prepare() async throws

    /// Run OCR / multimodal extraction on a single image. Returns the
    /// recognised German text. Caller chains this into `ExtractionService`
    /// to get a fully structured `ExtractedFields`.
    func extract(imageData: Data) async throws -> PhotoExtractionResult
}

/// Result of a single photo extraction pass.
struct PhotoExtractionResult: Sendable, Hashable {
    /// Concatenated text recognised in the photo, sorted top-to-bottom.
    let recognisedText: String
    /// Average confidence reported by Vision across all observations.
    /// Approximately `[0, 1]`. Mock engine reports a fixed value.
    let averageConfidence: Double
    /// Engine label for the writeup / debug surface ("Apple Vision OCR",
    /// "Mock", "Gemma 4 Multimodal" if/when we plug that in).
    let engineLabel: String
}

enum PhotoExtractionError: Error, LocalizedError {
    case unsupportedImage
    case recognitionFailed(String)
    case engineUnavailable

    var errorDescription: String? {
        switch self {
        case .unsupportedImage:
            return "Das Bild konnte nicht gelesen werden."
        case .recognitionFailed(let detail):
            return "Texterkennung fehlgeschlagen: \(detail)"
        case .engineUnavailable:
            return "Bildverarbeitung auf diesem Gerät nicht verfügbar."
        }
    }
}

// MARK: - Apple Vision implementation

#if canImport(Vision) && canImport(UIKit)

/// `VNRecognizeTextRequest`-backed engine. Configured for German
/// recognition with `.accurate` mode (slower, better for handwritten /
/// printed lab values typical of a Befund printout).
actor AppleVisionPhotoEngine: PhotoExtractionEngine {

    func prepare() async throws {
        // Vision's German script is always available where the framework
        // exists; nothing to install. Confirm the locale is supported on
        // this iOS revision for safety.
        let supported = (try? VNRecognizeTextRequest.supportedRecognitionLanguages(
            for: .accurate, revision: VNRecognizeTextRequestRevision3
        )) ?? []
        guard supported.contains(where: { $0.hasPrefix("de") }) else {
            throw PhotoExtractionError.engineUnavailable
        }
        photoLog.info("Apple Vision German OCR ready")
    }

    func extract(imageData: Data) async throws -> PhotoExtractionResult {
        guard let image = UIImage(data: imageData), let cgImage = image.cgImage else {
            throw PhotoExtractionError.unsupportedImage
        }

        let request = VNRecognizeTextRequest()
        request.recognitionLanguages = ["de-DE", "en-US"]
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.revision = VNRecognizeTextRequestRevision3

        let handler = VNImageRequestHandler(
            cgImage: cgImage,
            orientation: cgImageOrientation(from: image.imageOrientation),
            options: [:]
        )

        return try await withCheckedThrowingContinuation { continuation in
            do {
                try handler.perform([request])
                guard let observations = request.results else {
                    continuation.resume(returning: PhotoExtractionResult(
                        recognisedText: "",
                        averageConfidence: 0,
                        engineLabel: "Apple Vision OCR"
                    ))
                    return
                }
                let lines = observations.compactMap { $0.topCandidates(1).first?.string }
                let confidences = observations.compactMap { $0.topCandidates(1).first?.confidence }
                let avg = confidences.isEmpty
                    ? 0.0
                    : Double(confidences.reduce(0, +)) / Double(confidences.count)
                continuation.resume(returning: PhotoExtractionResult(
                    recognisedText: lines.joined(separator: "\n"),
                    averageConfidence: avg,
                    engineLabel: "Apple Vision OCR"
                ))
            } catch {
                continuation.resume(throwing: PhotoExtractionError.recognitionFailed(error.localizedDescription))
            }
        }
    }

    /// Map `UIImage.Orientation` to Vision's expected CGImagePropertyOrientation.
    private func cgImageOrientation(from uiOrientation: UIImage.Orientation) -> CGImagePropertyOrientation {
        switch uiOrientation {
        case .up:            return .up
        case .upMirrored:    return .upMirrored
        case .down:          return .down
        case .downMirrored:  return .downMirrored
        case .left:          return .left
        case .leftMirrored:  return .leftMirrored
        case .right:         return .right
        case .rightMirrored: return .rightMirrored
        @unknown default:    return .up
        }
    }
}

#endif // canImport(Vision) && canImport(UIKit)

// MARK: - Mock implementation (simulator + unit tests)

/// Returns a canned German Befund-style OCR output regardless of the
/// supplied image data. Used on the simulator so the photo flow can be
/// validated without an actual image library or Vision-on-simulator
/// quirks.
actor MockPhotoEngine: PhotoExtractionEngine {
    var scriptedText: String = """
        Klinik für Pädiatrische Onkologie
        Patient: Luca M.   Geb.: 11.03.2018
        Datum: 11.05.2026

        WBC       3.4   G/L   (4.0 – 11.0)
        ANC       0.8   G/L   (1.5 –  8.0)
        Hb        10.2  g/dL  (11.5 – 14.5)
        PLT       142   G/L   (150 – 450)
        CRP       4.2   mg/L  (<5)
        """

    init(scripted: String? = nil) {
        if let scripted { self.scriptedText = scripted }
    }

    func setScriptedText(_ text: String) { scriptedText = text }

    func prepare() async throws {
        try? await Task.sleep(for: .milliseconds(50))
    }

    func extract(imageData: Data) async throws -> PhotoExtractionResult {
        try? await Task.sleep(for: .milliseconds(150))
        return PhotoExtractionResult(
            recognisedText: scriptedText,
            averageConfidence: 0.95,
            engineLabel: "Mock OCR"
        )
    }
}

// MARK: - Default selection

enum DefaultPhotoExtractionEngine {
    static func make() -> any PhotoExtractionEngine {
        #if targetEnvironment(simulator)
        return MockPhotoEngine()
        #elseif canImport(Vision) && canImport(UIKit)
        return AppleVisionPhotoEngine()
        #else
        return MockPhotoEngine()
        #endif
    }
}
