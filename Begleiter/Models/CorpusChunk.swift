import Foundation

/// A paragraph-sized unit of reference text retrievable by `CorpusService`.
///
/// The corpus is shipped as a single bundled `corpus.json` produced by
/// `research/corpus/build_corpus.py` from hand-curated JSON glossaries
/// (drugs, lab parameters) plus hand-authored German summaries citing
/// external sources (kinderkrebsinfo.de, kinderkrebshilfe.de).
///
/// We do NOT ship verbatim third-party text. Every chunk's `text` is the
/// team's own German prose; `referenceURL` points to the authoritative
/// upstream page so the UI links out rather than reproducing.
nonisolated struct CorpusChunk: Codable, Hashable, Sendable, Identifiable {
    /// Stable identifier, e.g. `"glossary_labs/anc"` or `"kki/induction-ia-overview"`.
    /// Used verbatim as a citation token in `AskService` prompts (`[K:<id>]`),
    /// so it must be URL-safe and short enough for Gemma to reproduce reliably.
    let id: String

    /// Which authoring stream the chunk came from. Drives the citation
    /// chip's accent colour and the source attribution in `CorpusChunkSheet`.
    let source: CorpusSource

    /// Topic / facet tags used by `CorpusService` to scope retrieval
    /// (`["lab", "anc"]` for the lab-focused chat). Open-vocabulary on
    /// purpose so the corpus can evolve tag conventions without a Swift
    /// recompile.
    let topicTags: [String]

    /// Human-readable heading shown in `CorpusChunkSheet`.
    let title: String

    /// The German body of the chunk. Target 80–200 words.
    let text: String

    /// Canonical upstream URL for the parent to verify the summary.
    /// `nil` only for fully self-authored glossary entries (drugs / labs).
    let referenceURL: String?

    /// ISO `yyyy-MM-dd` last-update date. Surfaced in `CorpusChunkSheet`
    /// so the parent can tell the summary isn't months out of date.
    let updatedAt: String

    /// Optional dense embedding for the dense-rerank path
    /// (`AskService` + `RerankerEngine`). Today this stays `nil` in the
    /// bundled `corpus.json` and gets filled at runtime by
    /// `CorpusService.backfillVectors(using:)`. Auto-Codable treats the
    /// missing key as `nil`, so older `corpus.json` files keep decoding.
    let vector: [Float]?

    /// Memberwise initialiser with `vector` defaulting to `nil` so call
    /// sites that predate the dense-rerank feature (especially the test
    /// fixtures and any future code building chunks programmatically)
    /// don't have to spell `vector: nil` at every construction site.
    init(
        id: String,
        source: CorpusSource,
        topicTags: [String],
        title: String,
        text: String,
        referenceURL: String?,
        updatedAt: String,
        vector: [Float]? = nil
    ) {
        self.id = id
        self.source = source
        self.topicTags = topicTags
        self.title = title
        self.text = text
        self.referenceURL = referenceURL
        self.updatedAt = updatedAt
        self.vector = vector
    }
}

/// Authoring stream of a `CorpusChunk`. The raw values are stable identifiers
/// in `corpus.json` and in `[K:<id>]` citation prefixes — do not rename.
nonisolated enum CorpusSource: String, Codable, Hashable, Sendable {
    /// Hand-authored summaries of parent-relevant pages on kinderkrebsinfo.de
    /// (the GPOH portal). The summary text is our own; the URL is the credit.
    case kinderkrebsinfo

    /// Hand-authored summaries of parent-relevant content from the Deutsche
    /// Kinderkrebshilfe foundation (family-support focus).
    case kinderkrebshilfe

    /// Self-authored drug glossary, one chunk per INN. Synonyms, plain-German
    /// summary, common side-effects, monitoring notes.
    case glossaryDrugs = "glossary_drugs"

    /// Self-authored lab parameter glossary, one chunk per parameter
    /// (WBC, ANC, Hb, …). Abbreviations, parent-facing explanation,
    /// reference range guidance.
    case glossaryLabs = "glossary_labs"
}
