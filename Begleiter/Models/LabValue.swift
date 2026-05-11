import Foundation

/// A single laboratory value as it appears in a journal entry.
///
/// Lab values are extracted from voice/text/photo and may also be entered
/// directly. `referenceMin` / `referenceMax` are taken from the Befund when
/// available; otherwise the UI consults a static table.
///
/// `source` records where the value came from so the timeline can render
/// the right provenance icon ("aus Befund", "aus Sprachnotiz", etc.).
nonisolated struct LabValue: Codable, Hashable, Sendable {
    nonisolated enum Source: String, Codable, Sendable {
        case befundPhoto = "befund_photo"
        case voice
        case text
        case manual
    }

    let parameter: String        // canonical short code, e.g. "WBC", "ANC", "Hb", "PLT"
    let germanLabel: String      // "Leukozyten", "Neutrophile", "Hämoglobin", "Thrombozyten"
    let value: Double
    let unit: String             // "G/L", "g/dL", etc. — kept as-is from the Befund
    let referenceMin: Double?
    let referenceMax: Double?
    let measuredAt: Date
    let source: Source
}
