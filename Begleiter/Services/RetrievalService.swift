import Foundation

/// In-memory BM25 over `JournalEntry`. Designed for the iteration-6 retrieval
/// pass; dense-embedding rerank is a future enhancement once `EmbeddingService`
/// lands.
///
/// Tokenization is German-aware: case-folded with `localizedLowercase`, splits
/// on Unicode whitespace + punctuation, strips a small German stoplist. We
/// search across:
/// - `rawText`
/// - `extractedFields.summary?.value`
/// - drug names (German + canonical)
/// - parent observations, decisions, open questions
/// - reactions descriptions
///
/// The journal is expected to stay under a few thousand entries, so brute-force
/// scoring per query is acceptable. If retrieval becomes hot, swap in an
/// inverted-index structure.
struct RetrievalService: Sendable {

    /// A single result with its BM25 score and the field that contributed
    /// most to the match (for surfacing "matched in: summary" in UI later).
    struct Hit: Sendable, Hashable {
        let entryId: UUID
        let score: Double
    }

    /// Filters narrow the candidate set before scoring.
    struct Filters: Sendable {
        var phase: Phase?
        var fromDate: Date?
        var toDate: Date?
        /// Restrict to entries that mention any drug whose `name` matches one
        /// of these canonical INNs.
        var drugs: Set<String> = []

        static let none = Filters()
    }

    // BM25 parameters — defaults from the original paper, validated to work
    // well on short documents (which journal entries are).
    private let k1: Double = 1.5
    private let b: Double = 0.75

    // MARK: - Public API

    /// Returns entries ranked by relevance to `query`. `limit` caps the
    /// result set (default 20). Empty query returns the most recent entries
    /// in `filters` order, score 0.
    func search(
        query: String,
        in entries: [JournalEntry],
        filters: Filters = .none,
        limit: Int = 20
    ) -> [Hit] {
        let candidates = applyFilters(entries: entries, filters: filters)
        let queryTerms = Self.tokenize(query)

        if queryTerms.isEmpty {
            return candidates
                .sorted { $0.visitDate > $1.visitDate }
                .prefix(limit)
                .map { Hit(entryId: $0.entryId, score: 0) }
        }

        let docs = candidates.map { entry -> (entry: JournalEntry, tokens: [String]) in
            (entry, Self.tokenize(Self.searchableText(of: entry)))
        }
        let avgDocLength = docs.isEmpty ? 0 :
            Double(docs.map(\.tokens.count).reduce(0, +)) / Double(docs.count)
        let docCount = docs.count
        var docFreq: [String: Int] = [:]
        for doc in docs {
            let unique = Set(doc.tokens)
            for term in unique { docFreq[term, default: 0] += 1 }
        }

        let scored: [(JournalEntry, Double)] = docs.map { doc in
            let length = Double(doc.tokens.count)
            let counts = Self.termCounts(doc.tokens)
            var score = 0.0
            for qt in queryTerms {
                guard let tf = counts[qt] else { continue }
                let n = Double(docFreq[qt] ?? 0)
                let idf = log((Double(docCount) - n + 0.5) / (n + 0.5) + 1.0)
                let normalizedLength = avgDocLength == 0 ? 1.0 : (length / avgDocLength)
                let denom = Double(tf) + k1 * (1.0 - b + b * normalizedLength)
                score += idf * (Double(tf) * (k1 + 1.0)) / denom
            }
            return (doc.entry, score)
        }

        return scored
            .filter { $0.1 > 0 }
            .sorted { $0.1 > $1.1 }
            .prefix(limit)
            .map { Hit(entryId: $0.0.entryId, score: $0.1) }
    }

    /// Convenience: entries that mention a specific drug (canonical name),
    /// most recent first.
    func entries(
        mentioningDrug drugName: String,
        in entries: [JournalEntry]
    ) -> [JournalEntry] {
        let needle = drugName.localizedLowercase
        return entries
            .filter { entry in
                let drugs = entry.extractedFields.drugsMentioned?.value ?? []
                return drugs.contains { $0.name.localizedLowercase == needle }
            }
            .sorted { $0.visitDate > $1.visitDate }
    }

