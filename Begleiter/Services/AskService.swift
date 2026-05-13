import Foundation
import MLXLMCommon
import OSLog

private let askLog = Logger(subsystem: "io.grimso.Begleiter", category: "gemma.ask")

/// Per-call generation parameters for the Q&A path.
/// - maxTokens: read from `AppSettings.askMaxTokens` (default 512).
///   Five cited claims + 3 follow-ups in German runs ~300–450 tokens; 512
///   gives margin. The Settings screen lets users dial 256–1024.
/// - temperature: 0.4 — moderate fluency, low drift.
private func askParameters() -> GenerateParameters {
    GenerateParameters(maxTokens: AppSettings.askMaxTokens, temperature: 0.4)
}

/// Errors surfaced internally by `AskService`. End-users never see these —
/// failure paths swap the answer for the canonical refusal so the chat UI
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
    /// No surviving citations OR true refusal. UI hides the footer in this
    /// case; the `warnings` list explains the situation if there is one.
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
/// are the references that survived the verifiable-generation filter.
/// We no longer drop claims for missing citations — that gets surfaced as
/// an `.noCitations` warning at the answer level instead, so the parent
/// still sees the model's prose.
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

/// Non-fatal issues raised during answer assembly. Communicated to the UI
/// as warning banners — the parent still sees the answer, with context.
nonisolated enum AnswerWarning: String, Sendable, Hashable, CaseIterable {
    /// `RefusalService.containsClinicalAdvice` matched a clue phrase in
    /// at least one claim. Pre-existing strict mode replaced the entire
    /// claim with the redirect — now we surface a banner instead and let
    /// the parent read the text in context.
    case adviceDrift

    /// Filter dropped every citation Gemma emitted because none matched
    /// the retrieved subset (typically: model hallucinated UUIDs). The
    /// claim text is preserved so the parent still sees the answer.
    case noCitations

    /// Some citations were dropped but at least one survived. Common when
    /// Gemma mixes a real entryId with an invented one.
    case partialCitations
}

/// Why an answer was emitted as a refusal. Populated only when
/// `basis == .refusal` AND the answer carries the canonical redirect
/// message (i.e., we never reached the post-generation phase, or the
/// model returned nothing parseable).
nonisolated enum RefusalReason: String, Sendable, Hashable {
    case emptyRetrieval     // no journal hits AND no corpus hits
    case modelError         // gemma.generate threw
    case parseFailure       // model returned no parseable JSON
    case emptyClaims        // model returned JSON with zero claims
}

/// Developer-facing diagnostic snapshot of one answer round-trip.
/// Surfaced in `AskDebugSheet` when the Settings toggle is enabled.
/// Always populated, even on refusal, so the parent can ask "why did it
/// say that" and see the actual retrieval + model output.
nonisolated struct AskDebugInfo: Sendable, Hashable {
    let scope: AskScope
    let journalHits: Int
    let corpusHits: Int
    let promptedEntryIds: [UUID]
    let promptedChunkIds: [String]
    let promptCharCount: Int
    let thinkingEnabled: Bool
    let rawModelOutput: String
    let parseError: String?
    let modelError: String?
    let claimsBeforeFilter: Int
    let claimsAfterFilter: Int
    let droppedCitationCount: Int
    let refusalReason: RefusalReason?

    /// Empty placeholder used when an answer is constructed outside the
    /// real pipeline (e.g., tests, the static `AskAnswer.refusal` helper).
    static let empty = AskDebugInfo(
        scope: .all,
        journalHits: 0,
        corpusHits: 0,
        promptedEntryIds: [],
        promptedChunkIds: [],
        promptCharCount: 0,
        thinkingEnabled: false,
        rawModelOutput: "",
        parseError: nil,
        modelError: nil,
        claimsBeforeFilter: 0,
        claimsAfterFilter: 0,
        droppedCitationCount: 0,
        refusalReason: nil
    )
}

