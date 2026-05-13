import Foundation
import MLXLMCommon
import OSLog

private let askLog = Logger(subsystem: "io.grimso.Begleiter", category: "gemma.ask")

/// Per-call generation parameters for the Q&A path.
/// - maxTokens: read from `AppSettings.askMaxTokens` (default 512).
///   Five cited claims + 3 follow-ups in German runs ~300–450 tokens; 512
///   gives margin. The Settings screen lets users dial 256–1024.
/// - temperature: 0.4 — moderate fluency, low drift. The honesty-bias
///   refusal pathway is the safety net, not low temperature.
private func askParameters() -> GenerateParameters {
    GenerateParameters(maxTokens: AppSettings.askMaxTokens, temperature: 0.4)
}

/// Errors surfaced internally by `AskService`. End-users never see these —
/// any failure swaps the answer for the canonical refusal so the chat UI
/// stays usable.
enum AskError: Error, LocalizedError {
    case modelReturnedNoJSON
    case modelReturnedInvalidJSON(String)

    var errorDescription: String? {
        switch self {
        case .modelReturnedNoJSON:
            return "Gemma hat keinen JSON-Block geliefert."
        case .modelReturnedInvalidJSON(let detail):
            return "Gemma hat ungültiges JSON geliefert: \(detail)"
        }
    }
}

/// A user-typed question along with its scope. `AskService.answer(...)`
/// turns this into an `AskAnswer`.
nonisolated struct AskQuestion: Sendable, Hashable {
    let text: String
    let scope: AskScope
}

/// Where the surviving claims of an answer were grounded. Surfaced as a
/// small footer chip ("Aus deinem Journal" / "Aus dem Korpus" / "Aus
/// beidem") so the parent isn't misled about the source.
nonisolated enum AnswerBasis: String, Sendable, Hashable {
    case journal
    case corpus
    case both
    case refusal
}

/// A single citation reference within an answer claim. `entry(...)`
/// points at a `JournalEntry.entryId`, `corpus(...)` at a `CorpusChunk.id`.
/// Tappable in the UI via `CitationChip`.
nonisolated enum Citation: Sendable, Hashable {
    case entry(UUID)
    case corpus(chunkId: String)

    /// Parse the inline marker form Gemma emits. Examples:
    /// `"E:0F3A8E6E-..."` → `.entry`; `"K:glossary_labs/anc"` → `.corpus`.
    /// Returns `nil` for malformed tokens.
    static func parse(_ token: String) -> Citation? {
        let parts = token.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return nil }
        switch parts[0] {
        case "E":
            if let uuid = UUID(uuidString: parts[1]) { return .entry(uuid) }
            return nil
        case "K":
            let id = parts[1]
            return id.isEmpty ? nil : .corpus(chunkId: id)
        default:
            return nil
        }
    }
}

/// One claim in an answer. `text` is German parent-language; `citations`
/// are the grounded references that survived the verifiable-generation
/// filter.
nonisolated struct AnswerClaim: Sendable, Hashable, Identifiable {
    let id: UUID
    let text: String
    let citations: [Citation]

    init(id: UUID = UUID(), text: String, citations: [Citation]) {
        self.id = id
        self.text = text
        self.citations = citations
    }
}

/// One full answer. Session-ephemeral — `AskViewModel` holds a stack of
/// these and discards them on sheet dismissal.
nonisolated struct AskAnswer: Sendable, Hashable, Identifiable {
    let id: UUID
    let question: String
    let claims: [AnswerClaim]
    let followUps: [String]
    let basis: AnswerBasis
    let renderedAt: Date

    /// Joined claim text for accessibility readouts and clipboard copy.
    var answerText: String {
        claims.map(\.text).joined(separator: "\n")
    }

    /// A canonical refusal answer carrying only `RefusalService.redirectMessage`.
    /// Used when retrieval is empty, parsing fails, all citations are
    /// fabricated, or `RefusalService.containsClinicalAdvice` fires.
    static func refusal(question: String) -> AskAnswer {
        AskAnswer(
            id: UUID(),
            question: question,
            claims: [AnswerClaim(text: RefusalService.redirectMessage, citations: [])],
            followUps: [],
            basis: .refusal,
            renderedAt: .now
        )
    }
}

