import Foundation

/// A one-page clinical-style handoff for a new rotating doctor.
///
/// Distinct from `Briefing`:
/// - Audience is a clinician, not a parent → terse, structured German.
/// - Optional English translation for cross-border / specialist sharing.
/// - Sections are fixed and mirror the spec's clinical handoff outline.
nonisolated struct HandoffDocument: Codable, Hashable, Sendable {
    let generatedAt: Date
    let language: HandoffLanguage

    let patientId: String                       // anonymised initials + DOB or similar
    let diagnose: String                        // e.g. "ALL, ED 03/2026"
    let riskGroupLabel: String
    let randomizationLabel: String
    let phaseLabel: String
    let dayInPhase: Int

    /// Compressed treatment history (one line per completed phase + current).
    /// Items synthesized from `ChildState.completedPhases` carry
    /// `entryId == nil`; items Gemma generates from a specific journal
    /// entry carry that entry's UUID after the citation filter
    /// validated it against the surfaced set.
    let behandlungsverlauf: [HandoffClaim]
    /// Recent lab values, most recent first.
    let aktuelleLabore: [HandoffLabLine]
    /// Reactions / adverse events worth flagging — Gemma-generated with
    /// `[HandoffClaim/entryId]` pointing at the source journal entry
    /// when present.
    let reaktionen: [HandoffClaim]
    /// Current medication list as parent has documented it.
    let aktuelleMedikation: [String]
    /// Open concerns the family wants the new doctor to know — Gemma-
    /// generated with `[HandoffClaim/entryId]` pointing at the source
    /// journal entry when present.
    let familienanliegen: [HandoffClaim]

    /// Tolerant decoder. Legacy persisted handoffs (before §S4 added
    /// citation fields) stored these three sections as `[String]`; the
    /// decoder unboxes either shape so an upgrade doesn't break.
    private enum CodingKeys: String, CodingKey {
        case generatedAt, language, patientId, diagnose
        case riskGroupLabel, randomizationLabel, phaseLabel, dayInPhase
        case behandlungsverlauf, aktuelleLabore, reaktionen
        case aktuelleMedikation, familienanliegen
    }

    init(
        generatedAt: Date,
        language: HandoffLanguage,
        patientId: String,
        diagnose: String,
        riskGroupLabel: String,
        randomizationLabel: String,
        phaseLabel: String,
        dayInPhase: Int,
        behandlungsverlauf: [HandoffClaim],
        aktuelleLabore: [HandoffLabLine],
        reaktionen: [HandoffClaim],
        aktuelleMedikation: [String],
        familienanliegen: [HandoffClaim]
    ) {
        self.generatedAt = generatedAt
        self.language = language
        self.patientId = patientId
        self.diagnose = diagnose
        self.riskGroupLabel = riskGroupLabel
        self.randomizationLabel = randomizationLabel
        self.phaseLabel = phaseLabel
        self.dayInPhase = dayInPhase
        self.behandlungsverlauf = behandlungsverlauf
        self.aktuelleLabore = aktuelleLabore
        self.reaktionen = reaktionen
        self.aktuelleMedikation = aktuelleMedikation
        self.familienanliegen = familienanliegen
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.generatedAt = try c.decode(Date.self, forKey: .generatedAt)
        self.language = try c.decode(HandoffLanguage.self, forKey: .language)
        self.patientId = try c.decode(String.self, forKey: .patientId)
        self.diagnose = try c.decode(String.self, forKey: .diagnose)
        self.riskGroupLabel = try c.decode(String.self, forKey: .riskGroupLabel)
        self.randomizationLabel = try c.decode(String.self, forKey: .randomizationLabel)
        self.phaseLabel = try c.decode(String.self, forKey: .phaseLabel)
        self.dayInPhase = try c.decode(Int.self, forKey: .dayInPhase)
        self.aktuelleLabore = (try? c.decode([HandoffLabLine].self, forKey: .aktuelleLabore)) ?? []
        self.aktuelleMedikation = (try? c.decode([String].self, forKey: .aktuelleMedikation)) ?? []
        self.behandlungsverlauf = Self.decodeClaims(from: c, forKey: .behandlungsverlauf)
        self.reaktionen = Self.decodeClaims(from: c, forKey: .reaktionen)
        self.familienanliegen = Self.decodeClaims(from: c, forKey: .familienanliegen)
    }

    /// Decode `[HandoffClaim]` first; fall back to `[String]` for
    /// legacy persisted handoffs and synthesize claims with
    /// `entryId == nil`.
    private static func decodeClaims(
        from container: KeyedDecodingContainer<CodingKeys>,
        forKey key: CodingKeys
    ) -> [HandoffClaim] {
        if let claims = try? container.decode([HandoffClaim].self, forKey: key) {
            return claims
        }
        if let strings = try? container.decode([String].self, forKey: key) {
            return strings.map { HandoffClaim(text: $0, entryId: nil) }
        }
        return []
    }
}

/// One bullet in a Gemma-generated handoff section. Mirrors
/// ``BriefingClaim`` — flat optional `entryId` instead of the full
/// ``Citation`` enum because handoff prose only ever cites journal
/// entries (corpus and document grounding are out of scope here). The
/// post-hoc filter in `HandoffService` drops `entryId`s the surfaced
/// set didn't include and scrubs advice-shaped text via
/// `RefusalService.scrubbed`, matching the `BriefingService` contract.
nonisolated struct HandoffClaim: Codable, Hashable, Sendable {
    /// The German (or English, on `.english` runs) clinical phrasing.
    let text: String
    /// `JournalEntry.entryId` the claim is grounded in. `nil` for
    /// items synthesized from the protocol state machine (e.g.
    /// `ChildState.completedPhases` history lines) and for Gemma-
    /// generated items that didn't supply a citation or whose
    /// citation failed the filter.
    let entryId: UUID?

    init(text: String, entryId: UUID?) {
        self.text = text
        self.entryId = entryId
    }

    private enum CodingKeys: String, CodingKey {
        case text, entryId
    }

    /// Tolerant decoder — same shape as ``BriefingClaim``. Real Gemma
    /// output occasionally emits a non-UUID string for `entryId` (or
    /// the literal `"null"`); catch and set to `nil` rather than
    /// crash. The claim text is still useful without a chip.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.text = (try? c.decode(String.self, forKey: .text)) ?? ""
        if let uuid = try? c.decode(UUID.self, forKey: .entryId) {
            self.entryId = uuid
        } else {
            self.entryId = nil
        }
    }
}

nonisolated enum HandoffLanguage: String, Codable, Sendable {
    case german = "de"
    case english = "en"

    var humanLabel: String {
        switch self {
        case .german:  return "Deutsch"
        case .english: return "English"
        }
    }
}

nonisolated struct HandoffLabLine: Codable, Hashable, Sendable {
    let parameter: String      // e.g. "ANC"
    let germanLabel: String    // e.g. "Neutrophile"
    let value: String          // pre-formatted, e.g. "0.6 G/L"
    let measuredAt: Date
    let referenceRange: String?
}
