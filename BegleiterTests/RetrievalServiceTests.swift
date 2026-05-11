import XCTest
@testable import Begleiter

final class RetrievalServiceTests: XCTestCase {

    // MARK: - Tokenizer

    func test_tokenize_caseFoldsAndStripsPunctuation() {
        let tokens = RetrievalService.tokenize("ANC 0.8, gestern bei Dr. Schäfer!")
        // "schäfer" lowercased; "anc" kept; numbers kept; punctuation stripped;
        // German stopwords removed ("bei").
        XCTAssertTrue(tokens.contains("anc"))
        XCTAssertTrue(tokens.contains("schäfer"))
        XCTAssertTrue(tokens.contains("gestern"))
        XCTAssertFalse(tokens.contains("bei"))    // stopword
        XCTAssertFalse(tokens.contains(""))
    }

    func test_tokenize_dropsTokensShorterThanTwoChars() {
        let tokens = RetrievalService.tokenize("a b cc d")
        XCTAssertEqual(tokens, ["cc"])
    }

    func test_tokenize_handlesUmlauts() {
        let tokens = RetrievalService.tokenize("Mundschleimhaut Übelkeit")
        XCTAssertTrue(tokens.contains("mundschleimhaut"))
        XCTAssertTrue(tokens.contains("übelkeit"))
    }

    // MARK: - BM25 ranking

    /// Tiny in-memory corpus to drive the ranker. We don't need SwiftData —
    /// JournalEntry's `init` works standalone.
    private func corpus() -> [JournalEntry] {
        [
            entry(text: "Heute Vincristin bekommen, leichte Übelkeit.", visitDate: dayAgo(0)),
            entry(text: "ANC ist auf 0.6 gefallen, das Team sagt weiter beobachten.", visitDate: dayAgo(1)),
            entry(text: "Vincristin und Methotrexat heute, alles ruhig.", visitDate: dayAgo(2)),
            entry(text: "Kontroll-Lumbalpunktion, kein Befund.", visitDate: dayAgo(3)),
        ]
    }

    private func entry(text: String, visitDate: Date) -> JournalEntry {
        JournalEntry(
            childId: UUID(),
            visitDate: visitDate,
            phase: .inductionIA,
            dayInPhase: 1,
            riskGroup: .standardRisk,
            arm: .standard,
            inputModalities: ["text"],
            rawText: text
        )
    }

    private func dayAgo(_ n: Int) -> Date {
        Calendar.current.date(byAdding: .day, value: -n, to: .now) ?? .now
    }

    func test_search_emptyQuery_returnsAllSortedByDate() {
        let svc = RetrievalService()
        let entries = corpus()
        let hits = svc.search(query: "", in: entries)
        XCTAssertEqual(hits.count, 4)
        // Newest first
        XCTAssertEqual(hits[0].entryId, entries[0].entryId)
        XCTAssertEqual(hits[3].entryId, entries[3].entryId)
    }

    func test_search_singleTerm_rankingHigherForMoreOccurrences() {
        let svc = RetrievalService()
        let entries = corpus()
        let hits = svc.search(query: "Vincristin", in: entries)
        XCTAssertEqual(hits.count, 2, "Both Vincristin entries should match")
        // The top hits should be the two entries that actually mention it
        let topIds = Set(hits.map(\.entryId))
        XCTAssertTrue(topIds.contains(entries[0].entryId))
        XCTAssertTrue(topIds.contains(entries[2].entryId))
        XCTAssertFalse(topIds.contains(entries[1].entryId))
    }

    func test_search_returnsEmptyWhenNoMatch() {
        let svc = RetrievalService()
        let hits = svc.search(query: "Asparaginase", in: corpus())
        XCTAssertTrue(hits.isEmpty)
    }

    func test_filters_phase_narrowsCorpus() {
        let svc = RetrievalService()
        var entries = corpus()
        // Mutate one to be in a different phase
        entries[2].phase = .reinductionII
        let hits = svc.search(
            query: "Vincristin",
            in: entries,
            filters: .init(phase: .inductionIA)
        )
        // Only the Induction IA entry containing Vincristin should remain
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits[0].entryId, entries[0].entryId)
    }

    func test_entries_mentioningDrug_byCanonicalName() {
        let svc = RetrievalService()
        var entries = corpus()
        // Inject a DrugMention into entry[0]
        entries[0].extractedFields = ExtractedFields(
            drugsMentioned: ConfidenceField(
                value: [DrugMention(name: "vincristine", germanLabel: "Vincristin", doseDescription: nil, administeredAt: nil)],
                confidence: 0.9
            )
        )
        let hits = svc.entries(mentioningDrug: "vincristine", in: entries)
        XCTAssertEqual(hits.first?.entryId, entries[0].entryId)
    }
}
