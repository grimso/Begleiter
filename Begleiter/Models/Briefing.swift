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

    init(
        targetDate: Date,
        aktuellerStand: BriefingClaim,
        seitDemLetztenTermin: [BriefingClaim],
        offenePunkte: [BriefingClaim],
        fragenVorschlaege: [String]
    ) {
        self.targetDate = targetDate
        self.aktuellerStand = aktuellerStand
        self.seitDemLetztenTermin = seitDemLetztenTermin
        self.offenePunkte = offenePunkte
        self.fragenVorschlaege = fragenVorschlaege
    }

    private enum CodingKeys: String, CodingKey {
        case targetDate, aktuellerStand, seitDemLetztenTermin
        case offenePunkte, fragenVorschlaege
    }

    /// Tolerant decoder. Briefing's schema has many required fields; the
    /// model sometimes omits or malforms one. Rather than failing the
    /// whole briefing, default missing pieces (caller passes `visitDate`
    /// for the missing `targetDate`; missing arrays default to `[]`;
    /// missing `aktuellerStand` becomes an empty-text placeholder which
    /// the UI hides via `if !text.isEmpty`).
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // targetDate: try to decode as ISO8601 date or "yyyy-MM-dd" string.
        if let date = try? c.decode(Date.self, forKey: .targetDate) {
            self.targetDate = date
        } else if let str = try? c.decode(String.self, forKey: .targetDate),
                  let parsed = Self.dateFormatter.date(from: str) {
            self.targetDate = parsed
        } else {
            // Fallback: caller (BriefingService.generateBriefing) overwrites
            // with the visitDate it passed in. Sentinel: distant past.
            self.targetDate = Date(timeIntervalSince1970: 0)
        }
        self.aktuellerStand = (try? c.decode(BriefingClaim.self, forKey: .aktuellerStand))
            ?? BriefingClaim(text: "", entryId: nil)
        self.seitDemLetztenTermin = (try? c.decode([BriefingClaim].self, forKey: .seitDemLetztenTermin)) ?? []
        self.offenePunkte = (try? c.decode([BriefingClaim].self, forKey: .offenePunkte)) ?? []
        self.fragenVorschlaege = (try? c.decode([String].self, forKey: .fragenVorschlaege)) ?? []
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "de_DE")
        return formatter
    }()
}

nonisolated struct BriefingClaim: Codable, Hashable, Sendable {
    /// The German text of the claim.
    let text: String
    /// JournalEntry.entryId the claim is grounded in. May be `nil` for
    /// "general" claims sourced from the protocol state machine (drugs in
    /// current phase, anticipated events, etc).
    let entryId: UUID?

    init(text: String, entryId: UUID?) {
        self.text = text
        self.entryId = entryId
    }

    private enum CodingKeys: String, CodingKey {
        case text, entryId
    }

    /// Tolerant decoder. Real Gemma output occasionally emits a non-UUID
    /// string for `entryId` (or the literal "null"), which would crash
    /// strict UUID decoding. Catch and set to `nil` in those cases — the
    /// claim text is still useful even without a citation chip.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.text = (try? c.decode(String.self, forKey: .text)) ?? ""
        if let uuid = try? c.decode(UUID.self, forKey: .entryId) {
            self.entryId = uuid
        } else {
            // Either missing, null, or a malformed string. Drop the citation.
            self.entryId = nil
        }
    }
}
