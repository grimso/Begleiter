import Foundation
import MLXLMCommon
import OSLog

private let agentLog = Logger(subsystem: "io.grimso.Begleiter", category: "gemma.agent.tools")

/// Tool registry exposed to Gemma 4 in the function-calling Ask agent
/// path (`AskService.answerAgent`, gated by `AppSettings.askAgentEnabled`).
///
/// Why typed `Tool<Input, Output>` instead of raw `[String: Any]` dispatch:
/// the strongly-typed wrapper auto-generates the OpenAI-function JSON
/// schema from a list of ``ToolParameter`` declarations *and* decodes the
/// argument dict from a ``ToolCall`` into a Swift `Codable` struct via
/// ``ToolCall/execute(with:)``. That gives us schema/handler symmetry
/// for free, makes unit tests trivial (call the handler directly with an
/// Input struct), and matches what every other mlx-swift-lm sample uses.
///
/// Citation contract: each handler that surfaces journal entries or
/// corpus chunks decorates them with the inline marker form the
/// existing single-shot Ask path already understands —
/// `[E:<UUID>]` for journal entries, `[K:<chunkId>]` for corpus chunks.
/// The system prompt tells Gemma to thread these markers into its final
/// JSON claim text; `AskService.parseAnswer` lifts them out into
/// `Citation` objects the UI renders as tappable chips.
///
/// All tools are pure inspectors — none of them mutate journal state or
/// touch the network. The toggle that activates the path lives in
/// Settings → Entwicklung; the path stays off by default so existing
/// users see the single-shot Ask until they opt in.
///
/// Concurrency: `@unchecked Sendable` because the snapshot of journal
/// entries it carries (`[JournalEntry]` — a SwiftData `@Model` class
/// array) is not auto-Sendable. The contract is that a fresh
/// `AgentTools` is constructed at the start of every agent call from a
/// just-fetched read-only entry list, captures it by value, and is
/// dropped when the call returns. No tool mutates entry state, and the
/// snapshot lives only for the duration of the single
/// `AskService.answerAgent` invocation that built it. The risk is the
/// same one the single-shot path already accepts when reading entry
/// fields off `RetrievalService.search`.
struct AgentTools: @unchecked Sendable {

    // MARK: - Dependencies

    let retrieval: RetrievalService
    let corpus: CorpusService
    let entries: [JournalEntry]

    // MARK: - Tools

    let searchJournal: Tool<SearchJournalInput, String>
    let searchCorpus: Tool<SearchCorpusInput, String>
    let getLabTrend: Tool<GetLabTrendInput, String>
    let getPhaseMetadataTool: Tool<GetPhaseMetadataInput, String>

    // MARK: - Init

