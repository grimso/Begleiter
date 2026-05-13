import XCTest
@testable import Begleiter
import MLXLMCommon

/// Tests for the pure-Swift surface of `AgentTools`:
/// - schema generation (auto-built from `ToolParameter` declarations)
/// - per-tool handlers exercised with in-memory fixtures
/// - dispatcher routing
/// - JSON-arg → Codable Input decoding via `ToolCall.execute(with:)`
///
/// On-device Gemma + the multi-turn `ChatSession` agent loop are exercised
/// manually on the iPhone — those tests would need a loaded model and the
/// codebase memory rule says "MLX cannot run on simulator."
final class AgentToolsTests: XCTestCase {

    // MARK: - Fixtures

    private static let childId = UUID()
    private static let entryA = UUID()
    private static let entryB = UUID()
    private static let entryC = UUID()

    private static let mtxLab = LabValue(
        parameter: "ANC", germanLabel: "Neutrophile",
        value: 0.8, unit: "G/L",
        measuredAt: Date(timeIntervalSince1970: 1_704_067_200) // 2024-01-01
    )
    private static let mtxLab2 = LabValue(
        parameter: "ANC", germanLabel: "Neutrophile",
        value: 1.6, unit: "G/L",
        measuredAt: Date(timeIntervalSince1970: 1_706_745_600) // 2024-02-01
    )
    private static let hbLab = LabValue(
        parameter: "Hb", germanLabel: "Hämoglobin",
        value: 9.5, unit: "g/dL",
        measuredAt: Date(timeIntervalSince1970: 1_704_067_200)
    )

    private func makeEntries() -> [JournalEntry] {
        let extractedA = ExtractedFields(
            labValues: ConfidenceField(
                value: [Self.mtxLab, Self.hbLab],
                confidence: 1.0
            ),
            summary: ConfidenceField(value: "Methotrexat-Infusion, ANC niedrig.", confidence: 1.0)
        )
        let extractedB = ExtractedFields(
            labValues: ConfidenceField(value: [Self.mtxLab2], confidence: 1.0),
            summary: ConfidenceField(value: "Verlaufskontrolle, ANC erholt.", confidence: 1.0)
        )
        let a = JournalEntry(
            entryId: Self.entryA,
            childId: Self.childId,
            visitDate: Date(timeIntervalSince1970: 1_704_067_200),
            phase: .inductionIA,
            dayInPhase: 12,
            riskGroup: .standardRisk,
            arm: .standard,
            inputModalities: ["text"],
            rawText: "Heute Methotrexat bekommen.",
            extractedFields: extractedA
        )
        let b = JournalEntry(
            entryId: Self.entryB,
            childId: Self.childId,
            visitDate: Date(timeIntervalSince1970: 1_706_745_600),
            phase: .consolidationM,
            dayInPhase: 4,
            riskGroup: .standardRisk,
            arm: .standard,
            inputModalities: ["text"],
            rawText: "Kurzer Termin, Werte besser.",
            extractedFields: extractedB
        )
        let c = JournalEntry(
            entryId: Self.entryC,
            childId: Self.childId,
            visitDate: Date(timeIntervalSince1970: 1_709_251_200), // 2024-03-01
            phase: .consolidationM,
            dayInPhase: 20,
            riskGroup: .standardRisk,
            arm: .standard,
            inputModalities: ["text"],
            rawText: "Fieber 38.6, Notaufnahme. Keine Labordaten erfasst.",
            extractedFields: .empty
        )
        return [a, b, c]
    }

    private static func makeCorpus() -> CorpusService {
        let chunks: [CorpusChunk] = [
            CorpusChunk(
                id: "glossary_labs/anc",
                source: .glossaryLabs,
                topicTags: ["lab", "anc"],
                title: "ANC",
                text: "Die absolute Neutrophilenzahl zeigt die Bakterien-Abwehrzellen.",
                referenceURL: nil,
                updatedAt: "2026-05-13"
            ),
            CorpusChunk(
                id: "glossary_drugs/methotrexate",
                source: .glossaryDrugs,
                topicTags: ["drug", "methotrexate"],
                title: "Methotrexat",
                text: "Methotrexat ist ein zentrales Medikament der ALL-Behandlung.",
                referenceURL: nil,
                updatedAt: "2026-05-13"
            ),
            CorpusChunk(
                id: "kki/fever",
                source: .kinderkrebsinfo,
                topicTags: ["emergency", "fever"],
                title: "Fieber in der Neutropenie",
                text: "Bei Fieber über 38,5 Grad sollte das Behandlungsteam kontaktiert werden.",
                referenceURL: nil,
                updatedAt: "2026-05-13"
            ),
        ]
        return CorpusService(testIndex: CorpusService.buildIndex(from: chunks))
    }

