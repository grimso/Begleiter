import SwiftData
import SwiftUI

/// Sheet that turns a free-form German question into a rendered lab
/// plot. Hosted from `LabValuesView` via its new "Plot bauen" CTA.
///
/// Layout (top to bottom):
///   - Input area: TextField + Parser picker + Plotten button
///   - Starter chip suggestions when there's no result yet
///   - Result section (LabPlotResultView) when parse + resolve succeeded
///   - Error banner when the parser couldn't make sense of the question
///   - Debug disclosure (gated on AppSettings.askDiagnosticsEnabled)
///     showing the parsed JSON spec + resolved date ranges
struct LabPlotComposerView: View {
    let child: ChildState

    @Environment(\.dismiss) private var dismiss

    @Query(sort: \JournalEntry.visitDate, order: .reverse)
    private var entries: [JournalEntry]

    @State private var viewModel = LabPlotComposerViewModel()
    @FocusState private var inputFocused: Bool

    @AppStorage(AppSettings.askDiagnosticsEnabledKey)
    private var diagnosticsEnabled: Bool = AppSettings.defaultAskDiagnosticsEnabled

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    inputCard
                    if let error = viewModel.lastError {
                        errorBanner(error)
                    }
                    if let result = viewModel.lastResult {
                        LabPlotResultView(result: result)
                            .padding(.top, 4)
                        if diagnosticsEnabled {
                            debugDisclosure(result: result)
                        }
                    } else {
                        startersCard
                    }
                }
                .padding()
            }
            .navigationTitle(L10n.key("labs.plotComposer.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.t("app.done")) { dismiss() }
                }
            }
        }
    }

    // MARK: - Input card

    private var inputCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField(
                L10n.t("labs.plotComposer.placeholder"),
                text: Binding(
                    get: { viewModel.draft },
                    set: { viewModel.draft = $0 }
                ),
                axis: .vertical
            )
            .lineLimit(1...4)
            .textFieldStyle(.roundedBorder)
            .focused($inputFocused)
            .onSubmit { submit() }

            HStack(spacing: 12) {
                Picker(
                    L10n.t("labs.plotComposer.parser.label"),
                    selection: Binding(
                        get: { viewModel.parserKind },
                        set: { viewModel.parserKind = $0 }
                    )
                ) {
                    Text(L10n.key("labs.plotComposer.parser.heuristic"))
                        .tag(LabPlotParserKind.heuristic)
                    Text(L10n.key("labs.plotComposer.parser.gemma"))
                        .tag(LabPlotParserKind.gemma)
                }
                .pickerStyle(.segmented)

                Button {
                    submit()
                } label: {
                    if viewModel.isBusy {
                        ProgressView()
                            .controlSize(.small)
                            .frame(width: 60)
                    } else {
                        Text(L10n.key("labs.plotComposer.submit"))
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(
                    viewModel.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    || viewModel.isBusy
                )
            }
        }
    }

    private func submit() {
        viewModel.submit(child: child, entries: entries)
    }

    // MARK: - Starters

    private var startersCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L10n.key("labs.plotComposer.starters.heading"))
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            VStack(alignment: .leading, spacing: 6) {
                ForEach(starterSuggestions, id: \.self) { phrase in
                    Button {
                        viewModel.prefillDraft(phrase)
                        inputFocused = true
                    } label: {
                        HStack {
                            Image(systemName: "sparkles")
                                .font(.caption)
                            Text(phrase)
                                .multilineTextAlignment(.leading)
                            Spacer()
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .background(Color.accentColor.opacity(0.10))
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .foregroundStyle(.tint)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    /// Four canned German phrasings that all parse with the heuristic
    /// path. Pulled from the localized strings so they translate
    /// cleanly later.
    private var starterSuggestions: [String] {
        (1...4).map { L10n.t("labs.plotComposer.starter.\($0)") }
    }

    // MARK: - Error banner

    private func errorBanner(_ error: LabPlotComposerError) -> some View {
        Label(error.errorDescription ?? L10n.t("labs.plotComposer.error.generic"),
              systemImage: "exclamationmark.triangle.fill")
            .font(.callout)
            .foregroundStyle(.orange)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.orange.opacity(0.12))
            .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - Debug

    private func debugDisclosure(result: LabPlotResult) -> some View {
        DisclosureGroup(L10n.t("labs.plotComposer.debug.title")) {
            VStack(alignment: .leading, spacing: 12) {
                Text(L10n.key("labs.plotComposer.debug.specHeader"))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(prettyJSON(for: result.spec))
                    .font(.caption2.monospaced())
                    .textSelection(.enabled)

                Text(L10n.key("labs.plotComposer.debug.rangesHeader"))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                ForEach(Array(result.resolvedRanges.enumerated()), id: \.offset) { idx, range in
                    let label = idx < result.panels.first?.windows.count ?? 0
                        ? result.panels.first?.windows[idx].label ?? "?"
                        : "?"
                    HStack {
                        Text(label).font(.caption2)
                        Spacer()
                        Text(formatRange(range)).font(.caption2.monospaced())
                    }
                }
            }
            .padding(.top, 4)
        }
        .padding(.top, 8)
    }

    private func prettyJSON(for spec: LabPlotSpec) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(spec),
              let str = String(data: data, encoding: .utf8) else {
            return "<encoding failed>"
        }
        return str
    }

    private func formatRange(_ range: DateInterval?) -> String {
        guard let range else { return "—" }
        let f = DateFormatter()
        f.dateStyle = .short
        f.locale = Locale(identifier: "de_DE")
        return "\(f.string(from: range.start)) – \(f.string(from: range.end))"
    }
}
