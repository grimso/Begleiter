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

    init(value: Value, confidence: Double) {
        self.value = value
        self.confidence = confidence
    }

    private enum CodingKeys: String, CodingKey {
        case value
        case confidence
    }

    /// Tolerant decoder: required `value`, optional `confidence` (defaults to
    /// 0.5 when the model omits it — Gemma sometimes leaves `confidence`
    /// off empty-array fields).
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.value = try container.decode(Value.self, forKey: .value)
        self.confidence = try container.decodeIfPresent(Double.self, forKey: .confidence) ?? 0.5
    }
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

    init(
        visitType: ConfidenceField<VisitType>? = nil,
        doctorName: ConfidenceField<String>? = nil,
        drugsMentioned: ConfidenceField<[DrugMention]>? = nil,
        labValues: ConfidenceField<[LabValue]>? = nil,
        proceduresMentioned: ConfidenceField<[String]>? = nil,
        decisions: ConfidenceField<[String]>? = nil,
        parentObservations: ConfidenceField<[String]>? = nil,
        openQuestions: ConfidenceField<[String]>? = nil,
        reactions: ConfidenceField<[AdverseEvent]>? = nil,
        summary: ConfidenceField<String>? = nil
    ) {
        self.visitType = visitType
        self.doctorName = doctorName
        self.drugsMentioned = drugsMentioned
        self.labValues = labValues
        self.proceduresMentioned = proceduresMentioned
        self.decisions = decisions
        self.parentObservations = parentObservations
        self.openQuestions = openQuestions
        self.reactions = reactions
        self.summary = summary
    }

    private enum CodingKeys: String, CodingKey {
        case visitType, doctorName, drugsMentioned, labValues
        case proceduresMentioned, decisions, parentObservations
        case openQuestions, reactions, summary
    }

    /// Per-field tolerant decoder. Each field is decoded with `try?` — a
    /// single malformed field (e.g. `"doctorName": {"value": null}`) drops
    /// only that field, leaving the rest of the extraction intact.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.visitType           = try? c.decodeIfPresent(ConfidenceField<VisitType>.self,        forKey: .visitType)
        self.doctorName          = try? c.decodeIfPresent(ConfidenceField<String>.self,           forKey: .doctorName)
        self.drugsMentioned      = try? c.decodeIfPresent(ConfidenceField<[DrugMention]>.self,    forKey: .drugsMentioned)
        self.labValues           = try? c.decodeIfPresent(ConfidenceField<[LabValue]>.self,       forKey: .labValues)
        self.proceduresMentioned = try? c.decodeIfPresent(ConfidenceField<[String]>.self,         forKey: .proceduresMentioned)
        self.decisions           = try? c.decodeIfPresent(ConfidenceField<[String]>.self,         forKey: .decisions)
        self.parentObservations  = try? c.decodeIfPresent(ConfidenceField<[String]>.self,         forKey: .parentObservations)
        self.openQuestions       = try? c.decodeIfPresent(ConfidenceField<[String]>.self,         forKey: .openQuestions)
        self.reactions           = try? c.decodeIfPresent(ConfidenceField<[AdverseEvent]>.self,   forKey: .reactions)
        self.summary             = try? c.decodeIfPresent(ConfidenceField<String>.self,           forKey: .summary)
    }
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
