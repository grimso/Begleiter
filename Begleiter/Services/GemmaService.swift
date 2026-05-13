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

    /// App-wide shared instance. **All callers** (ExtractionService,
    /// BriefingService, HandoffService) point at this so iPhone 14 Pro
    /// never holds two copies of the 3.3 GB model in memory at once. Each
    /// caller passes its own `GenerateParameters` into `generate(...)`
    /// rather than baking parameters into the service.
    static let shared = GemmaService()

    /// Mutable so `reload(variant:)` can swap E2B ↔ E4B at runtime. Reads
    /// the persisted `AppSettings.modelVariant` on first load.
    private var configuration: ModelConfiguration
    private(set) var activeVariant: ModelVariant
    private let defaultGenerateParameters: GenerateParameters
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
        variant: ModelVariant? = nil,
        maxTokens: Int = 256,
        temperature: Float = 0.6
    ) {
        let resolved = variant ?? AppSettings.modelVariant
        self.activeVariant = resolved
        self.configuration = Self.configuration(for: resolved)
        self.defaultGenerateParameters = GenerateParameters(
            maxTokens: maxTokens,
            temperature: temperature
        )
    }

    /// Map a `ModelVariant` to the matching `LLMRegistry` entry from
    /// mlx-swift-lm. Centralised so `init` and `reload(variant:)` agree
    /// on which symbol corresponds to which variant.
    private static func configuration(for variant: ModelVariant) -> ModelConfiguration {
        switch variant {
        case .e2b: return LLMRegistry.gemma4_e2b_it_4bit
        case .e4b: return LLMRegistry.gemma4_e4b_it_4bit
        }
    }

    // MARK: - Load

    /// Load (or download + load) the model weights. Safe to call repeatedly;
    /// the second call returns the cached container. Progress is reflected
    /// into `state`; callers poll `state` while awaiting `loadModel()`.
    @discardableResult
    func loadModel() async throws -> ModelContainer {
        if let container { return container }

        // Mutex with the multimodal sibling service. The VLM-loaded
        // Gemma 4 carries the vision tower (~200–300 MB extra resident)
        // and we cannot afford both copies in memory on iPhone 14 Pro.
        // Symmetric call lives in ``GemmaVisionService.loadModel``.
        await GemmaVisionService.shared.unload()

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
    /// `parameters` overrides the service-wide default. Extraction wants
    /// long deterministic output (maxTokens 640, temp 0.3); briefing /
    /// handoff want moderate creative output (default 0.6). Each caller
    /// passes its own.
    ///
    /// `enableThinking` opts into Gemma 4's reasoning mode. When `true`,
    /// the chat template inserts a `<|think|>` token at the start of the
    /// system turn and Gemma emits a `<|channel>thought` reasoning section
    /// before the final answer. Costs several hundred extra output tokens
    /// per call — callers should pair this with a larger `maxTokens`
    /// budget (≥1024). Off by default to preserve the existing token
    /// budget for callers that don't need it.
    ///
    /// Memory-hygiene wrapper: snapshots before + after the generation and
    /// drops MLX's freed-buffer cache after it returns (or throws), which
    /// otherwise accumulates several GB across repeated calls.
    func generate(
        prompt: String,
        parameters: GenerateParameters? = nil,
        enableThinking: Bool = false
    ) async throws -> String {
        try await generate(
            prompt: prompt,
            parameters: parameters,
            enableThinking: enableThinking,
            instructions: nil,
            tools: nil,
            toolDispatch: nil
        )
    }

    /// Full generation overload: adds optional `instructions` (system
    /// message), `tools` schemas, and `toolDispatch` so callers that need
    /// the function-calling agent loop can opt in without disturbing the
    /// simple text-in / text-out callers above. ``ChatSession`` runs the
    /// multi-turn agent loop itself — it collects ``ToolCall`` items from
    /// the model's generation stream, invokes `toolDispatch`, feeds the
    /// returned string back as a `tool` message, and restarts generation
    /// until the model emits a tool-call-free turn. The string we return
    /// here is that final turn's content.
    ///
    /// Used by ``AskService.answerAgent`` behind the
    /// `AppSettings.askAgentEnabled` toggle (default OFF). Existing
    /// callers go through the parameterless-tools form above and see no
    /// behaviour change.
    func generate(
        prompt: String,
        parameters: GenerateParameters? = nil,
        enableThinking: Bool = false,
        instructions: String? = nil,
        tools: [ToolSpec]? = nil,
        toolDispatch: (@Sendable (ToolCall) async throws -> String)? = nil
    ) async throws -> String {
        let container = try await loadModel()
        let session = ChatSession(
            container,
            instructions: instructions,
            generateParameters: parameters ?? defaultGenerateParameters,
            additionalContext: enableThinking ? ["enable_thinking": true] : nil,
            tools: tools,
            toolDispatch: toolDispatch
        )
        MemoryDiagnostics.snapshot(label: "before-generate")
        defer {
            #if !targetEnvironment(simulator)
            MLX.Memory.clearCache()
            #endif
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

    /// Switch to a different Gemma variant at runtime. Called by the
    /// Settings screen after the user changes the model picker.
    ///
    /// Strategy:
    /// 1. Drop the current container so its weights can be freed before
    ///    the new ones load (otherwise we briefly hold both in memory
    ///    and trip jetsam on smaller devices).
    /// 2. Swap `configuration` to the new variant and load.
    /// 3. If the requested variant is E4B and the load fails — almost
    ///    always a memory-pressure kill on devices without the
    ///    Increased Memory Limit entitlement headroom — demote to E2B,
    ///    persist that demotion so the Settings UI reflects the
    ///    effective state, and retry. Surface a soft error to the
    ///    caller so they can show a toast.
    func reload(variant: ModelVariant) async throws {
        container = nil
        state = .idle
        activeVariant = variant
        configuration = Self.configuration(for: variant)
        do {
            _ = try await loadModel()
        } catch {
            guard variant == .e4b else { throw error }
            // E4B is the only variant we fall back from. E2B is the
            // baseline; if that fails, something is fundamentally
            // wrong (corrupt cache, no disk space) and we let it raise.
            container = nil
            state = .idle
            activeVariant = .e2b
            configuration = Self.configuration(for: .e2b)
            AppSettings.persistModelVariant(.e2b)
            _ = try await loadModel()
            throw GemmaReloadError.fellBackToE2B(originalError: error)
        }
    }
}

/// Soft error reported by `reload(variant:)` when the requested variant
/// could not be loaded but the service successfully fell back to E2B.
/// Surfaced so the Settings UI can show a one-time alert explaining the
/// demotion; the app is otherwise fully functional.
enum GemmaReloadError: LocalizedError {
    case fellBackToE2B(originalError: Error)

    var errorDescription: String? {
        switch self {
        case .fellBackToE2B(let originalError):
            return "E4B konnte nicht geladen werden, daher wurde auf E2B zurückgeschaltet. Grund: \(originalError.localizedDescription)"
        }
    }
}