/// Single-shot Q&A engine: parent asks a German question → grounded
/// answer with `[E:...]` / `[K:...]` citations + 2–3 suggested follow-ups.
///
/// Pipeline:
/// 1. Retrieve top-6 journal hits (`RetrievalService.search`) +
///    top-6 corpus hits (`CorpusService.search`), filtered by `AskScope`.
/// 2. If both are empty → return `AskAnswer.refusal`, skip the model call.
/// 3. Build a prompt with `[ENTRY n]` / `[CORPUS n]` context blocks
///    (BriefingService shape).
/// 4. `gemma.generate(prompt:parameters:)`.
/// 5. Parse JSON via `ExtractionService.firstJSONObject` +
///    `JSONDecoder.extraction`.
/// 6. Drop any citation whose UUID/chunkId is not in the retrieved subset
///    (verifiable-generation guard — mirrors
///    `BriefingService.filterUngroundedClaims`).
/// 7. Scrub each claim via `RefusalService.scrubbed`; on any clinical-
///    advice trigger swap the whole answer for the refusal.
/// 8. Compute `AnswerBasis` from surviving citation kinds.
actor AskService {

    /// App-wide shared instance. One Gemma container, one corpus index.
    static let shared = AskService()

    private let gemma: GemmaService
    private let retrieval: RetrievalService
    private let corpus: CorpusService

    init(
        gemma: GemmaService = .shared,
        retrieval: RetrievalService = RetrievalService(),
        corpus: CorpusService = .shared
    ) {
        self.gemma = gemma
        self.retrieval = retrieval
        self.corpus = corpus
    }

    /// Generate a grounded answer to `question`. `entries` is the full
    /// journal — `AskService` does the retrieval pass against it.
    func answer(
        _ question: AskQuestion,
        in entries: [JournalEntry]
    ) async -> AskAnswer {
        // 1. Retrieval
        let filters = Self.filters(for: question.scope)
        let journalHits = retrieval.search(
            query: question.text,
            in: entries,
            filters: filters,
            limit: 6
        )
        let corpusHits = corpus.search(
            query: question.text,
            scope: question.scope,
            limit: 6
        )

        if journalHits.isEmpty && corpusHits.isEmpty {
            askLog.info("empty retrieval — emitting refusal")
            return AskAnswer.refusal(question: question.text)
        }

        // 2. Materialise hits → entries / chunks
        let entryById = Dictionary(
            uniqueKeysWithValues: entries.map { ($0.entryId, $0) }
        )
        let topEntries: [JournalEntry] = journalHits
            .prefix(4)
            .compactMap { entryById[$0.entryId] }
        let topChunks: [CorpusChunk] = corpusHits
            .prefix(4)
            .compactMap { corpus.chunk(id: $0.chunkId) }

        // 3. Generate
        let prompt = Self.buildPrompt(
            question: question.text,
            entries: topEntries,
            chunks: topChunks
        )
        let raw: String
        do {
            raw = try await gemma.generate(prompt: prompt, parameters: askParameters())
        } catch {
            askLog.error("gemma.generate failed: \(error.localizedDescription, privacy: .public)")
            return AskAnswer.refusal(question: question.text)
        }
        askLog.debug("raw=\(raw, privacy: .public)")

        // 4. Parse
        let parsed: ParsedAnswer
        do {
            parsed = try Self.parseAnswer(from: raw)
        } catch {
            askLog.error("parse failed: \(error.localizedDescription, privacy: .public)")
            return AskAnswer.refusal(question: question.text)
        }

        // 5. Verifiable-generation filter
        let validEntryIds = Set(topEntries.map(\.entryId))
        let validChunkIds = Set(topChunks.map(\.id))
        let filteredClaims = Self.filterUngrounded(
            claims: parsed.claims,
            validEntryIds: validEntryIds,
            validChunkIds: validChunkIds
        )

        if filteredClaims.isEmpty {
            askLog.info("all claims dropped by verifiable-generation filter — emitting refusal")
            return AskAnswer.refusal(question: question.text)
        }

        // 6. Refusal scrub on the joined text (the per-claim scrub is in
        // `filterUngrounded`; this catches advice that spans multiple
        // claims).
        let joined = filteredClaims.map(\.text).joined(separator: "\n")
        if RefusalService.containsClinicalAdvice(joined) {
            askLog.info("advice-drift fired on joined claims — emitting refusal")
            return AskAnswer.refusal(question: question.text)
        }

        // 7. Compute basis
        let basis = Self.computeBasis(for: filteredClaims)

        return AskAnswer(
            id: UUID(),
            question: question.text,
            claims: filteredClaims,
            followUps: parsed.followUps,
            basis: basis,
            renderedAt: .now
        )
    }

    // MARK: - Suggested starters

    /// 3–4 starter questions the empty-state UI surfaces as tap-to-prefill
    /// chips. Scope-specific so the lab chat doesn't suggest drug
    /// questions and vice versa.
    nonisolated static func suggestedStarters(for scope: AskScope) -> [String] {
        switch scope {
        case .all:
            return [
                "Wann gab es zuletzt eine Asparaginase-Reaktion?",
                "Was sind die häufigsten Nebenwirkungen von Methotrexat?",
                "Welche Medikamente bekommt mein Kind aktuell?",
                "Was passiert in der Induktion IA?",
            ]
        case .labs:
            return [
                "Was bedeutet ANC?",
                "Wann waren die Thrombozyten zuletzt im Normbereich?",
                "Was bedeutet ein erhöhtes CRP?",
                "Wie war der letzte Verlauf der Leukozyten?",
            ]
        }
    }

    // MARK: - Prompt

    /// Build the German prompt. Models the `[ENTRY n] id=...` block shape
    /// of `BriefingService.buildPrompt` (lines 115–135) but adds
    /// `[CORPUS n] id=...` blocks for retrieved reference chunks.
    static func buildPrompt(
        question: String,
        entries: [JournalEntry],
        chunks: [CorpusChunk]
    ) -> String {
        let entryBlocks = entries.enumerated().map { (idx, entry) -> String in
            let date = dateFormatter.string(from: entry.visitDate)
            let f = entry.extractedFields
            var lines: [String] = []
            lines.append("[ENTRY \(idx + 1)] id=\(entry.entryId.uuidString) | datum=\(date)")
            if let summary = f.summary?.value, !summary.isEmpty {
                lines.append("  zusammenfassung: \(summary)")
            }
            if let drugs = f.drugsMentioned?.value, !drugs.isEmpty {
                lines.append("  medikamente: \(drugs.map { $0.germanLabel }.joined(separator: ", "))")
            }
            if let labs = f.labValues?.value, !labs.isEmpty {
                let lab = labs.map { "\($0.germanLabel) \($0.value)\($0.unit)" }.joined(separator: ", ")
                lines.append("  labor: \(lab)")
            }
            if let rx = f.reactions?.value, !rx.isEmpty {
                lines.append("  reaktionen: \(rx.map { $0.description }.joined(separator: "; "))")
            }
            if let obs = f.parentObservations?.value, !obs.isEmpty {
                lines.append("  beobachtungen: \(obs.joined(separator: "; "))")
            }
            return lines.joined(separator: "\n")
        }.joined(separator: "\n\n")

        let chunkBlocks = chunks.enumerated().map { (idx, chunk) -> String in
            """
            [CORPUS \(idx + 1)] id=\(chunk.id)
              titel: \(chunk.title)
              inhalt: \(chunk.text)
            """
        }.joined(separator: "\n\n")

        let entriesSection = entries.isEmpty
            ? ""
            : "EINTRÄGE AUS DEM JOURNAL (gefiltert nach Relevanz):\n\(entryBlocks)\n\n"
        let chunksSection = chunks.isEmpty
            ? ""
            : "REFERENZKORPUS (gefiltert nach Relevanz):\n\(chunkBlocks)\n\n"

        return """
        Sie beantworten die Frage eines Elternteils zum Krebsbehandlungsverlauf seines Kindes. Antworten Sie AUSSCHLIESSLICH mit JSON nach dem unten stehenden Schema. Maximal 200 Wörter im JSON insgesamt.

        REGELN:
        - Antworten Sie auf Deutsch, in einfacher Sprache für Eltern (keine Fachsprache ohne Erklärung).
        - Jede Aussage MUSS mindestens eine Citation tragen.
        - Citation-Format: "E:<UUID>" für einen Journal-Eintrag, "K:<chunkId>" für einen Korpus-Eintrag.
        - Verwenden Sie NUR IDs, die in den Kontext-Blöcken oben vorkommen. Erfinden Sie keine IDs.
        - KEINE medizinischen Empfehlungen, KEINE Dosis-Aussagen, KEINE Diagnosen. Bei Behandlungsfragen verweisen Sie an das Behandlungsteam.
        - Schlagen Sie 2–3 hilfreiche Folgefragen auf Deutsch vor, die zur Frage passen.

        \(entriesSection)\(chunksSection)FRAGE: \(question)

        SCHEMA:
        {
          "claims": [
            { "text": "<eine Aussage auf Deutsch>", "citations": ["E:<UUID>" oder "K:<chunkId>"] }
          ],
          "followUps": ["<Folgefrage 1>", "<Folgefrage 2>", "<Folgefrage 3>"]
        }

        JSON:
        """
    }

    // MARK: - Parse

    /// Wire JSON shape Gemma emits. `[String]` for citations keeps the
    /// parser lenient — `Citation.parse(_:)` filters malformed tokens.
    private struct WireAnswer: Decodable {
        struct WireClaim: Decodable {
            let text: String
            let citations: [String]?
        }
        let claims: [WireClaim]?
        let followUps: [String]?
    }

    /// Intermediate parse result. Internal so unit tests can verify the
    /// JSON parser without exercising the full pipeline.
    struct ParsedAnswer: Hashable {
        let claims: [AnswerClaim]
        let followUps: [String]
    }

    static func parseAnswer(from raw: String) throws -> ParsedAnswer {
        guard let jsonString = ExtractionService.firstJSONObject(in: raw) else {
            throw AskError.modelReturnedNoJSON
        }
        guard let data = jsonString.data(using: .utf8) else {
            throw AskError.modelReturnedInvalidJSON("UTF-8 encoding failed")
        }
        let wire: WireAnswer
        do {
            wire = try JSONDecoder.extraction.decode(WireAnswer.self, from: data)
        } catch {
            throw AskError.modelReturnedInvalidJSON(error.localizedDescription)
        }
        let claims: [AnswerClaim] = (wire.claims ?? []).map { wc in
            let citations: [Citation] = (wc.citations ?? []).compactMap(Citation.parse)
            return AnswerClaim(text: wc.text, citations: citations)
        }
        return ParsedAnswer(claims: claims, followUps: wire.followUps ?? [])
    }

    // MARK: - Verifiable-generation guard

    /// Drop citations whose UUID/chunkId is not in the retrieved subset,
    /// scrub claim text via `RefusalService.scrubbed`, drop claims with
    /// zero surviving citations. Mirrors
    /// `BriefingService.filterUngroundedClaims` (lines 202–225), extended
    /// for corpus IDs.
    static func filterUngrounded(
        claims: [AnswerClaim],
        validEntryIds: Set<UUID>,
        validChunkIds: Set<String>
    ) -> [AnswerClaim] {
        claims.compactMap { claim -> AnswerClaim? in
            let surviving = claim.citations.filter { citation in
                switch citation {
                case .entry(let id):
                    return validEntryIds.contains(id)
                case .corpus(let id):
                    return validChunkIds.contains(id)
                }
            }
            guard !surviving.isEmpty else { return nil }
            return AnswerClaim(
                id: claim.id,
                text: RefusalService.scrubbed(claim.text),
                citations: surviving
            )
        }
    }

    // MARK: - Basis

    static func computeBasis(for claims: [AnswerClaim]) -> AnswerBasis {
        var hasEntry = false
        var hasCorpus = false
        for c in claims {
            for cit in c.citations {
                switch cit {
                case .entry: hasEntry = true
                case .corpus: hasCorpus = true
                }
            }
        }
        switch (hasEntry, hasCorpus) {
        case (true, true):  return .both
        case (true, false): return .journal
        case (false, true): return .corpus
        case (false, false): return .refusal
        }
    }

    // MARK: - Filters

    private static func filters(for scope: AskScope) -> RetrievalService.Filters {
        switch scope {
        case .all:
            return .none
        case .labs:
            var f = RetrievalService.Filters.none
            f.labsOnly = true
            return f
        }
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "de_DE")
        return f
    }()
}
