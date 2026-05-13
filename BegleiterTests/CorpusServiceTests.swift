import XCTest
@testable import Begleiter

final class CorpusServiceTests: XCTestCase {

    // MARK: - Fixture chunks

    private static let ancChunk = CorpusChunk(
        id: "glossary_labs/anc",
        source: .glossaryLabs,
        topicTags: ["lab", "anc", "neutrophile"],
        title: "ANC (Neutrophile)",
        text: "Die absolute Neutrophilenzahl zeigt die Bakterien-Abwehrzellen. Ein Wert unter 0,5 G/l heißt schwere Neutropenie.",
        referenceURL: nil,
        updatedAt: "2026-05-13"
    )

    private static let mtxChunk = CorpusChunk(
        id: "glossary_drugs/methotrexate",
        source: .glossaryDrugs,
        topicTags: ["drug", "methotrexate", "mtx"],
        title: "Methotrexat",
        text: "Methotrexat ist ein zentrales Medikament der ALL-Behandlung. Nebenwirkungen umfassen Mukositis.",
        referenceURL: nil,
        updatedAt: "2026-05-13"
    )

    private static let kkiFeverChunk = CorpusChunk(
        id: "kki/fever-neutropenia",
        source: .kinderkrebsinfo,
        topicTags: ["emergency", "infection", "fever", "neutropenia"],
        title: "Fieber in der Neutropenie",
        text: "Bei Fieber über 38,5 Grad sollte das Behandlungsteam kontaktiert werden.",
        referenceURL: "https://www.kinderkrebsinfo.de/",
        updatedAt: "2026-05-13"
    )

    private static let kkiInductionChunk = CorpusChunk(
        id: "kki/induction-ia-overview",
        source: .kinderkrebsinfo,
        topicTags: ["phase", "inductionIA", "intro"],
        title: "Was passiert in Induktion IA",
        text: "Die Induktion IA ist der erste Behandlungsblock im AIEOP-BFM Protokoll mit Vincristin und Steroiden.",
        referenceURL: "https://www.kinderkrebsinfo.de/",
        updatedAt: "2026-05-12"
    )

    private func makeService(chunks: [CorpusChunk]) -> CorpusService {
        CorpusService(testIndex: CorpusService.buildIndex(from: chunks))
    }

    // MARK: - BM25 retrieval

    func test_search_returnsRelevantChunks() {
        let service = makeService(chunks: [
            Self.ancChunk, Self.mtxChunk, Self.kkiFeverChunk,
        ])
        let hits = service.search(query: "Neutropenie", scope: .all, limit: 3)
        XCTAssertFalse(hits.isEmpty, "BM25 should match 'Neutropenie' against at least one chunk")
        XCTAssertTrue(hits.contains { $0.chunkId == Self.ancChunk.id || $0.chunkId == Self.kkiFeverChunk.id })
    }

    func test_search_emptyQueryReturnsRecentChunksByUpdatedAt() {
        // Use unambiguously distinct dates so the sort has a unique answer.
        let newest = CorpusChunk(
            id: "fixture/newest",
            source: .kinderkrebsinfo,
            topicTags: ["intro"],
            title: "Neu",
            text: "Aktueller Inhalt.",
            referenceURL: nil,
            updatedAt: "2026-06-01"
        )
        let middle = CorpusChunk(
            id: "fixture/middle",
            source: .kinderkrebsinfo,
            topicTags: ["intro"],
            title: "Mittel",
            text: "Mittelalter Inhalt.",
            referenceURL: nil,
            updatedAt: "2026-05-01"
        )
        let oldest = CorpusChunk(
            id: "fixture/oldest",
            source: .kinderkrebsinfo,
            topicTags: ["intro"],
            title: "Alt",
            text: "Älterer Inhalt.",
            referenceURL: nil,
            updatedAt: "2026-04-01"
        )
        let service = makeService(chunks: [oldest, middle, newest])
        let hits = service.search(query: "", scope: .all, limit: 3)
        XCTAssertEqual(hits.count, 3)
        XCTAssertTrue(hits.allSatisfy { $0.score == 0 })
        XCTAssertEqual(hits.map(\.chunkId), [newest.id, middle.id, oldest.id])
    }

    // MARK: - Scope filter

    func test_search_scopeLabs_excludesNonLabChunks() {
        let service = makeService(chunks: [
            Self.ancChunk,
            Self.mtxChunk,
            Self.kkiFeverChunk,
            Self.kkiInductionChunk,
        ])
        // Query both lab and non-lab content
        let hits = service.search(query: "Behandlung Neutropenie Vincristin", scope: .labs, limit: 4)
        let ids = Set(hits.map(\.chunkId))
        XCTAssertTrue(ids.contains(Self.ancChunk.id), "lab-tagged glossary should match")
        XCTAssertFalse(ids.contains(Self.mtxChunk.id), "drug chunk should not match in .labs scope")
        XCTAssertFalse(ids.contains(Self.kkiInductionChunk.id), "non-lab kki chunk should not match in .labs scope")
    }

    func test_search_scopeLabs_includesKKIWithLabTag() {
        let labTaggedKKI = CorpusChunk(
            id: "kki/cbc-interpretation",
            source: .kinderkrebsinfo,
            topicTags: ["lab", "cbc"],
            title: "Blutbild verstehen",
            text: "Das Blutbild zeigt Leukozyten, Hämoglobin und Thrombozyten.",
            referenceURL: "https://www.kinderkrebsinfo.de/",
            updatedAt: "2026-05-13"
        )
        let service = makeService(chunks: [Self.ancChunk, labTaggedKKI])
        let hits = service.search(query: "Blutbild", scope: .labs, limit: 4)
        XCTAssertTrue(hits.contains { $0.chunkId == labTaggedKKI.id },
                      "kki chunk with topicTags containing 'lab' must be retrievable in .labs scope")
    }

    // MARK: - Lookup

    func test_chunk_lookupReturnsRecordedChunk() {
        let service = makeService(chunks: [Self.ancChunk, Self.mtxChunk])
        XCTAssertEqual(service.chunk(id: Self.ancChunk.id), Self.ancChunk)
        XCTAssertNil(service.chunk(id: "nonexistent/chunk"))
    }

    // MARK: - Index build

    func test_buildIndex_emptyCorpusProducesUsableEmptyIndex() {
        let service = makeService(chunks: [])
        XCTAssertEqual(service.search(query: "Neutropenie", scope: .all, limit: 5), [])
        XCTAssertNil(service.chunk(id: "anything"))
        XCTAssertTrue(service.allChunks.isEmpty)
    }

    func test_allChunks_returnsStableOrder() {
        let service = makeService(chunks: [
            Self.kkiFeverChunk,
            Self.ancChunk,
            Self.mtxChunk,
            Self.kkiInductionChunk,
        ])
        let order = service.allChunks.map(\.id)
        // Source-then-id ordering puts glossary_drugs first, then glossary_labs,
        // then kinderkrebsinfo (alphabetical by raw value).
        XCTAssertEqual(order, [
            Self.mtxChunk.id,
            Self.ancChunk.id,
            Self.kkiFeverChunk.id,
            Self.kkiInductionChunk.id,
        ])
    }
}
