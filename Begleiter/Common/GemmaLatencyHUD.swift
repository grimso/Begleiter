import Foundation
import Observation

/// In-memory store for the most recent Gemma generation's latency stats.
///
/// Populated by ``GemmaService.generate`` and ``GemmaVisionService.generate``
/// after each successful call. Read by ``LatencyHUDView`` to render a
/// floating chip in the top-right of the app. Failures do not record —
/// the HUD keeps showing the last successful sample rather than flashing
/// an error state that wipes the only useful number on screen.
///
/// Why ``@MainActor`` + ``@Observable``. The HUD is a SwiftUI surface, so
/// reads must happen on the main actor. ``GemmaService`` is its own actor
/// and records via a hop:
///
/// ```swift
/// Task { @MainActor in GemmaLatencyHUD.shared.record(sample) }
/// ```
///
/// The hop is fire-and-forget — generation has already returned before
/// the record lands, and a dropped sample on app shutdown is harmless.
@MainActor
@Observable
final class GemmaLatencyHUD {
    static let shared = GemmaLatencyHUD()

    /// One generation's worth of PII-free measurements. Mirrors the
    /// `gemma.generate.done` log line schema so the HUD value and the
    /// unified-log value are the same numbers.
    struct Sample: Equatable, Sendable {
        let surface: String
        let elapsedMs: UInt64
        let ttftMs: UInt64
        let decodeTokPerSec: Double
        let promptChars: Int
        let outputTokensApprox: Int
        let thinking: Bool
        let imageCount: Int?
        let timestamp: Date
    }

    private(set) var latest: Sample?

    func record(_ sample: Sample) {
        latest = sample
    }

    /// Clears the displayed sample. Not currently wired to any UI — kept
    /// for parity with the Settings-side "Embedding-Cache leeren" pattern
    /// in case a future Settings row wants to reset the HUD between A/B
    /// runs.
    func clear() {
        latest = nil
    }

    private init() {}
}
