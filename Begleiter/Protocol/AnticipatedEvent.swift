import Foundation

/// An event the protocol anticipates within a phase's day-range.
///
/// Used by the (future) `getAnticipatedEvents(childId:windowDays:)` tool:
/// given the current phase and day-in-phase, what events are expected in
/// the next N days? This feeds the pre-visit briefing.
///
/// CLINICAL-REVIEW: the events list under `Catalog` is illustrative — the
/// real catalog should be sourced from BFM publications and parent-education
/// materials with a clinical advisor.
struct AnticipatedEvent: Codable, Hashable, Sendable {
    let kind: String                       // e.g. "lp_with_chemo", "anc_nadir"
    let germanLabel: String                // parent-facing label
    let earliestDayFromPhaseStart: Int     // CLINICAL-REVIEW
    let latestDayFromPhaseStart: Int       // CLINICAL-REVIEW

    /// Returns true if a current day-in-phase falls within this event's window.
    func includes(dayInPhase: Int) -> Bool {
        dayInPhase >= earliestDayFromPhaseStart && dayInPhase <= latestDayFromPhaseStart
    }
}

extension AnticipatedEvent {
    /// Anticipated events by phase. Populated as stubs; the real catalog is
    /// future work. // CLINICAL-REVIEW
    static let catalog: [Phase: [AnticipatedEvent]] = [
        .inductionIA: [
            AnticipatedEvent(
                kind: "anc_nadir",
                germanLabel: "Erwarteter ANC-Tiefpunkt",
                earliestDayFromPhaseStart: 14,  // CLINICAL-REVIEW
                latestDayFromPhaseStart: 28     // CLINICAL-REVIEW
            ),
        ],
        .inductionIB: [],     // CLINICAL-REVIEW: to be populated
        .consolidationM: [],
        .consolidationHR1: [],
        .consolidationHR2: [],
        .consolidationHR3: [],
        .reinductionII: [],
        .maintenance: [],
    ]
}
