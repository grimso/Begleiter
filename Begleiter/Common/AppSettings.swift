import Foundation
import SwiftUI

/// Which Gemma 4 variant the app loads at startup.
///
/// E2B is the safe default — 3.3 GB on disk, ~2 GB resident, fits inside the
/// default per-app memory limit on iPhone 14/15. E4B needs the Increased
/// Memory Limit entitlement (already scaffolded in `Begleiter.entitlements`)
/// and is only stable on iPhone 15 Pro+ in practice. If E4B fails to load
/// on a device that can't host it, `GemmaService.reload(variant:)` falls
/// back to `.e2b` and persists the demotion here, so the UI reflects the
/// effective state.
enum ModelVariant: String, CaseIterable, Identifiable, Sendable {
    case e2b
    case e4b

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .e2b: return "Gemma 4 E2B (3,3 GB)"
        case .e4b: return "Gemma 4 E4B (4,86 GB)"
        }
    }

    /// HuggingFace model ID surfaced in the Diagnostics section.
    var modelId: String {
        switch self {
        case .e2b: return "mlx-community/gemma-4-e2b-it-4bit"
        case .e4b: return "mlx-community/gemma-4-e4b-it-4bit"
        }
    }
}

/// How the app turns a lab-report attachment into structured fields.
///
/// `.ocrThenGemma` (default) — Apple Vision OCR builds a text block,
/// then `ExtractionService` feeds it to text-only Gemma 4 via
/// ``GemmaService``. The proven path; ~150 MB lighter resident.
///
/// `.directMultimodal` — `ExtractionService` skips OCR for image
/// attachments and feeds the photo directly to Gemma 4 via
/// ``GemmaVisionService`` (MLXVLM). Better on handwritten margin notes
/// and multi-column lab tables; costs the vision tower (~200–300 MB)
/// resident on top of the LM body and triggers an unload/reload of the
/// text-only sibling on first activation. Branch lives in
/// `ExtractionService.extractWithVision`.
///
/// Per project convention every new AI behaviour ships behind a toggle;
/// this enum IS the toggle. Default stays `.ocrThenGemma` so an update
/// changes nothing until the user opts in via Settings →
/// Befund-Verarbeitung.
enum LabPipelineMode: String, CaseIterable, Identifiable, Sendable {
    case ocrThenGemma
    case directMultimodal

    var id: String { rawValue }
}

/// How `AskService.answer(...)` runs end-to-end.
///
/// `.chat` (default) — single-shot retrieve-then-prompt pipeline.
/// `RetrievalService` + `CorpusService` pull top-K candidates before the
/// model runs; the model just synthesises an answer from the prefab
/// context. Production-quality, deterministic latency, no tool loop.
///
/// `.mlxToolCall` — `ChatSession(tools:toolDispatch:)` path. Gemma 4
/// decides which tools to call. Currently **broken end-to-end** because
/// mlx-swift-lm 3.31.3 doesn't recognise Gemma 4's tool-call format
/// (see `docs/upstream-issue-gemma4-toolcall.md`). Kept for evidence
/// of intent and to start working automatically once upstream lands a
/// fix.
///
/// `.customAgent` — own parser + multi-turn loop. We rebuild the
/// prompt each turn with the running tool transcript and parse
/// Gemma 4's native function-call syntax ourselves
/// (`GemmaToolCallExtractor`). Slower than `.chat` (multiple Gemma
/// calls) but actually executes the function-calling story today.
///
/// Default stays `.chat` so existing users see no behaviour change.
enum AskMode: String, CaseIterable, Identifiable, Sendable {
    case chat
    case mlxToolCall
    case customAgent

    var id: String { rawValue }
}

/// Static facade around `@AppStorage` keys so any view or actor can read
/// settings without dependency injection. Defaults match the values that
/// were hardcoded at call sites before this screen existed, so an upgrade
/// changes no behaviour until the user actually opens Settings.
///
/// All members are `nonisolated`: `GemmaService` is an `actor` and the
/// extraction / briefing / handoff services are too. `UserDefaults` itself
/// is thread-safe, so there's nothing for an actor to protect here and
/// the isolation would only force `await` at every call site.
enum AppSettings {
    nonisolated static let modelVariantKey         = "gemmaModelVariant"
    nonisolated static let extractionMaxTokensKey  = "extractionMaxTokens"
    nonisolated static let briefingMaxTokensKey    = "briefingMaxTokens"
    nonisolated static let handoffMaxTokensKey     = "handoffMaxTokens"
    nonisolated static let askMaxTokensKey         = "askMaxTokens"
    nonisolated static let askDiagnosticsEnabledKey = "askDiagnosticsEnabled"
    nonisolated static let askThinkingEnabledKey   = "askThinkingEnabled"
    nonisolated static let askDenseRerankerEnabledKey = "askDenseRerankerEnabled"
    nonisolated static let askEventGuardEnabledKey = "askEventGuardEnabled"
    nonisolated static let askAgentEnabledKey      = "askAgentEnabled"
    nonisolated static let askModeKey              = "askMode"
    nonisolated static let labPipelineModeKey      = "labPipelineMode"
    nonisolated static let visionMaxLongEdgeKey    = "visionMaxLongEdge"

