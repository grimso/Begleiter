import Foundation

/// Pure-Swift implementation of the dense-rerank step that sits between
/// BM25 retrieval and Gemma prompt building in `AskService`. No MLX
/// imports so this is fully unit-testable with synthetic float vectors.
///
/// Strategy: **Reciprocal Rank Fusion (RRF) over BM25 rank and cosine
/// rank.** For each candidate:
///
/// ```
/// score = 1/(k + bm25Rank) + 1/(k + cosineRank)
/// ```
///
/// with `k = 60` (Cormack/Clarke/Buettcher 2009 default). RRF dominates
/// raw-score fusion when the two signals have very different scales —
/// BM25 is unbounded and corpus-specific, cosine is bounded [-1, 1] for
/// L2-normalised vectors. Both have monotone-meaningful ranks; RRF
/// combines them without score normalisation.
///
/// **Missing-vector fallback**: a candidate whose vector is `nil` keeps
/// its BM25 rank but gets a cosine rank equal to "worst" (length of the
/// list + 1). The fusion still places it above truly bad lexical hits.
enum RerankerEngine {

    /// Reciprocal Rank Fusion constant. Standard value from the
    /// canonical paper; not user-tunable. Bigger `k` flattens both
    /// signals; smaller `k` over-rewards top ranks. 60 is the value
    /// every public benchmark uses.
    static let rrfK: Double = 60

    /// Cosine similarity of two L2-normalised vectors (i.e. dot product).
    /// Returns 0 on length mismatch or zero-length inputs — the rerank
    /// loop treats that as "no signal" without crashing.
    static func cosine(_ a: [Float], _ b: [Float]) -> Double {
        guard !a.isEmpty, a.count == b.count else { return 0 }
        var sum: Double = 0
        for i in 0..<a.count {
            sum += Double(a[i]) * Double(b[i])
        }
        return sum
    }

    /// One reranked candidate. `bm25Rank` and `cosineRank` are
    /// 1-indexed positions in their respective rankings (1 = best).
    /// Exposed for the Diagnose sheet's reorder display.
    struct RerankedHit<ID: Hashable>: Hashable where ID: Sendable {
        let id: ID
        let bm25Rank: Int
        let cosineRank: Int
        let fusedScore: Double
    }

    /// Rerank `bm25Ranking` by RRF of BM25 rank + cosine rank.
    /// `bm25Ranking` must be sorted by BM25 score descending. Position
    /// (1-indexed) is the BM25 rank.
    ///
    /// `vectorFor(id)` returns `nil` for candidates we couldn't embed
    /// (e.g. journal entries the user hasn't engaged with yet — vectors
    /// get lazily backfilled in `AskService` before this is called, so
    /// most calls return non-nil).
    ///
    /// Returns a list sorted by `fusedScore` descending. Same length as
    /// `bm25Ranking`.
    static func rerank<ID: Hashable>(
        bm25Ranking: [ID],
        queryVector: [Float],
        vectorFor: (ID) -> [Float]?
    ) -> [RerankedHit<ID>] where ID: Sendable {
        guard !bm25Ranking.isEmpty else { return [] }

        // 1. Compute cosine scores for every candidate. Missing vectors
        // become `nil` and get sorted to the end of the cosine ranking.
        let cosines: [(ID, Double?)] = bm25Ranking.map { id in
            guard let v = vectorFor(id), !queryVector.isEmpty else {
                return (id, nil)
            }
            return (id, cosine(queryVector, v))
        }

        // 2. Cosine rank: 1-indexed, highest cosine = rank 1. Nil cosines
        // get worst rank = N + 1 so they don't beat any concrete signal.
        let worstRank = bm25Ranking.count + 1
        let cosineRanks: [ID: Int] = {
            let withValues = cosines.compactMap { (id, c) -> (ID, Double)? in
                guard let c else { return nil }
                return (id, c)
            }
            let sorted = withValues.sorted { $0.1 > $1.1 }
            var ranks: [ID: Int] = [:]
            for (i, (id, _)) in sorted.enumerated() {
                ranks[id] = i + 1
            }
            // Anything without a vector keeps the worst rank.
            for (id, c) in cosines where c == nil {
                ranks[id] = worstRank
            }
            return ranks
        }()

        // 3. RRF fusion.
        let fused: [RerankedHit<ID>] = bm25Ranking.enumerated().map { (i, id) in
            let bm25Rank = i + 1
            let cosineRank = cosineRanks[id] ?? worstRank
            let score =
                1.0 / (Self.rrfK + Double(bm25Rank))
                + 1.0 / (Self.rrfK + Double(cosineRank))
            return RerankedHit(
                id: id,
                bm25Rank: bm25Rank,
                cosineRank: cosineRank,
                fusedScore: score
            )
        }

        return fused.sorted { $0.fusedScore > $1.fusedScore }
    }

    /// Number of positions that changed between `bm25Ranking` and the
    /// reranked output, evaluated only over the top `topN`. Used by the
    /// Diagnose sheet to surface "how much did this rerank do anything".
    /// 0 means the rerank was a no-op for the top.
    static func reorderCount<ID: Hashable>(
        bm25Ranking: [ID],
        reranked: [RerankedHit<ID>],
        topN: Int
    ) -> Int where ID: Sendable {
        let n = min(topN, bm25Ranking.count, reranked.count)
        var changes = 0
        for i in 0..<n where bm25Ranking[i] != reranked[i].id {
            changes += 1
        }
        return changes
    }
}
