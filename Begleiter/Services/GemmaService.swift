import Foundation
import MLXLLM
import MLXLMCommon

/// Loads Gemma 4 (E4B, 4-bit) via MLX-Swift and runs prompts against it.
///
/// `GemmaService` is an `actor` so that concurrent calls from UI/services
/// serialize against the underlying model container, which is not safe to
/// invoke from multiple threads simultaneously.
///
/// **First-launch behavior.** `loadModel()` downloads the weights from
/// Hugging Face (~2 GB on disk after 4-bit quantization) into the OS-managed
/// cache directory the MLX-Swift Hub client uses. Subsequent launches load
/// from cache. The demo must therefore be performed on a device that has
/// completed at least one cold load while online.
///
/// **Model selection.** `Configuration.modelId` is the only place to change
/// which Gemma variant is loaded. Iteration 2 pins a Hugging Face repo path
/// rather than relying on `LLMRegistry` so we can swap models without a
/// library upgrade.
///
/// **Smoke test only.** This iteration has no function-calling, no system
/// prompt, no context management. It exists to prove the model loads and
/// generates on the device. Function-calling, structured extraction, and
/// the tool-surface arrive in iteration 3.
actor GemmaService {

    // MARK: - Configuration

    struct Configuration: Sendable {
        /// Hugging Face repository path for the quantized Gemma 4 weights.
        ///
        /// TODO(iteration-2): confirm the exact `mlx-community` repo for
        /// Gemma 4 E4B once the model is published. The placeholder below
        /// uses the closest currently-published Gemma family weights to
        /// allow the smoke test to pass before Gemma 4 weights ship to MLX
        /// community mirrors. Swap to the Gemma 4 E4B path when available.
        let modelId: String

        /// Sampling and length controls for the smoke-test prompt.
        let maxTokens: Int
        let temperature: Float

        static let `default` = Configuration(
            modelId: "mlx-community/gemma-3-4b-it-4bit",
            maxTokens: 256,
            temperature: 0.6
        )
    }

    // MARK: - State

    enum LoadState: Sendable, Equatable {
        case idle
        case loading(progress: Double)
        case loaded
        case failed(message: String)
    }

    private let configuration: Configuration
    private var container: ModelContainer?
    private(set) var state: LoadState = .idle

    /// Callback fired on the actor whenever `state` changes. UI views set
    /// this to mirror state into an `@Observable` view model.
    var onStateChange: (@Sendable (LoadState) -> Void)?

    init(configuration: Configuration = .default) {
        self.configuration = configuration
    }

    func setOnStateChange(_ handler: @escaping @Sendable (LoadState) -> Void) {
        self.onStateChange = handler
        handler(state)
    }

    // MARK: - Load

    /// Load (or download + load) the model weights. Safe to call repeatedly;
    /// the second call returns the cached container.
    @discardableResult
    func loadModel() async throws -> ModelContainer {
        if let container { return container }

        update(state: .loading(progress: 0))
        let modelConfiguration = ModelConfiguration(id: configuration.modelId)

        do {
            let loaded = try await LLMModelFactory.shared.loadContainer(
                configuration: modelConfiguration
            ) { progress in
                Task { [weak self] in
                    await self?.update(state: .loading(progress: progress.fractionCompleted))
                }
            }
            self.container = loaded
            update(state: .loaded)
            return loaded
        } catch {
            update(state: .failed(message: error.localizedDescription))
            throw error
        }
    }

    // MARK: - Generate

    /// Run a single-turn prompt against the loaded model and return the full
    /// decoded string. Streams are not exposed in iteration 2 — UI shows the
    /// final response only.
    func generate(prompt: String) async throws -> String {
        let container = try await loadModel()

        return try await container.perform { [configuration] context in
            let input = try await context.processor.prepare(
                input: .init(messages: [
                    ["role": "user", "content": prompt]
                ])
            )

            let parameters = GenerateParameters(
                maxTokens: configuration.maxTokens,
                temperature: configuration.temperature
            )

            var accumulated = ""
            _ = try MLXLMCommon.generate(
                input: input,
                parameters: parameters,
                context: context
            ) { tokens in
                let decoded = context.tokenizer.decode(tokens: tokens)
                accumulated = decoded
                return .more
            }
            return accumulated
        }
    }

    // MARK: - Internal

    private func update(state newState: LoadState) {
        state = newState
        onStateChange?(newState)
    }
}
