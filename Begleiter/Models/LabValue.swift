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

    init(
        parameter: String,
        germanLabel: String,
        value: Double,
        unit: String,
        referenceMin: Double? = nil,
        referenceMax: Double? = nil,
        measuredAt: Date = .now,
        source: Source = .text
    ) {
        self.parameter = parameter
        self.germanLabel = germanLabel
        self.value = value
        self.unit = unit
        self.referenceMin = referenceMin
        self.referenceMax = referenceMax
        self.measuredAt = measuredAt
        self.source = source
    }

    private enum CodingKeys: String, CodingKey {
        case parameter, germanLabel, value, unit
        case referenceMin, referenceMax, measuredAt, source
    }

    /// Tolerant decoder. Real Gemma output sometimes omits `germanLabel`
    /// (it's redundant with parameter) or `source` (irrelevant for the
    /// parent UI), or emits a source string that isn't one of our enum
    /// cases ("pdf", "Befund", etc.). The previous strict decoder
    /// rejected the **entire labValues array** when any individual entry
    /// failed — explaining why "no labs show up" when the OCR text
    /// clearly contained labs. Each field now defaults to a sensible
    /// fallback if missing / malformed.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.parameter = try c.decode(String.self, forKey: .parameter)
        self.germanLabel = (try? c.decode(String.self, forKey: .germanLabel)) ?? parameter
        self.value = try c.decode(Double.self, forKey: .value)
        self.unit = (try? c.decode(String.self, forKey: .unit)) ?? ""
        self.referenceMin = try? c.decode(Double.self, forKey: .referenceMin)
        self.referenceMax = try? c.decode(Double.self, forKey: .referenceMax)

        // measuredAt: accept Date (ISO8601) or "yyyy-MM-dd" string, else .now.
        if let date = try? c.decode(Date.self, forKey: .measuredAt) {
            self.measuredAt = date
        } else if let s = try? c.decode(String.self, forKey: .measuredAt),
                  let parsed = Self.dateFormatter.date(from: s) {
            self.measuredAt = parsed
        } else {
            self.measuredAt = .now
        }

        // source: accept any known enum case, else default to .text.
        self.source = (try? c.decode(Source.self, forKey: .source)) ?? .text
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "de_DE")
        return f
    }()
}
