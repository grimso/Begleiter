import CoreGraphics
import CoreImage
import Foundation
import HuggingFace
import ImageIO
import MLX
import MLXHuggingFace
import MLXLMCommon
import MLXVLM
import OSLog
import Tokenizers
import UniformTypeIdentifiers

private let visionLog = Logger(subsystem: "io.grimso.Begleiter", category: "gemma.vision")

/// Loads Gemma 4 (4-bit) via mlx-swift-lm's **MLXVLM** factory and runs
/// vision-conditioned prompts against it.
///
/// Sibling to ``GemmaService`` (which loads the same weights via the
/// MLXLLM / language-only factory). The two services share the
/// downloaded HuggingFace cache on disk but **must not both be resident
/// in memory at the same time** on iPhone — Gemma 4 E2B 4-bit is already
/// ~2 GB resident, and the VLM-loaded variant additionally holds the
/// vision tower (~200–300 MB). Coordination is done by ``ensureExclusive``
/// in this service and the mirrored call inside ``GemmaService.loadModel``.
///
/// **Default behaviour: opt-in.** Nothing in the app uses this service
/// unless `AppSettings.labPipelineMode` is set to `.directMultimodal`
/// in Settings → Befund-Verarbeitung. The OCR→Gemma path stays the
/// production default. This mirrors every other Gemma toggle in the
/// project: new behaviour ships off, the user flips it on for A/B
/// comparison.
///
/// **Why explicit factory call.** `MLXLMCommon.loadModelContainer(...)`
/// iterates every registered ``ModelFactory``. Both ``LLMModelFactory``
/// and ``VLMModelFactory`` register the `"gemma4"` model type — so the
/// polymorphic load is order-dependent. Calling
/// ``VLMModelFactory.shared.loadContainer`` directly removes that
/// ambiguity and guarantees the multimodal `Gemma4` class is
/// instantiated (the one whose `prepare(_:cache:windowSize:)` knows
/// about `input.image?.pixels`).
///
/// **Simulator.** Same constraint as ``GemmaService`` — MLX's Metal
/// allocator aborts on the simulator. `loadModel()` is guarded with
/// `#if !targetEnvironment(simulator)`.
actor GemmaVisionService {

    // MARK: - State

    enum LoadState: Sendable, Equatable {
        case idle
        case loading(progress: Double)
        case loaded
        case failed(message: String)
    }

    /// App-wide shared instance. Singleton for the same reason as
    /// ``GemmaService.shared`` — never two copies of the model in memory.
    static let shared = GemmaVisionService()

    private var configuration: ModelConfiguration
    private(set) var activeVariant: ModelVariant
    private let defaultGenerateParameters: GenerateParameters
    private var container: ModelContainer?
    private(set) var state: LoadState = .idle

    init(
        variant: ModelVariant? = nil,
        maxTokens: Int = 2500,
        temperature: Float = 0.3
    ) {
        let resolved = variant ?? AppSettings.modelVariant
        self.activeVariant = resolved
        self.configuration = Self.configuration(for: resolved)
        self.defaultGenerateParameters = GenerateParameters(
            maxTokens: maxTokens,
            temperature: temperature
        )
    }

    /// VLM-side configurations point at the same HF repo as the LLM-side
    /// ones (`mlx-community/gemma-4-e2b-it-4bit` etc.) so the on-disk
    /// cache is shared. The difference is purely runtime — the VLM
    /// factory instantiates the multimodal model class.
    private static func configuration(for variant: ModelVariant) -> ModelConfiguration {
        switch variant {
        case .e2b: return VLMRegistry.gemma4_E2B_it_4bit
        case .e4b: return VLMRegistry.gemma4_E4B_it_4bit
        }
    }

    // MARK: - Load

    /// Load (or download + load) the multimodal Gemma 4 weights via
    /// ``VLMModelFactory``. Idempotent; subsequent calls return the
    /// cached container.
    @discardableResult
    func loadModel() async throws -> ModelContainer {
        if let container { return container }

        // Mutex: the text-only sibling cannot stay resident while we
        // load the vision-tower-bearing copy. ~2 GB combined would push
        // iPhone 14 Pro into jetsam territory.
        await GemmaService.shared.unload()

        state = .loading(progress: 0)
        MemoryDiagnostics.snapshot(label: "vision.before-load")
        do {
            let loaded = try await VLMModelFactory.shared.loadContainer(
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
            MemoryDiagnostics.snapshot(label: "vision.after-load")
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

    /// Run a single-turn vision-conditioned prompt against the loaded
    /// model and return the full decoded string.
    ///
    /// - Parameters:
    ///   - prompt: the German extraction prompt. Should reference an
    ///     attached Befund image so the model knows to read it.
    ///   - imageURLs: file URLs to images (JPEG / PNG / HEIC) to attach
    ///     to the user turn. mlx-swift handles decoding and resizing
    ///     according to the model's processor config.
    ///   - parameters: per-call generation parameters. Defaults to this
    ///     service's `defaultGenerateParameters` (maxTokens 2500,
    ///     temperature 0.3 — same as text extraction).
    ///   - enableThinking: opt-in to Gemma 4's reasoning mode. Costs
    ///     several hundred extra output tokens. Off by default.
    /// - Returns: the model's full decoded answer (verbatim — caller
    ///   does any JSON parsing).
    func generate(
        prompt: String,
        imageURLs: [URL],
        parameters: GenerateParameters? = nil,
        enableThinking: Bool = false
    ) async throws -> String {
        let container = try await loadModel()
        let session = ChatSession(
            container,
            generateParameters: parameters ?? defaultGenerateParameters,
            additionalContext: enableThinking ? ["enable_thinking": true] : nil
        )
        // Downscale the source photos before they reach Gemma's vision
        // processor. iPhone camera output is routinely 4032 × 3024 (~12 MP)
        // — passing the full image through MLX's processor allocates a
        // ~50 MB CIImage + tens of MB of pixel-value tensors on top of
        // the already-resident 2.5 GB model, which trips the per-app
        // memory limit on iPhone 13 / 14 Pro. The long-edge cap defaults
        // to ``AppSettings.visionMaxLongEdge`` (1568 px — matches Gemma's
        // largest grid resolution); user-tunable in Settings.
        let images = Self.preprocess(
            imageURLs: imageURLs,
            maxLongEdge: AppSettings.visionMaxLongEdge
        )
        MemoryDiagnostics.snapshot(label: "vision.before-generate")
        defer {
            #if !targetEnvironment(simulator)
            MLX.Memory.clearCache()
            #endif
            MemoryDiagnostics.snapshot(label: "vision.after-generate")
        }
        return try await session.respond(to: prompt, images: images, videos: [])
    }

    /// Load each URL via ImageIO with a `kCGImageSourceThumbnailMaxPixelSize`
    /// hint so the decode itself produces a downsized image — avoiding
    /// the OOM that a full-resolution decode would trigger.
    ///
    /// Fall-back order:
    /// 1. ImageIO thumbnail decode (preferred — caps decoded resolution)
    /// 2. CIImage decode + transform (works for HEIC / oddball formats)
    /// 3. Passthrough `.url(_:)` if both fail (let mlx-swift try)
    static func preprocess(
        imageURLs: [URL],
        maxLongEdge: Int
    ) -> [UserInput.Image] {
        imageURLs.map { url in
            if let cg = thumbnailCGImage(at: url, maxPixelSize: maxLongEdge) {
                visionLog.debug(
                    "preprocess: thumbnail \(url.lastPathComponent, privacy: .public) → \(cg.width, privacy: .public)x\(cg.height, privacy: .public)"
                )
                return .ciImage(CIImage(cgImage: cg))
            }
            if let ci = CIImage(contentsOf: url) {
                let scale = scaleFactor(
                    width: ci.extent.width,
                    height: ci.extent.height,
                    maxLongEdge: CGFloat(maxLongEdge)
                )
                let scaled = scale < 1
                    ? ci.transformed(by: .init(scaleX: scale, y: scale))
                    : ci
                visionLog.debug(
                    "preprocess: ciImage \(url.lastPathComponent, privacy: .public) → \(scaled.extent.width, privacy: .public)x\(scaled.extent.height, privacy: .public)"
                )
                return .ciImage(scaled)
            }
            visionLog.warning(
                "preprocess: passthrough \(url.lastPathComponent, privacy: .public) — could not decode"
            )
            return .url(url)
        }
    }

    private static func thumbnailCGImage(
        at url: URL, maxPixelSize: Int
    ) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            return nil
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    private static func scaleFactor(
        width: CGFloat, height: CGFloat, maxLongEdge: CGFloat
    ) -> CGFloat {
        let longEdge = max(width, height)
        guard longEdge > maxLongEdge, longEdge > 0 else { return 1 }
        return maxLongEdge / longEdge
    }

    /// Drop the in-memory model. Mirrors ``GemmaService.unload``.
    /// Called automatically before ``GemmaService.loadModel`` runs so
    /// only one Gemma 4 instance is ever resident.
    func unload() {
        container = nil
        state = .idle
    }

    /// Switch variant at runtime. Mirrors ``GemmaService.reload`` so
    /// the Settings model picker affects both services consistently.
    /// E4B → E2B fallback semantics are intentionally NOT implemented
    /// here — ``GemmaService.reload`` already persists the demotion via
    /// ``AppSettings.persistModelVariant``, and we read that variant on
    /// the next load.
    func reload(variant: ModelVariant) async throws {
        container = nil
        state = .idle
        activeVariant = variant
        configuration = Self.configuration(for: variant)
        _ = try await loadModel()
    }
}