    private func makeTools(entries: [JournalEntry]? = nil) -> AgentTools {
        AgentTools(
            retrieval: RetrievalService(),
            corpus: Self.makeCorpus(),
            entries: entries ?? makeEntries()
        )
    }

    // MARK: - Schema

    func test_schemas_advertiseAllFourTools() {
        let tools = makeTools()
        let names = tools.schemas.compactMap { schema -> String? in
            (schema["function"] as? [String: Any])?["name"] as? String
        }
        XCTAssertEqual(
            Set(names),
            ["search_journal", "search_corpus", "get_lab_trend", "get_phase_metadata"],
            "All four agent tools must be exposed to Gemma."
        )
    }

    func test_searchJournal_schema_marksQueryRequiredAndEnumeratesPhase() {
        let tools = makeTools()
        guard
            let function = tools.searchJournal.schema["function"] as? [String: Any],
            let parameters = function["parameters"] as? [String: Any],
            let properties = parameters["properties"] as? [String: Any],
            let required = parameters["required"] as? [String]
        else {
            return XCTFail("search_journal schema is malformed")
        }
        XCTAssertTrue(required.contains("query"))
        XCTAssertFalse(required.contains("phase"))
        // The `phase` property must carry an `enum` so Gemma sees the
        // legal phase rawValues.
        let phaseProp = properties["phase"] as? [String: Any]
        let phaseEnum = phaseProp?["enum"] as? [String]
        XCTAssertNotNil(phaseEnum)
        XCTAssertEqual(Set(phaseEnum ?? []), Set(Phase.allCases.map(\.rawValue)))
    }

    // MARK: - Handlers

    func test_handleSearchJournal_returnsEntryMarkers() async {
        let entries = makeEntries()
        let out = await AgentTools.handleSearchJournal(
            SearchJournalInput(
                query: "Methotrexat",
                phase: nil, drug: nil, since: nil, until: nil,
                labs_only: nil, limit: nil
            ),
            retrieval: RetrievalService(),
            entries: entries
        )
        XCTAssertTrue(
            out.contains("[E:\(Self.entryA.uuidString)]"),
            "BM25 hit for 'Methotrexat' should surface the matching entry's UUID marker.\nGot: \(out)"
        )
    }

    func test_handleSearchJournal_phaseFilter_narrowsResults() async {
        let entries = makeEntries()
        let out = await AgentTools.handleSearchJournal(
            SearchJournalInput(
                query: "Werte",
                phase: Phase.consolidationM.rawValue,
                drug: nil, since: nil, until: nil,
                labs_only: nil, limit: nil
            ),
            retrieval: RetrievalService(),
            entries: entries
        )
        XCTAssertFalse(out.contains("[E:\(Self.entryA.uuidString)]"),
                       "Entry A is in InductionIA and should be excluded by the phase filter.")
    }

    func test_handleSearchJournal_emptyResult_emitsCanonicalMessage() async {
        let out = await AgentTools.handleSearchJournal(
            SearchJournalInput(
                query: "Methotrexat",
                phase: nil, drug: nil, since: nil, until: nil,
                labs_only: nil, limit: nil
            ),
            retrieval: RetrievalService(),
            entries: []
        )
        XCTAssertTrue(out.contains("Keine passenden Journal-Einträge"),
                      "Empty result must surface the canonical no-hits message.")
    }

    func test_handleSearchCorpus_emitsChunkMarkers() async {
        let out = await AgentTools.handleSearchCorpus(
            SearchCorpusInput(query: "ANC Neutrophilen", scope: nil, limit: nil),
            corpus: Self.makeCorpus()
        )
        XCTAssertTrue(out.contains("[K:glossary_labs/anc]"),
                      "Corpus hit must carry the [K:<id>] citation marker.\nGot: \(out)")
    }

    func test_handleSearchCorpus_labsScope_excludesNonLabChunks() async {
        let out = await AgentTools.handleSearchCorpus(
            SearchCorpusInput(query: "Methotrexat Fieber ANC", scope: "labs", limit: nil),
            corpus: Self.makeCorpus()
        )
        XCTAssertFalse(out.contains("[K:glossary_drugs/methotrexate]"),
                       "scope=labs must keep the drug-glossary chunk out of results.")
    }

