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
    let behandlungsverlauf: [String]
    /// Recent lab values, most recent first.
    let aktuelleLabore: [HandoffLabLine]
    /// Reactions / adverse events worth flagging.
    let reaktionen: [String]
    /// Current medication list as parent has documented it.
    let aktuelleMedikation: [String]
    /// Open concerns the family wants the new doctor to know.
    let familienanliegen: [String]
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
