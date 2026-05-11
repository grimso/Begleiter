import Foundation

/// A generated pre-visit briefing.
///
/// The model emits a `Briefing` with sections. Each claim in the body is a
/// `BriefingClaim` paired with an `entryId` so the UI can tap-to-trace a
/// claim back to the source journal entry. This is the project's
/// "verifiable generation" affordance.
nonisolated struct Briefing: Codable, Hashable, Sendable {
    /// Date the briefing is targeted at — typically tomorrow's visit.
    let targetDate: Date
    /// One-line "where are we now" header.
    let aktuellerStand: BriefingClaim
    /// What happened since the last visit. Multiple claims, each cited.
    let seitDemLetztenTermin: [BriefingClaim]
    /// Open questions / unresolved items the parent should bring up.
    let offenePunkte: [BriefingClaim]
    /// Three suggested questions the parent might want to ask.
    let fragenVorschlaege: [String]
    /// Concrete things to bring (lab booklet, Heparin pen, ID, etc.).
    let mitzunehmen: [String]
}

nonisolated struct BriefingClaim: Codable, Hashable, Sendable {
    /// The German text of the claim.
    let text: String
    /// JournalEntry.entryId the claim is grounded in. May be `nil` for
    /// "general" claims sourced from the protocol state machine (drugs in
    /// current phase, anticipated events, etc).
    let entryId: UUID?
}
