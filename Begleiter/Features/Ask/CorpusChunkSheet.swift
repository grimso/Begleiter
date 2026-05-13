import SwiftUI

/// Inspector sheet shown when the parent taps a `[K:...]` citation chip.
/// Renders the chunk's full body with its source attribution and a
/// tappable link out to the canonical reference page — important
/// because we hand-author short summaries rather than reproducing
/// upstream text. The parent goes to the source for the full picture.
struct CorpusChunkSheet: View {
    let chunk: CorpusChunk

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(chunk.title)
                        .font(.title2.bold())

                    sourceBadge

                    Text(chunk.text)
                        .font(.body)
                        .textSelection(.enabled)

                    if let urlString = chunk.referenceURL,
                       let url = URL(string: urlString) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(L10n.key("corpus.referenceURL.label"))
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .textCase(.uppercase)
                            Link(destination: url) {
                                HStack(spacing: 6) {
                                    Image(systemName: "link")
                                    Text(urlString)
                                        .lineLimit(2)
                                        .truncationMode(.middle)
                                }
                                .font(.footnote)
                            }
                        }
                        .padding(.top, 8)
                    }

                    Text(String(format: L10n.t("corpus.updatedAt"), chunk.updatedAt))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .padding(.top, 12)
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .navigationTitle(L10n.key("corpus.sheet.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.t("app.done")) { dismiss() }
                }
            }
        }
    }

    private var sourceBadge: some View {
        let labelKey: String = {
            switch chunk.source {
            case .kinderkrebsinfo:  return "corpus.source.kinderkrebsinfo"
            case .kinderkrebshilfe: return "corpus.source.kinderkrebshilfe"
            case .glossaryDrugs:    return "corpus.source.glossaryDrugs"
            case .glossaryLabs:     return "corpus.source.glossaryLabs"
            }
        }()
        return Text(L10n.key(labelKey))
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Color.purple.opacity(0.15))
            .foregroundStyle(.purple)
            .clipShape(Capsule())
    }
}
