import SwiftData
import SwiftUI

/// Timeline of journal entries.
///
/// Default rendering is grouped by treatment phase, newest first within
/// each phase. When the parent types in the search bar, the view switches
/// to a flat results list ranked by `RetrievalService` BM25 score —
/// the recall demo beat ("Wann gab es das erste Mal eine
/// Asparaginase-Reaktion?" / "Wann hat Luca Vincristin bekommen?").
struct TimelineView: View {
    let child: ChildState

    @Query(sort: \JournalEntry.visitDate, order: .reverse) private var entries: [JournalEntry]
    @State private var presentingCapture = false
    @State private var presentingBriefing = false
    @State private var presentingHandoff = false
    @State private var presentingLabs = false
    @State private var searchText: String = ""

    private let retrieval = RetrievalService()

    var body: some View {
        Group {
            if entries.isEmpty {
                emptyState
            } else if !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                searchResultsList
            } else {
                groupedList
            }
        }
        .scrollContentBackground(.hidden)
        .background(Color("BegleiterBackground").ignoresSafeArea())
        .navigationTitle(L10n.key("timeline.title"))
        .searchable(
            text: $searchText,
            placement: .navigationBarDrawer(displayMode: .automatic),
            prompt: L10n.t("timeline.search.prompt")
        )
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    presentingCapture = true
                } label: {
                    Label(L10n.t("timeline.add"), systemImage: "plus")
                }
            }
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    presentingBriefing = true
                } label: {
                    Label(L10n.t("briefing.title"), systemImage: "calendar.badge.clock")
                }
                .disabled(entries.isEmpty)
            }
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    presentingHandoff = true
                } label: {
                    Label(L10n.t("handoff.title"), systemImage: "doc.text")
                }
                .disabled(entries.isEmpty)
            }
        }
        .sheet(isPresented: $presentingCapture) {
            CaptureView(child: child)
        }
        .sheet(isPresented: $presentingBriefing) {
            PreVisitBriefingView(child: child)
        }
        .sheet(isPresented: $presentingHandoff) {
            HandoffDocumentView(child: child)
        }
        .sheet(isPresented: $presentingLabs) {
            LabValuesView(child: child)
        }
    }

    // MARK: - Rendering paths

    private var groupedList: some View {
        let aggregatedSeries = LabSeries.aggregate(entries: entries)
        return List {
            LabStatusPill(series: aggregatedSeries) {
                presentingLabs = true
            }
            .listRowBackground(Color("BegleiterCardSurface"))
            ForEach(groupedByPhase, id: \.phase) { group in
                Section {
                    ForEach(group.entries) { entry in
                        NavigationLink {
                            EntryDetailView(entry: entry)
                        } label: {
                            TimelineRow(entry: entry)
                        }
                        .listRowBackground(Color("BegleiterCardSurface"))
                    }
                } header: {
                    Text(group.phaseLabel)
                }
            }
        }
    }

    @ViewBuilder
    private var searchResultsList: some View {
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let hits = retrieval.search(query: trimmed, in: entries, limit: 50)
        let resolved: [JournalEntry] = hits.compactMap { hit in
            entries.first { $0.entryId == hit.entryId }
        }

        if resolved.isEmpty {
            ContentUnavailableView(
                L10n.t("timeline.search.empty.title"),
                systemImage: "magnifyingglass",
                description: Text(
                    String(format: L10n.t("timeline.search.empty.description"), trimmed)
                )
            )
        } else {
            List {
                Section {
                    ForEach(resolved) { entry in
                        NavigationLink {
                            EntryDetailView(entry: entry)
                        } label: {
                            TimelineRow(entry: entry, highlightingTerm: trimmed)
                        }
                        .listRowBackground(Color("BegleiterCardSurface"))
                    }
                } header: {
                    Text(String(format: L10n.t("timeline.search.resultsHeader"), resolved.count))
                }
            }
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label(L10n.t("timeline.empty.title"), systemImage: "book.closed")
        } description: {
            Text(L10n.key("timeline.empty.description"))
        } actions: {
            Button {
                presentingCapture = true
            } label: {
                Text(L10n.key("timeline.empty.action"))
            }
            .buttonStyle(.borderedProminent)
        }
    }

    // MARK: - Grouping

    private struct PhaseGroup {
        let phase: Phase
        let phaseLabel: String
        let entries: [JournalEntry]
    }

    private var groupedByPhase: [PhaseGroup] {
        // Preserve canonical phase order, dropping phases with no entries.
        Phase.canonicalOrder.compactMap { phase in
            let inPhase = entries.filter { $0.phase == phase }
            guard !inPhase.isEmpty else { return nil }
            let label = NSLocalizedString("phase.\(phase.rawValue).label", comment: "")
            return PhaseGroup(phase: phase, phaseLabel: label, entries: inPhase)
        }
    }
}

private struct TimelineRow: View {
    let entry: JournalEntry
    /// When provided (search mode), the row shows a snippet around the
    /// matched term so the parent can see what hit. nil in default mode.
    var highlightingTerm: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(entry.visitDate, style: .date)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                ProcessingBadge(status: entry.processingStatus)
                if let visitType = entry.extractedFields.visitType?.value {
                    Text(visitType.germanLabel)
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.secondary.opacity(0.15))
                        .clipShape(Capsule())
                }
            }
            Text(entry.displayTitle)
                .font(.body)
                .lineLimit(2)
            if let term = highlightingTerm, let snippet = snippet(for: term) {
                Text(snippet)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 2)
    }

    // MARK: - snippet helpers

    /// Find a ~80-char window around the first case-insensitive match of
    /// `term` in the entry's searchable text. Falls back to nil if no
    /// match (which shouldn't happen because the entry IS a search hit,
    /// but defends against the rare case where the BM25 score came from
    /// a metadata field).
    private func snippet(for term: String) -> String? {
        let body = RetrievalService.searchableText(of: entry)
        guard let range = body.range(of: term, options: .caseInsensitive) else { return nil }
        let pad = 40
        let lower = body.index(range.lowerBound,
                               offsetBy: -pad,
                               limitedBy: body.startIndex) ?? body.startIndex
        let upper = body.index(range.upperBound,
                               offsetBy: pad,
                               limitedBy: body.endIndex) ?? body.endIndex
        var snippet = String(body[lower..<upper])
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespaces)
        if lower != body.startIndex { snippet = "… " + snippet }
        if upper != body.endIndex   { snippet = snippet + " …" }
        return snippet
    }
}

/// Small pill rendered on `TimelineRow` whenever the entry is not in
/// the terminal `.extracted` state. Invisible for normal extracted
/// entries to keep the timeline visually quiet.
private struct ProcessingBadge: View {
    let status: ProcessingStatus

    var body: some View {
        switch status {
        case .pending:
            label(L10n.t("entry.status.pending"), background: .secondary)
        case .extracting:
            HStack(spacing: 4) {
                ProgressView().controlSize(.mini)
                label(L10n.t("entry.status.extracting"), background: .blue)
            }
        case .failed:
            label(L10n.t("entry.status.failed"), background: .orange)
        case .extracted:
            EmptyView()
        }
    }

    private func label(_ text: String, background: Color) -> some View {
        Text(text)
            .font(.caption2)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(background.opacity(0.18))
            .foregroundStyle(background)
            .clipShape(Capsule())
    }
}