    init(
        retrieval: RetrievalService,
        corpus: CorpusService,
        entries: [JournalEntry]
    ) {
        self.retrieval = retrieval
        self.corpus = corpus
        self.entries = entries

        // Capture-by-value into each handler so the closures stay
        // `@Sendable`. The deps are all value-typed (`struct: Sendable`).
        // `[JournalEntry]` is a SwiftData `@Model` class array and not
        // auto-Sendable; we wrap it in `EntrySnapshotBox` (an
        // `@unchecked Sendable` shim) so the capture compiles without
        // suppressing the warning project-wide. The contract here is
        // identical to the one documented on `AgentTools` itself: the
        // entries are a read-only snapshot captured at agent-call time
        // and dropped when the call returns.
        let capturedRetrieval = retrieval
        let capturedCorpus = corpus
        let capturedEntries = EntrySnapshotBox(entries: entries)

        let phaseValues = Phase.allCases.map(\.rawValue)

        self.searchJournal = Tool(
            name: "search_journal",
            description:
                "Sucht das Journal des Kindes (BM25-Ranking) nach passenden Einträgen. " +
                "Liefert eine kompakte Liste mit `[E:<UUID>]`-Marker pro Treffer, " +
                "die in der Endantwort zitiert werden müssen.",
            parameters: [
                .required(
                    "query",
                    type: .string,
                    description: "Deutsche Anfrage; die wichtigen Stichwörter genügen."
                ),
                .optional(
                    "phase",
                    type: .string,
                    description: "Optionaler Filter: nur Einträge in dieser Phase.",
                    extraProperties: ["enum": phaseValues]
                ),
                .optional(
                    "drug",
                    type: .string,
                    description: "Optionaler Filter: kanonischer Wirkstoffname (INN), z.B. \"vincristine\"."
                ),
                .optional(
                    "since",
                    type: .string,
                    description: "Optional ISO-8601 Datum (YYYY-MM-DD); nur Einträge ab diesem Datum."
                ),
                .optional(
                    "until",
                    type: .string,
                    description: "Optional ISO-8601 Datum (YYYY-MM-DD); nur Einträge bis zu diesem Datum."
                ),
                .optional(
                    "labs_only",
                    type: .bool,
                    description: "Wenn true, nur Einträge mit Laborwerten."
                ),
                .optional(
                    "limit",
                    type: .int,
                    description: "Max. Treffer (Standard 4, Maximum 10)."
                ),
            ]
        ) { input in
            await AgentTools.handleSearchJournal(
                input,
                retrieval: capturedRetrieval,
                entries: capturedEntries.entries
            )
        }

        self.searchCorpus = Tool(
            name: "search_corpus",
            description:
                "Sucht den gebündelten Wissens-Korpus (Medikamente, Laborwerte, " +
                "Phaseninfos, Eltern-Ressourcen). Liefert Auszüge mit " +
                "`[K:<chunkId>]`-Marker zur Zitation.",
            parameters: [
                .required(
                    "query",
                    type: .string,
                    description: "Deutsche Anfrage."
                ),
                .optional(
                    "scope",
                    type: .string,
                    description: "\"all\" (alles) oder \"labs\" (nur Labor-Glossar).",
                    extraProperties: ["enum": ["all", "labs"]]
                ),
                .optional(
                    "limit",
                    type: .int,
                    description: "Max. Treffer (Standard 4, Maximum 10)."
                ),
            ]
        ) { input in
            await AgentTools.handleSearchCorpus(
                input,
                corpus: capturedCorpus
            )
        }

        self.getLabTrend = Tool(
            name: "get_lab_trend",
            description:
                "Liefert die Zeitreihe eines Laborparameters über die " +
                "Journal-Einträge des Kindes. Jeder Punkt trägt einen " +
                "`[E:<UUID>]`-Marker, falls die Endantwort zitieren soll.",
            parameters: [
                .required(
                    "parameter",
                    type: .string,
                    description: "Kanonischer Kurzname, z.B. \"ANC\", \"WBC\", \"Hb\", \"PLT\", \"CRP\"."
                ),
                .optional(
                    "since",
                    type: .string,
                    description: "Optional ISO-8601 Datum (YYYY-MM-DD); nur Werte ab diesem Datum."
                ),
                .optional(
                    "until",
                    type: .string,
                    description: "Optional ISO-8601 Datum (YYYY-MM-DD); nur Werte bis zu diesem Datum."
                ),
            ]
        ) { input in
            await AgentTools.handleGetLabTrend(
                input,
                entries: capturedEntries.entries
            )
        }

        self.getPhaseMetadataTool = Tool(
            name: "get_phase_metadata",
            description:
                "Gibt die hinterlegten Metadaten zu einer Behandlungsphase " +
                "(typische Dauer, Medikamente, Prozeduren, typische " +
                "Eltern-Sorgen). Quelle: Swift-State-Machine, NICHT Gemma — " +
                "diese Werte sind deterministisch.",
            parameters: [
                .required(
                    "phase",
                    type: .string,
                    description: "Phase als rawValue.",
                    extraProperties: ["enum": phaseValues]
                ),
            ]
        ) { input in
            AgentTools.handleGetPhaseMetadata(input)
        }
    }

