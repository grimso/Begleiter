import Foundation
import HuggingFace
import MLXHuggingFace
import MLXLLM
import MLXLMCommon
import Tokenizers

/// Loads Gemma 4 E4B (4-bit) via mlx-swift-lm and runs prompts against it.
///
/// `GemmaService` is an `actor` so concurrent calls from UI/services serialize
/// against the underlying model container.
///
/// **Model selection.** Uses `LLMRegistry.gemma4_e4b_it_4bit` — the canonical
/// registry entry for `mlx-community/gemma-4-e4b-it-4bit` with the correct
/// `<turn|>` EOS token configuration. Swap to a sibling entry within the
/// gemma-4-e4b family (e.g. `gemma4_e2b_it_4bit` for a smaller variant) only
/// if iteration 2 reveals iPhone 14 Pro can't comfortably hold E4B.
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

    init(
        configuration: ModelConfiguration = LLMRegistry.gemma4_e4b_it_4bit,
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

        state = .loading(progress: 0)
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
    func generate(prompt: String) async throws -> String {
        let container = try await loadModel()
        let session = ChatSession(
            container,
            generateParameters: generateParameters
        )
        return try await session.respond(to: prompt)
    }

}
