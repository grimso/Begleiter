import Foundation
import HuggingFace
import MLX
import MLXEmbedders
import MLXHuggingFace
import MLXLMCommon
import OSLog
import Tokenizers

private let embedLog = Logger(subsystem: "io.grimso.Begleiter", category: "mlx.embedder")

/// Loads `intfloat/multilingual-e5-small` via MLXEmbedders and produces
/// L2-normalised float vectors for German + English text. Used by the
/// dense-rerank path in `AskService` when `AppSettings.askDenseRerankerEnabled`
/// is true. Off by default — the embedder is never loaded unless the
/// parent flips the Settings toggle.
///
/// Lifecycle mirrors `GemmaService`:
/// - Singleton via `static let shared`.
/// - `loadModel()` is idempotent; first call downloads the ~130 MB model
///   from Hugging Face into the device's local HF cache. Subsequent
///   launches read from that cache.
/// - `unload()` drops the container so the ~130 MB resident set is
///   freed — required before `GemmaService.loadModel()` runs, otherwise
///   both models sit in memory and trip jetsam on iPhone 14 Pro (per
///   `feedback_gemma4_e4b_too_big.md`).
///
/// **Sequential coexistence contract**: callers (currently only
/// `AskService.answer`) must `await embedding.unload()` before
/// `gemma.generate(...)`. Documented at each call site too.
actor EmbeddingService {

    // MARK: - Types

    /// E5-family models expect a "query: " or "passage: " prefix on the
    /// input text — without it, retrieval quality drops noticeably.
    /// `embed(_:kind:)` adds the prefix internally so callers stay
    /// scope-agnostic.
    enum TextKind: String, Sendable {
        case query
        case passage

        fileprivate var prefix: String {
            switch self {
            case .query:   return "query: "
            case .passage: return "passage: "
            }
        }
    }

    enum LoadState: Sendable, Equatable {
        case idle
        case loading(progress: Double)
        case loaded
        case failed(message: String)
    }

    // MARK: - State

    /// App-wide shared instance. AskService points at this.
    static let shared = EmbeddingService()

    private let configuration: ModelConfiguration
    private var container: EmbedderModelContainer?
    private(set) var state: LoadState = .idle

    /// One-shot MLX configuration applied just before the first model
    /// load. Mirrors the same pattern in `GemmaService.swift:81–93` —
    /// the `MLX.Memory.cacheLimit` setter fires the Metal allocator,
    /// which aborts on the iOS Simulator. We guard with a sentinel and
    /// `#if !targetEnvironment(simulator)`.
    private nonisolated(unsafe) static var _cacheLimitConfigured = false
    private static func applyCacheLimitIfNeeded() {
        guard !_cacheLimitConfigured else { return }
        _cacheLimitConfigured = true
        #if !targetEnvironment(simulator)
        // 32 MB cap on the recyclable buffer pool. multilingual-e5-small
        // is ~130 MB resident; the cache grows on long batches if
        // uncapped. 32 MB is half of what Gemma uses — embedder runs
        // are short.
        MLX.Memory.cacheLimit = 32 * 1024 * 1024
        #endif
    }

    init() {
        self.configuration = EmbedderRegistry.multilingual_e5_small
    }

    // MARK: - Load / unload

    /// Download (if needed) and load the embedder model. Safe to call
    /// repeatedly; returns the cached container on the fast path.
    @discardableResult
    func loadModel() async throws -> EmbedderModelContainer {
        if let container { return container }

        Self.applyCacheLimitIfNeeded()
        state = .loading(progress: 0)
        MemoryDiagnostics.snapshot(label: "embed-before-load")
        do {
            let loaded = try await EmbedderModelFactory.shared.loadContainer(
                from: #hubDownloader(),
                using: #huggingFaceTokenizerLoader(),
                configuration: configuration
            ) { progress in
                let fraction = progress.fractionCompleted
                Task { [weak self] in
                    await self?.setLoadingProgress(fraction)
                }
            }
            self.container = loaded
            state = .loaded
            MemoryDiagnostics.snapshot(label: "embed-after-load")
            return loaded
        } catch {
            state = .failed(message: error.localizedDescription)
            throw error
        }
    }

    private func setLoadingProgress(_ fraction: Double) {
        if case .loading = state {
            state = .loading(progress: fraction)
        }
    }

    /// Drop the in-memory embedder. Must be called before
    /// `GemmaService.loadModel()` to avoid holding both models resident.
    func unload() {
        container = nil
        state = .idle
        #if !targetEnvironment(simulator)
        MLX.Memory.clearCache()
        #endif
        MemoryDiagnostics.snapshot(label: "embed-after-unload")
    }

    // MARK: - Embed

    /// Embed a single string. Convenience wrapper around the batch path.
    func embed(_ text: String, kind: TextKind) async throws -> [Float] {
        let batch = try await embed([text], kind: kind)
        guard let first = batch.first else {
            throw EmbeddingError.emptyResult
        }
        return first
    }

    /// Embed a batch of strings. Returns L2-normalised float vectors;
    /// cosine similarity collapses to a dot product downstream.
    /// Processes in chunks of `batchSize` to keep peak memory bounded
    /// while indexing a journal of 30+ entries.
    func embed(_ texts: [String], kind: TextKind) async throws -> [[Float]] {
        guard !texts.isEmpty else { return [] }
        let container = try await loadModel()

        MemoryDiagnostics.snapshot(label: "embed-before-batch")
        defer {
            #if !targetEnvironment(simulator)
            MLX.Memory.clearCache()
            #endif
            MemoryDiagnostics.snapshot(label: "embed-after-batch")
        }

        let prefixed = texts.map { kind.prefix + $0 }
        var out: [[Float]] = []
        out.reserveCapacity(prefixed.count)

        for chunk in prefixed.chunked(into: Self.batchSize) {
            let vectors = try await embedBatch(chunk, container: container)
            out.append(contentsOf: vectors)
        }
        return out
    }

    /// Internal: one model forward pass over a small batch.
    /// Token-pad to the longest input in the batch (canonical
    /// MLXEmbedders pattern, see `Libraries/MLXEmbedders/README.md`).
    private func embedBatch(
        _ texts: [String],
        container: EmbedderModelContainer
    ) async throws -> [[Float]] {
        try await container.perform { context in
            let tokenizer = context.tokenizer
            let model = context.model
            let pooling = context.pooling

            let inputs = texts.map { text in
                tokenizer.encode(text: text, addSpecialTokens: true)
            }
            // Pad to the longest input in this batch. Floor at 16 so
            // very short inputs still hit the kernel's preferred size.
            let maxLength = inputs.reduce(into: 16) { acc, elem in
                acc = max(acc, elem.count)
            }
            let padId = tokenizer.eosTokenId ?? 0
            let padded = stacked(
                inputs.map { elem in
                    MLXArray(
                        elem
                            + Array(repeating: padId, count: maxLength - elem.count)
                    )
                })
            let mask = (padded .!= padId)
            let tokenTypes = MLXArray.zeros(like: padded)
            let result = pooling(
                model(padded, positionIds: nil, tokenTypeIds: tokenTypes, attentionMask: mask),
                normalize: true,
                applyLayerNorm: true
            )
            result.eval()
            return result.map { $0.asArray(Float.self) }
        }
    }

    // MARK: - Constants

    /// Batch size for the model forward pass. 8 is the sweet spot on
    /// iPhone 14 Pro — larger batches don't speed up much and grow the
    /// transient KV pool above the 32 MB cap.
    private static let batchSize: Int = 8

    /// Model identifier — exposed so the Diagnose sheet / cache layer
    /// can log it and the future "switch model" surface can read it.
    nonisolated static var modelId: String {
        // EmbedderRegistry.multilingual_e5_small wraps this id.
        "intfloat/multilingual-e5-small"
    }
}

/// Errors surfaced by `EmbeddingService`.
enum EmbeddingError: Error, LocalizedError {
    case emptyResult

    var errorDescription: String? {
        switch self {
        case .emptyResult:
            return "Der Embedder hat keinen Vektor geliefert."
        }
    }
}

// MARK: - Array chunking helper

private extension Array {
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0 else { return [self] }
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}
