import Foundation
import MLXLMCommon
import OSLog

private let docImportLog = Logger(
    subsystem: "io.grimso.Begleiter",
    category: "gemma.document.import"
)

/// Errors `DocumentImportService` raises when an import can't proceed.
/// The import view maps these to inline error rows; the service log
/// records the structural reason without leaking the source text.
enum DocumentImportError: Error, LocalizedError {
    /// Source text was empty or below the configured floor (200 chars).
    /// Typically a scanned-image PDF where PDFKit returned no text and
    /// rendered-page OCR also produced nothing. We refuse rather than
    /// hand Gemma nothing to summarise — the model would invent content.
    case tooShort(actual: Int)
    /// Source text exceeded `AppSettings.docImportMaxChars`. Surfaced
    /// with the current cap so the parent can either dial up the
    /// Settings slider (on 8 GB devices) or import a shorter excerpt.
    case tooLong(actual: Int, limit: Int)
    /// Gemma returned no parseable JSON block, even after the strict
    /// retry. Mirrors `ExtractionError.modelReturnedNoJSON` semantics.
    case modelReturnedNoJSON
    /// Gemma's JSON didn't decode into the expected schema.
    case modelReturnedInvalidJSON(String)

    var errorDescription: String? {
        switch self {
        case .tooShort(let actual):
            return "Das PDF enthält zu wenig lesbaren Text (\(actual) Zeichen). Vermutlich ein eingescanntes Bild ohne Text-Ebene."
        case .tooLong(let actual, let limit):
            return "Das Dokument ist zu lang: \(actual) Zeichen, Limit \(limit). Limit unter Einstellungen → Entwicklung anpassen oder einen Auszug importieren."
        case .modelReturnedNoJSON:
            return "Gemma hat keinen JSON-Block geliefert."
        case .modelReturnedInvalidJSON(let detail):
            return "Gemma hat ungültiges JSON geliefert: \(detail)"
        }
    }
}

/// JSON shape Gemma emits for one imported document. Mirrors
/// ``ExtractionService``'s tolerant decoder pattern — every field
/// outside `chunks[].text` has a sensible fallback so a partial
/// response still produces a usable `ImportedDocument`.
private struct WireImportedDocument: Codable {
    let title: String?
    let summary: String?
    let chunks: [WireChunk]?

    struct WireChunk: Codable {
        let kind: String?
        let text: String
    }
}

