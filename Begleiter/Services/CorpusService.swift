import Foundation
import OSLog

private let corpusLog = Logger(subsystem: "io.grimso.Begleiter", category: "corpus")

/// Scope for an `AskService` question. Drives both the journal-side
/// retrieval (`RetrievalService.Filters.labsOnly`) and the corpus-side
/// scope filter (`CorpusService.search(scope:)`).
///
/// Declared alongside `CorpusService` because both `CorpusService` and
/// `AskService` reference it, and `CorpusService` is the more primitive
/// of the two.
nonisolated enum AskScope: String, Sendable, Hashable {
    /// Any-topic chat reachable from `TimelineView`. Retrieval against
    /// the full corpus and the full journal.
    case all

    /// Lab-focused chat reachable from `LabValuesView`. Corpus retrieval
    /// is restricted to lab glossary chunks (and lab-tagged externals);
    /// journal retrieval is restricted to entries with lab values.
    case labs
}

/// In-memory BM25 over the bundled `corpus.json` reference corpus.
///
/// The corpus is produced by `research/corpus/build_corpus.py` from
/// hand-curated drug/lab glossaries plus hand-authored German summaries
/// citing kinderkrebsinfo.de and kinderkrebshilfe.de. Every chunk's text
/// is the team's own work; chunks carry a `referenceURL` so the UI links
/// out rather than reproducing third-party text.
///
/// `CorpusService` is a `struct` with a lazy-loaded shared index. The
/// first call to `search(...)` reads `corpus.json` from the app bundle
/// and tokenises every chunk; subsequent calls reuse the cached index.
///
/// Tokenisation reuses `RetrievalService.tokenize(_:)` — same German
/// stoplist, same casefold, so a query that hits journal entries and a
/// query that hits the corpus go through identical processing.
struct CorpusService: Sendable {

    /// App-wide singleton. Index loads lazily on first `search(...)`.
    static let shared = CorpusService()

    /// A single retrieval hit with its BM25 score.
    struct Hit: Sendable, Hashable {
        let chunkId: String
        let score: Double
    }

    /// Optional instance-level index override. Production callers go
    /// through `CorpusService.shared`, which loads the bundled
    /// `corpus.json` lazily. Unit tests inject a synthetic index built
    /// from in-memory chunk fixtures.
    private let overrideIndex: Index?

    init(testIndex: Index? = nil) {
        self.overrideIndex = testIndex
    }

    /// The index this instance reads from. Production: cached static
    /// index from the bundle. Tests: the injected `testIndex`.
    private var activeIndex: Index? {
        overrideIndex ?? Self.indexResult
    }

    // MARK: - Public API

    /// BM25 search over the corpus, scoped per `AskScope`.
    ///
    /// `scope == .labs` filters to chunks whose `source == .glossaryLabs`
    /// or whose `topicTags` contains `"lab"`. Empty query returns the
    /// most recently updated chunks (score = 0) so the caller can still
    /// surface starter content if it wants.
    func search(
        query: String,
        scope: AskScope = .all,
        limit: Int = 6
    ) -> [Hit] {
        guard let index = activeIndex else { return [] }
        let candidates = Self.candidateIds(for: scope, in: index)
        let queryTerms = RetrievalService.tokenize(query)

        if queryTerms.isEmpty {
            return candidates
                .sorted { (a, b) in
                    let ua = index.chunks[a]?.updatedAt ?? ""
                    let ub = index.chunks[b]?.updatedAt ?? ""
                    return ua > ub
                }
                .prefix(limit)
                .map { Hit(chunkId: $0, score: 0) }
        }

        let scored: [(String, Double)] = candidates.compactMap { id -> (String, Double)? in
            guard let entry = index.documents[id] else { return nil }
            let length = Double(entry.length)
            var score = 0.0
            for qt in queryTerms {
                guard let tf = entry.termCounts[qt] else { continue }
                let n = Double(index.docFreq[qt] ?? 0)
                let idf = log((Double(index.docCount) - n + 0.5) / (n + 0.5) + 1.0)
                let normalizedLength = index.avgDocLength == 0
                    ? 1.0
                    : (length / index.avgDocLength)
                let denom = Double(tf) + Self.k1 * (1.0 - Self.b + Self.b * normalizedLength)
                score += idf * (Double(tf) * (Self.k1 + 1.0)) / denom
            }
            return (id, score)
        }

        return scored
            .filter { $0.1 > 0 }
            .sorted { $0.1 > $1.1 }
            .prefix(limit)
            .map { Hit(chunkId: $0.0, score: $0.1) }
    }

    /// Lookup a chunk by id. Used by the citation chip tap handler when
    /// the parent taps a `[K:<id>]` chip and the UI needs to present the
    /// full chunk in `CorpusChunkSheet`.
    func chunk(id: String) -> CorpusChunk? {
        activeIndex?.chunks[id]
    }

    // MARK: - Dense vectors (rerank cache)