    /// Convenience: entries within a specific phase, most recent first.
    func entries(
        in phase: Phase,
        from entries: [JournalEntry]
    ) -> [JournalEntry] {
        entries
            .filter { $0.phase == phase }
            .sorted { $0.visitDate > $1.visitDate }
    }

    // MARK: - Filtering

    private func applyFilters(
        entries: [JournalEntry],
        filters: Filters
    ) -> [JournalEntry] {
        entries.filter { entry in
            if let phase = filters.phase, entry.phase != phase { return false }
            if let from = filters.fromDate, entry.visitDate < from { return false }
            if let to = filters.toDate, entry.visitDate > to { return false }
            if !filters.drugs.isEmpty {
                let names = Set((entry.extractedFields.drugsMentioned?.value ?? [])
                    .map { $0.name.localizedLowercase })
                if names.isDisjoint(with: filters.drugs.map { $0.localizedLowercase }) {
                    return false
                }
            }
            return true
        }
    }

    // MARK: - Searchable text extraction

    /// Concatenate every text field we want to consider for retrieval.
    static func searchableText(of entry: JournalEntry) -> String {
        var parts: [String] = []
        if let raw = entry.rawText { parts.append(raw) }
        if let transcript = entry.rawVoiceTranscript { parts.append(transcript) }
        let f = entry.extractedFields
        if let summary = f.summary?.value { parts.append(summary) }
        if let doctor = f.doctorName?.value { parts.append(doctor) }
        if let drugs = f.drugsMentioned?.value {
            for d in drugs {
                parts.append(d.name)
                parts.append(d.germanLabel)
                if let dose = d.doseDescription { parts.append(dose) }
            }
        }
        if let labs = f.labValues?.value {
            for lab in labs {
                parts.append(lab.parameter)
                parts.append(lab.germanLabel)
            }
        }
        if let procs = f.proceduresMentioned?.value { parts.append(contentsOf: procs) }
        if let decisions = f.decisions?.value { parts.append(contentsOf: decisions) }
        if let obs = f.parentObservations?.value { parts.append(contentsOf: obs) }
        if let qs = f.openQuestions?.value { parts.append(contentsOf: qs) }
        if let rxs = f.reactions?.value {
            for r in rxs {
                parts.append(r.description)
                if let cause = r.suspectedCause { parts.append(cause) }
            }
        }
        return parts.joined(separator: "\n")
    }

    // MARK: - Tokenization

    /// German-aware tokenizer: case-fold (handles umlauts), split on
    /// Unicode whitespace + punctuation, drop a small stoplist and tokens
    /// shorter than 2 characters.
    static func tokenize(_ text: String) -> [String] {
        let folded = text.localizedLowercase
        let scalars = folded.unicodeScalars
        var current = ""
        var tokens: [String] = []
        for scalar in scalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                current.unicodeScalars.append(scalar)
            } else {
                if current.count >= 2, !germanStoplist.contains(current) {
                    tokens.append(current)
                }
                current = ""
            }
        }
        if current.count >= 2, !germanStoplist.contains(current) {
            tokens.append(current)
        }
        return tokens
    }

    private static func termCounts(_ tokens: [String]) -> [String: Int] {
        var counts: [String: Int] = [:]
        for t in tokens { counts[t, default: 0] += 1 }
        return counts
    }

    /// Small German stoplist. Intentionally short — over-aggressive stop-word
    /// removal hurts BM25 quality more than it helps for medical text.
    private static let germanStoplist: Set<String> = [
        "der", "die", "das", "den", "dem", "des",
        "ein", "eine", "einen", "einem", "einer", "eines",
        "und", "oder", "aber", "auch", "noch",
        "ist", "war", "sind", "waren", "wird", "wurde",
        "haben", "hatte", "hat",
        "wir", "sie", "er", "es",
        "auf", "bei", "mit", "von", "zu", "zur", "zum",
        "im", "in", "an", "am",
        "fuer", "für", "als", "wie", "so", "dann",
        "nicht", "kein", "keine",
    ]
}
