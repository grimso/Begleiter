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

    // MARK: - Async extraction pipeline state

    /// Where the entry sits in the extraction pipeline. Persisted as a
    /// raw string for SwiftData stability across iOS minor versions.
    /// Defaults to `"extracted"` so rows created before async extraction
    /// existed render unchanged on first launch after upgrade.
    var processingStatusRaw: String = "extracted"

    /// Error message attached to the last `.failed` extraction attempt.
    /// `nil` on success.
    var processingFailureMessage: String?

    /// When the processing status was last updated. Drives sort order
    /// for the pending queue and lets the UI show "wird seit X analysiert".
    var processingUpdatedAt: Date = Date.distantPast

    /// How many times extraction has been attempted (success or failure).
    /// Used to decide whether to back off automatic retries.
    var extractionAttempts: Int = 0

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
        graphNodeIds: [String] = [],
        processingStatus: ProcessingStatus = .extracted
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
        self.processingStatusRaw = processingStatus.rawValue
        self.processingFailureMessage = processingStatus.failureMessage
        self.processingUpdatedAt = .now
        self.extractionAttempts = 0
    }
}

/// Lifecycle position of an entry in the background extraction pipeline.
///
/// Encoded on disk as a raw string (`processingStatusRaw`) for SwiftData
/// migration stability. The failure message on `.failed` is stored in
/// `processingFailureMessage` rather than as an associated value, again
/// for migration safety.
enum ProcessingStatus: Sendable, Hashable {
    /// Raw entry persisted, waiting for the queue to pick it up.
    case pending
    /// The worker has claimed this entry and is running Gemma now.
    case extracting
    /// Extraction completed successfully; structured fields populated.
    case extracted
    /// Extraction failed. `processingFailureMessage` carries the detail.
    case failed(message: String?)

    var rawValue: String {
        switch self {
        case .pending:    return "pending"
        case .extracting: return "extracting"
        case .extracted:  return "extracted"
        case .failed:     return "failed"
        }
    }

    var failureMessage: String? {
        if case .failed(let m) = self { return m }
        return nil
    }

    /// Reconstruct from the raw column + optional failure message.
    static func from(raw: String, failureMessage: String?) -> ProcessingStatus {
        switch raw {
        case "pending":    return .pending
        case "extracting": return .extracting
        case "failed":     return .failed(message: failureMessage)
        default:           return .extracted
        }
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

    /// Typed lifecycle accessor. Setter writes both the raw column and
    /// the failure message, and bumps `processingUpdatedAt`.
    var processingStatus: ProcessingStatus {
        get { ProcessingStatus.from(raw: processingStatusRaw, failureMessage: processingFailureMessage) }
        set {
            processingStatusRaw = newValue.rawValue
            processingFailureMessage = newValue.failureMessage
            processingUpdatedAt = .now
        }
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
