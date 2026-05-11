import Foundation

/// A value Gemma 4 extracted from the parent's input, paired with a
/// self-reported confidence in `[0, 1]`.
///
/// Low-confidence fields are surfaced to the parent for confirmation in
/// later iterations; for now they're stored and rendered with a warning
/// in `EntryDetailView`.
nonisolated struct ConfidenceField<Value: Codable & Hashable & Sendable>: Codable, Hashable, Sendable {
    let value: Value
    let confidence: Double
}

/// Visit categorisation. Stable raw strings — used as JSON values and
/// localised at display time.
nonisolated enum VisitType: String, Codable, Hashable, Sendable, CaseIterable {
    case ambulant
    case stationaer
    case notfall
    case telefonisch
    case zuhause

    var germanLabel: String {
        switch self {
        case .ambulant:     return "Ambulanter Termin"
        case .stationaer:   return "Stationärer Aufenthalt"
        case .notfall:      return "Notfall"
        case .telefonisch:  return "Telefonisch"
        case .zuhause:      return "Beobachtung zuhause"
        }
    }

    var englishLabel: String {
        switch self {
        case .ambulant:     return "Outpatient visit"
        case .stationaer:   return "Inpatient stay"
        case .notfall:      return "Emergency"
        case .telefonisch:  return "Phone call"
        case .zuhause:      return "Home observation"
        }
    }
}

/// A drug as mentioned in a journal entry. Distinct from `Drug` in the
/// protocol module because here it carries an occurrence (dose, etc.) the
/// parent reported, not the canonical catalog entry. The `name` field
/// should match a canonical `Drug.name` when possible so retrieval can
/// join across the two.
nonisolated struct DrugMention: Codable, Hashable, Sendable {
    let name: String                   // canonical INN, e.g. "vincristine"
    let germanLabel: String            // as the parent said it, e.g. "Vincristin"
    let doseDescription: String?       // free text — never used for dose computation
    let administeredAt: Date?
}

/// All the fields Gemma 4 extracts from a single journal entry. Every
/// optional field corresponds to information that may or may not be
/// present in the parent's text.
///
/// Serialised as JSON and stored on `JournalEntry.extractedJSON`.
nonisolated struct ExtractedFields: Codable, Hashable, Sendable {
    var visitType: ConfidenceField<VisitType>?
    var doctorName: ConfidenceField<String>?
    var drugsMentioned: ConfidenceField<[DrugMention]>?
    var labValues: ConfidenceField<[LabValue]>?
    var proceduresMentioned: ConfidenceField<[String]>?
    var decisions: ConfidenceField<[String]>?
    var parentObservations: ConfidenceField<[String]>?
    var openQuestions: ConfidenceField<[String]>?
    var reactions: ConfidenceField<[AdverseEvent]>?
    /// Short, parent-facing one-line summary of the entry. Used as the
    /// timeline row title when the parent didn't supply one.
    var summary: ConfidenceField<String>?

    static let empty = ExtractedFields()
}

extension ExtractedFields {
    /// Encode as compact JSON for `JournalEntry.extractedJSON` (Data).
    func encoded() -> Data {
        (try? JSONEncoder.extraction.encode(self)) ?? Data("{}".utf8)
    }

    /// Decode from `JournalEntry.extractedJSON`. Returns `.empty` if data
    /// is malformed — we never want a bad blob to make the timeline
    /// uncrashable.
    static func decoded(from data: Data) -> ExtractedFields {
        (try? JSONDecoder.extraction.decode(ExtractedFields.self, from: data)) ?? .empty
    }
}

extension JSONEncoder {
    static let extraction: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()
}

extension JSONDecoder {
    static let extraction: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