    // MARK: - Schemas + dispatch

    /// All tool schemas in the order they are advertised to Gemma.
    /// Pass this to ``ChatSession``'s `tools:` parameter.
    var schemas: [ToolSpec] {
        [
            searchJournal.schema,
            searchCorpus.schema,
            getLabTrend.schema,
            getPhaseMetadataTool.schema,
        ]
    }

    /// Routes a single ``ToolCall`` from Gemma to the correct handler and
    /// returns the result string to feed back into the conversation.
    /// Errors raised here become exceptions on the surrounding
    /// `ChatSession.respond(...)` call; ``AskService.answerAgent`` catches
    /// them and turns them into a `.modelError` refusal so the chat UI
    /// stays usable.
    func dispatch(_ call: ToolCall) async throws -> String {
        let name = call.function.name
        agentLog.info("dispatch: \(name, privacy: .public)")
        switch name {
        case searchJournal.name:
            return try await call.execute(with: searchJournal)
        case searchCorpus.name:
            return try await call.execute(with: searchCorpus)
        case getLabTrend.name:
            return try await call.execute(with: getLabTrend)
        case getPhaseMetadataTool.name:
            return try await call.execute(with: getPhaseMetadataTool)
        default:
            agentLog.warning("dispatch: unknown tool \(name, privacy: .public)")
            throw AgentToolError.unknownTool(name)
        }
    }

    /// Parallel dispatcher for the custom agent loop
    /// (``AskService.answerCustomAgent``) that takes the
    /// ``GemmaToolCallExtractor.Call`` output directly — bypassing the
    /// mlx-swift-lm `ToolCall` round-trip that doesn't fire for Gemma 4
    /// today (see `docs/upstream-issue-gemma4-toolcall.md`).
    ///
    /// Argument coercion is intentionally lenient: missing string
    /// arguments become `""`, missing optional arguments become `nil`,
    /// non-string arguments where a string was expected get stringified
    /// via Swift's `String(describing:)`. The handler then validates
    /// "important" args (e.g. an empty `query` short-circuits to a
    /// no-result message inside `handleSearchJournal`), so a fuzzy
    /// extraction doesn't crash the loop — it just yields an empty
    /// tool result and the model can retry on the next turn.
    func dispatch(
        name: String,
        args: [String: GemmaToolCallExtractor.ArgValue]
    ) async throws -> String {
        agentLog.info("dispatch.custom: \(name, privacy: .public)")
        switch name {
        case searchJournal.name:
            let input = SearchJournalInput(
                query: stringArg(args["query"]) ?? "",
                phase: stringArg(args["phase"]),
                drug: stringArg(args["drug"]),
                since: stringArg(args["since"]) ?? stringArg(args["sinceISO"]),
                until: stringArg(args["until"]) ?? stringArg(args["untilISO"]),
                labs_only: boolArg(args["labs_only"]) ?? boolArg(args["labsOnly"]),
                limit: intArg(args["limit"])
            )
            return await Self.handleSearchJournal(
                input,
                retrieval: retrieval,
                entries: entries
            )

        case searchCorpus.name:
            let input = SearchCorpusInput(
                query: stringArg(args["query"]) ?? "",
                scope: stringArg(args["scope"]),
                limit: intArg(args["limit"])
            )
            return await Self.handleSearchCorpus(
                input,
                corpus: corpus
            )

        case getLabTrend.name:
            let input = GetLabTrendInput(
                parameter: stringArg(args["parameter"]) ?? "",
                since: stringArg(args["since"]) ?? stringArg(args["sinceISO"]),
                until: stringArg(args["until"]) ?? stringArg(args["untilISO"])
            )
            return await Self.handleGetLabTrend(
                input,
                entries: entries
            )

        case getPhaseMetadataTool.name:
            let input = GetPhaseMetadataInput(
                phase: stringArg(args["phase"]) ?? ""
            )
            return await Self.handleGetPhaseMetadata(input)

        default:
            agentLog.warning("dispatch.custom: unknown tool \(name, privacy: .public)")
            throw AgentToolError.unknownTool(name)
        }
    }

