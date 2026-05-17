import SwiftUI

/// Floating diagnostic chip rendered as an overlay in the top-right of
/// the app while the developer toggle (Settings → Entwicklung → Latenz-HUD)
/// is on. Reads from ``GemmaLatencyHUD.shared``; updates whenever any
/// Gemma surface (Ask, Extraction, Briefing, Handoff, Vision) finishes
/// a generation.
///
/// Non-interactive (`allowsHitTesting(false)`) so it never intercepts taps
/// from the underlying view tree. Renders nothing until the first sample
/// arrives, so opening the app fresh doesn't show an empty placeholder.
struct LatencyHUDView: View {
    @State private var hud = GemmaLatencyHUD.shared

    var body: some View {
        if let latest = hud.latest {
            VStack(alignment: .leading, spacing: 2) {
                row(label: "Gemma", value: "\(latest.elapsedMs) ms")
                row(label: "TTFT", value: "\(latest.ttftMs) ms")
                row(label: "Decode", value: String(format: "%.1f tok/s", latest.decodeTokPerSec))
                row(label: "Surface", value: surfaceLine(latest))
            }
            .font(.system(.caption2, design: .monospaced))
            .foregroundStyle(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(.black.opacity(0.72), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .padding(.top, 8)
            .padding(.trailing, 8)
            .allowsHitTesting(false)
            .transition(.opacity.combined(with: .move(edge: .top)))
            .accessibilityElement(children: .combine)
            .accessibilityLabel(
                "Gemma latency: \(latest.elapsedMs) milliseconds total, TTFT \(latest.ttftMs) milliseconds, surface \(latest.surface)"
            )
        }
    }

    private func row(label: String, value: String) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .foregroundStyle(.white.opacity(0.6))
            Spacer(minLength: 6)
            Text(value)
                .bold()
        }
        .frame(minWidth: 160, alignment: .leading)
    }

    private func surfaceLine(_ sample: GemmaLatencyHUD.Sample) -> String {
        var parts: [String] = [sample.surface]
        if sample.thinking { parts.append("thinking") }
        if let imageCount = sample.imageCount, imageCount > 0 {
            parts.append("img=\(imageCount)")
        }
        return parts.joined(separator: " ")
    }
}
