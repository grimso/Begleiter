import Foundation
import HuggingFace
import MLX
import MLXHuggingFace
import MLXLLM
import MLXLMCommon
import Tokenizers

/// Loads Gemma 4 (4-bit) via mlx-swift-lm and runs prompts against it.
///
/// `GemmaService` is an `actor` so concurrent calls from UI/services serialize
/// against the underlying model container.
///
/// **Model selection.** Defaults to `LLMRegistry.gemma4_e2b_it_4bit` — the
/// Gemma 4 E2B variant (3.3 GB on disk, ~2 GB resident). E4B 4-bit is
/// 4.86 GB on disk and exceeds the default per-app memory limit on
/// iPhone 14 Pro (~3 GB). To use E4B instead:
///   1. Swap the default below to `LLMRegistry.gemma4_e4b_it_4bit`.
///   2. Enable the **Increased Memory Limit** capability on the Begleiter
///      target (Signing & Capabilities → + → "Increased Memory Limit"),
///      which sets `com.apple.developer.kernel.increased-memory-limit`.
///      The entitlements file `Begleiter/Begleiter.entitlements` is
///      already scaffolded.
/// Both E2B and E4B are Gemma 4 — both satisfy the hackathon's model
/// requirement.
///
/// **First-launch behavior.** `loadModel()` downloads the weights (~2.5 GB
/// for E4B 4-bit) into the Hugging Face Hub cache directory on the device.
/// Subsequent launches load from cache. The download path is provided by
/// the `#hubDownloader()` macro from MLXHuggingFace (wraps `HubClient`).
///
/// **Smoke test only.** This iteration has no function-calling, no system
/// prompt, no journal context. It exists to prove the model loads and
/// generates on the device. Function-calling, structured extraction, and
/// the tool surface arrive in iteration 3.
actor GemmaService {

    // MARK: - State

    enum LoadState: Sendable, Equatable {
        case idle
        case loading(progress: Double)
        case loaded
        case failed(message: String)
    }

    private let configuration: ModelConfiguration
    private let generateParameters: GenerateParameters
    private var container: ModelContainer?
    private(set) var state: LoadState = .idle

    /// One-shot MLX configuration applied just before the first model load.
    ///
    /// Lowering `Memory.cacheLimit` is the single most impactful lever for
    /// the iOS-jetsam case per the framework's own docs. **The setter itself
    /// initialises MLX's Metal allocator**, which aborts on the iOS Simulator
    /// (no Metal device available in the simulator's Metal shim — same
    /// reason inference can't run on simulator). Therefore:
    ///
    /// 1. We do not touch `MLX.Memory.cacheLimit` from `init` (which would
    ///    fire during unit tests on the simulator host, crashing the test
    ///    runner before bootstrap).
    /// 2. We only apply the cap from `loadModel()`, where we are about to
    ///    talk to MLX anyway. On simulator, `loadModel()` never runs in
    ///    tests, so the setter is never reached.
    /// 3. Within `loadModel()` we further guard with
    ///    `#if !targetEnvironment(simulator)`. Belt and braces — if someone
    ///    in the future taps "Modell laden" inside the simulator UI, this
    ///    line stays skipped and MLX's own subsequent crash on inference
    ///    surfaces a clearer failure than ours.
    private nonisolated(unsafe) static var _cacheLimitConfigured = false
    private static func applyCacheLimitIfNeeded() {
        guard !_cacheLimitConfigured else { return }
        _cacheLimitConfigured = true
        #if !targetEnvironment(simulator)
        // 50 MB cap on the recyclable buffer pool. Default scales with
        // recommendedMaxWorkingSetSize and can grow to multiple GB on long
        // inference runs — that's exactly the headroom we're losing on
        // iPhone 14 Pro running Gemma 4 E2B (~3.3 GB resident + uncapped
        // scratch ≈ jetsam).
        MLX.Memory.cacheLimit = 50 * 1024 * 1024
        #endif
    }

    init(
        configuration: ModelConfiguration = LLMRegistry.gemma4_e2b_it_4bit,
        maxTokens: Int = 256,
        temperature: Float = 0.6
    ) {
        self.configuration = configuration
        self.generateParameters = GenerateParameters(
            maxTokens: maxTokens,
            temperature: temperature
        )
    }

    // MARK: - Load

    /// Load (or download + load) the model weights. Safe to call repeatedly;
    /// the second call returns the cached container. Progress is reflected
    /// into `state`; callers poll `state` while awaiting `loadModel()`.
    @discardableResult
    func loadModel() async throws -> ModelContainer {
        if let container { return container }

        Self.applyCacheLimitIfNeeded()
        state = .loading(progress: 0)
        MemoryDiagnostics.snapshot(label: "before-load")
        do {
            let loaded = try await loadModelContainer(
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
            MemoryDiagnostics.snapshot(label: "after-load")
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

    // MARK: - Generate

    /// Run a single-turn prompt against the loaded model and return the full
    /// decoded string. ChatSession applies Gemma 4's chat template internally.
    ///
    /// Memory-hygiene wrapper: snapshots before + after the generation and
    /// drops MLX's freed-buffer cache after it returns (or throws), which
    /// otherwise accumulates several GB across repeated calls.
    func generate(prompt: String) async throws -> String {
        let container = try await loadModel()
        let session = ChatSession(
            container,
            generateParameters: generateParameters
        )
        MemoryDiagnostics.snapshot(label: "before-generate")
        defer {
            MLX.Memory.clearCache()
            MemoryDiagnostics.snapshot(label: "after-generate")
        }
        return try await session.respond(to: prompt)
    }

    /// Drop the in-memory model so its ~3.3 GB of weights can be paged out.
    /// The next call to `loadModel()` reads from the local HF cache
    /// (no network), typically completing in a few seconds.
    ///
    /// Call this when the parent navigates away from a screen that uses
    /// Gemma so we don't keep ~3 GB resident while browsing the timeline.
    func unload() {
        container = nil
        state = .idle
    }
}
