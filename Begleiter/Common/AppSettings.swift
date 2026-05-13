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
/// `.ocrThenGemma` is the only path that runs today (Apple Vision OCR
/// builds a text block, then `ExtractionService` feeds it to Gemma).
/// `.directMultimodal` is persisted for forward compatibility — when
/// `MLXVLM` lands the same value flips the branch in `ExtractionService`.
/// The Settings UI disables the multimodal row, but the persisted value
/// is still defensively switched on at the call site.
enum LabPipelineMode: String, CaseIterable, Identifiable, Sendable {
    case ocrThenGemma
    case directMultimodal

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
    nonisolated static let labPipelineModeKey      = "labPipelineMode"

    nonisolated static let defaultExtractionMaxTokens = 2500
    nonisolated static let defaultBriefingMaxTokens   = 640
    nonisolated static let defaultHandoffMaxTokens    = 512
    nonisolated static let defaultAskMaxTokens        = 512
    nonisolated static let defaultAskDiagnosticsEnabled = false

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
    /// ~5 cited claims + 3 follow-ups; Settings slider lets advanced
    /// users dial it between 256 (terse) and 1024 (more verbose).
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

    nonisolated static var labPipelineMode: LabPipelineMode {
        let raw = UserDefaults.standard.string(forKey: labPipelineModeKey) ?? LabPipelineMode.ocrThenGemma.rawValue
        return LabPipelineMode(rawValue: raw) ?? .ocrThenGemma
    }

    /// Write path used by `GemmaService` when E4B load fails and the
    /// service falls back to E2B. Keeps the UI in sync with reality on
    /// next read.
    nonisolated static func persistModelVariant(_ variant: ModelVariant) {
        UserDefaults.standard.set(variant.rawValue, forKey: modelVariantKey)
    }
}