/// One full answer. Session-ephemeral — `AskViewModel` holds a stack of
/// these and discards them on sheet dismissal.
nonisolated struct AskAnswer: Sendable, Hashable, Identifiable {
    let id: UUID
    let question: String
    let claims: [AnswerClaim]
    let followUps: [String]
    let basis: AnswerBasis
    let warnings: [AnswerWarning]
    let debug: AskDebugInfo
    let renderedAt: Date

    /// Joined claim text for accessibility readouts and clipboard copy.
    var answerText: String {
        claims.map(\.text).joined(separator: "\n")
    }

    /// Canonical refusal answer carrying only `RefusalService.redirectMessage`.
    /// Used when retrieval is empty, model fails, parse fails, or Gemma
    /// emits no claims. `debug` carries the reason; the UI's debug sheet
    /// renders it when enabled.
    static func refusal(
        question: String,
        reason: RefusalReason,
        debug: AskDebugInfo
    ) -> AskAnswer {
        AskAnswer(
            id: UUID(),
            question: question,
            claims: [AnswerClaim(text: RefusalService.redirectMessage, citations: [])],
            followUps: [],
            basis: .refusal,
            warnings: [],
            debug: AskDebugInfo(
                scope: debug.scope,
                journalHits: debug.journalHits,
                corpusHits: debug.corpusHits,
                promptedEntryIds: debug.promptedEntryIds,
                promptedChunkIds: debug.promptedChunkIds,
                promptCharCount: debug.promptCharCount,
                thinkingEnabled: debug.thinkingEnabled,
                rawModelOutput: debug.rawModelOutput,
                parseError: debug.parseError,
                modelError: debug.modelError,
                claimsBeforeFilter: debug.claimsBeforeFilter,
                claimsAfterFilter: debug.claimsAfterFilter,
                droppedCitationCount: debug.droppedCitationCount,
                refusalReason: reason
            ),
            renderedAt: .now
        )
    }

    /// Test convenience refusal with empty debug info.
    static func refusal(question: String, reason: RefusalReason = .emptyRetrieval) -> AskAnswer {
        refusal(question: question, reason: reason, debug: .empty)
    }
}

