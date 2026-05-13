import Foundation
import SwiftUI

/// Session-ephemeral state for the `LabPlotComposerView` sheet.
///
/// Drives the natural-language → plot pipeline:
///   draft → parser.parse → resolver.resolve → result
///
/// One result + one error are held at a time; resubmitting a new
/// question replaces both. The view discards the model on sheet
/// dismissal — no SwiftData persistence by design (the Fragen chat
/// composer follows the same pattern).
@MainActor
@Observable
final class LabPlotComposerViewModel {

    /// What the user is typing.
    var draft: String = ""

    /// Which parser the next submit will use. Persisted only in-memory
    /// for the session — Settings doesn't expose this because the
    /// in-view picker IS the toggle.
    var parserKind: LabPlotParserKind = .heuristic

    /// True while a parse + resolve cycle is in flight.
    var isBusy: Bool = false

    /// Last successfully produced result. `nil` before the first
    /// submit or after a parse error. The view shows it under the
    /// input.
    var lastResult: LabPlotResult?

    /// Last error from the parser or resolver. `nil` when the latest
    /// submit succeeded. Shown as a banner above the input.
    var lastError: LabPlotComposerError?

    private let parser: LabPlotParser

    init(parser: LabPlotParser = .shared) {
        self.parser = parser
    }

    // MARK: - Intents

    /// Submit `draft`. No-op when blank or already busy. The view
    /// supplies `child` + `entries` so this VM doesn't need its own
    /// SwiftData access — same shape as `AskViewModel.submit(...)`.
    func submit(child: ChildState, entries: [JournalEntry]) {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isBusy else { return }
        isBusy = true
        lastError = nil
        let chosenParser = parserKind
        Task {
            do {
                let spec = try await parser.parse(
                    question: trimmed,
                    kind: chosenParser
                )
                let result = LabPlotResolver.resolve(
                    spec: spec,
                    child: child,
                    entries: entries
                )
                self.lastResult = result
                self.lastError = nil
            } catch let error as LabPlotParserError {
                self.lastResult = nil
                self.lastError = .parser(error)
            } catch {
                self.lastResult = nil
                self.lastError = .other(error.localizedDescription)
            }
            self.isBusy = false
        }
    }

    /// Tapping a starter chip prefills the input but doesn't submit —
    /// the parent gets a chance to edit before hitting "Plotten". Same
    /// affordance as Frag-deine-Werte.
    func prefillDraft(_ text: String) {
        draft = text
    }
}

/// Errors the composer surfaces to the user. Wraps `LabPlotParserError`
/// so the view can render a friendlier message + the underlying detail.
enum LabPlotComposerError: Error, LocalizedError, Hashable {
    case parser(LabPlotParserError)
    case other(String)

    var errorDescription: String? {
        switch self {
        case .parser(let inner): return inner.errorDescription
        case .other(let msg):    return msg
        }
    }

    static func == (lhs: LabPlotComposerError, rhs: LabPlotComposerError) -> Bool {
        switch (lhs, rhs) {
        case (.parser(let a), .parser(let b)):
            return (a.errorDescription ?? "") == (b.errorDescription ?? "")
        case (.other(let a), .other(let b)):
            return a == b
        default:
            return false
        }
    }

    func hash(into hasher: inout Hasher) {
        switch self {
        case .parser(let e): hasher.combine(0); hasher.combine(e.errorDescription ?? "")
        case .other(let s):  hasher.combine(1); hasher.combine(s)
        }
    }
}
