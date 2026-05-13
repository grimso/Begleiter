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
    /// `EventQuestionDetector` matched a past-tense phrase AND journal
    /// retrieval was empty AND `askEventGuardEnabled` was on, so we
    /// emitted the canonical "Im Journal finde ich dazu keinen
    /// Eintrag." answer without calling Gemma.
    case noJournalForEventQuestion
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
    /// The full prompt string sent to Gemma. Always captured; the
    /// Diagnose sheet only renders it when the diagnostics toggle is
    /// on. Empty when retrieval was empty (no Gemma call).
    let promptText: String
    let thinkingEnabled: Bool
    let rawModelOutput: String
    let parseError: String?
    let modelError: String?
    let claimsBeforeFilter: Int
    let claimsAfterFilter: Int
    let droppedCitationCount: Int
    let refusalReason: RefusalReason?

    // MARK: - Dense rerank diagnostics
    /// True when `AppSettings.askDenseRerankerEnabled` was on for this
    /// answer and the rerank path actually ran end-to-end (embedder
    /// loaded, query+candidates embedded, RRF applied).
    let denseRerankerEnabled: Bool
    let candidatesBeforeRerankJournal: Int
    let candidatesBeforeRerankCorpus: Int
    /// Number of positions in the combined journal+corpus top-6 that
    /// changed vs the BM25-only ordering. 0 means rerank was a no-op.
    let rerankReorderCount: Int
    /// Wall-clock milliseconds spent in `EmbeddingService.loadModel()`.
    /// `nil` when the toggle is off; tiny when the embedder was already
    /// loaded from a prior call this session.
    let embedderLoadMs: Int?
    let queryEmbedMs: Int?
    /// How many journal entries / corpus chunks needed fresh embeddings
    /// this call. After the first rerank in a session, these usually
    /// drop to 0 because the on-disk cache hydrates everything.
    let entryEmbedCount: Int
    let corpusEmbedCount: Int
    /// Populated when rerank was requested but skipped or failed,
    /// e.g. `"toggle off"`, `"both candidate sets empty"`,
    /// `"embedder load failed: <message>"`.
    let rerankSkippedReason: String?

    // MARK: - Event-question guard diagnostics
    /// True if `EventQuestionDetector.looksLikeEventQuestion(...)`
    /// matched the question text — regardless of whether the guard
    /// fired. Lets the Diagnose sheet distinguish "no match" from
    /// "matched but guard was off / journal had hits".
    let eventQuestionDetected: Bool
    /// True if `AppSettings.askEventGuardEnabled` was on AND the
    /// detector matched AND the journal retrieval was empty — i.e.,
    /// the answer was synthesised as `noJournalForEventQuestion`
    /// without a Gemma call.
    let eventGuardFired: Bool

    /// Empty placeholder used when an answer is constructed outside the
    /// real pipeline (e.g., tests, the static `AskAnswer.refusal` helper).
    static let empty = AskDebugInfo(
        scope: .all,
        journalHits: 0,
        corpusHits: 0,
        promptedEntryIds: [],
        promptedChunkIds: [],
        promptCharCount: 0,
        promptText: "",
        thinkingEnabled: false,
        rawModelOutput: "",
        parseError: nil,
        modelError: nil,
        claimsBeforeFilter: 0,
        claimsAfterFilter: 0,
        droppedCitationCount: 0,
        refusalReason: nil,
        denseRerankerEnabled: false,
        candidatesBeforeRerankJournal: 0,
        candidatesBeforeRerankCorpus: 0,
        rerankReorderCount: 0,
        embedderLoadMs: nil,
        queryEmbedMs: nil,
        entryEmbedCount: 0,
        corpusEmbedCount: 0,
        rerankSkippedReason: nil,
        eventQuestionDetected: false,
        eventGuardFired: false
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
                promptText: debug.promptText,
                thinkingEnabled: debug.thinkingEnabled,
                rawModelOutput: debug.rawModelOutput,
                parseError: debug.parseError,
                modelError: debug.modelError,
                claimsBeforeFilter: debug.claimsBeforeFilter,
                claimsAfterFilter: debug.claimsAfterFilter,
                droppedCitationCount: debug.droppedCitationCount,
                refusalReason: reason,
                denseRerankerEnabled: debug.denseRerankerEnabled,
                candidatesBeforeRerankJournal: debug.candidatesBeforeRerankJournal,
                candidatesBeforeRerankCorpus: debug.candidatesBeforeRerankCorpus,
                rerankReorderCount: debug.rerankReorderCount,
                embedderLoadMs: debug.embedderLoadMs,
                queryEmbedMs: debug.queryEmbedMs,
                entryEmbedCount: debug.entryEmbedCount,
                corpusEmbedCount: debug.corpusEmbedCount,
                rerankSkippedReason: debug.rerankSkippedReason,
                eventQuestionDetected: debug.eventQuestionDetected,
                eventGuardFired: debug.eventGuardFired
            ),
            renderedAt: .now
        )
    }

    /// Synthesised answer for the case where the Swift-side event-
    /// question guard fired. Same shape as `.refusal` (no Gemma call,
    /// empty citations, no follow-ups) but the claim text is the
    /// specific "Im Journal finde ich dazu keinen Eintrag." phrase
    /// rather than the canonical `RefusalService.redirectMessage` —
    /// the parent gets a precise answer, not a generic redirect.
    static func noJournalForEvent(
        question: String,
        debug: AskDebugInfo
    ) -> AskAnswer {
        AskAnswer(
            id: UUID(),
            question: question,
            claims: [
                AnswerClaim(
                    text: "Im Journal finde ich dazu keinen Eintrag.",
                    citations: []
                )
            ],
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
                promptText: debug.promptText,
                thinkingEnabled: debug.thinkingEnabled,
                rawModelOutput: debug.rawModelOutput,
                parseError: debug.parseError,
                modelError: debug.modelError,
                claimsBeforeFilter: debug.claimsBeforeFilter,
                claimsAfterFilter: debug.claimsAfterFilter,
                droppedCitationCount: debug.droppedCitationCount,
                refusalReason: .noJournalForEventQuestion,
                denseRerankerEnabled: debug.denseRerankerEnabled,
                candidatesBeforeRerankJournal: debug.candidatesBeforeRerankJournal,
                candidatesBeforeRerankCorpus: debug.candidatesBeforeRerankCorpus,
                rerankReorderCount: debug.rerankReorderCount,
                embedderLoadMs: debug.embedderLoadMs,
                queryEmbedMs: debug.queryEmbedMs,
                entryEmbedCount: debug.entryEmbedCount,
                corpusEmbedCount: debug.corpusEmbedCount,
                rerankSkippedReason: debug.rerankSkippedReason,
                eventQuestionDetected: true,
                eventGuardFired: true
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

    /// Callback signature `AskService` uses to persist freshly computed
    /// journal-entry embeddings back to SwiftData. Called from the
    /// `@MainActor` so the `@Model` write happens on the right context.
    /// `AskView` supplies this; tests pass `nil` and the rerank path
    /// just doesn't persist the per-session vectors (which is fine for
    /// the toggle-off default and for unit-test scope).
    typealias EntryEmbeddingPersister = @MainActor @Sendable (
        [UUID: [Float]]
    ) async -> Void

    /// App-wide shared instance. One Gemma container, one corpus index.
    static let shared = AskService()

    private let gemma: GemmaService
    private let retrieval: RetrievalService
    private let corpus: CorpusService
    private let embedder: any AskEmbedder

    init(
        gemma: GemmaService = .shared,
        retrieval: RetrievalService = RetrievalService(),
        corpus: CorpusService = .shared,
        embedder: any AskEmbedder = EmbeddingService.shared
    ) {
        self.gemma = gemma
        self.retrieval = retrieval
        self.corpus = corpus
        self.embedder = embedder
    }

    /// Generate a grounded answer to `question`. `entries` is the full
    /// journal — `AskService` does the retrieval pass against it.
    /// `persistEntryEmbeddings` is called from `@MainActor` when the
    /// rerank path freshly embeds journal entries; pass `nil` (the
    /// default) when running in tests or when persistence isn't needed.
    func answer(
        _ question: AskQuestion,
        in entries: [JournalEntry],
        persistEntryEmbeddings: EntryEmbeddingPersister? = nil
    ) async -> AskAnswer {
        let thinkingEnabled = AppSettings.askThinkingEnabled
        let rerankEnabled = AppSettings.askDenseRerankerEnabled
        var debug = AskDebugInfo(
            scope: question.scope,
            journalHits: 0,
            corpusHits: 0,
            promptedEntryIds: [],
            promptedChunkIds: [],
            promptCharCount: 0,
            promptText: "",
            thinkingEnabled: thinkingEnabled,
            rawModelOutput: "",
            parseError: nil,
            modelError: nil,
            claimsBeforeFilter: 0,
            claimsAfterFilter: 0,
            droppedCitationCount: 0,
            refusalReason: nil,
            denseRerankerEnabled: false,  // flips to true only if rerank actually runs
            candidatesBeforeRerankJournal: 0,
            candidatesBeforeRerankCorpus: 0,
            rerankReorderCount: 0,
            embedderLoadMs: nil,
            queryEmbedMs: nil,
            entryEmbedCount: 0,
            corpusEmbedCount: 0,
            rerankSkippedReason: rerankEnabled ? nil : "toggle off",
            eventQuestionDetected: false,
            eventGuardFired: false
        )

        // 1. Retrieval. With rerank on, pull a wider candidate set
        // (limit 20 instead of 6) so the second-stage RRF has room to
        // promote semantic matches that BM25 ranks low.
        let firstStageLimit = rerankEnabled ? 20 : 6
        let filters = Self.filters(for: question.scope)
        let journalHits = retrieval.search(
            query: question.text,
            in: entries,
            filters: filters,
            limit: firstStageLimit
        )
        let corpusHits = corpus.search(
            query: question.text,
            scope: question.scope,
            limit: firstStageLimit
        )
        debug = debug.with(journalHits: journalHits.count, corpusHits: corpusHits.count)
        askLog.info("retrieval: journal=\(journalHits.count, privacy: .public) corpus=\(corpusHits.count, privacy: .public) scope=\(question.scope.rawValue, privacy: .public) limit=\(firstStageLimit, privacy: .public)")

        if journalHits.isEmpty && corpusHits.isEmpty {
            askLog.info("empty retrieval — emitting refusal")
            // Rerank doesn't run when there's nothing to rerank.
            if rerankEnabled {
                debug = debug.with(rerankSkippedReason: "both candidate sets empty")
            }
            return AskAnswer.refusal(
                question: question.text,
                reason: .emptyRetrieval,
                debug: debug
            )
        }

        // 1b. Event-question guard. If the question looks like a
        // past-tense event question ("Welche … gab es?", "Wann hatte
        // …?") AND the journal retrieval found nothing AND the toggle
        // is on: short-circuit to "Im Journal finde ich dazu keinen
        // Eintrag." without calling Gemma. Prevents the model from
        // paraphrasing a topically-relevant corpus chunk into an
        // answer that reads like a journal claim.
        let eventDetected = EventQuestionDetector.looksLikeEventQuestion(question.text)
        debug = debug.with(eventQuestionDetected: eventDetected)
        if AppSettings.askEventGuardEnabled,
           journalHits.isEmpty,
           eventDetected
        {
            askLog.info("event-question guard fired (journal empty, question is event-shaped)")
            if rerankEnabled {
                debug = debug.with(rerankSkippedReason: "event-question guard fired")
            }
            return AskAnswer.noJournalForEvent(
                question: question.text,
                debug: debug
            )
        }

        // 2. Dense rerank (optional). Reorders BM25's top-K by RRF of
        // BM25 rank + cosine rank, with E5-multilingual embeddings.
        // Falls back to BM25 if the embedder fails to load.
        var rerankedJournalIds: [UUID] = journalHits.map { $0.entryId }
        var rerankedChunkIds: [String] = corpusHits.map { $0.chunkId }
        if rerankEnabled, !journalHits.isEmpty || !corpusHits.isEmpty {
            debug = debug.with(
                candidatesBeforeRerankJournal: journalHits.count,
                candidatesBeforeRerankCorpus: corpusHits.count
            )
            do {
                let outcome = try await runRerank(
                    question: question.text,
                    journalHits: journalHits,
                    corpusHits: corpusHits,
                    entries: entries,
                    persistEntryEmbeddings: persistEntryEmbeddings
                )
                rerankedJournalIds = outcome.journalIds
                rerankedChunkIds = outcome.chunkIds
                debug = debug.with(
                    denseRerankerEnabled: true,
                    rerankReorderCount: outcome.reorderCount,
                    embedderLoadMs: outcome.embedderLoadMs,
                    queryEmbedMs: outcome.queryEmbedMs,
                    entryEmbedCount: outcome.entryEmbedCount,
                    corpusEmbedCount: outcome.corpusEmbedCount,
                    rerankSkippedReason: Optional<String>.none
                )
                askLog.info("rerank: reorder=\(outcome.reorderCount, privacy: .public) entryEmbed=\(outcome.entryEmbedCount, privacy: .public) corpusEmbed=\(outcome.corpusEmbedCount, privacy: .public) loadMs=\(outcome.embedderLoadMs ?? -1, privacy: .public) queryMs=\(outcome.queryEmbedMs ?? -1, privacy: .public)")
            } catch {
                let msg = "embedder load failed: \(error.localizedDescription)"
                askLog.error("\(msg, privacy: .public)")
                debug = debug.with(rerankSkippedReason: msg)
                // Fall through with BM25 ordering. UI will show the
                // skipped-reason in the Diagnose sheet.
            }
        }

        // 3. Materialise: take top-4 from the (possibly reranked) lists.
        let entryById = Dictionary(
            uniqueKeysWithValues: entries.map { ($0.entryId, $0) }
        )
        let topEntries: [JournalEntry] = rerankedJournalIds
            .prefix(4)
            .compactMap { entryById[$0] }
        let topChunks: [CorpusChunk] = rerankedChunkIds
            .prefix(4)
            .compactMap { corpus.chunk(id: $0) }
        debug = debug.with(
            promptedEntryIds: topEntries.map(\.entryId),
            promptedChunkIds: topChunks.map(\.id)
        )

        // 4. Generate
        let prompt = Self.buildPrompt(
            question: question.text,
            entries: topEntries,
            chunks: topChunks
        )
        debug = debug.with(promptCharCount: prompt.count, promptText: prompt)

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

        // 5. Parse
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

        // 6. Filter + warn (warn-don't-replace)
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

        // 7. Compute basis from surviving citations
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

    // MARK: - Dense rerank stage

    /// Result of one rerank pass — the reordered candidate id lists
    /// plus the timing / count signals AskDebugInfo carries to the
    /// Diagnose sheet.
    private struct RerankOutcome {
        let journalIds: [UUID]
        let chunkIds: [String]
        let reorderCount: Int
        let embedderLoadMs: Int?
        let queryEmbedMs: Int?
        let entryEmbedCount: Int
        let corpusEmbedCount: Int
    }

    /// Drive the embedder through one rerank cycle:
    /// 1. Load the embedder (timed).
    /// 2. Embed the question with `kind: .query` (timed).
    /// 3. Backfill any journal entries missing an embedding — read them
    ///    out of the BM25 candidate list, embed in one batch with
    ///    `kind: .passage`, persist via the caller-supplied callback.
    /// 4. Backfill corpus chunks missing a vector via
    ///    `CorpusService.backfillVectors(for:using:)`.
    /// 5. Unload the embedder so Gemma has the memory it needs.
    /// 6. Apply RRF over BM25 rank + cosine rank for both lists.
    ///
    /// Throws on embedder load / embedding errors. Caller catches and
    /// surfaces `rerankSkippedReason` in the Diagnose sheet, falling
    /// back to BM25 order.
    private func runRerank(
        question: String,
        journalHits: [RetrievalService.Hit],
        corpusHits: [CorpusService.Hit],
        entries: [JournalEntry],
        persistEntryEmbeddings: EntryEmbeddingPersister?
    ) async throws -> RerankOutcome {
        // Load.
        let loadStart = DispatchTime.now()
        try await embedder.ensureLoaded()
        let loadMs = Int((Double(DispatchTime.now().uptimeNanoseconds
                                 - loadStart.uptimeNanoseconds) / 1_000_000).rounded())

        // Query embedding.
        let queryStart = DispatchTime.now()
        let queryVector = try await embedder.embedQuery(question)
        let queryMs = Int((Double(DispatchTime.now().uptimeNanoseconds
                                  - queryStart.uptimeNanoseconds) / 1_000_000).rounded())

        // Journal backfill: find entries lacking an embedding among the
        // top-K BM25 candidates and embed them in one batch.
        let entryById = Dictionary(uniqueKeysWithValues: entries.map { ($0.entryId, $0) })
        var freshEntryVectors: [UUID: [Float]] = [:]
        let candidateEntries: [JournalEntry] = journalHits.compactMap { entryById[$0.entryId] }
        let missingEntries: [JournalEntry] = candidateEntries.filter { $0.embedding.isEmpty }
        if !missingEntries.isEmpty {
            let texts = missingEntries.map { RetrievalService.searchableText(of: $0) }
            let vectors = try await embedder.embedPassages(texts)
            if vectors.count == missingEntries.count {
                for (i, entry) in missingEntries.enumerated() {
                    freshEntryVectors[entry.entryId] = vectors[i]
                }
                // Persist to SwiftData on the main actor so the next
                // call doesn't re-embed. Best-effort; if the callback
                // is nil (tests) we keep them in `freshEntryVectors`
                // for this call only.
                if let persistEntryEmbeddings {
                    await persistEntryEmbeddings(freshEntryVectors)
                }
            } else {
                askLog.error("entry embed batch size mismatch: got \(vectors.count, privacy: .public) for \(missingEntries.count, privacy: .public) texts")
            }
        }

        // Corpus backfill. Pass `embedPassages` as a closure so
        // `CorpusService` stays free of MLX imports.
        let corpusIds = corpusHits.map { $0.chunkId }
        let freshChunkIds = try await corpus.backfillVectors(
            for: corpusIds,
            embedPassages: { try await self.embedder.embedPassages($0) }
        )

        // Unload BEFORE rerank math + Gemma load.
        await embedder.unload()

        // Build vectorFor lookups.
        let journalVectorFor: (UUID) -> [Float]? = { id in
            if let fresh = freshEntryVectors[id] { return fresh }
            if let stored = entryById[id]?.embedding, !stored.isEmpty { return stored }
            return nil
        }
        let corpusVectorMap = corpus.vectors(for: corpusIds)
        let corpusVectorFor: (String) -> [Float]? = { id in
            corpusVectorMap[id]
        }

        // Rerank each list.
        let journalBM25: [UUID] = journalHits.map(\.entryId)
        let corpusBM25: [String] = corpusHits.map(\.chunkId)
        let rerankedJournal = RerankerEngine.rerank(
            bm25Ranking: journalBM25,
            queryVector: queryVector,
            vectorFor: journalVectorFor
        )
        let rerankedCorpus = RerankerEngine.rerank(
            bm25Ranking: corpusBM25,
            queryVector: queryVector,
            vectorFor: corpusVectorFor
        )

        // Reorder count over the journal top-4 + corpus top-4 (what
        // actually feeds the prompt). 0 means rerank was a no-op for
        // what Gemma sees.
        let journalReorder = RerankerEngine.reorderCount(
            bm25Ranking: journalBM25,
            reranked: rerankedJournal,
            topN: 4
        )
        let corpusReorder = RerankerEngine.reorderCount(
            bm25Ranking: corpusBM25,
            reranked: rerankedCorpus,
            topN: 4
        )

        return RerankOutcome(
            journalIds: rerankedJournal.map(\.id),
            chunkIds: rerankedCorpus.map(\.id),
            reorderCount: journalReorder + corpusReorder,
            embedderLoadMs: loadMs,
            queryEmbedMs: queryMs,
            entryEmbedCount: missingEntries.count,
            corpusEmbedCount: freshChunkIds.count
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
    ///
    /// Trimmed for token budget — every line in REGELN earns its place.
    /// Adds a **Quellenwahl** rule that distinguishes event-questions
    /// ("welche … gab es?", "wann hatte …?", "wie war …?") from
    /// knowledge-questions ("was bedeutet …?", "Nebenwirkungen?"). For
    /// event-questions the model is told to answer only from ENTRY
    /// blocks and to admit no match rather than fall back to CORPUS —
    /// without this rule, BM25/dense retrieval surfaces a topically
    /// relevant corpus chunk that the model happily paraphrases,
    /// producing answers that read true but are actually generic info.
    static func buildPrompt(
        question: String,
        entries: [JournalEntry],
        chunks: [CorpusChunk]
    ) -> String {
        let entryBlocks = entries.enumerated().map { (idx, entry) -> String in
            let date = dateFormatter.string(from: entry.visitDate)
            let f = entry.extractedFields
            var lines: [String] = []
            lines.append("[ENTRY \(idx + 1)] id=\(entry.entryId.uuidString) datum=\(date)")
            if let summary = f.summary?.value, !summary.isEmpty {
                lines.append("zusf: \(summary)")
            }
            if let drugs = f.drugsMentioned?.value, !drugs.isEmpty {
                lines.append("med: \(drugs.map { $0.germanLabel }.joined(separator: ", "))")
            }
            if let labs = f.labValues?.value, !labs.isEmpty {
                let lab = labs.map { "\($0.germanLabel) \($0.value)\($0.unit)" }.joined(separator: ", ")
                lines.append("lab: \(lab)")
            }
            if let rx = f.reactions?.value, !rx.isEmpty {
                lines.append("rx: \(rx.map { $0.description }.joined(separator: "; "))")
            }
            if let obs = f.parentObservations?.value, !obs.isEmpty {
                lines.append("obs: \(obs.joined(separator: "; "))")
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
            : "EINTRÄGE AUS DEM JOURNAL:\n\(entryBlocks)\n\n"
        let chunksSection = chunks.isEmpty
            ? ""
            : "REFERENZKORPUS:\n\(chunkBlocks)\n\n"

        return """
        Beantworte die Frage des Elternteils zum Behandlungsverlauf des Kindes. Antworte AUSSCHLIESSLICH mit JSON (max. 200 Wörter).

        REGELN:
        - Einfaches Deutsch für Eltern.
        - Jede Aussage braucht eine Citation. Format: E:<UUID> für ENTRY, K:<id> für CORPUS. Nur IDs aus den Kontext-Blöcken.
        - Quellenwahl: Bei Ereignisfragen ("welche … gab es?", "wann hatte …?", "wie war …?", "was ist passiert?") AUSSCHLIESSLICH aus ENTRY-Blöcken antworten. Kein passender Eintrag? Antworte genau: "Im Journal finde ich dazu keinen Eintrag." mit leerer citations-Liste — keine CORPUS-Inhalte als Ersatz. Bei Wissensfragen ("was bedeutet …?", "Nebenwirkungen?") darfst du CORPUS nutzen.
        - Keine Empfehlungen/Dosen/Diagnosen — verweise ans Behandlungsteam.
        - Schlage 2–3 Folgefragen vor.

        \(entriesSection)\(chunksSection)FRAGE: \(question)

        SCHEMA:
        {"claims":[{"text":"…","citations":["E:<UUID>" oder "K:<id>"]}],"followUps":["…"]}

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
        promptText: String? = nil,
        thinkingEnabled: Bool? = nil,
        rawModelOutput: String? = nil,
        parseError: String? = nil,
        modelError: String? = nil,
        claimsBeforeFilter: Int? = nil,
        claimsAfterFilter: Int? = nil,
        droppedCitationCount: Int? = nil,
        refusalReason: RefusalReason? = nil,
        denseRerankerEnabled: Bool? = nil,
        candidatesBeforeRerankJournal: Int? = nil,
        candidatesBeforeRerankCorpus: Int? = nil,
        rerankReorderCount: Int? = nil,
        embedderLoadMs: Int?? = nil,
        queryEmbedMs: Int?? = nil,
        entryEmbedCount: Int? = nil,
        corpusEmbedCount: Int? = nil,
        rerankSkippedReason: String?? = nil,
        eventQuestionDetected: Bool? = nil,
        eventGuardFired: Bool? = nil
    ) -> AskDebugInfo {
        AskDebugInfo(
            scope: self.scope,
            journalHits: journalHits ?? self.journalHits,
            corpusHits: corpusHits ?? self.corpusHits,
            promptedEntryIds: promptedEntryIds ?? self.promptedEntryIds,
            promptedChunkIds: promptedChunkIds ?? self.promptedChunkIds,
            promptCharCount: promptCharCount ?? self.promptCharCount,
            promptText: promptText ?? self.promptText,
            thinkingEnabled: thinkingEnabled ?? self.thinkingEnabled,
            rawModelOutput: rawModelOutput ?? self.rawModelOutput,
            parseError: parseError ?? self.parseError,
            modelError: modelError ?? self.modelError,
            claimsBeforeFilter: claimsBeforeFilter ?? self.claimsBeforeFilter,
            claimsAfterFilter: claimsAfterFilter ?? self.claimsAfterFilter,
            droppedCitationCount: droppedCitationCount ?? self.droppedCitationCount,
            refusalReason: refusalReason ?? self.refusalReason,
            denseRerankerEnabled: denseRerankerEnabled ?? self.denseRerankerEnabled,
            candidatesBeforeRerankJournal: candidatesBeforeRerankJournal ?? self.candidatesBeforeRerankJournal,
            candidatesBeforeRerankCorpus: candidatesBeforeRerankCorpus ?? self.candidatesBeforeRerankCorpus,
            rerankReorderCount: rerankReorderCount ?? self.rerankReorderCount,
            embedderLoadMs: embedderLoadMs ?? self.embedderLoadMs,
            queryEmbedMs: queryEmbedMs ?? self.queryEmbedMs,
            entryEmbedCount: entryEmbedCount ?? self.entryEmbedCount,
            corpusEmbedCount: corpusEmbedCount ?? self.corpusEmbedCount,
            rerankSkippedReason: rerankSkippedReason ?? self.rerankSkippedReason,
            eventQuestionDetected: eventQuestionDetected ?? self.eventQuestionDetected,
            eventGuardFired: eventGuardFired ?? self.eventGuardFired
        )
    }
}