/// Single-shot Q&A engine: parent asks a German question → grounded
/// answer with `[E:...]` / `[K:...]` citations + 2–3 suggested follow-ups.
///
/// Pipeline:
/// 1. Retrieve top-6 journal hits (`RetrievalService.search`) +
///    top-6 corpus hits (`CorpusService.search`), filtered by `AskScope`.
/// 2. If both are empty → refusal (`emptyRetrieval`), skip the model call.
/// 3. Build a prompt with `[ENTRY n]` / `[CORPUS n]` context blocks.
/// 4. `gemma.generate(prompt:parameters:)`. On error → refusal (`modelError`).
/// 5. Parse JSON. On failure → refusal (`parseFailure`).
/// 6. **Filter + warn (warn-don't-replace).** Drop fabricated citations
///    but keep the claim text. If text matches an advice-pattern, emit
///    a `.adviceDrift` warning — do NOT replace the text. If all citations
///    of a claim get dropped, emit `.noCitations` warning. If parsed
///    claims is empty → refusal (`emptyClaims`).
/// 7. Compute `AnswerBasis` from surviving citations.
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
        let thinkingEnabled = AppSettings.askThinkingEnabled
        var debug = AskDebugInfo(
            scope: question.scope,
            journalHits: 0,
            corpusHits: 0,
            promptedEntryIds: [],
            promptedChunkIds: [],
            promptCharCount: 0,
            thinkingEnabled: thinkingEnabled,
            rawModelOutput: "",
            parseError: nil,
            modelError: nil,
            claimsBeforeFilter: 0,
            claimsAfterFilter: 0,
            droppedCitationCount: 0,
            refusalReason: nil
        )

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
        debug = debug.with(journalHits: journalHits.count, corpusHits: corpusHits.count)
        askLog.info("retrieval: journal=\(journalHits.count, privacy: .public) corpus=\(corpusHits.count, privacy: .public) scope=\(question.scope.rawValue, privacy: .public)")

        if journalHits.isEmpty && corpusHits.isEmpty {
            askLog.info("empty retrieval — emitting refusal")
            return AskAnswer.refusal(
                question: question.text,
                reason: .emptyRetrieval,
                debug: debug
            )
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
        debug = debug.with(
            promptedEntryIds: topEntries.map(\.entryId),
            promptedChunkIds: topChunks.map(\.id)
        )

        // 3. Generate
        let prompt = Self.buildPrompt(
            question: question.text,
            entries: topEntries,
            chunks: topChunks
        )
        debug = debug.with(promptCharCount: prompt.count)

        let raw: String
        do {
            raw = try await gemma.generate(
                prompt: prompt,
                parameters: askParameters(),
                enableThinking: thinkingEnabled
            )
        } catch {
            let errMessage = error.localizedDescription
            askLog.error("gemma.generate failed: \(errMessage, privacy: .public)")
            debug = debug.with(modelError: errMessage)
            return AskAnswer.refusal(
                question: question.text,
                reason: .modelError,
                debug: debug
            )
        }
        debug = debug.with(rawModelOutput: raw)
        askLog.debug("raw=\(raw, privacy: .public)")

        // 4. Parse
        let parsed: ParsedAnswer
        do {
            parsed = try Self.parseAnswer(from: raw)
        } catch {
            let errMessage = error.localizedDescription
            askLog.error("parse failed: \(errMessage, privacy: .public)")
            debug = debug.with(parseError: errMessage)
            return AskAnswer.refusal(
                question: question.text,
                reason: .parseFailure,
                debug: debug
            )
        }
        debug = debug.with(claimsBeforeFilter: parsed.claims.count)

        if parsed.claims.isEmpty {
            askLog.info("model returned zero claims — emitting refusal")
            return AskAnswer.refusal(
                question: question.text,
                reason: .emptyClaims,
                debug: debug
            )
        }

        // 5. Filter + warn (warn-don't-replace)
        let validEntryIds = Set(topEntries.map(\.entryId))
        let validChunkIds = Set(topChunks.map(\.id))
        let outcome = Self.filterAndWarn(
            claims: parsed.claims,
            validEntryIds: validEntryIds,
            validChunkIds: validChunkIds
        )
        debug = debug.with(
            claimsAfterFilter: outcome.claims.count,
            droppedCitationCount: outcome.droppedCitations
        )
        askLog.info("filter: claimsBefore=\(parsed.claims.count, privacy: .public) claimsAfter=\(outcome.claims.count, privacy: .public) droppedCitations=\(outcome.droppedCitations, privacy: .public) warnings=\(outcome.warnings.map(\.rawValue).joined(separator: ","), privacy: .public)")

        // 6. Compute basis from surviving citations
        let basis = Self.computeBasis(for: outcome.claims)

        return AskAnswer(
            id: UUID(),
            question: question.text,
            claims: outcome.claims,
            followUps: parsed.followUps,
            basis: basis,
            warnings: outcome.warnings,
            debug: debug,
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

    // MARK: - Filter + warn

    struct FilterOutcome: Hashable {
        let claims: [AnswerClaim]
        let warnings: [AnswerWarning]
        let droppedCitations: Int
    }

    /// Verifiable-generation filter. **Warn-don't-replace** semantics:
    /// - Drops citations whose entry UUID / corpus chunkId is not in the
    ///   retrieved subset (model fabrications).
    /// - **Keeps the claim text intact** even when all citations dropped
    ///   or when `RefusalService.containsClinicalAdvice` matches a clue
    ///   phrase. Both surface as `AnswerWarning`s instead.
    /// - **Does not drop claims** — the parent always sees the model's
    ///   prose. The previous "drop on no surviving citation" behaviour
    ///   caused wholesale refusals when the 4-bit model hallucinated UUIDs.
    static func filterAndWarn(
        claims: [AnswerClaim],
        validEntryIds: Set<UUID>,
        validChunkIds: Set<String>
    ) -> FilterOutcome {
        var warnings: [AnswerWarning] = []
        var droppedTotal = 0
        var anyClaimHadCitations = false
        var anyClaimLostAllCitations = false
        var adviceFired = false

        let filtered: [AnswerClaim] = claims.map { claim in
            let surviving = claim.citations.filter { citation in
                switch citation {
                case .entry(let id):  return validEntryIds.contains(id)
                case .corpus(let id): return validChunkIds.contains(id)
                }
            }
            let dropped = claim.citations.count - surviving.count
            droppedTotal += dropped
            if !claim.citations.isEmpty {
                anyClaimHadCitations = true
                if surviving.isEmpty { anyClaimLostAllCitations = true }
            }
            if RefusalService.containsClinicalAdvice(claim.text) {
                adviceFired = true
            }
            return AnswerClaim(
                id: claim.id,
                text: claim.text,  // text preserved verbatim — warn, don't replace
                citations: surviving
            )
        }

        if adviceFired {
            warnings.append(.adviceDrift)
        }
        let totalSurvivingCitations = filtered.flatMap(\.citations).count
        if anyClaimHadCitations && totalSurvivingCitations == 0 {
            warnings.append(.noCitations)
        } else if droppedTotal > 0 {
            warnings.append(.partialCitations)
        } else if !anyClaimHadCitations {
            // Model emitted text but never provided any citations at all.
            warnings.append(.noCitations)
        }

        return FilterOutcome(
            claims: filtered,
            warnings: warnings,
            droppedCitations: droppedTotal
        )
    }

    /// Back-compat shim for tests written against the old API. Returns
    /// just the claims so existing assertions still hold — but now claim
    /// text is preserved (no `RefusalService.scrubbed` replacement) and
    /// claims with no surviving citations are kept.
    static func filterUngrounded(
        claims: [AnswerClaim],
        validEntryIds: Set<UUID>,
        validChunkIds: Set<String>
    ) -> [AnswerClaim] {
        filterAndWarn(
            claims: claims,
            validEntryIds: validEntryIds,
            validChunkIds: validChunkIds
        ).claims
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

// MARK: - AskDebugInfo builder helpers

extension AskDebugInfo {
    func with(
        journalHits: Int? = nil,
        corpusHits: Int? = nil,
        promptedEntryIds: [UUID]? = nil,
        promptedChunkIds: [String]? = nil,
        promptCharCount: Int? = nil,
        thinkingEnabled: Bool? = nil,
        rawModelOutput: String? = nil,
        parseError: String? = nil,
        modelError: String? = nil,
        claimsBeforeFilter: Int? = nil,
        claimsAfterFilter: Int? = nil,
        droppedCitationCount: Int? = nil,
        refusalReason: RefusalReason? = nil
    ) -> AskDebugInfo {
        AskDebugInfo(
            scope: self.scope,
            journalHits: journalHits ?? self.journalHits,
            corpusHits: corpusHits ?? self.corpusHits,
            promptedEntryIds: promptedEntryIds ?? self.promptedEntryIds,
            promptedChunkIds: promptedChunkIds ?? self.promptedChunkIds,
            promptCharCount: promptCharCount ?? self.promptCharCount,
            thinkingEnabled: thinkingEnabled ?? self.thinkingEnabled,
            rawModelOutput: rawModelOutput ?? self.rawModelOutput,
            parseError: parseError ?? self.parseError,
            modelError: modelError ?? self.modelError,
            claimsBeforeFilter: claimsBeforeFilter ?? self.claimsBeforeFilter,
            claimsAfterFilter: claimsAfterFilter ?? self.claimsAfterFilter,
            droppedCitationCount: droppedCitationCount ?? self.droppedCitationCount,
            refusalReason: refusalReason ?? self.refusalReason
        )
    }
}
