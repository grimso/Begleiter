import Foundation
import OSLog
import PDFKit
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
    /// Raw file bytes of the selected attachment — held so we can hand it
    /// to PhotoStorage when the parent taps "Übernehmen". May be JPEG
    /// (from PhotosPicker), PDF (from .fileImporter), or any image type
    /// the file importer accepts.
    private(set) var imageData: Data?
    /// File extension to use when persisting — `jpg` for images,
    /// `pdf` for PDFs. Picked up by `CaptureViewModel.submit` via the
    /// `fileExtension` accessor in `onAdopt`.
    private(set) var fileExtension: String = "jpg"
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
                    self.fileExtension = "jpg"
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

    /// Ingest a file picked via `.fileImporter`. Detects PDF vs image.
    /// For PDFs we try PDFKit's embedded text extraction first — most
    /// lab printouts arrive as digital PDFs and we get clean text with no
    /// OCR pass at all. If the PDF has no extractable text (image-only
    /// scan), we render page 1 to UIImage and run Vision OCR on it.
    func ingest(fileURL: URL) {
        processTask?.cancel()
        phase = .processing

        processTask = Task { [engine] in
            // Access scoped resource for files outside our sandbox.
            let needsScope = fileURL.startAccessingSecurityScopedResource()
            defer { if needsScope { fileURL.stopAccessingSecurityScopedResource() } }

            do {
                let data = try Data(contentsOf: fileURL)
                let ext = fileURL.pathExtension.lowercased()
                try Task.checkCancellation()

                if ext == "pdf" {
                    try await ingestPDF(data: data, engine: engine)
                } else {
                    // Treat as image.
                    await MainActor.run {
                        self.imageData = data
                        self.fileExtension = ext.isEmpty ? "jpg" : ext
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
                    photoCaptureLog.info("image OCR via \(result.engineLabel, privacy: .public): \(result.recognisedText.count, privacy: .public) chars, confidence=\(Int(result.averageConfidence * 100), privacy: .public)%")
                    photoCaptureLog.debug("OCR text preview: \(result.recognisedText.prefix(800), privacy: .public)")
                    await MainActor.run {
                        self.phase = .done(text: result.recognisedText, confidence: result.averageConfidence)
                    }
                }
            } catch is CancellationError {
                await MainActor.run { self.phase = .idle }
            } catch {
                await MainActor.run { self.phase = .failed(error.localizedDescription) }
            }
        }
    }

    /// PDF-specific ingest path. Uses PDFKit's embedded-text extraction
    /// when present; falls back to rendering page 1 for OCR.
    private func ingestPDF(data: Data, engine: any PhotoExtractionEngine) async throws {
        guard let document = PDFDocument(data: data) else {
            throw PhotoExtractionError.unsupportedImage
        }

        // Gather layout-aware embedded text from all pages. Reading
        // `PDFPage.string` directly returns text in document-stream
        // order, which loses row structure on column-organised forms
        // (the user's lab printouts). OCRLayout.reconstruct(pdfPage:)
        // uses per-character bounding boxes to cluster characters into
        // rows by y midpoint and reconstruct left-to-right.
        let embedded = (0..<document.pageCount)
            .compactMap { document.page(at: $0).map { OCRLayout.reconstruct(pdfPage: $0) } }
            .joined(separator: "\n\n")

        // Render page 1 to a thumbnail for preview regardless of which
        // path provides the text.
        #if canImport(UIKit)
        let thumbnail: UIImage? = document.page(at: 0).map { page in
            let bounds = page.bounds(for: .cropBox)
            let renderer = UIGraphicsImageRenderer(size: bounds.size)
            return renderer.image { ctx in
                UIColor.white.setFill()
                ctx.cgContext.fill(CGRect(origin: .zero, size: bounds.size))
                ctx.cgContext.translateBy(x: 0, y: bounds.size.height)
                ctx.cgContext.scaleBy(x: 1, y: -1)
                page.draw(with: .cropBox, to: ctx.cgContext)
            }
        }
        #endif

        await MainActor.run {
            self.imageData = data
            self.fileExtension = "pdf"
            #if canImport(UIKit)
            if let thumbnail {
                self.previewImage = Image(uiImage: thumbnail)
            }
            #endif
        }
        try Task.checkCancellation()

        let cleanedEmbedded = embedded.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cleanedEmbedded.isEmpty {
            // High-quality path: PDF had digital text. No OCR needed.
            photoCaptureLog.info("PDF embedded-text extraction: \(cleanedEmbedded.count, privacy: .public) chars over \(document.pageCount, privacy: .public) pages (layout-aware)")
            photoCaptureLog.debug("PDF text preview: \(cleanedEmbedded.prefix(800), privacy: .public)")
            await MainActor.run {
                self.phase = .done(text: cleanedEmbedded, confidence: 1.0)
            }
            return
        }

        // Image-only PDF — render page 1 and OCR it.
        #if canImport(UIKit)
        guard let thumbnail, let jpeg = thumbnail.jpegData(compressionQuality: 0.9) else {
            throw PhotoExtractionError.unsupportedImage
        }
        try await engine.prepare()
        try Task.checkCancellation()
        let result = try await engine.extract(imageData: jpeg)
        try Task.checkCancellation()
        await MainActor.run {
            self.phase = .done(text: result.recognisedText, confidence: result.averageConfidence)
        }
        photoCaptureLog.info("PDF rendered-page OCR: \(result.recognisedText.count, privacy: .public) chars, confidence=\(Int(result.averageConfidence * 100))%")
        #else
        throw PhotoExtractionError.engineUnavailable
        #endif
    }

    /// Cancel any in-progress OCR. Idempotent.
    func cancel() {
        processTask?.cancel()
        processTask = nil
    }

    /// Surface a file-importer-side error in the view model's failed state
    /// so the existing failed-row UI handles it consistently.
    func surfaceFileImporterError(_ message: String) async {
        phase = .failed(message)
    }
}
