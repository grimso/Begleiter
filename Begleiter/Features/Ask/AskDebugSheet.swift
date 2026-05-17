import SwiftUI

/// Developer-facing diagnostic sheet showing every signal the answer
/// pipeline collected for one Q&A round-trip. Surfaced only when the
/// `AppSettings.askDiagnosticsEnabledKey` toggle is on
/// (Settings → Entwicklung → "Ask-Diagnose anzeigen").
///
/// Three sections answer the question "why this answer?":
/// 1. Retrieval — how many journal entries / corpus chunks were found
///    and which IDs went into the prompt.
/// 2. Modell — raw Gemma output and any parse/model error.
/// 3. Filter — claims before vs after the verifiable-generation pass,
///    how many citations got dropped, which warnings fired, and (if
///    the answer was a refusal) why.
struct AskDebugSheet: View {
    let answer: AskAnswer

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                retrievalSection
                if rerankerVisible {
                    rerankerSection
                }
                contextSection
                modelSection
                filterSection
                if !answer.warnings.isEmpty {
                    warningsSection
                }
                if let reason = answer.debug.refusalReason {
                    refusalSection(reason: reason)
                }
            }
            .navigationTitle(L10n.key("ask.debug.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.t("app.done")) { dismiss() }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color("BegleiterBackground").ignoresSafeArea())
        }
    }

    private var rowBackground: Color { Color("BegleiterCardSurface") }

    private var retrievalSection: some View {
        Section {
            LabeledContent(L10n.t("ask.debug.scope")) {
                Text(answer.debug.scope.rawValue)
                    .font(.callout.monospaced())
            }
            LabeledContent(L10n.t("ask.debug.journalHits")) {
                Text("\(answer.debug.journalHits)").monospacedDigit()
            }
            LabeledContent(L10n.t("ask.debug.corpusHits")) {
                Text("\(answer.debug.corpusHits)").monospacedDigit()
            }
            if answer.debug.timelinePackTokens > 0 {
                LabeledContent(L10n.t("ask.debug.timelinePackTokens")) {
                    Text("\(answer.debug.timelinePackTokens)").monospacedDigit()
                        .foregroundStyle(.purple)
                }
            }
            if answer.debug.timelinePackOmittedCount > 0 {
                LabeledContent(L10n.t("ask.debug.timelinePackOmitted")) {
                    Text("\(answer.debug.timelinePackOmittedCount)")
                        .monospacedDigit()
                        .foregroundStyle(.orange)
                }
            }
        } header: {
            Text(L10n.key("ask.debug.retrieval"))
        }
        .listRowBackground(rowBackground)
    }

    private var rerankerVisible: Bool {
        answer.debug.denseRerankerEnabled || answer.debug.rerankSkippedReason != nil
    }

    private var rerankerSection: some View {
        Section {
            Label(
                answer.debug.denseRerankerEnabled
                ? L10n.t("ask.debug.reranker.active")
                : L10n.t("ask.debug.reranker.inactive"),
                systemImage: answer.debug.denseRerankerEnabled
                    ? "rectangle.stack.badge.plus"
                    : "rectangle.stack"
            )
            .foregroundStyle(answer.debug.denseRerankerEnabled ? .purple : .secondary)

            if answer.debug.denseRerankerEnabled {
                LabeledContent(L10n.t("ask.debug.reranker.candidatesBefore")) {
                    Text("\(answer.debug.candidatesBeforeRerankJournal) / \(answer.debug.candidatesBeforeRerankCorpus)")
                        .monospacedDigit()
                }
                LabeledContent(L10n.t("ask.debug.reranker.reorderCount")) {
                    Text("\(answer.debug.rerankReorderCount)")
                        .monospacedDigit()
                        .foregroundStyle(answer.debug.rerankReorderCount > 0 ? .purple : .secondary)
                }
                if let loadMs = answer.debug.embedderLoadMs {
                    LabeledContent(L10n.t("ask.debug.reranker.embedderLoadMs")) {
                        Text("\(loadMs) ms")
                            .monospacedDigit()
                    }
                }
                if let queryMs = answer.debug.queryEmbedMs {
                    LabeledContent(L10n.t("ask.debug.reranker.queryEmbedMs")) {
                        Text("\(queryMs) ms")
                            .monospacedDigit()
                    }
                }
                LabeledContent(L10n.t("ask.debug.reranker.newVectors")) {
                    Text("\(answer.debug.entryEmbedCount) / \(answer.debug.corpusEmbedCount)")
                        .monospacedDigit()
                }
            }
            if let reason = answer.debug.rerankSkippedReason {
                Label(reason, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }
        } header: {
            Text(L10n.key("ask.debug.reranker.title"))
        }
        .listRowBackground(rowBackground)
    }

    private var contextSection: some View {
        Section {
            LabeledContent(L10n.t("ask.debug.promptedEntries")) {
                Text("\(answer.debug.promptedEntryIds.count)").monospacedDigit()
            }
            if !answer.debug.promptedEntryIds.isEmpty {
                DisclosureGroup(L10n.t("ask.debug.entryIds")) {
                    ForEach(answer.debug.promptedEntryIds, id: \.self) { id in
                        Text(id.uuidString)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                    }
                }
            }
            LabeledContent(L10n.t("ask.debug.promptedChunks")) {
                Text("\(answer.debug.promptedChunkIds.count)").monospacedDigit()
            }
            if !answer.debug.promptedChunkIds.isEmpty {
                DisclosureGroup(L10n.t("ask.debug.chunkIds")) {
                    ForEach(answer.debug.promptedChunkIds, id: \.self) { id in
                        Text(id)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                    }
                }
            }
            LabeledContent(L10n.t("ask.debug.promptChars")) {
                Text("\(answer.debug.promptCharCount)").monospacedDigit()
            }
        } header: {
            Text(L10n.key("ask.debug.promptContext"))
        }
        .listRowBackground(rowBackground)
    }

    private var modelSection: some View {
        Section {
            Label(answer.debug.thinkingEnabled
                  ? L10n.t("ask.debug.thinkingEnabled")
                  : L10n.t("ask.debug.thinkingDisabled"),
                  systemImage: answer.debug.thinkingEnabled ? "brain" : "brain.head.profile")
                .foregroundStyle(answer.debug.thinkingEnabled ? .purple : .secondary)
            if !answer.debug.promptText.isEmpty {
                DisclosureGroup(
                    "\(L10n.t("ask.debug.promptText")) (\(answer.debug.promptCharCount))"
                ) {
                    Text(answer.debug.promptText)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            if let modelError = answer.debug.modelError {
                Label(modelError, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
            } else if answer.debug.rawModelOutput.isEmpty {
                Text(L10n.key("ask.debug.modelNotCalled"))
                    .foregroundStyle(.secondary)
            } else {
                LabeledContent(L10n.t("ask.debug.rawCharCount")) {
                    Text("\(answer.debug.rawModelOutput.count)").monospacedDigit()
                }
                if let parseError = answer.debug.parseError {
                    Label(parseError, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
                DisclosureGroup(L10n.t("ask.debug.rawOutput")) {
                    Text(answer.debug.rawModelOutput)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        } header: {
            Text(L10n.key("ask.debug.model"))
        }
        .listRowBackground(rowBackground)
    }

    private var filterSection: some View {
        Section {
            LabeledContent(L10n.t("ask.debug.claimsBefore")) {
                Text("\(answer.debug.claimsBeforeFilter)").monospacedDigit()
            }
            LabeledContent(L10n.t("ask.debug.claimsAfter")) {
                Text("\(answer.debug.claimsAfterFilter)").monospacedDigit()
            }
            LabeledContent(L10n.t("ask.debug.droppedCitations")) {
                Text("\(answer.debug.droppedCitationCount)").monospacedDigit()
                    .foregroundStyle(answer.debug.droppedCitationCount > 0 ? .orange : .primary)
            }
        } header: {
            Text(L10n.key("ask.debug.filter"))
        }
        .listRowBackground(rowBackground)
    }

    private var warningsSection: some View {
        Section {
            ForEach(answer.warnings, id: \.self) { warning in
                Label(label(for: warning), systemImage: icon(for: warning))
                    .foregroundStyle(.orange)
            }
        } header: {
            Text(L10n.key("ask.debug.warnings"))
        }
        .listRowBackground(rowBackground)
    }

    private func refusalSection(reason: RefusalReason) -> some View {
        Section {
            Label(label(for: reason), systemImage: "xmark.octagon.fill")
                .foregroundStyle(.red)
        } header: {
            Text(L10n.key("ask.debug.refusalReason"))
        } footer: {
            Text(L10n.key("ask.debug.refusalReason.footer"))
        }
        .listRowBackground(rowBackground)
    }

    // MARK: - Label helpers

    private func label(for warning: AnswerWarning) -> String {
        switch warning {
        case .adviceDrift:       return L10n.t("ask.warning.adviceDrift")
        case .noCitations:       return L10n.t("ask.warning.noCitations")
        case .partialCitations:  return L10n.t("ask.warning.partialCitations")
        }
    }

    private func icon(for warning: AnswerWarning) -> String {
        switch warning {
        case .adviceDrift:       return "stethoscope"
        case .noCitations:       return "questionmark.diamond"
        case .partialCitations:  return "exclamationmark.triangle"
        }
    }

    private func label(for reason: RefusalReason) -> String {
        switch reason {
        case .emptyRetrieval:            return L10n.t("ask.debug.refusalReason.emptyRetrieval")
        case .modelError:                return L10n.t("ask.debug.refusalReason.modelError")
        case .parseFailure:              return L10n.t("ask.debug.refusalReason.parseFailure")
        case .emptyClaims:               return L10n.t("ask.debug.refusalReason.emptyClaims")
        case .noJournalForEventQuestion: return L10n.t("ask.debug.refusalReason.noJournalForEventQuestion")
        }
    }
}