    // MARK: - ArgValue down-casting helpers

    /// Strings the model emits as Python-style sentinels for "no
    /// value". The model fills in EVERY optional argument when its
    /// thinking trace adopts Python style (`phase=None, drug=None,
    /// since=None, ...`), so we treat these literal strings as nil
    /// rather than passing them through to the handler. Case-
    /// insensitive — observed in the wild: `None`, `NONE`, `null`.
    private static let nullSentinelStrings: Set<String> = [
        "none", "null", "nil", "nan"
    ]

    private func isNullSentinel(_ s: String) -> Bool {
        Self.nullSentinelStrings.contains(s.lowercased())
    }

    /// Coerce an `ArgValue?` to `String?`. Non-string types get
    /// stringified — the model occasionally emits `query:Asparaginase`
    /// (no escape markers) which decodes as a `.string("Asparaginase")`
    /// already, but if it ever decodes as e.g. `.int(42)` we still
    /// hand the handler a usable string. Python-style `None` sentinels
    /// are stripped to nil so the handler doesn't try to filter on
    /// the literal string `"None"`.
    private func stringArg(_ value: GemmaToolCallExtractor.ArgValue?) -> String? {
        guard let value else { return nil }
        switch value {
        case .string(let s):
            if s.isEmpty || isNullSentinel(s) { return nil }
            return s
        case .int(let i):    return String(i)
        case .double(let d): return String(d)
        case .bool(let b):   return String(b)
        case .null:          return nil
        }
    }

    private func intArg(_ value: GemmaToolCallExtractor.ArgValue?) -> Int? {
        guard let value else { return nil }
        switch value {
        case .int(let i):    return i
        case .double(let d): return Int(d)
        case .string(let s):
            if isNullSentinel(s) { return nil }
            return Int(s)
        case .bool, .null:   return nil
        }
    }

    private func boolArg(_ value: GemmaToolCallExtractor.ArgValue?) -> Bool? {
        guard let value else { return nil }
        switch value {
        case .bool(let b):   return b
        case .string(let s):
            if isNullSentinel(s) { return nil }
            // Recognise both "true"/"false" and Python "True"/"False".
            return Bool(s.lowercased())
        case .int(let i):    return i != 0
        case .double, .null: return nil
        }
    }

    // MARK: - Handlers (static so unit tests can call them without
    //         constructing a full registry)

    static func handleSearchJournal(
        _ input: SearchJournalInput,
        retrieval: RetrievalService,
        entries: [JournalEntry]
    ) async -> String {
        let limit = min(max(input.limit ?? 4, 1), 10)
        var filters = RetrievalService.Filters.none
        if let phaseRaw = input.phase, let phase = Phase(rawValue: phaseRaw) {
            filters.phase = phase
        }
        if let drug = input.drug, !drug.isEmpty {
            filters.drugs = [drug.lowercased()]
        }
        if let sinceIso = input.since, let since = parseISODate(sinceIso) {
            filters.fromDate = since
        }
        if let untilIso = input.until, let until = parseISODate(untilIso) {
            filters.toDate = until
        }
        if input.labs_only == true {
            filters.labsOnly = true
        }

        let hits = retrieval.search(
            query: input.query,
            in: entries,
            filters: filters,
            limit: limit
        )
        guard !hits.isEmpty else {
            return "Keine passenden Journal-Einträge gefunden."
        }

        // Build a compact summary the model can read back.
        let byId = Dictionary(uniqueKeysWithValues: entries.map { ($0.entryId, $0) })
        let lines: [String] = hits.compactMap { hit in
            guard let entry = byId[hit.entryId] else { return nil }
            return formatEntrySnippet(entry, score: hit.score)
        }
        return ([
            "Treffer (\(lines.count)) — jeder Eintrag muss in der Endantwort mit `[E:<UUID>]` zitiert werden:",
        ] + lines).joined(separator: "\n")
    }