    /// Lookup dense embeddings for the given chunk ids. Returns the
    /// subset that have a cached vector — caller can detect missing
    /// chunks by comparing keys to the input list and trigger backfill.
    /// Used by the dense-rerank path in `AskService`.
    func vectors(for ids: [String]) -> [String: [Float]] {
        _ = activeIndex  // trigger lazy hydration of `_vectors` from disk
        var out: [String: [Float]] = [:]
        for id in ids {
            if let v = Self._vectors[id] {
                out[id] = v
            }
        }
        return out
    }

    /// Compute and persist vectors for every chunk that doesn't have one
    /// yet. No-op when every retrieved candidate already has a cached
    /// vector. The embedder must be loaded by the caller; vectors are
    /// produced with `kind: .passage` (E5 convention for indexed text).
    ///
    /// Returns the chunk ids that were freshly embedded — `AskService`
    /// records this in `AskDebugInfo.corpusEmbedCount` for the Diagnose
    /// sheet.
    @discardableResult
    func backfillVectors(
        for ids: [String],
        using embedder: EmbeddingService
    ) async throws -> [String] {
        _ = activeIndex  // hydrate _vectors if first call
        guard let index = activeIndex else { return [] }

        let missing: [(id: String, text: String)] = ids.compactMap { id in
            guard Self._vectors[id] == nil, let chunk = index.chunks[id] else {
                return nil
            }
            // Pre-baked vector path: if the bundled JSON ever carries
            // baked vectors, promote them straight into the cache.
            if let baked = chunk.vector, !baked.isEmpty {
                Self._vectors[id] = baked
                return nil
            }
            return (id, chunk.title + " " + chunk.text)
        }
        guard !missing.isEmpty else { return [] }

        let texts = missing.map(\.text)
        let vectors = try await embedder.embed(texts, kind: .passage)
        guard vectors.count == missing.count else {
            corpusLog.error("embedder returned \(vectors.count, privacy: .public) vectors for \(missing.count, privacy: .public) inputs")
            return []
        }
        var freshlyEmbedded: [String] = []
        for (i, item) in missing.enumerated() {
            Self._vectors[item.id] = vectors[i]
            freshlyEmbedded.append(item.id)
        }
        Self.persistVectors()
        return freshlyEmbedded
    }

    /// Total cached vectors right now — useful for the "Clear cache"
    /// affordance to know whether the button does anything.
    var cachedVectorCount: Int {
        _ = activeIndex
        return Self._vectors.count
    }

    /// Drop all cached corpus vectors and delete the on-disk file.
    /// Called by the Settings "Clear embedding cache" button.
    func clearCachedVectors() {
        Self._vectors.removeAll()
        let url = Self.vectorsCacheURL
        if let url, FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// All chunks currently in the index. Stable order: source then id.
    /// Used by tests and by a future in-app corpus browser.
    var allChunks: [CorpusChunk] {
        guard let index = activeIndex else { return [] }
        return index.chunks.values.sorted { (a, b) in
            if a.source.rawValue != b.source.rawValue {
                return a.source.rawValue < b.source.rawValue
            }
            return a.id < b.id
        }
    }

    // MARK: - BM25 parameters

    private static let k1: Double = 1.5
    private static let b: Double = 0.75

    // MARK: - Index

    /// One indexed document — token frequencies plus its length so BM25
    /// can normalise by document length without re-tokenising.
    struct IndexedDoc {
        let length: Int
        let termCounts: [String: Int]
    }

    /// Everything `search(...)` needs in memory. Built once at first use,
    /// then cached forever — the corpus does not change at runtime.
    /// Internal so unit tests can call `buildIndex(from:)` against
    /// synthetic chunk fixtures.
    struct Index {
        let chunks: [String: CorpusChunk]
        let documents: [String: IndexedDoc]
        let docFreq: [String: Int]
        let docCount: Int
        let avgDocLength: Double
        /// chunk ids matching `scope = .labs` — `source == .glossaryLabs`
        /// OR `topicTags.contains("lab")`. Pre-computed so per-call
        /// retrieval doesn't re-walk every chunk.
        let labChunkIds: Set<String>
        /// All chunk ids — convenient for `scope = .all`.
        let allChunkIds: Set<String>
    }

    /// Cache the index in a nonisolated atomic so callers from any actor
    /// see the same instance after the first load. `nonisolated(unsafe)`
    /// is acceptable here because:
    /// - the index is immutable after construction
    /// - construction goes through `buildIndex()` exactly once via the
    ///   `_indexLoaded` sentinel (loadIndex is idempotent and we only
    ///   ever read after writing).
    nonisolated(unsafe) private static var _cachedIndex: Index?
    nonisolated(unsafe) private static var _indexAttempted: Bool = false

    /// Runtime cache of dense embeddings keyed by chunk id. Populated
    /// from `Documents/corpus_embeddings.json` on first index load and
    /// extended by `backfillVectors(...)` whenever the rerank path
    /// encounters a chunk without a vector. Persisted back to disk so
    /// the next launch can rehydrate instantly. `nonisolated(unsafe)`
    /// because all writes go through `CorpusService.shared` from
    /// `AskService` (an actor), which serialises access.
    nonisolated(unsafe) fileprivate static var _vectors: [String: [Float]] = [:]

    private static var indexResult: Index? {
        if !_indexAttempted {
            _indexAttempted = true
            _cachedIndex = loadIndex()
            hydrateVectorsFromDisk()
        }
        return _cachedIndex
    }

    /// Locate `corpus.json` in the main bundle, decode it, tokenise each
    /// chunk's `text + title`, build the inverted index. Returns `nil` if
    /// the resource is missing or malformed — the `AskService` empty-
    /// retrieval pathway handles `nil` gracefully (the parent gets a
    /// refusal rather than a crash).
    private static func loadIndex() -> Index? {
        guard let url = Bundle.main.url(forResource: "corpus", withExtension: "json") else {
            corpusLog.error("corpus.json not found in main bundle")
            return nil
        }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            corpusLog.error("failed to read corpus.json: \(error.localizedDescription, privacy: .public)")
            return nil
        }
        let chunks: [CorpusChunk]
        do {
            chunks = try JSONDecoder().decode([CorpusChunk].self, from: data)
        } catch {
            corpusLog.error("failed to decode corpus.json: \(error.localizedDescription, privacy: .public)")
            return nil
        }
        return buildIndex(from: chunks)
    }