    nonisolated static let defaultExtractionMaxTokens = 2500
    nonisolated static let defaultBriefingMaxTokens   = 640
    nonisolated static let defaultHandoffMaxTokens    = 512
    nonisolated static let defaultAskMaxTokens        = 512
    nonisolated static let defaultAskDiagnosticsEnabled = false
    nonisolated static let defaultAskThinkingEnabled    = false
    nonisolated static let defaultAskDenseRerankerEnabled = false
    nonisolated static let defaultAskEventGuardEnabled    = true
    nonisolated static let defaultAskAgentEnabled         = false
    /// Long-edge pixel cap applied to Befund images before they reach
    /// Gemma 4 vision. 1568 px matches the largest grid resolution
    /// Gemma's vision processor maps onto its 1120-token budget without
    /// upscaling, so dropping below it loses no useful detail. The
    /// downscale runs in `GemmaVisionService.preprocess(imageURLs:)`
    /// and uses Core Graphics so the resize happens out of the Swift
    /// stack. Range 768–2048 px; users on iPhone 13 or older can dial
    /// down if they hit the memory limit on Befunde with text near the
    /// edges; users on iPhone 15 Pro+ can dial up.
    nonisolated static let defaultVisionMaxLongEdge = 1568

    /// Plain-Swift read path for non-SwiftUI callers (services / actors).
    /// `@AppStorage` is a SwiftUI property wrapper and can't be read from
    /// an `actor`, so services go through `UserDefaults.standard` directly.
    nonisolated static var modelVariant: ModelVariant {
        let raw = UserDefaults.standard.string(forKey: modelVariantKey) ?? ModelVariant.e2b.rawValue
        return ModelVariant(rawValue: raw) ?? .e2b
    }

    nonisolated static var extractionMaxTokens: Int {
        let v = UserDefaults.standard.integer(forKey: extractionMaxTokensKey)
        return v > 0 ? v : defaultExtractionMaxTokens
    }

    nonisolated static var briefingMaxTokens: Int {
        let v = UserDefaults.standard.integer(forKey: briefingMaxTokensKey)
        return v > 0 ? v : defaultBriefingMaxTokens
    }

    nonisolated static var handoffMaxTokens: Int {
        let v = UserDefaults.standard.integer(forKey: handoffMaxTokensKey)
        return v > 0 ? v : defaultHandoffMaxTokens
    }

    /// Output budget for `AskService.answer(...)`. Default 512 covers
    /// ~5 cited claims + 3 follow-ups on the single-shot path. The
    /// Settings slider runs 256–8192 in 256-token steps. The high end
    /// exists for the agent path (`askAgentEnabled`) which forces
    /// thinking mode and adds several hundred reasoning tokens per
    /// turn × N tool turns × the final JSON answer — 2048 is often
    /// not enough for a multi-tool agent run, so users need headroom.
    /// KV-cache memory cost is roughly ~25 KB per output token on
    /// Gemma 4 E2B 4-bit, so 8192 ≈ 200 MB transient — fits inside
    /// the Increased-Memory-Limit ceiling but worth flagging.
    nonisolated static var askMaxTokens: Int {
        let v = UserDefaults.standard.integer(forKey: askMaxTokensKey)
        return v > 0 ? v : defaultAskMaxTokens
    }

    /// When `true`, every Q&A card in `AskView` shows an "ⓘ" button that
    /// opens `AskDebugSheet` with retrieval counts, prompted IDs, raw
    /// model output, parse status, filter results, and any refusal
    /// reason. Off by default; the toggle lives in
    /// `SettingsView`→Entwicklung.
    nonisolated static var askDiagnosticsEnabled: Bool {
        UserDefaults.standard.bool(forKey: askDiagnosticsEnabledKey)
    }