    static func handleSearchCorpus(
        _ input: SearchCorpusInput,
        corpus: CorpusService
    ) async -> String {
        let limit = min(max(input.limit ?? 4, 1), 10)
        let scope: AskScope = (input.scope == "labs") ? .labs : .all
        let hits = corpus.search(query: input.query, scope: scope, limit: limit)
        guard !hits.isEmpty else {
            return "Keine passenden Korpus-Auszüge gefunden."
        }
        let lines = hits.map { hit -> String in
            guard let chunk = corpus.chunk(id: hit.chunkId) else {
                return "[K:\(hit.chunkId)] (Auszug nicht gefunden)"
            }
            return "[K:\(hit.chunkId)] \(chunk.title): \(chunk.text.truncatedForTool())"
        }
        return ([
            "Treffer (\(lines.count)) — jeder Auszug muss in der Endantwort mit `[K:<chunkId>]` zitiert werden:",
        ] + lines).joined(separator: "\n")
    }

    static func handleGetLabTrend(
        _ input: GetLabTrendInput,
        entries: [JournalEntry]
    ) async -> String {
        let normalizedParam = input.parameter.lowercased()
        let since = input.since.flatMap(parseISODate)
        let until = input.until.flatMap(parseISODate)

        struct Point {
            let entryId: UUID
            let parameter: String
            let value: Double
            let unit: String
            let measuredAt: Date
        }

        var points: [Point] = []
        for entry in entries {
            guard let labs = entry.extractedFields.labValues?.value else { continue }
            for lab in labs {
                guard lab.parameter.lowercased() == normalizedParam else { continue }
                if let since, lab.measuredAt < since { continue }
                if let until, lab.measuredAt > until { continue }
                points.append(Point(
                    entryId: entry.entryId,
                    parameter: lab.parameter,
                    value: lab.value,
                    unit: lab.unit,
                    measuredAt: lab.measuredAt
                ))
            }
        }
        guard !points.isEmpty else {
            return "Keine Werte für \(input.parameter) im Journal gefunden."
        }
        points.sort { $0.measuredAt < $1.measuredAt }
        // Use the canonical parameter name from the data (the lab's own
        // `parameter` field), not whatever casing the model passed in,
        // so the output is deterministic across "ANC" / "anc" / "Anc"
        // — the handler is case-insensitive by design.
        let canonicalParameter = points.first?.parameter ?? input.parameter
        let lines = points.map { p in
            "\(isoDateFormatter.string(from: p.measuredAt)) \(p.value) \(p.unit) [E:\(p.entryId.uuidString)]"
        }
        return ([
            "\(canonicalParameter)-Verlauf (\(points.count) Werte):",
        ] + lines).joined(separator: "\n")
    }

    static func handleGetPhaseMetadata(
        _ input: GetPhaseMetadataInput
    ) -> String {
        guard let phase = Phase(rawValue: input.phase) else {
            return "Unbekannte Phase: \(input.phase). Erlaubt: \(Phase.allCases.map(\.rawValue).joined(separator: ", "))."
        }
        let meta = PhaseMetadata.for(phase)
        let drugs = meta.drugs.map { schedule in
            "  - \(schedule.drug.germanLabel) (\(schedule.route.rawValue)): \(schedule.scheduleDescription)"
        }.joined(separator: "\n")
        let procedures = meta.procedures.map { "  - \($0.germanLabel)" }.joined(separator: "\n")
        let concerns = meta.commonParentConcerns.map { "  - \($0)" }.joined(separator: "\n")
        return """
        Phase: \(meta.germanLabel)
        Typische Dauer: \(meta.typicalDurationDays) Tage
        Medikamente:
        \(drugs.isEmpty ? "  (keine hinterlegt)" : drugs)
        Prozeduren:
        \(procedures.isEmpty ? "  (keine hinterlegt)" : procedures)
        Typische Eltern-Sorgen:
        \(concerns.isEmpty ? "  (keine hinterlegt)" : concerns)
        Hinweis: Die Werte stammen aus der deterministischen Swift-State-Machine.
        """
    }

