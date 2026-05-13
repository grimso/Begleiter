import SwiftUI

/// One Q&A card rendered in the `AskView` chat surface. Layout:
///
/// ```
/// Frage: <question text>
/// ──────────────────────
/// Antwort:
///   <claim 1 text>
///   [chip] [chip]
///   <claim 2 text>
///   [chip]
///   ...
///   [basis footer]
///
/// Vorschläge:
///   [follow-up] [follow-up] [follow-up]
/// ```
///
/// Citation chips appear on a row below each claim rather than inline
/// with the prose. SwiftUI doesn't natively flow custom views inside
/// `Text`; for hackathon scope the below-the-text layout is honest and
/// readable. Tap routing is delegated up to the owning view via the
/// `onTapCitation` and `onTapFollowUp` callbacks.
struct QACardView: View {
    let answer: AskAnswer
    let chunkLabel: (String) -> String
    let onTapCitation: (Citation) -> Void
    let onTapFollowUp: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            questionHeader
            Divider()
            ForEach(answer.claims) { claim in
                claimRow(claim)
            }
            basisFooter
            if !answer.followUps.isEmpty {
                followUpRow
            }
        }
        .padding(12)
        .background(Color.secondary.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Question

    private var questionHeader: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "person.fill")
                .foregroundStyle(.tint)
                .font(.subheadline)
            Text(answer.question)
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Claim

    @ViewBuilder
    private func claimRow(_ claim: AnswerClaim) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(Self.stripCitationMarkers(from: claim.text))
                .font(.body)
                .textSelection(.enabled)
            if !claim.citations.isEmpty {
                citationsLine(claim.citations)
            }
        }
    }

    @ViewBuilder
    private func citationsLine(_ citations: [Citation]) -> some View {
        // FlowLayout-like behaviour with horizontal scroll for now —
        // simpler and works on every iOS version we target. Few enough
        // citations per claim (≤3 typical) that horizontal scroll is
        // never engaged in practice.
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(Array(citations.enumerated()), id: \.offset) { (_, citation) in
                    CitationChip(
                        citation: citation,
                        label: label(for: citation)
                    ) {
                        onTapCitation(citation)
                    }
                }
            }
        }
    }

    private func label(for citation: Citation) -> String {
        switch citation {
        case .entry:
            return L10n.t("ask.citation.entry")
        case .corpus(let id):
            return chunkLabel(id)
        }
    }

    // MARK: - Basis

    @ViewBuilder
    private var basisFooter: some View {
        let key: String? = {
            switch answer.basis {
            case .journal: return "ask.basis.journal"
            case .corpus:  return "ask.basis.corpus"
            case .both:    return "ask.basis.both"
            case .refusal: return nil
            }
        }()
        if let key {
            HStack(spacing: 4) {
                Image(systemName: "info.circle")
                    .font(.caption2)
                Text(L10n.key(key))
                    .font(.caption2)
            }
            .foregroundStyle(.secondary)
        }
    }

    // MARK: - Follow-ups

    private var followUpRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L10n.key("ask.followups.title"))
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(answer.followUps.enumerated()), id: \.offset) { (_, q) in
                    Button {
                        onTapFollowUp(q)
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "questionmark.circle")
                                .font(.caption)
                            Text(q)
                                .font(.callout)
                                .multilineTextAlignment(.leading)
                            Spacer()
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Color.accentColor.opacity(0.10))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .foregroundStyle(.tint)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.top, 4)
    }

    // MARK: - Marker stripping

    /// Regex that matches our inline citation markers `[E:UUID]` and
    /// `[K:chunkId]`. Used to clean Gemma's claim text before display so
    /// the parent never sees raw tokens.
    private static let markerRegex: NSRegularExpression = {
        try! NSRegularExpression(
            pattern: #"\s*\[(?:E|K):[A-Za-z0-9_/\-]+\]"#,
            options: []
        )
    }()

    static func stripCitationMarkers(from text: String) -> String {
        let range = NSRange(text.startIndex..., in: text)
        let cleaned = markerRegex.stringByReplacingMatches(
            in: text, options: [], range: range, withTemplate: ""
        )
        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