/// Wraps one Gemma call that takes a long-form document and emits a
/// structured cited memory: title + one-line summary + N topical
/// chunks. Each chunk becomes citable in the agent's final answer via
/// `[D:<docId>#<chunkIndex>]`.
///
/// Single-call by design: the long-context Gemma 4 path is the headline
/// capability here. We do NOT chunk-and-loop — if a document doesn't
/// fit in `AppSettings.docImportMaxChars`, the import refuses with a
/// `.tooLong` error pointing the parent at the Settings dial.
actor DocumentImportService {

    /// App-wide shared instance — mirrors `ExtractionService.shared`
    /// so the memory-warning handler can drop weights without holding a
    /// per-view-model reference.
    static let shared = DocumentImportService()

    private let gemma: GemmaService

    init(gemma: GemmaService = .shared) {
        self.gemma = gemma
    }

    /// Bridge to the memory-warning handler — unloads the same Gemma
    /// instance the rest of the app shares.
    func unloadModel() async {
        await gemma.unload()
    }

    /// Import a document. The caller has already extracted the source
    /// text via `PhotoCaptureViewModel.ingestPDF` (or equivalent); we
    /// take `sourceText` as input rather than re-running PDFKit so the
    /// import view stays the one place that knows about file URLs.
    ///
    /// - Parameters:
    ///   - originalFilename: surfaced to the parent in the list view.
    ///   - sourceText: raw PDF text post-extraction.
    ///   - maxChars: hard cap on `sourceText.count` from `AppSettings`.
    /// - Returns: an `ImportedDocument` whose `chunks` array carries
    ///   `[D:<docId>#<idx>]`-citable units. **Not** inserted into the
    ///   SwiftData store — the import view is responsible for that so
    ///   we don't need a `@MainActor` ModelContext on this actor.
    /// - Throws: ``DocumentImportError`` on empty / oversize / parse
    ///   failure. Caller maps to a `.failed(message:)` row.
    func importDocument(
        originalFilename: String,
        sourceText: String,
        maxChars: Int
    ) async throws -> ImportedDocument {
        let trimmed = sourceText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 200 else {
            docImportLog.warning("import refused: too short (\(trimmed.count, privacy: .public) chars)")
            throw DocumentImportError.tooShort(actual: trimmed.count)
        }
        guard trimmed.count <= maxChars else {
            docImportLog.warning("import refused: too long (\(trimmed.count, privacy: .public) > \(maxChars, privacy: .public))")
            throw DocumentImportError.tooLong(actual: trimmed.count, limit: maxChars)
        }

        docImportLog.info("import: \(originalFilename, privacy: .public) — \(trimmed.count, privacy: .public) chars")

        // First attempt with the regular prompt.
        let prompt1 = Self.buildPrompt(sourceText: trimmed, strictMode: false)
        let raw1 = try await gemma.generate(
            prompt: prompt1,
            parameters: Self.parameters(),
            surface: "docimport"
        )
        docImportLog.debug("attempt=1 raw=\(raw1, privacy: .private)")
        if let wire = Self.parseWire(from: raw1) {
            let doc = Self.makeDocument(
                originalFilename: originalFilename,
                sourceText: trimmed,
                wire: wire
            )
            docImportLog.info("attempt=1 parsed OK, chunks=\(doc.chunks.count, privacy: .public)")
            return doc
        }

        // Strict retry — same prompt + "JSON only, no markdown" header.
        docImportLog.warning("attempt=1 parse failed, retrying in strict mode")
        let prompt2 = Self.buildPrompt(sourceText: trimmed, strictMode: true)
        let raw2 = try await gemma.generate(
            prompt: prompt2,
            parameters: Self.parameters(),
            surface: "docimport.retry"
        )
        docImportLog.debug("attempt=2 raw=\(raw2, privacy: .private)")
        guard let wire = Self.parseWire(from: raw2) else {
            throw DocumentImportError.modelReturnedNoJSON
        }
        let doc = Self.makeDocument(
            originalFilename: originalFilename,
            sourceText: trimmed,
            wire: wire
        )
        docImportLog.info("attempt=2 parsed OK, chunks=\(doc.chunks.count, privacy: .public)")
        return doc
    }

    // MARK: - Prompt + parameters

    /// Reuse ExtractionService's temperature discipline (0.3) — we want
    /// deterministic JSON output, not creative prose. `maxTokens` is
    /// generous: a 12 000-char source can produce ~20 chunks; allow
    /// headroom so the model doesn't truncate mid-array.
    private static func parameters() -> GenerateParameters {
        GenerateParameters(maxTokens: 4096, temperature: 0.3)
    }

    static func buildPrompt(sourceText: String, strictMode: Bool) -> String {
        let header = strictMode
            ? "Strict mode: respond with valid JSON only. No markdown, no prose. Start with { and end with }."
            : "Return JSON only, following the schema below."
        return """
        You convert one German medical document (discharge letter, lab report, protocol excerpt) for a child in AIEOP-BFM ALL 2017 treatment into a structured, citable memory.

        \(header)

        Rules:
        - Never invent content. Copy concrete values (lab numbers, drug names, dates) verbatim from the source.
        - No advice, diagnosis, dose calculation, or interpretation — only structure what's in the document.
        - All free-text values inside the JSON are German.
        - `title`: short German title, max 80 chars (e.g. "Entlassungsbericht UKE 2026-04-12").
        - `summary`: one German sentence summarising the document.
        - `chunks`: 3 to 20 topical sections, in source order. Each section:
          - `kind`: one of "befund", "medikation", "prozedur", "entscheidung", "beobachtung", "naechste_schritte", "sonstiges".
          - `text`: German prose (multiple sentences allowed); preserve concrete values; max 600 chars per chunk.

        Schema:
        {
          "title": "<German title>",
          "summary": "<one German sentence>",
          "chunks": [
            { "kind": "befund", "text": "<German prose>" },
            { "kind": "medikation", "text": "<German prose>" }
          ]
        }

        Document (German source):
        ```
        \(sourceText)
        ```

        JSON:
        """
    }

    // MARK: - Parsing

    private static func parseWire(from raw: String) -> WireImportedDocument? {
        guard let jsonString = ExtractionService.firstJSONObject(in: raw),
              let data = jsonString.data(using: .utf8) else {
            return nil
        }
        return try? JSONDecoder().decode(WireImportedDocument.self, from: data)
    }

    /// Turn a parsed wire shape into the on-disk `ImportedDocument`.
    /// Fallbacks are deliberate — a missing title becomes the filename
    /// stem, a missing summary becomes a generic placeholder, and
    /// chunks get a sequential `index` regardless of what the model
    /// emitted.
    private static func makeDocument(
        originalFilename: String,
        sourceText: String,
        wire: WireImportedDocument
    ) -> ImportedDocument {
        let cleanedChunks: [DocumentChunk] = (wire.chunks ?? [])
            .enumerated()
            .compactMap { offset, wireChunk -> DocumentChunk? in
                let body = wireChunk.text
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !body.isEmpty else { return nil }
                let kind = (wireChunk.kind ?? "sonstiges")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .lowercased()
                // Post-process span recovery: find the longest run of
                // characters in `body` that appears verbatim inside
                // `sourceText`. When ≥ 30 characters match, the chunk
                // ships with a `sourceSpan` the UI can highlight on a
                // `[D:docId#chunkIndex]` tap — turning Gemma's
                // structured paraphrase into a partial source-grounded
                // citation. Costs O(n×m) per chunk; cheap at the
                // import-side budget cap of `docImportMaxChars` ≤ 64k.
                let span = SourceSpanRecovery.findLongestVerbatimSpan(
                    of: body,
                    in: sourceText
                )
                return DocumentChunk(
                    index: offset,
                    kind: kind.isEmpty ? "sonstiges" : kind,
                    text: body,
                    sourceSpan: span
                )
            }
        let title = (wire.title?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap {
            $0.isEmpty ? nil : $0
        } ?? defaultTitle(forFilename: originalFilename)
        let summary = (wire.summary?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap {
            $0.isEmpty ? nil : $0
        } ?? "Importiertes Dokument."
        return ImportedDocument(
            title: title,
            originalFilename: originalFilename,
            sourceText: sourceText,
            summary: summary,
            chunks: cleanedChunks
        )
    }

    private static func defaultTitle(forFilename filename: String) -> String {
        let stem = (filename as NSString).deletingPathExtension
        return stem.isEmpty ? "Importiertes Dokument" : stem
    }
}