    // MARK: - Internal helpers

    /// One-line summary of a journal entry, prefixed with its citation
    /// marker so the model can copy it verbatim into the final claim.
    static func formatEntrySnippet(_ entry: JournalEntry, score: Double) -> String {
        let date = isoDateFormatter.string(from: entry.visitDate)
        let phase = entry.phase.germanLabel
        let summary = entry.extractedFields.summary?.value
            ?? entry.rawText
            ?? entry.rawVoiceTranscript
            ?? "(kein Text)"
        return "[E:\(entry.entryId.uuidString)] \(date) · \(phase) · \(summary.truncatedForTool())"
    }

    static func parseISODate(_ raw: String) -> Date? {
        // Accept either "YYYY-MM-DD" or full ISO-8601.
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let date = isoDateFormatter.date(from: trimmed) { return date }
        return isoDateTimeFormatter.date(from: trimmed)
    }
}

// MARK: - Input shapes

/// Strongly-typed Input/Output shapes for each tool. They are the
/// boundary between Gemma's JSON args and the Swift handlers; the
/// auto-generated schema mirrors these properties one-for-one (modulo
/// the optional flag).
nonisolated struct SearchJournalInput: Codable, Sendable {
    let query: String
    let phase: String?
    let drug: String?
    let since: String?
    let until: String?
    let labs_only: Bool?
    let limit: Int?
}

nonisolated struct SearchCorpusInput: Codable, Sendable {
    let query: String
    let scope: String?
    let limit: Int?
}

nonisolated struct GetLabTrendInput: Codable, Sendable {
    let parameter: String
    let since: String?
    let until: String?
}

nonisolated struct GetPhaseMetadataInput: Codable, Sendable {
    let phase: String
}

// MARK: - Capture shim

/// `@unchecked Sendable` box around an entry snapshot so that the tool
/// handler closures (which the `Tool<>` protocol marks `@Sendable`) can
/// capture the array without the project-wide concurrency check
/// upgrading to a Swift-6 error. The contract — read-only snapshot for
/// the lifetime of one `AskService.answerAgent` call — is documented on
/// `AgentTools` itself; this type only exists to keep the compiler
/// happy without weakening guarantees elsewhere.
private struct EntrySnapshotBox: @unchecked Sendable {
    let entries: [JournalEntry]
}

// MARK: - Errors

nonisolated enum AgentToolError: Error, LocalizedError, Equatable {
    case unknownTool(String)

    var errorDescription: String? {
        switch self {
        case .unknownTool(let name):
            return "Unbekanntes Werkzeug: \(name)."
        }
    }
}

// MARK: - Formatting helpers

private let isoDateFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd"
    f.locale = Locale(identifier: "de_DE")
    f.timeZone = TimeZone(identifier: "Europe/Berlin")
    return f
}()

private let isoDateTimeFormatter: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime]
    return f
}()

private extension String {
    /// Trim long fields to a tool-output-friendly length so the agent's
    /// context window doesn't fill up with one giant search result.
    /// 180 chars is enough for a German one-sentence summary or a corpus
    /// blurb teaser.
    func truncatedForTool(_ max: Int = 180) -> String {
        let trimmed = self.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n", with: " ")
        if trimmed.count <= max { return trimmed }
        return String(trimmed.prefix(max - 1)) + "…"
    }
}
