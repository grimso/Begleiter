import Foundation
import SwiftData
import SwiftUI

/// View model for the text-only journal capture screen.
///
/// Drives a single flow: parent types German text → tap "Eintrag analysieren"
/// → ExtractionService runs Gemma → on success we persist a JournalEntry
/// in SwiftData and signal the view to dismiss.
@MainActor
@Observable
final class CaptureViewModel {
    enum Phase: Equatable {
        case idle
        case extracting
        case saving
        case done
        case failed(message: String)
    }

    var text: String = ""
    var visitDate: Date = .now
    var phase: Phase = .idle
    /// Verbatim transcript from the SpeechAnalyzer pass, set when the
    /// parent uses voice input. Persisted on JournalEntry.rawVoiceTranscript
    /// alongside the (possibly edited) `text` that gets sent to extraction.
    var voiceTranscript: String?
    /// Basename of the .m4a recording in Documents/voice/. Set when the
    /// parent uses voice input and the recording was successfully written.
    var voiceAudioFilename: String?
    /// Raw bytes (image or PDF) of Befund attachments picked by the
    /// parent. Persisted to `Documents/photos/<entryId>/<n>.<ext>` at
    /// submit time and referenced from `JournalEntry.rawPhotoFilenames`.
    var pendingPhotoData: [PendingAttachment] = []

    struct PendingAttachment: Sendable, Hashable {
        let data: Data
        /// Original file extension (jpg, png, pdf, …) so the file
        /// survives in its native format on disk.
        let ext: String
    }
    /// Most recent successful extraction. UI may show a preview before saving.
    private(set) var lastExtraction: ExtractedFields?

    private let extraction: ExtractionService

    init(extraction: ExtractionService = .shared) {
        self.extraction = extraction
    }

    var canSubmit: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !isBusy
    }

    var isBusy: Bool {
        if case .extracting = phase { return true }
        if case .saving = phase { return true }
        return false
    }

    /// Extract + save in one shot. Iteration 7 will split this so the
    /// parent can confirm low-confidence fields before persistence.
    func submit(child: ChildState, context: ModelContext) {
        guard canSubmit else { return }
        let snapshotText = text
        let snapshotDate = visitDate
        let childPhase = child.currentPhase
        let dayInPhase = child.currentPhaseInfo().dayInPhase
        let riskGroup = child.riskGroup
        let arm = child.randomizationArm
        let childId = child.childId

        phase = .extracting
        Task {
            do {
                let result = try await extraction.extract(
                    text: snapshotText,
                    phase: childPhase,
                    dayInPhase: dayInPhase,
                    visitDate: snapshotDate
                )
                lastExtraction = result.fields
                phase = .saving
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
                // Persist any picked attachments to Documents/photos/.
                // Save in original format (jpg / pdf / …) so PDFs survive.
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
                    rawText: snapshotText,
                    rawVoiceTranscript: voiceTranscript,
                    rawPhotoFilenames: photoFilenames,
                    extractedFields: result.fields,
                    rawExtractionResponse: result.rawResponse
                )
                entry.rawVoiceAudioFilename = voiceAudioFilename
                context.insert(entry)
                try context.save()
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
        lastExtraction = nil
    }
}
