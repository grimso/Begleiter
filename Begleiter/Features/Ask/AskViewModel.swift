import Foundation
import SwiftData
import SwiftUI

/// Session-ephemeral state for the `AskView` chat surface. Holds the
/// stack of prior Q&A cards rendered within the sheet, the in-flight
/// loading state, and the draft text the user is composing.
///
/// Discarded on sheet dismissal — no SwiftData persistence by design.
/// Multi-turn conversation, history, and OTA corpus updates are the
/// stretch list, not the MVP.
@MainActor
@Observable
final class AskViewModel {
    /// All Q&A cards produced this session, oldest first. The view
    /// renders them top-to-bottom and auto-scrolls to the newest on
    /// append.
    var cards: [AskAnswer] = []

    /// What the user is typing into the input bar.
    var draft: String = ""

    /// True while a Gemma call is in flight. Disables the send button
    /// and renders a loading indicator below the most recent card.
    var isAnswering: Bool = false

    /// Which scope this chat is locked to. `.all` for the toolbar entry
    /// from TimelineView, `.labs` for the LabValuesView CTA.
    let scope: AskScope

    private let service: AskService
    /// Snapshot of the journal supplied at construction. Refreshed via
    /// `updateEntries(_:)` whenever the SwiftData @Query upstream
    /// changes — keeps retrieval in sync with new captures without
    /// rebuilding the viewmodel.
    private(set) var entries: [JournalEntry] = []

    init(scope: AskScope, service: AskService = .shared) {
        self.scope = scope
        self.service = service
    }

    /// SwiftUI calls this from `onAppear` and again whenever the
    /// upstream `@Query` updates so the retrieval pass always sees the
    /// current journal.
    func updateEntries(_ entries: [JournalEntry]) {
        self.entries = entries
    }

    // MARK: - Intents

    /// Submit the current draft. No-op if blank or already answering.
    func submit() {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isAnswering else { return }
        let question = AskQuestion(text: trimmed, scope: scope)
        draft = ""
        isAnswering = true
        let entriesSnapshot = entries
        Task {
            let answer = await service.answer(question, in: entriesSnapshot)
            self.cards.append(answer)
            self.isAnswering = false
        }
    }

    /// Tapping a starter or follow-up chip populates the input rather
    /// than auto-submitting — gives the parent a moment to edit the
    /// wording before sending.
    func prefillDraft(_ text: String) {
        draft = text
    }
}