    /// When `true`, `AskService` opts every Gemma call into thinking mode
    /// (`additionalContext: ["enable_thinking": true]`). The chat template
    /// inserts a `<|think|>` token; Gemma emits a `<|channel>thought`
    /// reasoning section before the JSON answer. Costs several hundred
    /// extra output tokens per call — pair with `askMaxTokens ≥ 1024`.
    /// Off by default; the toggle lives in `SettingsView`→Entwicklung.
    nonisolated static var askThinkingEnabled: Bool {
        UserDefaults.standard.bool(forKey: askThinkingEnabledKey)
    }

    /// When `true`, `AskService` adds a second-stage dense rerank
    /// (RRF over BM25 rank + cosine rank using
    /// `intfloat/multilingual-e5-small`) on top of the BM25 first stage.
    /// Loads the ~130 MB embedder on first activation. Off by default;
    /// the toggle lives in `SettingsView`→Entwicklung.
    nonisolated static var askDenseRerankerEnabled: Bool {
        UserDefaults.standard.bool(forKey: askDenseRerankerEnabledKey)
    }

    /// When `true` (the default), `AskService` short-circuits past-
    /// tense event questions ("Welche … gab es?", "Wann hatte …?",
    /// etc.) with a deterministic "Im Journal finde ich dazu keinen
    /// Eintrag." answer when the journal retrieval finds nothing —
    /// instead of letting Gemma paraphrase a topically-relevant corpus
    /// chunk into an answer that reads like a journal claim. Toggle off
    /// in Settings → Entwicklung for comparison.
    nonisolated static var askEventGuardEnabled: Bool {
        // Default true: reads false from UserDefaults if the key was
        // never set, so we mirror via a sentinel.
        UserDefaults.standard.object(forKey: askEventGuardEnabledKey) as? Bool
            ?? defaultAskEventGuardEnabled
    }

    /// **Deprecated** — replaced by ``askMode``. Kept only so the read
    /// path can migrate a pre-1.0 user who had the old boolean toggle
    /// on: those users land in ``AskMode.mlxToolCall`` (the current
    /// behaviour of "toggle on" before the 3-way picker shipped). New
    /// callers should read ``askMode`` directly.
    @available(*, deprecated, message: "Read AppSettings.askMode instead.")
    nonisolated static var askAgentEnabled: Bool {
        UserDefaults.standard.bool(forKey: askAgentEnabledKey)
    }

    /// Which `AskService.answer(...)` path runs. See ``AskMode`` for
    /// the three options. Default `.chat` — single-shot retrieval +
    /// synthesis, the production-quality path. The picker lives in
    /// Settings → Entwicklung → Antwort-Modus.
    ///
    /// Migration: if the new key is unset but the old `askAgentEnabled`
    /// boolean was `true`, we return `.mlxToolCall` so the user who
    /// previously opted into the broken upstream path stays there.
    nonisolated static var askMode: AskMode {
        if let raw = UserDefaults.standard.string(forKey: askModeKey),
           let mode = AskMode(rawValue: raw) {
            return mode
        }
        // Legacy migration. Once a user actively picks via the new
        // picker, the new key gets written and this branch never
        // fires for them again.
        if UserDefaults.standard.bool(forKey: askAgentEnabledKey) {
            return .mlxToolCall
        }
        return .chat
    }

    nonisolated static var labPipelineMode: LabPipelineMode {
        let raw = UserDefaults.standard.string(forKey: labPipelineModeKey) ?? LabPipelineMode.ocrThenGemma.rawValue
        return LabPipelineMode(rawValue: raw) ?? .ocrThenGemma
    }

    /// Pixel cap (long edge) for Befund images on the `.directMultimodal`
    /// path. 0 / unset → use ``defaultVisionMaxLongEdge`` (1568 px).
    /// Read by ``GemmaVisionService.preprocess(imageURLs:)`` before the
    /// images are wrapped as `UserInput.Image.ciImage(_:)`. Adjust in
    /// Settings → Befund-Verarbeitung if you hit the per-app memory
    /// limit on a smaller device.
    nonisolated static var visionMaxLongEdge: Int {
        let v = UserDefaults.standard.integer(forKey: visionMaxLongEdgeKey)
        return v > 0 ? v : defaultVisionMaxLongEdge
    }

    /// Write path used by `GemmaService` when E4B load fails and the
    /// service falls back to E2B. Keeps the UI in sync with reality on
    /// next read.
    nonisolated static func persistModelVariant(_ variant: ModelVariant) {
        UserDefaults.standard.set(variant.rawValue, forKey: modelVariantKey)
    }
}