    func test_handleGetLabTrend_sortsByDateAndIncludesEntryMarker() async {
        let entries = makeEntries()
        let out = await AgentTools.handleGetLabTrend(
            GetLabTrendInput(parameter: "ANC", since: nil, until: nil),
            entries: entries
        )
        // Both ANC values present, oldest first, each tagged with its source entry.
        let lines = out.split(separator: "\n").map(String.init)
        let valueLines = lines.filter { $0.contains("G/L") }
        XCTAssertEqual(valueLines.count, 2)
        XCTAssertTrue(valueLines.first?.contains("0.8") == true,
                      "Older ANC reading (0.8) must come first.")
        XCTAssertTrue(valueLines.first?.contains("[E:\(Self.entryA.uuidString)]") == true,
                      "Each point must carry the source entry marker.")
    }

    func test_handleGetLabTrend_isCaseInsensitiveOnParameter() async {
        let entries = makeEntries()
        let lower = await AgentTools.handleGetLabTrend(
            GetLabTrendInput(parameter: "anc", since: nil, until: nil),
            entries: entries
        )
        let upper = await AgentTools.handleGetLabTrend(
            GetLabTrendInput(parameter: "ANC", since: nil, until: nil),
            entries: entries
        )
        XCTAssertEqual(lower, upper)
    }

    func test_handleGetLabTrend_noMatches_emitsCanonicalMessage() async {
        let out = await AgentTools.handleGetLabTrend(
            GetLabTrendInput(parameter: "CRP", since: nil, until: nil),
            entries: makeEntries()
        )
        XCTAssertTrue(out.contains("Keine Werte"),
                      "Missing parameter should surface the canonical no-data message.")
    }

    func test_handleGetPhaseMetadata_knownPhase_returnsLabelAndDuration() {
        let out = AgentTools.handleGetPhaseMetadata(
            GetPhaseMetadataInput(phase: Phase.inductionIA.rawValue)
        )
        XCTAssertTrue(out.contains("Induktion"),
                      "Phase block must include the German phase label.")
        XCTAssertTrue(out.contains("Tage"),
                      "Phase block must surface typical duration.")
    }

    func test_handleGetPhaseMetadata_unknownPhase_returnsErrorString() {
        let out = AgentTools.handleGetPhaseMetadata(
            GetPhaseMetadataInput(phase: "not_a_phase")
        )
        XCTAssertTrue(out.contains("Unbekannte Phase"))
    }

    func test_parseISODate_acceptsDateOnlyAndFullISO() {
        XCTAssertNotNil(AgentTools.parseISODate("2026-05-13"))
        XCTAssertNotNil(AgentTools.parseISODate("2026-05-13T08:30:00Z"))
        XCTAssertNil(AgentTools.parseISODate("yesterday"))
    }

    // MARK: - Dispatcher

    func test_dispatch_unknownTool_throwsTypedError() async {
        let tools = makeTools()
        let call = ToolCall(function: .init(
            name: "do_something_evil",
            arguments: ["x": JSONValue.string("y")]
        ))
        await XCTAssertThrowsErrorAsync(
            try await tools.dispatch(call)
        ) { error in
            guard case AgentToolError.unknownTool(let name) = error else {
                return XCTFail("Expected AgentToolError.unknownTool, got \(error)")
            }
            XCTAssertEqual(name, "do_something_evil")
        }
    }

    func test_dispatch_routesSearchJournalCallEndToEnd() async throws {
        let tools = makeTools()
        let call = ToolCall(function: .init(
            name: "search_journal",
            arguments: [
                "query": JSONValue.string("Methotrexat"),
            ]
        ))
        let out = try await tools.dispatch(call)
        XCTAssertTrue(out.contains("[E:\(Self.entryA.uuidString)]"),
                      "Dispatcher must route to the search_journal handler and surface its output.")
    }

    func test_dispatch_decodesGetLabTrendArgumentsFromJSONValue() async throws {
        let tools = makeTools()
        let call = ToolCall(function: .init(
            name: "get_lab_trend",
            arguments: [
                "parameter": JSONValue.string("ANC"),
            ]
        ))
        let out = try await tools.dispatch(call)
        XCTAssertTrue(out.contains("ANC-Verlauf"),
                      "Dispatcher must decode JSON args into GetLabTrendInput and invoke the handler.")
    }
}

// MARK: - Async XCTest assert helper

/// `XCTAssertThrowsError` doesn't support async throwers; this is the
/// canonical async equivalent used elsewhere in the test suite (see
/// `ExtractionServiceTests`-style patterns).
private func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    file: StaticString = #file,
    line: UInt = #line,
    _ errorHandler: (Error) -> Void = { _ in }
) async {
    do {
        _ = try await expression()
        XCTFail("Expected expression to throw", file: file, line: line)
    } catch {
        errorHandler(error)
    }
}
