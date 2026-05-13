import XCTest
@testable import Begleiter

final class RerankerEngineTests: XCTestCase {

    // MARK: - Cosine

    func test_cosine_identicalVectors_isOne() {
        let v: [Float] = normalised([0.6, 0.8])
        XCTAssertEqual(RerankerEngine.cosine(v, v), 1.0, accuracy: 1e-6)
    }

    func test_cosine_orthogonalVectors_isZero() {
        let a: [Float] = [1, 0]
        let b: [Float] = [0, 1]
        XCTAssertEqual(RerankerEngine.cosine(a, b), 0.0, accuracy: 1e-6)
    }

    func test_cosine_antiParallel_isNegativeOne() {
        let a: [Float] = [1, 0]
        let b: [Float] = [-1, 0]
        XCTAssertEqual(RerankerEngine.cosine(a, b), -1.0, accuracy: 1e-6)
    }

    func test_cosine_lengthMismatch_returnsZero() {
        XCTAssertEqual(RerankerEngine.cosine([1, 0, 0], [1, 0]), 0)
    }

    // MARK: - Rerank

    func test_rerank_emptyInput_returnsEmpty() {
        let result = RerankerEngine.rerank(
            bm25Ranking: [String](),
            queryVector: [0.5, 0.5]
        ) { _ in nil }
        XCTAssertTrue(result.isEmpty)
    }

    func test_rerank_emptyQueryVector_preservesBM25Order() {
        // Empty query vector means no cosine signal — every candidate
        // gets the worst cosine rank, so RRF collapses to BM25 order.
        let ids = ["a", "b", "c"]
        let result = RerankerEngine.rerank(
            bm25Ranking: ids,
            queryVector: []
        ) { _ in [Float]([1, 0]) }
        XCTAssertEqual(result.map(\.id), ids)
    }

    func test_rerank_cosinePromotesBM25MiddleCandidate() {
        // BM25 ranks a > b > c. Cosine ranks: b=best, c=middle, a=worst.
        // Candidate `b` is rank-2 by BM25 and rank-1 by cosine — RRF
        // should lift it to the top because both signals partially
        // agree it's strong, with cosine pushing harder than BM25.
        let query: [Float] = [1, 0]
        let vectors: [String: [Float]] = [
            "a": [0, 1],         // cosine 0   → worst (rank 3)
            "b": [1, 0],         // cosine 1   → best  (rank 1)
            "c": [0.7, 0.7],     // cosine 0.7 → mid   (rank 2)
        ]
        let result = RerankerEngine.rerank(
            bm25Ranking: ["a", "b", "c"],
            queryVector: query
        ) { vectors[$0] }
        XCTAssertEqual(result.first?.id, "b",
                       "RRF should promote the BM25-middle candidate when cosine ranks it first")
        // RRF math: b: 1/62 + 1/61 = 0.0325 > a: 1/61 + 1/63 = 0.0323
        // > c: 1/63 + 1/62 = 0.0320. So `c` (BM25-last, cosine-mid)
        // lands at the bottom — both signals nudge it down.
        XCTAssertEqual(result.last?.id, "c")
    }

    func test_rerank_missingVector_keepsBM25RankAndGetsWorstCosineRank() {
        // BM25 ranking: ["x", "y"]. x has no vector, y has perfect cosine.
        // y should outrank x because its cosine rank is 1 and x's is N+1.
        let query: [Float] = [1, 0]
        let vectors: [String: [Float]] = [
            "y": [1, 0],
        ]
        let result = RerankerEngine.rerank(
            bm25Ranking: ["x", "y"],
            queryVector: query
        ) { vectors[$0] }
        XCTAssertEqual(result.first?.id, "y")
        // x's cosine rank should be the worst slot (N+1 = 3).
        let xHit = result.first { $0.id == "x" }
        XCTAssertEqual(xHit?.cosineRank, 3)
    }

    func test_rerank_allMissingVectors_preservesBM25Order() {
        let ids = ["a", "b", "c", "d"]
        let result = RerankerEngine.rerank(
            bm25Ranking: ids,
            queryVector: [1, 0]
        ) { _ in nil }
        XCTAssertEqual(result.map(\.id), ids,
                       "no cosine signal → RRF reduces to BM25 ranking")
    }

    func test_rerank_recordsBM25AndCosineRanks() {
        let query: [Float] = [1, 0]
        let vectors: [String: [Float]] = [
            "a": [1, 0],
            "b": [0, 1],
        ]
        let result = RerankerEngine.rerank(
            bm25Ranking: ["a", "b"],
            queryVector: query
        ) { vectors[$0] }
        let a = result.first { $0.id == "a" }
        XCTAssertEqual(a?.bm25Rank, 1)
        XCTAssertEqual(a?.cosineRank, 1)
        let b = result.first { $0.id == "b" }
        XCTAssertEqual(b?.bm25Rank, 2)
        XCTAssertEqual(b?.cosineRank, 2)
    }

    // MARK: - Reorder count

    func test_reorderCount_unchangedTop_isZero() {
        let bm25 = ["a", "b", "c"]
        let reranked = bm25.enumerated().map {
            RerankerEngine.RerankedHit(
                id: $1, bm25Rank: $0 + 1, cosineRank: $0 + 1, fusedScore: 1.0 - Double($0)
            )
        }
        XCTAssertEqual(
            RerankerEngine.reorderCount(bm25Ranking: bm25, reranked: reranked, topN: 3),
            0
        )
    }

    func test_reorderCount_fullReverse_countsAllPositions() {
        let bm25 = ["a", "b", "c"]
        let reranked = [
            RerankerEngine.RerankedHit(id: "c", bm25Rank: 3, cosineRank: 1, fusedScore: 1),
            RerankerEngine.RerankedHit(id: "b", bm25Rank: 2, cosineRank: 2, fusedScore: 0.5),
            RerankerEngine.RerankedHit(id: "a", bm25Rank: 1, cosineRank: 3, fusedScore: 0.1),
        ]
        XCTAssertEqual(
            RerankerEngine.reorderCount(bm25Ranking: bm25, reranked: reranked, topN: 3),
            2  // positions 0 and 2 changed; position 1 (b) stayed
        )
    }

    // MARK: - Helpers

    private func normalised(_ v: [Float]) -> [Float] {
        let mag = sqrt(v.reduce(0) { $0 + $1 * $1 })
        return mag > 0 ? v.map { $0 / mag } : v
    }
}
