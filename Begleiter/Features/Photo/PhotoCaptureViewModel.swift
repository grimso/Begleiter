import Foundation
import OSLog
import PhotosUI
import SwiftUI

private let photoCaptureLog = Logger(subsystem: "io.grimso.Begleiter", category: "photo.capture")

/// View model for the modal photo / Befund picker sheet.
///
/// Lifecycle:
/// - `.idle` — picker visible, no selection yet.
/// - `.processing` — image bytes loaded, Vision OCR running.
/// - `.done(text)` — OCR finished; UI shows the recognised text + a
///   preview thumbnail; parent taps **Übernehmen** to ship it back to
///   CaptureView.
/// - `.failed(message)` — recoverable error; parent can pick another
///   photo.
///
/// All work is in a cancellable child Task so the **Abbrechen** button
/// always works, even mid-OCR.
@MainActor
@Observable
final class PhotoCaptureViewModel {
    enum Phase: Equatable {
        case idle
        case processing
        case done(text: String, confidence: Double)
        case failed(String)
    }

    /// The PhotosPicker selection. Observed; on change we load the data
    /// and kick OCR.
    var pickerItem: PhotosPickerItem? {
        didSet {
            guard pickerItem != oldValue, let item = pickerItem else { return }
            ingest(item)
        }
    }
    private(set) var phase: Phase = .idle
    /// Raw JPEG bytes of the selected image — held so we can hand it to
    /// PhotoStorage when the parent taps "Übernehmen".
    private(set) var imageData: Data?
    /// The displayed preview thumbnail.
    private(set) var previewImage: Image?

    private let engine: any PhotoExtractionEngine
    private var processTask: Task<Void, Never>?

    init(engine: any PhotoExtractionEngine = DefaultPhotoExtractionEngine.make()) {
        self.engine = engine
    }

    /// Recognised text (final OCR result), or empty until processing
    /// completes.
    var recognisedText: String {
        if case .done(let text, _) = phase { return text }
        return ""
    }

    var isBusy: Bool {
        if case .processing = phase { return true }
        return false
    }

    var canAdopt: Bool {
        if case .done = phase, imageData != nil { return true }
        return false
    }

    // MARK: - Ingest a picker selection

    private func ingest(_ item: PhotosPickerItem) {
        // Cancel any in-progress run so a quick second pick doesn't race.
        processTask?.cancel()
        phase = .processing

        processTask = Task { [engine] in
            do {
                guard let data = try await item.loadTransferable(type: Data.self) else {
                    throw PhotoExtractionError.unsupportedImage
                }
                try Task.checkCancellation()

                await MainActor.run {
                    self.imageData = data
                    #if canImport(UIKit)
                    if let ui = UIImage(data: data) {
                        self.previewImage = Image(uiImage: ui)
                    }
                    #endif
                }

                try await engine.prepare()
                try Task.checkCancellation()

                let result = try await engine.extract(imageData: data)
                try Task.checkCancellation()

                await MainActor.run {
                    self.phase = .done(text: result.recognisedText, confidence: result.averageConfidence)
                }
                photoCaptureLog.info("OCR completed via \(result.engineLabel, privacy: .public), confidence=\(Int(result.averageConfidence * 100))%")
            } catch is CancellationError {
                await MainActor.run { self.phase = .idle }
            } catch {
                await MainActor.run { self.phase = .failed(error.localizedDescription) }
            }
        }
    }

    /// Cancel any in-progress OCR. Idempotent.
    func cancel() {
        processTask?.cancel()
        processTask = nil
    }
}
