import Foundation
import OSLog
import SwiftData

private let queueLog = Logger(subsystem: "io.grimso.Begleiter", category: "extraction.queue")

/// Background pipeline that turns raw journal entries into structured
/// `ExtractedFields`. Decouples capture (instant) from extraction
/// (slow — Gemma 4 on-device takes 10–60 s).
///
/// Lifecycle:
/// - `bootstrap(container:)` called once at app launch. Stores the
///   SwiftData container, recovers orphans (entries left in
///   `.extracting` by a previous run that was killed), enqueues any
///   `.pending` entries that hadn't been processed yet, and starts the
///   worker.
/// - `enqueue(entryId:)` is called by `CaptureViewModel` after the raw
///   entry is persisted with `.pending` status. It signals the worker
///   without blocking.
/// - `requeue(entryId:)` flips an existing entry back to `.pending`
///   and signals the worker. Used by the "Neuanalyse" button.
/// - `requeueAll()` does the same for every entry. Useful after a prompt
///   change so old entries get re-extracted against the new logic.
///
/// Concurrency model:
/// - The worker is a single long-lived `Task` waiting on an
///   `AsyncStream<Void>` for signals. One entry is processed at a time;
///   Gemma is the bottleneck anyway and `GemmaService` already serialises
///   concurrent calls through its actor.
/// - Each work unit creates a fresh `ModelContext` on the actor so the
///   background save doesn't fight with the UI's `@Query` context.
///   SwiftData broadcasts saves across contexts via the shared
///   `ModelContainer`, so UI views update automatically when the worker
///   writes back results.
actor ExtractionQueue {

    static let shared = ExtractionQueue()

    private var container: ModelContainer?
    private var workerTask: Task<Void, Never>?
    private var signalContinuation: AsyncStream<Void>.Continuation?

    /// Called once from `BegleiterApp` on launch. Stores the container,
    /// recovers orphans, kicks the worker.
    func bootstrap(container: ModelContainer) {
        guard self.container == nil else { return }
        self.container = container
        recoverOrphans()
        startWorkerIfNeeded()
        signal()  // pick up any pre-existing pending entries
    }

    /// Mark already-persisted entry's intent. The entry must already exist
    /// in SwiftData with `processingStatus == .pending` — the caller
    /// (typically `CaptureViewModel.submit`) is responsible for that.
    /// This just wakes the worker.
    func enqueue(entryId: UUID) {
        queueLog.info("enqueue \(entryId.uuidString, privacy: .public)")
        signal()
    }

    /// Reset a specific entry to `.pending` and wake the worker. Used by
    /// the "Neuanalyse" button on `EntryDetailView`.
    func requeue(entryId: UUID) {
        guard let container else { return }
        let context = ModelContext(container)
        let descriptor = FetchDescriptor<JournalEntry>(
            predicate: #Predicate { $0.entryId == entryId }
        )
        guard let entry = (try? context.fetch(descriptor))?.first else {
            queueLog.warning("requeue: entry \(entryId.uuidString, privacy: .public) not found")
            return
        }
        entry.processingStatus = .pending
        try? context.save()
        signal()
    }

    /// Reset every entry to `.pending`. Useful after a prompt change so
    /// historical entries can be re-extracted against the new logic.
    func requeueAll() {
        guard let container else { return }
        let context = ModelContext(container)
        let descriptor = FetchDescriptor<JournalEntry>()
        guard let entries = try? context.fetch(descriptor) else { return }
        for entry in entries {
            entry.processingStatus = .pending
        }
        try? context.save()
        queueLog.info("requeueAll: \(entries.count, privacy: .public) entries reset")
        signal()
    }

    // MARK: - Worker

    private func startWorkerIfNeeded() {
        guard workerTask == nil else { return }
        let (stream, continuation) = AsyncStream<Void>.makeStream()
        signalContinuation = continuation
        workerTask = Task { [weak self] in
            for await _ in stream {
                await self?.drainPending()
            }
        }
    }

    /// Wake the worker. The stream is buffered so signals arriving while
    /// the worker is busy are not lost.
    private func signal() {
        signalContinuation?.yield(())
    }

    /// Process every entry currently in `.pending` status, oldest-first.
    /// Returns when no more pending entries remain. Will be re-invoked
    /// the next time `signal()` fires.
    private func drainPending() async {
        guard let container else { return }
        let context = ModelContext(container)

        while true {
            var descriptor = FetchDescriptor<JournalEntry>(
                predicate: #Predicate { $0.processingStatusRaw == "pending" },
                sortBy: [SortDescriptor(\.createdAt, order: .forward)]
            )
            descriptor.fetchLimit = 1
            guard let entry = (try? context.fetch(descriptor))?.first else {
                return
            }
            await process(entry: entry, in: context)
        }
    }

    /// Run extraction for a single entry. Mutates the entry's status and
    /// fields, saves through the worker's context. Never throws — failure
    /// is recorded on the entry.
    private func process(entry: JournalEntry, in context: ModelContext) async {
        let entryId = entry.entryId
        entry.processingStatus = .extracting
        try? context.save()
        queueLog.info("process \(entryId.uuidString, privacy: .public) → extracting")

        let text = entry.rawText ?? ""
        let ocr = entry.rawPhotoOCRText
        let phase = entry.phase
        let dayInPhase = entry.dayInPhase
        let visitDate = entry.visitDate

        // Resolve persisted photo basenames back to file URLs so the
        // `.directMultimodal` extraction path can feed them straight to
        // Gemma 4 vision. Photos that no longer exist on disk are
        // silently dropped — extraction falls back to the OCR text we
        // already captured at capture time.
        let imageURLs: [URL] = entry.rawPhotoFilenames.compactMap { name in
            // Skip non-image attachments (e.g. PDFs) — the VLM path is
            // image-only. The original OCR-text path still picked their
            // text up because PDFKit ran inside the photo engine.
            let isImage = name.lowercased().hasSuffix(".jpg")
                || name.lowercased().hasSuffix(".jpeg")
                || name.lowercased().hasSuffix(".png")
                || name.lowercased().hasSuffix(".heic")
            guard isImage else { return nil }
            return PhotoStorage.storedURL(for: name)
        }

        do {
            let result = try await ExtractionService.shared.extract(
                text: text,
                phase: phase,
                dayInPhase: dayInPhase,
                visitDate: visitDate,
                ocrText: ocr,
                imageURLs: imageURLs
            )
            entry.extractedJSON = result.fields.encoded()
            entry.rawExtractionResponse = result.rawResponse
            entry.processingStatus = .extracted
            entry.extractionAttempts += 1
            try? context.save()
            queueLog.info("process \(entryId.uuidString, privacy: .public) → extracted (attempts=\(entry.extractionAttempts, privacy: .public))")
        } catch {
            entry.processingStatus = .failed(message: error.localizedDescription)
            entry.extractionAttempts += 1
            try? context.save()
            queueLog.error("process \(entryId.uuidString, privacy: .public) → failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Orphan recovery

    /// Reset any entry left in `.extracting` to `.pending`. Called at
    /// app launch after a previous run was killed mid-extraction.
    private func recoverOrphans() {
        guard let container else { return }
        let context = ModelContext(container)
        let descriptor = FetchDescriptor<JournalEntry>(
            predicate: #Predicate { $0.processingStatusRaw == "extracting" }
        )
        guard let orphans = try? context.fetch(descriptor), !orphans.isEmpty else {
            return
        }
        for entry in orphans {
            entry.processingStatus = .pending
        }
        try? context.save()
        queueLog.info("recoverOrphans: \(orphans.count, privacy: .public) entries reset to pending")
    }
}
