import SwiftData
import SwiftUI

/// Single-shot Q&A chat surface. Presented as a sheet from two entry
/// points:
///
/// - **TimelineView toolbar** with `scope == .all` ("Fragen")
/// - **LabValuesView CTA** with `scope == .labs` ("Frag deine Werte")
///
/// Each question is a fresh retrieval + generate cycle against the
/// journal + reference corpus. The screen holds an ephemeral, session-
/// local stack of Q&A cards — closing the sheet discards the history.
struct AskView: View {
    let child: ChildState
    let scope: AskScope

    @Environment(\.dismiss) private var dismiss

    @Query(sort: \JournalEntry.visitDate, order: .reverse)
    private var entries: [JournalEntry]

    @State private var viewModel: AskViewModel?
    @State private var presentedChunk: CorpusChunk?
    @State private var pendingEntryDetailId: UUID?
    @FocusState private var inputFocused: Bool

    private let corpus = CorpusService.shared

    var body: some View {
        NavigationStack {
            Group {
                if let viewModel {
                    contentBody(vm: viewModel)
                } else {
                    ProgressView()
                }
            }
            .navigationTitle(L10n.key(scope == .labs ? "ask.title.labs" : "ask.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.t("app.done")) { dismiss() }
                }
            }
            .sheet(item: $presentedChunk) { chunk in
                CorpusChunkSheet(chunk: chunk)
            }
            .sheet(
                isPresented: Binding(
                    get: { pendingEntryDetailId != nil },
                    set: { if !$0 { pendingEntryDetailId = nil } }
                )
            ) {
                if let id = pendingEntryDetailId,
                   let entry = entries.first(where: { $0.entryId == id }) {
                    NavigationStack {
                        EntryDetailView(entry: entry)
                            .toolbar {
                                ToolbarItem(placement: .confirmationAction) {
                                    Button(L10n.t("app.done")) {
                                        pendingEntryDetailId = nil
                                    }
                                }
                            }
                    }
                }
            }
        }
        .task {
            if viewModel == nil {
                viewModel = AskViewModel(scope: scope)
            }
            viewModel?.updateEntries(entries)
        }
        .onChange(of: entries) { _, newValue in
            viewModel?.updateEntries(newValue)
        }
    }

    // MARK: - Content body

    @ViewBuilder
    private func contentBody(vm: AskViewModel) -> some View {
        Group {
            if vm.cards.isEmpty && !vm.isAnswering {
                emptyState(vm: vm)
            } else {
                cardStack(vm: vm)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            inputBar(vm: vm)
        }
    }

    // MARK: - Empty state

    private func emptyState(vm: AskViewModel) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Image(systemName: scope == .labs
                      ? "testtube.2"
                      : "bubble.left.and.text.bubble.right")
                    .font(.system(size: 44))
                    .foregroundStyle(.tint)
                    .padding(.top, 32)

                Text(L10n.key(scope == .labs
                              ? "ask.empty.title.labs"
                              : "ask.empty.title"))
                    .font(.title3.bold())

                Text(L10n.key(scope == .labs
                              ? "ask.empty.description.labs"
                              : "ask.empty.description"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                Text(L10n.key("ask.starters.heading"))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                    .padding(.top, 12)

                VStack(alignment: .leading, spacing: 8) {
                    ForEach(AskService.suggestedStarters(for: scope), id: \.self) { starter in
                        Button {
                            vm.prefillDraft(starter)
                            inputFocused = true
                        } label: {
                            HStack {
                                Image(systemName: "sparkles")
                                    .font(.caption)
                                Text(starter)
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
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Card stack

    private func cardStack(vm: AskViewModel) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(vm.cards) { answer in
                        QACardView(
                            answer: answer,
                            chunkLabel: { corpus.chunk(id: $0)?.title ?? $0 },
                            onTapCitation: { handleTapCitation($0) },
                            onTapFollowUp: { followUp in
                                vm.prefillDraft(followUp)
                                inputFocused = true
                            }
                        )
                        .id(answer.id)
                    }
                    if vm.isAnswering {
                        answeringRow
                            .id("answering")
                    }
                }
                .padding()
            }
            .onChange(of: vm.cards.count) { _, _ in
                if let last = vm.cards.last {
                    withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
            .onChange(of: vm.isAnswering) { _, newValue in
                if newValue {
                    withAnimation { proxy.scrollTo("answering", anchor: .bottom) }
                }
            }
        }
    }

    private var answeringRow: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(L10n.key("ask.answering"))
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .background(Color.secondary.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Input bar

    private func inputBar(vm: AskViewModel) -> some View {
        HStack(spacing: 8) {
            TextField(
                L10n.t("ask.placeholder"),
                text: Binding(
                    get: { vm.draft },
                    set: { vm.draft = $0 }
                ),
                axis: .vertical
            )
            .lineLimit(1...4)
            .textFieldStyle(.roundedBorder)
            .focused($inputFocused)
            .onSubmit { vm.submit() }

            Button {
                vm.submit()
            } label: {
                Image(systemName: "paperplane.fill")
                    .padding(8)
            }
            .buttonStyle(.borderedProminent)
            .disabled(vm.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                      || vm.isAnswering)
            .accessibilityLabel(L10n.t("ask.send"))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }

    // MARK: - Citation tap routing

    private func handleTapCitation(_ citation: Citation) {
        switch citation {
        case .entry(let id):
            pendingEntryDetailId = id
        case .corpus(let chunkId):
            presentedChunk = corpus.chunk(id: chunkId)
        }
    }
}
