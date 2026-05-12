import Foundation
import SwiftData
import SwiftUI

/// View model for the journal capture screen.
///
/// Behaviour after the async-extraction refactor: `submit(...)` persists
/// the raw entry to SwiftData with `processingStatus = .pending`, kicks
/// the `ExtractionQueue`, and immediately sets `phase = .done` so the
/// modal dismisses. Gemma runs in the background; the timeline shows the
/// entry with a "wird analysiert" badge until the worker fills in
/// structured fields.
@MainActor
@Observable
final class CaptureViewModel {
    enum Phase: Equatable {
        case idle
        case saving
        case done
        case failed(message: String)
    }

    var text: String = ""
    var visitDate: Date = .now
    var phase: Phase = .idle
    /// Verbatim transcript from the SpeechRecognizer pass, set when the
    /// parent uses voice input. Persisted on JournalEntry.rawVoiceTranscript.
    var voiceTranscript: String?
    /// Basename of the .m4a recording in Documents/voice/. Set when the
    /// parent uses voice input and the recording was successfully written.
    var voiceAudioFilename: String?
    /// Raw bytes (image or PDF) of Befund attachments picked by the
    /// parent. Persisted to `Documents/photos/<entryId>/<n>.<ext>` at
    /// submit time and referenced from `JournalEntry.rawPhotoFilenames`.
    var pendingPhotoData: [PendingAttachment] = []
    /// OCR text from each picked photo / PDF, in pick order. Concatenated
    /// at submit time and stored on `JournalEntry.rawPhotoOCRText` so the
    /// ExtractionQueue can re-run extraction against it any number of times.
    var pendingOCRTexts: [String] = []

    struct PendingAttachment: Sendable, Hashable {
        let data: Data
        /// Original file extension (jpg, png, pdf, …) so the file
        /// survives in its native format on disk.
        let ext: String
    }

    /// Combined OCR text from all picked Befund attachments. `nil` if no
    /// photo/PDF was picked (or all OCR passes were empty).
    var combinedOCRText: String? {
        let parts = pendingOCRTexts
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: "\n\n---\n\n")
    }

    init() {}

    var canSubmit: Bool {
        // The entry is creatable if the parent typed something OR picked
        // an attachment OR recorded voice. The previous all-text-only
        // gate was overly strict for the attachment-only flow.
        let hasText = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasVoice = voiceTranscript != nil
        let hasPhoto = !pendingPhotoData.isEmpty
        return (hasText || hasVoice || hasPhoto) && !isBusy
    }

    var isBusy: Bool {
        if case .saving = phase { return true }
        return false
    }

    /// Persist the raw entry and hand off extraction to the background
    /// `ExtractionQueue`. The sheet dismisses as soon as the SwiftData
    /// save completes (~milliseconds) — Gemma never runs synchronously
    /// from here.
    func submit(child: ChildState, context: ModelContext) {
        guard canSubmit else { return }
        let snapshotText = text
        let snapshotDate = visitDate
        let childPhase = child.currentPhase
        let dayInPhase = child.currentPhaseInfo().dayInPhase
        let riskGroup = child.riskGroup
        let arm = child.randomizationArm
        let childId = child.childId

        phase = .saving
        Task {
            do {
                var modalities: [String] = []
                if voiceTranscript != nil { modalities.append("voice") }
                if !pendingPhotoData.isEmpty { modalities.append("photo") }
                let userEditedText = snapshotText.trimmingCharacters(in: .whitespacesAndNewlines)
                let voiceText = (voiceTranscript ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                if !userEditedText.isEmpty, userEditedText != voiceText {
                    modalities.append("text")
                } else if voiceTranscript == nil, pendingPhotoData.isEmpty {
                    modalities.append("text")
                }
                let entryId = UUID()

                // Persist attachments to Documents/photos/.
                var photoFilenames: [String] = []
                for (index, attachment) in pendingPhotoData.enumerated() {
                    if attachment.ext.lowercased() == "jpg" || attachment.ext.lowercased() == "jpeg" {
                        if let name = try? PhotoStorage.saveJPEG(attachment.data, entryId: entryId, index: index) {
                            photoFilenames.append(name)
                        }
                    } else {
                        if let name = try? PhotoStorage.saveRawFile(attachment.data, entryId: entryId, index: index, ext: attachment.ext) {
                            photoFilenames.append(name)
                        }
                    }
                }

                let entry = JournalEntry(
                    entryId: entryId,
                    childId: childId,
                    visitDate: snapshotDate,
                    phase: childPhase,
                    dayInPhase: dayInPhase,
                    riskGroup: riskGroup,
                    arm: arm,
                    inputModalities: modalities,
                    rawText: snapshotText.isEmpty ? nil : snapshotText,
                    rawVoiceTranscript: voiceTranscript,
                    rawPhotoFilenames: photoFilenames,
                    extractedFields: .empty,
                    rawExtractionResponse: nil,
                    processingStatus: .pending
                )
                entry.rawVoiceAudioFilename = voiceAudioFilename
                entry.rawPhotoOCRText = combinedOCRText
                context.insert(entry)
                try context.save()

                // Hand off to the background queue. Fire-and-forget;
                // the queue's worker will pick the entry up on its next
                // signal-driven cycle.
                await ExtractionQueue.shared.enqueue(entryId: entryId)

                phase = .done
            } catch {
                phase = .failed(message: error.localizedDescription)
            }
        }
    }

    func reset() {
        text = ""
        visitDate = .now
        phase = .idle
        voiceTranscript = nil
        voiceAudioFilename = nil
        pendingPhotoData = []
        pendingOCRTexts = []
    }
}
