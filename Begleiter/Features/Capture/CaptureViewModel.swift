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
                let entry = JournalEntry(
                    childId: childId,
                    visitDate: snapshotDate,
                    phase: childPhase,
                    dayInPhase: dayInPhase,
                    riskGroup: riskGroup,
                    arm: arm,
                    inputModalities: ["text"],
                    rawText: snapshotText,
                    extractedFields: result.fields,
                    rawExtractionResponse: result.rawResponse
                )
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
