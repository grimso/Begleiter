import Foundation
import SwiftData

/// A long-form document (typically a discharge letter or multi-page lab
/// PDF) the parent imported into the app. Gemma 4 reads the extracted
/// text in one long-context call and produces a structured memory: a
/// title, a one-sentence summary, and N topical chunks. Each chunk is
/// citable in the agent's final answer via `[D:<docId>#<chunkIndex>]`.
///
/// ## Why a separate model class instead of journal entries
///
/// Imported documents have different provenance and a different UX from
/// parent-authored journal entries:
/// - they're machine-summarised, not parent-typed,
/// - they're typically much longer per-record,
/// - the parent doesn't edit them after import (the model is the source
///   of truth — re-import to refresh),
/// - they expose a distinct citation kind so the answer footer can say
///   "Aus deinem Dokument-Speicher" instead of conflating with journal.
///
/// ## Persistence shape
///
/// `chunks` is stored as JSON-encoded `Data` for the same reason
/// `JournalEntry.extractedJSON` is — direct `Codable` arrays on `@Model`
/// are fragile across iOS minor versions. Use the `chunks` computed
/// property to read / write.
///
/// `processingStatusRaw` mirrors `JournalEntry`'s pattern so the same
/// `ProcessingStatus` enum can be reused for failure / pending /
/// imported state without re-defining it.
@Model
final class ImportedDocument {
    /// Stable per-document id used in `[D:<docId>#<chunkIndex>]`
    /// citation markers. Generated at import time.
    @Attribute(.unique) var docId: UUID

    /// Human-readable title — Gemma's best guess at the document's
    /// primary subject (e.g. "Entlassungsbericht UKE 2026-04-12").
    var title: String

    /// Filename the parent picked in the file importer. Surfaced in
    /// the list view so the parent recognises the source.
    var originalFilename: String

    /// When the parent imported it. Drives sort order in the list view.
    var importedAt: Date

    /// Raw PDF text post-extraction (PDFKit + `OCRLayout.reconstruct`).
    /// Kept verbatim so we can re-summarise with a future prompt
    /// revision without re-prompting the parent for the PDF.
    var sourceText: String

    /// One-line summary Gemma generates alongside the chunk array.
    /// Shown in the list row under the title.
    var summary: String

    /// JSON-encoded `[DocumentChunk]`. Read / write via the `chunks`
    /// accessor below.
    var chunksJSON: Data

    /// Same lifecycle state as `JournalEntry` so the UI can render
    /// failure / pending / imported rows consistently.
    var processingStatusRaw: String

    /// Error message attached to the last `.failed` import attempt.
    /// `nil` on success.
    var processingFailureMessage: String?

    init(
        docId: UUID = UUID(),
        title: String,
        originalFilename: String,
        importedAt: Date = .now,
        sourceText: String,
        summary: String,
        chunks: [DocumentChunk],
        processingStatus: ProcessingStatus = .extracted
    ) {
        self.docId = docId
        self.title = title
        self.originalFilename = originalFilename
        self.importedAt = importedAt
        self.sourceText = sourceText
        self.summary = summary
        self.chunksJSON = (try? JSONEncoder().encode(chunks)) ?? Data()
        self.processingStatusRaw = processingStatus.rawValue
        self.processingFailureMessage = processingStatus.failureMessage
    }

    /// Decoded chunks. Returns `[]` on decode failure so a corrupted
    /// row never crashes the UI — the parent can re-import.
    var chunks: [DocumentChunk] {
        (try? JSONDecoder().decode([DocumentChunk].self, from: chunksJSON)) ?? []
    }

    /// Convenience for the UI / accumulator: a chunk-ref for every
    /// chunk this document carries. Stable across reads (chunk order
    /// is the model's emit order; `index` is the contract).
    var chunkRefs: [DocumentChunkRef] {
        chunks.map { DocumentChunkRef(docId: docId, chunkIndex: $0.index) }
    }
}

/// One topical chunk of an imported document. The `kind` tag is a
/// free-text label Gemma emits — the UI just renders it as a small
/// caption ("Befund" / "Medikation" / "Entscheidung" / …). The `text`
/// field is what the agent's `search_documents` tool scores against
/// and what the final answer can quote.
///
/// `sourceSpan` is the longest contiguous run of characters from
/// ``text`` that appears verbatim in ``ImportedDocument/sourceText``,
/// recovered post-chunking by ``SourceSpanRecovery``. Optional — `nil`
/// when no run ≥ 30 characters matches (Gemma's paraphrase shares no
/// long verbatim window with the original), and on every chunk
/// persisted **before** spans were introduced (Codable migration:
/// missing key decodes to `nil`). When present, the UI can render the
/// original PDF text with the span highlighted in response to a
/// `[D:docId#chunkIndex]` citation tap — closing the
/// "structured-memory citation vs source-span grounding" gap the
/// reviewer flagged on docs/WRITEUP §4.6.
nonisolated struct DocumentChunk: Codable, Hashable, Sendable {
    let index: Int
    let kind: String
    let text: String
    let sourceSpan: SourceSpan?

    init(index: Int, kind: String, text: String, sourceSpan: SourceSpan? = nil) {
        self.index = index
        self.kind = kind
        self.text = text
        self.sourceSpan = sourceSpan
    }
}

/// A contiguous range inside ``ImportedDocument/sourceText`` that
/// matches a ``DocumentChunk/text`` verbatim. Offsets are
/// **Character-indexed** (Swift grapheme cluster offsets via
/// `String.index(_, offsetBy:)`) — not UTF-16, not byte offsets.
/// Storing the unit choice up front avoids the German-text edge cases
/// (`°`, `½`, combining accents) that bite later when extracting
/// substrings or building `AttributedString` highlights.
///
/// Persisted as part of ``DocumentChunk`` in
/// ``ImportedDocument/chunksJSON``. Codable-encoded with `start` +
/// `length`; tests assert round-trip stability and that decoders
/// tolerate the field's absence on legacy chunks.
nonisolated struct SourceSpan: Codable, Hashable, Sendable {
    /// Character offset of the first matching character into the
    /// source text. `0` means the match starts at the first character.
    let start: Int
    /// Number of characters in the match. Always `> 0` when the value
    /// exists — a zero-length span would be useless and ``SourceSpanRecovery``
    /// never emits one.
    let length: Int

    /// Extract the matching substring from `text`. Returns `nil` when
    /// the span runs off the end of `text` — e.g. when the source
    /// document was edited after the span was recorded.
    func substring(of text: String) -> String? {
        guard start >= 0, length > 0 else { return nil }
        guard start + length <= text.count else { return nil }
        let lo = text.index(text.startIndex, offsetBy: start)
        let hi = text.index(lo, offsetBy: length)
        return String(text[lo..<hi])
    }
}

/// Stable reference to one chunk inside one document. Used by the
/// surfaced-IDs accumulator and the verifiable-generation filter so
/// the agent can't cite a `(docId, chunkIndex)` pair that no tool
/// actually returned this conversation.
nonisolated struct DocumentChunkRef: Hashable, Sendable {
    let docId: UUID
    let chunkIndex: Int
}
