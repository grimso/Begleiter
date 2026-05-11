import Foundation

/// A reaction or adverse event the parent reports.
///
/// CTCAE grading is **not** done by the app. We capture what the parent says
/// in plain language plus an optional severity hint they assign themselves.
/// The treating team is the authority on actual grading.
nonisolated struct AdverseEvent: Codable, Hashable, Sendable {
    nonisolated enum ParentSeverity: String, Codable, Sendable {
        case mild = "leicht"
        case moderate = "mittel"
        case severe = "schwer"
    }

    /// Free-text description of the event in the parent's words.
    let description: String
    /// Drug or procedure the parent associates the event with, if any.
    let suspectedCause: String?
    /// Parent's own severity rating. Not a clinical grade.
    let parentSeverity: ParentSeverity?
    /// When the event occurred (may differ from the entry's visit date).
    let occurredAt: Date?
}
