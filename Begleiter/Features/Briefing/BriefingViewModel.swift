import Foundation
import SwiftData
import SwiftUI

@MainActor
@Observable
final class BriefingViewModel {
    enum State: Equatable {
        case idle
        case generating
        case done(Briefing)
        case failed(String)
    }

    var visitDate: Date = .now.addingTimeInterval(24 * 60 * 60)
    private(set) var state: State = .idle

    private let service: BriefingService
    /// Entries snapshotted at generate time so we can resolve `entryId →
    /// JournalEntry` for tap-to-trace.
    private(set) var resolveEntry: [UUID: JournalEntry] = [:]

    init(service: BriefingService = BriefingService()) {
        self.service = service
    }

    var isBusy: Bool {
        if case .generating = state { return true }
        return false
    }

    /// Generate a briefing using up to `entryLimit` most-recent entries for
    /// the given child.
    func generate(child: ChildState, allEntries: [JournalEntry], entryLimit: Int = 8) {
        let snapshot = child.snapshot()
        let recent = Array(
            allEntries
                .sorted { $0.visitDate > $1.visitDate }
                .prefix(entryLimit)
        )
        // Build the resolution map BEFORE we kick the model so the UI can
        // render citations even if the model is mid-flight.
        resolveEntry = Dictionary(uniqueKeysWithValues: recent.map { ($0.entryId, $0) })
        let date = visitDate

        state = .generating
        Task {
            do {
                let briefing = try await service.generateBriefing(
                    for: date, child: snapshot, entries: recent
                )
                state = .done(briefing)
            } catch {
                state = .failed(error.localizedDescription)
            }
        }
    }
}
