import SwiftUI

/// One tappable citation reference rendered inline with the claim it
/// supports. Two visual styles distinguish journal entries from corpus
/// chunks so the parent can tell at a glance which source they're about
/// to open.
struct CitationChip: View {
    let citation: Citation
    let label: String
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.caption2)
                Text(label)
                    .font(.caption2.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(background)
            .foregroundStyle(foreground)
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityHint(L10n.t("ask.citation.hint"))
    }

    private var icon: String {
        switch citation {
        case .entry:  return "doc.text"
        case .corpus: return "book.closed"
        }
    }

    private var background: Color {
        switch citation {
        case .entry:  return Color.blue.opacity(0.15)
        case .corpus: return Color.purple.opacity(0.15)
        }
    }

    private var foreground: Color {
        switch citation {
        case .entry:  return .blue
        case .corpus: return .purple
        }
    }
}
