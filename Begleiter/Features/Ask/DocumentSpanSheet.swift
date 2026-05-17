import SwiftUI

/// Sheet that opens when the parent taps a `[D:docId#chunkIndex]`
/// citation chip on an Ask answer. The reviewer flagged that the
/// previous routing synthesised a one-off `CorpusChunk` wrapper and
/// just rendered the chunk's prose — even though
/// ``DocumentChunk/sourceSpan`` now persists a verbatim character
/// range into ``ImportedDocument/sourceText`` that the UI can
/// highlight.
///
/// Two presentation paths:
/// - **`sourceSpan` present** — render the original document's
///   `sourceText` with the recovered span highlighted, so the parent
///   sees the exact characters Gemma anchored its chunk on.
/// - **`sourceSpan` is `nil`** — Gemma's paraphrase diverged from the
///   original past the recovery threshold; show the chunk text alone
///   with a "no verbatim span recovered" note so the framing stays
///   honest.
struct DocumentSpanSheet: View {
    let document: ImportedDocument
    let chunk: DocumentChunk

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    headerSection
                    Divider()
                    contentSection
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .navigationTitle(L10n.key("docSpan.sheet.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.t("app.done")) { dismiss() }
                }
            }
        }
    }

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(document.title)
                .font(.headline)
            HStack(spacing: 6) {
                Text(chunk.kind.capitalized)
                    .font(.caption)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.green.opacity(0.15))
                    .clipShape(Capsule())
                Text(L10n.t("docSpan.sheet.chunkIndex") + " \(chunk.index)")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var contentSection: some View {
        if let span = chunk.sourceSpan, let highlighted = makeHighlighted(span: span) {
            VStack(alignment: .leading, spacing: 12) {
                Label(L10n.key("docSpan.sheet.highlightHint"), systemImage: "highlighter")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(highlighted)
                    .font(.callout)
                    .textSelection(.enabled)
            }
        } else {
            VStack(alignment: .leading, spacing: 12) {
                Label(L10n.key("docSpan.sheet.noSpanHint"), systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(chunk.text)
                    .font(.callout)
                    .textSelection(.enabled)
            }
        }
    }

    /// Build an `AttributedString` of `sourceText` with `span`
    /// highlighted. Returns `nil` if the span has drifted out of
    /// bounds (e.g. legacy data; impossibly unlikely for in-app
    /// chunks but defensive against malformed Codable input).
    private func makeHighlighted(span: SourceSpan) -> AttributedString? {
        let text = document.sourceText
        guard span.start >= 0, span.length > 0,
              span.start + span.length <= text.count else { return nil }
        let lo = text.index(text.startIndex, offsetBy: span.start)
        let hi = text.index(lo, offsetBy: span.length)
        let before = String(text[text.startIndex..<lo])
        let highlighted = String(text[lo..<hi])
        let after = String(text[hi..<text.endIndex])

        var result = AttributedString()
        if !before.isEmpty {
            var seg = AttributedString(before)
            seg.foregroundColor = .secondary
            result.append(seg)
        }
        var hl = AttributedString(highlighted)
        hl.backgroundColor = Color.yellow.opacity(0.4)
        hl.foregroundColor = .primary
        result.append(hl)
        if !after.isEmpty {
            var seg = AttributedString(after)
            seg.foregroundColor = .secondary
            result.append(seg)
        }
        return result
    }
}

/// Identifiable wrapper used by `AskView`'s `.sheet(item:)` to present
/// `DocumentSpanSheet`. The `id` combines docId + chunkIndex so
/// SwiftUI correctly re-presents the sheet when the parent taps a
/// different chunk while one is already open.
struct PresentedDocumentSpan: Identifiable, Hashable {
    let id: String
    let document: ImportedDocument
    let chunk: DocumentChunk

    init(document: ImportedDocument, chunk: DocumentChunk) {
        self.id = "\(document.docId.uuidString)#\(chunk.index)"
        self.document = document
        self.chunk = chunk
    }

    // ImportedDocument is a SwiftData @Model class (Hashable via
    // identity); the synthesised hashable conformance uses object
    // identity for the document, which is what we want for sheet
    // routing — same chunk on the same model instance shouldn't
    // re-present.
    static func == (lhs: PresentedDocumentSpan, rhs: PresentedDocumentSpan) -> Bool {
        lhs.id == rhs.id
    }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}
