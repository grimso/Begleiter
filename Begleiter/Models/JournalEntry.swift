import Foundation
import SwiftData

/// A single journal entry — one captured visit/event in the child's
/// treatment record.
///
/// `extractedJSON` is a JSON-encoded `ExtractedFields`. Direct `Codable`
/// arrays on `@Model` types are still fragile across iOS minor versions,
/// so we keep the structured data as `Data` and bridge via typed accessors.
///
/// `embedding` is the dense vector for hybrid search (iteration 6). It is
/// populated as `[]` in iteration 3 and filled in once the embedding
/// service lands. `graphNodeIds` is similarly empty for now.
@Model
final class JournalEntry {
    var entryId: UUID
    var childId: UUID
    var createdAt: Date
    var visitDate: Date

    /// Phase context auto-captured at entry creation from `ChildState`.
    var phaseRaw: String
    var dayInPhase: Int
    var riskGroupRaw: String
    var randomizationArmRaw: String

    /// Which modalities contributed to this entry. Subset of
    /// `["voice", "photo", "text"]`. Iteration 3 produces text-only entries.
    var inputModalities: [String]

    /// Raw inputs preserved verbatim. Voice and photo paths fill in later.
    var rawText: String?
    var rawVoiceTranscript: String?
    var rawPhotoFilenames: [String]
    /// Basename of the .m4a file in `Documents/voice/`. Set by
    /// `CaptureViewModel.submit` when the parent used voice input.
    /// Optional → SwiftData auto-migrates existing entries to nil.
    var rawVoiceAudioFilename: String?

    /// `ExtractedFields` encoded as JSON. Use `extractedFields` accessor.
    var extractedJSON: Data

    /// The exact string Gemma emitted before we parsed it. Kept verbatim
    /// (including markdown fences if present) so we can:
    /// - re-parse with a future, more permissive parser,
    /// - A/B compare prompt revisions on the same input,
    /// - assemble (input, output) pairs for the iter-5 LoRA fine-tune,
    /// - audit what the model said in support of the parent-facing fields.
    /// `nil` for entries created before this field existed (SwiftData
    /// auto-migrates).
    var rawExtractionResponse: String?

    /// Concatenated OCR text from photo / PDF Befunde for this entry.
    /// Passed to Gemma as a separate context block during extraction
    /// (NOT merged into `rawText`, which stays the parent's free-text
    /// input). Persisted so we can re-run extraction with a better
    /// prompt later. Hidden from the main entry-detail UI by default;
    /// surfaced behind a disclosure for transparency. `nil` for entries
    /// without photo input.
    var rawPhotoOCRText: String?

    /// Dense semantic embedding. Empty in iteration 3 — filled by the
    /// embedding service in iteration 6.
    var embedding: [Float]

    /// Knowledge-graph node refs produced at ingestion. Empty in iteration 3.
    var graphNodeIds: [String]

    init(
        entryId: UUID = UUID(),
        childId: UUID,
        createdAt: Date = .now,
        visitDate: Date,
        phase: Phase,
        dayInPhase: Int,
        riskGroup: RiskGroup,
        arm: RandomizationArm,
        inputModalities: [String],
        rawText: String? = nil,
        rawVoiceTranscript: String? = nil,
        rawPhotoFilenames: [String] = [],
        extractedFields: ExtractedFields = .empty,
        rawExtractionResponse: String? = nil,
        embedding: [Float] = [],
        graphNodeIds: [String] = []
    ) {
        self.entryId = entryId
        self.childId = childId
        self.createdAt = createdAt
        self.visitDate = visitDate
        self.phaseRaw = phase.rawValue
        self.dayInPhase = dayInPhase
        self.riskGroupRaw = riskGroup.rawValue
        self.randomizationArmRaw = arm.rawValue
        self.inputModalities = inputModalities
        self.rawText = rawText
        self.rawVoiceTranscript = rawVoiceTranscript
        self.rawPhotoFilenames = rawPhotoFilenames
        self.extractedJSON = extractedFields.encoded()
        self.rawExtractionResponse = rawExtractionResponse
        self.embedding = embedding
        self.graphNodeIds = graphNodeIds
    }
}

// MARK: - Typed accessors

extension JournalEntry {
    var phase: Phase {
        get { Phase(rawValue: phaseRaw) ?? .inductionIA }
        set { phaseRaw = newValue.rawValue }
    }

    var riskGroup: RiskGroup {
        get { RiskGroup(rawValue: riskGroupRaw) ?? .standardRisk }
        set { riskGroupRaw = newValue.rawValue }
    }

    var randomizationArm: RandomizationArm {
        get { RandomizationArm(rawValue: randomizationArmRaw) ?? .unknown }
        set { randomizationArmRaw = newValue.rawValue }
    }

    var extractedFields: ExtractedFields {
        get { ExtractedFields.decoded(from: extractedJSON) }
        set { extractedJSON = newValue.encoded() }
    }

    /// One-line title for the timeline row. Prefers the summary from
    /// extraction, then falls back to the first non-empty line of raw text,
    /// then a generic phrase.
    var displayTitle: String {
        if let summary = extractedFields.summary?.value, !summary.isEmpty {
            return summary
        }
        if let raw = rawText?.split(separator: "\n").first?.trimmingCharacters(in: .whitespaces),
           !raw.isEmpty {
            return String(raw.prefix(80))
        }
        return "Tagebucheintrag"
    }
}