    /// Build the BM25 index from a `[CorpusChunk]`. Extracted so tests
    /// can build an index from a synthetic fixture without round-
    /// tripping through the bundle.
    static func buildIndex(from chunks: [CorpusChunk]) -> Index {
        var byId: [String: CorpusChunk] = [:]
        var documents: [String: IndexedDoc] = [:]
        var docFreq: [String: Int] = [:]
        var totalTokens = 0
        var labChunkIds: Set<String> = []
        var allChunkIds: Set<String> = []

        for chunk in chunks {
            byId[chunk.id] = chunk
            allChunkIds.insert(chunk.id)
            if chunk.source == .glossaryLabs || chunk.topicTags.contains("lab") {
                labChunkIds.insert(chunk.id)
            }
            // Index title + topic tags + body. Tags weigh equally with
            // body words — fine for a corpus of ~50 short chunks.
            let indexable = ([chunk.title] + chunk.topicTags + [chunk.text])
                .joined(separator: " ")
            let tokens = RetrievalService.tokenize(indexable)
            totalTokens += tokens.count
            var counts: [String: Int] = [:]
            for t in tokens { counts[t, default: 0] += 1 }
            documents[chunk.id] = IndexedDoc(length: tokens.count, termCounts: counts)
            for term in counts.keys {
                docFreq[term, default: 0] += 1
            }
        }
        let avg = chunks.isEmpty ? 0 : Double(totalTokens) / Double(chunks.count)
        return Index(
            chunks: byId,
            documents: documents,
            docFreq: docFreq,
            docCount: chunks.count,
            avgDocLength: avg,
            labChunkIds: labChunkIds,
            allChunkIds: allChunkIds
        )
    }

    private static func candidateIds(for scope: AskScope, in index: Index) -> [String] {
        switch scope {
        case .all:  return Array(index.allChunkIds)
        case .labs: return Array(index.labChunkIds)
        }
    }

    // MARK: - Vector persistence

    /// Resolved URL for the on-disk vector cache. Returns `nil` only on
    /// the rare device where `Documents` is unreachable.
    private static var vectorsCacheURL: URL? {
        guard let docs = FileManager.default.urls(
            for: .documentDirectory, in: .userDomainMask
        ).first else { return nil }
        return docs.appending(component: "corpus_embeddings.json")
    }

    /// Read `corpus_embeddings.json` if it exists; populate `_vectors`.
    /// Silently ignores read / decode errors — a missing or corrupt
    /// cache file just means the next backfill re-embeds.
    private static func hydrateVectorsFromDisk() {
        guard let url = vectorsCacheURL,
              FileManager.default.fileExists(atPath: url.path) else {
            return
        }
        do {
            let data = try Data(contentsOf: url)
            let decoded = try JSONDecoder().decode([String: [Float]].self, from: data)
            _vectors = decoded
            corpusLog.info("hydrated \(decoded.count, privacy: .public) corpus vectors from disk")
        } catch {
            corpusLog.error("failed to hydrate corpus vectors: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Write `_vectors` to disk. Called by `backfillVectors(...)` and
    /// any future invalidation path. Best-effort — if the write fails
    /// we still have the in-memory cache for this session.
    fileprivate static func persistVectors() {
        guard let url = vectorsCacheURL else { return }
        do {
            let data = try JSONEncoder().encode(_vectors)
            try data.write(to: url, options: [.atomic])
        } catch {
            corpusLog.error("failed to persist corpus vectors: \(error.localizedDescription, privacy: .public)")
        }
    }
}
